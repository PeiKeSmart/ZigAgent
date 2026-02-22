/// service.zig — 跨平台服务安装 / 卸载 / 管理
///
/// Linux  : 生成 systemd .service 文件，调用 systemctl 操作
/// Windows: 调用 sc.exe 命令行工具完成安装/卸载，net start/stop 管理
const std = @import("std");
const builtin = @import("builtin");
const agent = @import("agent.zig");

/// 服务操作结果
pub const Result = union(enum) {
    ok: []const u8,
    err: []const u8,
};

// ─────────────────────────────────────────────────────────────────────────────
// 公共接口
// ─────────────────────────────────────────────────────────────────────────────

/// 查询服务当前状态，返回描述字符串（调用者需 free）
pub fn getStatus(allocator: std.mem.Allocator, config: agent.Config) ![]u8 {
    return switch (builtin.os.tag) {
        .linux => getStatusLinux(allocator, config),
        .windows => getStatusWindows(allocator, config),
        else => try allocator.dupe(u8, "不支持当前操作系统"),
    };
}

/// 安装并启用服务（开机自启）
pub fn install(allocator: std.mem.Allocator, config: agent.Config, exe_path: []const u8) !Result {
    return switch (builtin.os.tag) {
        .linux => installLinux(allocator, config, exe_path),
        .windows => installWindows(allocator, config, exe_path),
        else => Result{ .err = "不支持当前操作系统" },
    };
}

/// 卸载服务
pub fn uninstall(allocator: std.mem.Allocator, config: agent.Config) !Result {
    return switch (builtin.os.tag) {
        .linux => uninstallLinux(allocator, config),
        .windows => uninstallWindows(allocator, config),
        else => Result{ .err = "不支持当前操作系统" },
    };
}

/// 启动服务
pub fn start(allocator: std.mem.Allocator, config: agent.Config) !Result {
    return switch (builtin.os.tag) {
        .linux => runSystemctl(allocator, "start", config.service_name),
        .windows => runSc(allocator, "start", config.service_name),
        else => Result{ .err = "不支持当前操作系统" },
    };
}

/// 停止服务
pub fn stop(allocator: std.mem.Allocator, config: agent.Config) !Result {
    return switch (builtin.os.tag) {
        .linux => runSystemctl(allocator, "stop", config.service_name),
        .windows => runSc(allocator, "stop", config.service_name),
        else => Result{ .err = "不支持当前操作系统" },
    };
}

/// 检查是否以管理员/root 权限运行
pub fn isAdmin() bool {
    return switch (builtin.os.tag) {
        .windows => isAdminWindows(),
        .linux, .macos => std.posix.getuid() == 0,
        else => false,
    };
}

/// 以提升权限重新运行当前程序并等待完成
/// exe_path: 当前可执行路径；arg: 传给新进程的参数（如 "-i"、"-u"，菜单模式传空字符串）
/// wait: true = 等待子进程结束（CLI 操作）；false = 启动后立即返回（菜单整体提权）
/// 返回 true 表示成功发起提权（wait=false 时不代表操作已完成）
pub fn relaunchElevated(allocator: std.mem.Allocator, exe_path: []const u8, arg: []const u8, wait: bool) !bool {
    return switch (builtin.os.tag) {
        .windows => relaunchElevatedWindows(allocator, exe_path, arg, wait),
        .linux, .macos => relaunchElevatedUnix(allocator, exe_path, arg),
        else => false,
    };
}

/// Windows: 通过 advapi32 令牌检查提升状态
fn isAdminWindows() bool {
    const w = std.os.windows;
    const winapi = std.builtin.CallingConvention.winapi;

    // 在函数作用域内声明 advapi32 导入，避免非 Windows 平台编译报错
    const OpenProcessToken = struct {
        extern "advapi32" fn OpenProcessToken(
            ProcessHandle: w.HANDLE,
            DesiredAccess: w.DWORD,
            TokenHandle: *w.HANDLE,
        ) callconv(winapi) w.BOOL;
    }.OpenProcessToken;

    const GetTokenInformation = struct {
        extern "advapi32" fn GetTokenInformation(
            TokenHandle: w.HANDLE,
            TokenInformationClass: w.DWORD,
            TokenInformation: *anyopaque,
            TokenInformationLength: w.DWORD,
            ReturnLength: *w.DWORD,
        ) callconv(winapi) w.BOOL;
    }.GetTokenInformation;

    const CloseHandle = struct {
        extern "kernel32" fn CloseHandle(hObject: w.HANDLE) callconv(winapi) w.BOOL;
    }.CloseHandle;

    var token: w.HANDLE = undefined;
    const TOKEN_QUERY: w.DWORD = 0x0008;
    if (OpenProcessToken(w.kernel32.GetCurrentProcess(), TOKEN_QUERY, &token) == 0) {
        return false;
    }
    defer _ = CloseHandle(token);

    var elevation: w.DWORD = 0;
    var ret_len: w.DWORD = 0;
    // TokenElevation = 20
    if (GetTokenInformation(token, 20, @ptrCast(&elevation), @sizeOf(w.DWORD), &ret_len) == 0) {
        return false;
    }
    return elevation != 0;
}

/// Windows: 通过 ShellExecuteExW + runas verb 直接触发 UAC，无需 PowerShell 中转。
/// wait=false（菜单整体提权）：新进程可见，当前进程立即返回。
/// wait=true（CLI 单次操作）：隐藏新进程，等待其完成后返回结果。
fn relaunchElevatedWindows(allocator: std.mem.Allocator, exe_path: []const u8, arg: []const u8, wait: bool) !bool {
    const w = std.os.windows;
    const winapi = std.builtin.CallingConvention.winapi;

    // SHELLEXECUTEINFOW 结构体（完整布局，匹配 shellapi.h）
    const SHELLEXECUTEINFOW = extern struct {
        cbSize: w.DWORD,
        fMask: w.ULONG,
        hwnd: ?*anyopaque,
        lpVerb: ?[*:0]const u16,
        lpFile: ?[*:0]const u16,
        lpParameters: ?[*:0]const u16,
        lpDirectory: ?[*:0]const u16,
        nShow: c_int,
        hInstApp: ?*anyopaque,
        lpIDList: ?*anyopaque,
        lpClass: ?[*:0]const u16,
        hkeyClass: ?*anyopaque,
        dwHotKey: w.DWORD,
        hIconOrMonitor: ?w.HANDLE,
        hProcess: ?w.HANDLE,
    };

    const ShellExecuteExW = struct {
        extern "shell32" fn ShellExecuteExW(pExecInfo: *SHELLEXECUTEINFOW) callconv(winapi) w.BOOL;
    }.ShellExecuteExW;

    const WaitForSingleObject = struct {
        extern "kernel32" fn WaitForSingleObject(hHandle: w.HANDLE, dwMilliseconds: w.DWORD) callconv(winapi) w.DWORD;
    }.WaitForSingleObject;

    const CloseHandle = struct {
        extern "kernel32" fn CloseHandle(hObject: w.HANDLE) callconv(winapi) w.BOOL;
    }.CloseHandle;

    // SEE_MASK_NOCLOSEPROCESS: 保持 hProcess 有效供 WaitForSingleObject 使用
    const SEE_MASK_NOCLOSEPROCESS: w.ULONG = 0x00000040;
    // wait=false 菜单模式：SW_SHOWNORMAL 让新的管理员窗口正常显示
    // wait=true  CLI 模式：SW_HIDE 静默执行
    const SW_SHOWNORMAL: c_int = 1;
    const SW_HIDE: c_int = 0;
    const nShow: c_int = if (wait) SW_HIDE else SW_SHOWNORMAL;
    const INFINITE: w.DWORD = 0xFFFFFFFF;

    // UTF-8 → UTF-16LE（WinAPI 宽字符）
    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, exe_path);
    defer allocator.free(exe_w);
    const arg_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, arg);
    defer allocator.free(arg_w);
    // "runas" verb 触发 UAC 提权
    const verb_w = comptime std.unicode.utf8ToUtf16LeStringLiteral("runas");

    var sei = SHELLEXECUTEINFOW{
        .cbSize = @sizeOf(SHELLEXECUTEINFOW),
        .fMask = SEE_MASK_NOCLOSEPROCESS,
        .hwnd = null,
        .lpVerb = verb_w,
        .lpFile = exe_w.ptr,
        .lpParameters = arg_w.ptr,
        .lpDirectory = null,
        .nShow = nShow,
        .hInstApp = null,
        .lpIDList = null,
        .lpClass = null,
        .hkeyClass = null,
        .dwHotKey = 0,
        .hIconOrMonitor = null,
        .hProcess = null,
    };

    if (ShellExecuteExW(&sei) == 0) {
        return false; // UAC 被拒绝或调用失败
    }

    if (sei.hProcess) |hProc| {
        if (wait) {
            // CLI 模式：等待子进程完成再返回结果
            _ = WaitForSingleObject(hProc, INFINITE);
        }
        _ = CloseHandle(hProc);
    }

    return true;
}

/// Linux/macOS: 用 sudo 重新运行当前程序（继承终端，用户可输入密码）
fn relaunchElevatedUnix(allocator: std.mem.Allocator, exe_path: []const u8, arg: []const u8) !bool {
    var child = std.process.Child.init(
        &[_][]const u8{ "sudo", exe_path, arg },
        allocator,
    );
    // 继承 stdin/stdout/stderr，sudo 密码提示正常显示
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    return term == .Exited and term.Exited == 0;
}

/// 检查服务是否正在运行
pub fn isRunning(allocator: std.mem.Allocator, config: agent.Config) bool {
    return switch (builtin.os.tag) {
        .linux => isRunningLinux(config),
        .windows => isRunningWindows(allocator, config),
        else => false,
    };
}

fn isRunningLinux(config: agent.Config) bool {
    // systemctl is-active 退出码 0 = active
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "systemctl", "is-active", config.service_name },
    }) catch return false;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    return result.term == .Exited and result.term.Exited == 0;
}

fn isRunningWindows(allocator: std.mem.Allocator, config: agent.Config) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sc", "queryex", config.service_name },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    // STATE: 4 = RUNNING（数字码与系统语言无关）
    return std.mem.indexOf(u8, result.stdout, ": 4 ") != null or
        std.mem.indexOf(u8, result.stdout, ":  4 ") != null;
}

/// 检查服务是否已安装
pub fn isInstalled(allocator: std.mem.Allocator, config: agent.Config) bool {
    return switch (builtin.os.tag) {
        .linux => isInstalledLinux(config),
        .windows => isInstalledWindows(allocator, config),
        else => false,
    };
}

fn isInstalledLinux(config: agent.Config) bool {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/etc/systemd/system/{s}.service", .{config.service_name}) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn isInstalledWindows(allocator: std.mem.Allocator, config: agent.Config) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sc", "queryex", config.service_name },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    // 退出码 1060 = 未安装（与语言无关）
    if (result.term == .Exited and result.term.Exited == 1060) return false;
    return result.term == .Exited and result.term.Exited == 0;
}

/// 重启服务
pub fn restart(allocator: std.mem.Allocator, config: agent.Config) !Result {
    return switch (builtin.os.tag) {
        .linux => runSystemctl(allocator, "restart", config.service_name),
        .windows => restartWindows(allocator, config),
        else => Result{ .err = "不支持当前操作系统" },
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Linux / systemd 实现
// ─────────────────────────────────────────────────────────────────────────────

fn getStatusLinux(allocator: std.mem.Allocator, config: agent.Config) ![]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "systemctl", "is-active", config.service_name },
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "查询失败: {}", .{err});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const status = std.mem.trimRight(u8, result.stdout, &[_]u8{ '\n', '\r', ' ' });
    if (std.mem.eql(u8, status, "active")) {
        return try std.fmt.allocPrint(allocator, "systemd \x1b[32m运行中\x1b[0m", .{});
    } else if (std.mem.eql(u8, status, "inactive")) {
        return try std.fmt.allocPrint(allocator, "systemd \x1b[33m已停止\x1b[0m", .{});
    } else {
        return try std.fmt.allocPrint(allocator, "systemd {s}", .{status});
    }
}

fn installLinux(allocator: std.mem.Allocator, config: agent.Config, exe_path: []const u8) !Result {
    // 生成 .service 文件内容
    const service_content = try std.fmt.allocPrint(
        allocator,
        \\[Unit]
        \\Description={s}
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s} -s
        \\Restart=on-failure
        \\RestartSec=5
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    ,
        .{ config.description, exe_path },
    );
    defer allocator.free(service_content);

    // 写入 /etc/systemd/system/<name>.service
    const service_path = try std.fmt.allocPrint(
        allocator,
        "/etc/systemd/system/{s}.service",
        .{config.service_name},
    );
    defer allocator.free(service_path);

    var file = std.fs.createFileAbsolute(service_path, .{}) catch |err| {
        return Result{ .err = try std.fmt.allocPrint(allocator, "写入服务文件失败（需要 root）: {}", .{err}) };
    };
    defer file.close();
    try file.writeAll(service_content);

    // systemctl daemon-reload
    _ = try runSystemctl(allocator, "daemon-reload", "");
    // systemctl enable
    var r = try runSystemctl(allocator, "enable", config.service_name);
    if (r == .err) return r;
    // systemctl start
    r = try runSystemctl(allocator, "start", config.service_name);
    if (r == .err) return r;

    return Result{ .ok = try std.fmt.allocPrint(allocator, "服务 [{s}] 已安装并启动", .{config.service_name}) };
}

fn uninstallLinux(allocator: std.mem.Allocator, config: agent.Config) !Result {
    _ = try runSystemctl(allocator, "stop", config.service_name);
    _ = try runSystemctl(allocator, "disable", config.service_name);

    const service_path = try std.fmt.allocPrint(
        allocator,
        "/etc/systemd/system/{s}.service",
        .{config.service_name},
    );
    defer allocator.free(service_path);

    std.fs.deleteFileAbsolute(service_path) catch {};
    _ = try runSystemctl(allocator, "daemon-reload", "");

    return Result{ .ok = try std.fmt.allocPrint(allocator, "服务 [{s}] 已卸载", .{config.service_name}) };
}

/// 执行 systemctl <action> [unit]
fn runSystemctl(allocator: std.mem.Allocator, action: []const u8, unit: []const u8) !Result {
    const argv: []const []const u8 = if (unit.len > 0)
        &[_][]const u8{ "systemctl", action, unit }
    else
        &[_][]const u8{ "systemctl", action };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch |err| {
        return Result{ .err = try std.fmt.allocPrint(allocator, "systemctl {s} 失败: {}", .{ action, err }) };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) {
        return Result{ .ok = try std.fmt.allocPrint(allocator, "systemctl {s} 成功", .{action}) };
    }
    return Result{ .err = try std.fmt.allocPrint(allocator, "systemctl {s} 退出码 {d}: {s}", .{ action, result.term.Exited, result.stderr }) };
}

// ─────────────────────────────────────────────────────────────────────────────
// Windows / sc.exe 实现
// ─────────────────────────────────────────────────────────────────────────────

fn getStatusWindows(allocator: std.mem.Allocator, config: agent.Config) ![]u8 {
    // sc queryex 退出码与系统语言无关：0=存在 1060=未安装
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sc", "queryex", config.service_name },
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "查询失败: {}", .{err});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // 退出码非零均视为未安装（1060=明确未安装，其他非零=异常/过渡态，与 isInstalledWindows 保持一致）
    if (!(result.term == .Exited and result.term.Exited == 0)) {
        return try std.fmt.allocPrint(allocator, "\x1b[31m未安装\x1b[0m", .{});
    }

    // STATE 数字与语言无关：1=已停止 2=启动中 3=停止中 4=运行 5=继续中 6=暂停中 7=已暂停
    if (std.mem.indexOf(u8, result.stdout, ": 4 ") != null or
        std.mem.indexOf(u8, result.stdout, ":  4 ") != null)
    {
        return try std.fmt.allocPrint(allocator, "Windows 服务 \x1b[32m运行中\x1b[0m", .{});
    } else if (std.mem.indexOf(u8, result.stdout, ": 1 ") != null or
        std.mem.indexOf(u8, result.stdout, ":  1 ") != null)
    {
        return try std.fmt.allocPrint(allocator, "Windows 服务 \x1b[33m已停止\x1b[0m", .{});
    } else if (std.mem.indexOf(u8, result.stdout, ": 2 ") != null or
        std.mem.indexOf(u8, result.stdout, ": 5 ") != null)
    {
        return try std.fmt.allocPrint(allocator, "Windows 服务 \x1b[33m启动中...\x1b[0m", .{});
    } else if (std.mem.indexOf(u8, result.stdout, ": 3 ") != null or
        std.mem.indexOf(u8, result.stdout, ": 6 ") != null)
    {
        return try std.fmt.allocPrint(allocator, "Windows 服务 \x1b[33m停止中...\x1b[0m", .{});
    } else if (std.mem.indexOf(u8, result.stdout, ": 7 ") != null) {
        return try std.fmt.allocPrint(allocator, "Windows 服务 \x1b[33m已暂停\x1b[0m", .{});
    }
    // 退出码为0但输出无法识别STATE（极少见）
    return try std.fmt.allocPrint(allocator, "Windows 服务 \x1b[33m状态未知\x1b[0m", .{});
}

fn installWindows(allocator: std.mem.Allocator, config: agent.Config, exe_path: []const u8) !Result {
    // binpath 需合并为单个参数，sc.exe 按 key=value 解析，value 含空格须带引号
    const bin_val = try std.fmt.allocPrint(allocator, "binpath=\"{s}\" -s", .{exe_path});
    defer allocator.free(bin_val);

    // sc create <name> binpath="<exe> -s" start=auto obj=LocalSystem
    const create_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "sc",    "create",     config.service_name,
            bin_val, "start=auto", "obj=LocalSystem",
        },
    }) catch |err| {
        return Result{ .err = try std.fmt.allocPrint(allocator, "sc create 失败: {}", .{err}) };
    };
    defer allocator.free(create_result.stdout);
    defer allocator.free(create_result.stderr);

    if (create_result.term == .Exited and create_result.term.Exited != 0) {
        const hint: []const u8 = if (create_result.term.Exited == 5)
            "（权限不足，请以管理员身份运行）"
        else
            "";
        return Result{ .err = try std.fmt.allocPrint(
            allocator,
            "sc create 失败 (退出码 {d}){s}",
            .{ create_result.term.Exited, hint },
        ) };
    }

    // sc description <name> "<desc>"
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sc", "description", config.service_name, config.description },
    }) catch {};

    return Result{ .ok = try std.fmt.allocPrint(allocator, "服务 [{s}] 安装成功（可按 3 启动）", .{config.service_name}) };
}

fn uninstallWindows(allocator: std.mem.Allocator, config: agent.Config) !Result {
    // 先停止
    _ = try runSc(allocator, "stop", config.service_name);
    // 轮询等待服务真正停止（最多 10 秒），避免 DELETE_PENDING 残留
    var waited_ms: u32 = 0;
    while (waited_ms < 10_000) : (waited_ms += 500) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        const s = try getStatusWindows(allocator, config);
        const stopped = std.mem.indexOf(u8, s, "已停止") != null or
            std.mem.indexOf(u8, s, "未安装") != null;
        allocator.free(s);
        if (stopped) break;
    }
    // 再删除
    return runSc(allocator, "delete", config.service_name);
}

fn restartWindows(allocator: std.mem.Allocator, config: agent.Config) !Result {
    // 先停止（服务已停止时 sc stop 返回非0，忽略错误继续）
    _ = try runSc(allocator, "stop", config.service_name);
    // 轮询等待服务真正停止（最多 10 秒）
    var waited_ms: u32 = 0;
    while (waited_ms < 10_000) : (waited_ms += 500) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        const s = try getStatusWindows(allocator, config);
        const stopped = std.mem.indexOf(u8, s, "已停止") != null;
        allocator.free(s);
        if (stopped) break;
    }
    return runSc(allocator, "start", config.service_name);
}

/// 执行 sc <action> <name>
fn runSc(allocator: std.mem.Allocator, action: []const u8, name: []const u8) !Result {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sc", action, name },
    }) catch |err| {
        return Result{ .err = try std.fmt.allocPrint(allocator, "sc {s} 失败: {}", .{ action, err }) };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) {
        return Result{ .ok = try std.fmt.allocPrint(allocator, "sc {s} [{s}] 成功", .{ action, name }) };
    }
    return Result{ .err = try std.fmt.allocPrint(allocator, "sc {s} 失败 (退出码 {d})\n{s}", .{ action, result.term.Exited, result.stderr }) };
}

// ─────────────────────────────────────────────────────────────────────────────
// 服务运行入口（供 main.zig -s 模式调用）
// ─────────────────────────────────────────────────────────────────────────────

/// 以服务方式运行 Agent：
/// - Windows: 向 SCM 注册 ServiceMain / CtrlHandler，正确响应启动/停止指令
/// - Linux:   直接运行（由 systemd 管理生命周期）
pub fn runAsService(config: agent.Config) void {
    switch (builtin.os.tag) {
        .windows => runAsServiceWindows(config),
        else => agent.run(config),
    }
}

// ─── Windows SCM 集成 ─────────────────────────────────────────────────────────
//
// Windows 服务必须通过以下流程与 SCM 握手，否则启动超时（错误29）：
//   1. StartServiceCtrlDispatcherW → SCM 在新线程调用 ServiceMain
//   2. ServiceMain: RegisterServiceCtrlHandlerExW → SetServiceStatus(START_PENDING)
//      → [初始化] → SetServiceStatus(RUNNING) → WaitForSingleObject(停止事件)
//      → SetServiceStatus(STOPPED)
//   3. HandlerEx: 收到 STOP/SHUTDOWN 信号 → 设置 stop_signal + SetEvent(停止事件)

// 全局变量（Windows 回调机制必须）
var g_status_handle: if (builtin.os.tag == .windows) std.os.windows.HANDLE else void =
    if (builtin.os.tag == .windows) undefined else {};
var g_stop_event: if (builtin.os.tag == .windows) std.os.windows.HANDLE else void =
    if (builtin.os.tag == .windows) undefined else {};
var g_svc_config: agent.Config = agent.default_config;

fn runAsServiceWindows(config: agent.Config) void {
    const w = std.os.windows;
    const winapi = std.builtin.CallingConvention.winapi;

    // SERVICE_STATUS 结构体
    const SERVICE_STATUS = extern struct {
        dwServiceType: w.DWORD,
        dwCurrentState: w.DWORD,
        dwControlsAccepted: w.DWORD,
        dwWin32ExitCode: w.DWORD,
        dwServiceSpecificExitCode: w.DWORD,
        dwCheckPoint: w.DWORD,
        dwWaitHint: w.DWORD,
    };

    // SERVICE_TABLE_ENTRYW 结构体
    const SERVICE_TABLE_ENTRYW = extern struct {
        lpServiceName: ?[*:0]const u16,
        lpServiceProc: ?*const fn (w.DWORD, [*][*:0]u16) callconv(winapi) void,
    };

    const StartServiceCtrlDispatcherW = struct {
        extern "advapi32" fn StartServiceCtrlDispatcherW(
            lpServiceStartTable: [*]const SERVICE_TABLE_ENTRYW,
        ) callconv(winapi) w.BOOL;
    }.StartServiceCtrlDispatcherW;

    // 传递配置给 ServiceMain 回调（通过全局变量）
    g_svc_config = config;

    // ServiceMain 回调：由 SCM 在独立线程调用
    const serviceMain = struct {
        fn f(_argc: w.DWORD, _argv: [*][*:0]u16) callconv(winapi) void {
            _ = _argc;
            _ = _argv;

            const winapi2 = std.builtin.CallingConvention.winapi;
            const w2 = std.os.windows;

            // 服务状态常量
            const SERVICE_WIN32_OWN_PROCESS: w2.DWORD = 0x00000010;
            const SERVICE_RUNNING: w2.DWORD = 4;
            const SERVICE_START_PENDING: w2.DWORD = 2;
            const SERVICE_STOPPED: w2.DWORD = 1;
            const SERVICE_ACCEPT_STOP: w2.DWORD = 0x00000001;
            const SERVICE_ACCEPT_SHUTDOWN: w2.DWORD = 0x00000004;
            const INFINITE2: w2.DWORD = 0xFFFFFFFF;
            const NO_ERROR: w2.DWORD = 0;

            const RegisterServiceCtrlHandlerExW = struct {
                extern "advapi32" fn RegisterServiceCtrlHandlerExW(
                    lpServiceName: [*:0]const u16,
                    lpHandlerProc: *const fn (w2.DWORD, w2.DWORD, ?*anyopaque, ?*anyopaque) callconv(winapi2) w2.DWORD,
                    lpContext: ?*anyopaque,
                ) callconv(winapi2) ?w2.HANDLE;
            }.RegisterServiceCtrlHandlerExW;

            const SetServiceStatus2 = struct {
                extern "advapi32" fn SetServiceStatus(
                    hServiceStatus: w2.HANDLE,
                    lpServiceStatus: *SERVICE_STATUS,
                ) callconv(winapi2) w2.BOOL;
            }.SetServiceStatus;

            const CreateEventW = struct {
                extern "kernel32" fn CreateEventW(
                    lpEventAttributes: ?*anyopaque,
                    bManualReset: w2.BOOL,
                    bInitialState: w2.BOOL,
                    lpName: ?[*:0]const u16,
                ) callconv(winapi2) ?w2.HANDLE;
            }.CreateEventW;

            const WaitForSingleObject2 = struct {
                extern "kernel32" fn WaitForSingleObject(
                    hHandle: w2.HANDLE,
                    dwMilliseconds: w2.DWORD,
                ) callconv(winapi2) w2.DWORD;
            }.WaitForSingleObject;

            const CloseHandle2 = struct {
                extern "kernel32" fn CloseHandle(hObject: w2.HANDLE) callconv(winapi2) w2.BOOL;
            }.CloseHandle;

            // 控制处理器（HandlerEx）
            const handlerEx = struct {
                fn h(control: w2.DWORD, _et: w2.DWORD, _ed: ?*anyopaque, _ctx: ?*anyopaque) callconv(winapi2) w2.DWORD {
                    _ = _et;
                    _ = _ed;
                    _ = _ctx;

                    const winapi3 = std.builtin.CallingConvention.winapi;
                    const w3 = std.os.windows;
                    const SERVICE_CONTROL_STOP: w3.DWORD = 0x00000001;
                    const SERVICE_CONTROL_SHUTDOWN: w3.DWORD = 0x00000005;
                    const SERVICE_STOP_PENDING2: w3.DWORD = 3;
                    const NO_ERROR2: w3.DWORD = 0;

                    const SetServiceStatus3 = struct {
                        extern "advapi32" fn SetServiceStatus(
                            hServiceStatus: w3.HANDLE,
                            lpServiceStatus: *SERVICE_STATUS,
                        ) callconv(winapi3) w3.BOOL;
                    }.SetServiceStatus;

                    const SetEvent2 = struct {
                        extern "kernel32" fn SetEvent(hEvent: w3.HANDLE) callconv(winapi3) w3.BOOL;
                    }.SetEvent;

                    switch (control) {
                        SERVICE_CONTROL_STOP, SERVICE_CONTROL_SHUTDOWN => {
                            // 上报"停止中"
                            var ss = SERVICE_STATUS{
                                .dwServiceType = 0x00000010,
                                .dwCurrentState = SERVICE_STOP_PENDING2,
                                .dwControlsAccepted = 0,
                                .dwWin32ExitCode = 0,
                                .dwServiceSpecificExitCode = 0,
                                .dwCheckPoint = 1,
                                .dwWaitHint = 5000,
                            };
                            _ = SetServiceStatus3(g_status_handle, &ss);
                            // 通知 agent.run 停止
                            agent.stop_signal.store(true, .release);
                            // 触发停止事件，解除 WaitForSingleObject
                            _ = SetEvent2(g_stop_event);
                        },
                        else => {},
                    }
                    return NO_ERROR2;
                }
            }.h;

            // 服务名称转 UTF-16
            var name_buf: [256:0]u16 = undefined;
            const name_len = std.unicode.utf8ToUtf16Le(
                name_buf[0..255],
                g_svc_config.service_name,
            ) catch 0;
            name_buf[name_len] = 0;

            // 注册控制处理器
            const handle = RegisterServiceCtrlHandlerExW(&name_buf, handlerEx, null) orelse {
                return; // 注册失败，退出（SCM 会标记服务启动失败）
            };
            g_status_handle = handle;

            // 上报 START_PENDING
            var status = SERVICE_STATUS{
                .dwServiceType = SERVICE_WIN32_OWN_PROCESS,
                .dwCurrentState = SERVICE_START_PENDING,
                .dwControlsAccepted = 0,
                .dwWin32ExitCode = NO_ERROR,
                .dwServiceSpecificExitCode = NO_ERROR,
                .dwCheckPoint = 1,
                .dwWaitHint = 3000,
            };
            _ = SetServiceStatus2(g_status_handle, &status);

            // 创建手动重置的停止事件
            g_stop_event = CreateEventW(null, 1, 0, null) orelse {
                status.dwCurrentState = SERVICE_STOPPED;
                status.dwWin32ExitCode = 1;
                _ = SetServiceStatus2(g_status_handle, &status);
                return;
            };
            defer _ = CloseHandle2(g_stop_event);

            // 重置停止信号
            agent.stop_signal.store(false, .release);

            // 上报 RUNNING（SCM 确认服务已启动）
            status.dwCurrentState = SERVICE_RUNNING;
            status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
            status.dwCheckPoint = 0;
            status.dwWaitHint = 0;
            _ = SetServiceStatus2(g_status_handle, &status);

            // 在独立线程运行 agent 主循环，避免阻塞 ServiceMain
            const t = std.Thread.spawn(.{}, agent.run, .{g_svc_config}) catch {
                status.dwCurrentState = SERVICE_STOPPED;
                status.dwWin32ExitCode = 1;
                _ = SetServiceStatus2(g_status_handle, &status);
                return;
            };

            // 等待停止事件（CtrlHandler 会触发）
            _ = WaitForSingleObject2(g_stop_event, INFINITE2);

            // 等待 agent 线程退出
            t.join();

            // 上报 STOPPED
            status.dwCurrentState = SERVICE_STOPPED;
            status.dwControlsAccepted = 0;
            status.dwCheckPoint = 0;
            status.dwWaitHint = 0;
            status.dwWin32ExitCode = NO_ERROR;
            _ = SetServiceStatus2(g_status_handle, &status);
        }
    }.f;

    // 构建 ServiceTable：末尾必须是 null 哨兵
    const table = [_]SERVICE_TABLE_ENTRYW{
        .{
            .lpServiceName = std.unicode.utf8ToUtf16LeStringLiteral("StarAgent"),
            .lpServiceProc = serviceMain,
        },
        .{ .lpServiceName = null, .lpServiceProc = null }, // 终止符
    };

    // StartServiceCtrlDispatcherW 阻塞，直到所有服务退出
    _ = StartServiceCtrlDispatcherW(&table);
}
