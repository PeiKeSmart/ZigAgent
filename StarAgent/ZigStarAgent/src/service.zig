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
/// exe_path: 当前可执行路径；arg: 传给新进程的参数（如 "-i"、"-u"）
/// 返回 true 表示提权进程正常退出
pub fn relaunchElevated(allocator: std.mem.Allocator, exe_path: []const u8, arg: []const u8) !bool {
    return switch (builtin.os.tag) {
        .windows => relaunchElevatedWindows(allocator, exe_path, arg),
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

/// Windows: 通过 PowerShell Start-Process -Verb RunAs 触发 UAC，等待提权进程完成
fn relaunchElevatedWindows(allocator: std.mem.Allocator, exe_path: []const u8, arg: []const u8) !bool {
    // 路径用双引号包裹，防止含空格的路径出错
    const ps_cmd = try std.fmt.allocPrint(
        allocator,
        "Start-Process -FilePath \"{s}\" -ArgumentList \"{s}\" -Verb RunAs -Wait",
        .{ exe_path, arg },
    );
    defer allocator.free(ps_cmd);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "powershell",   "-NoProfile", "-NonInteractive",
            "-WindowStyle", "Hidden",     "-Command",
            ps_cmd,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term == .Exited and result.term.Exited == 0;
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
        .argv = &[_][]const u8{ "sc", "query", config.service_name },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    // 错误码 1060 表示服务不存在
    if (std.mem.indexOf(u8, result.stdout, "1060") != null or
        std.mem.indexOf(u8, result.stderr, "1060") != null)
    {
        return false;
    }
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
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sc", "query", config.service_name },
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "查询失败: {}", .{err});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (std.mem.indexOf(u8, result.stdout, "RUNNING") != null) {
        return try std.fmt.allocPrint(allocator, "Windows 服务 \x1b[32m运行中\x1b[0m", .{});
    } else if (std.mem.indexOf(u8, result.stdout, "STOPPED") != null) {
        return try std.fmt.allocPrint(allocator, "Windows 服务 \x1b[33m已停止\x1b[0m", .{});
    } else if (std.mem.indexOf(u8, result.stdout, "1060") != null or
        std.mem.indexOf(u8, result.stderr, "1060") != null)
    {
        return try std.fmt.allocPrint(allocator, "\x1b[31m未安装\x1b[0m", .{});
    }
    return try std.fmt.allocPrint(allocator, "未知状态", .{});
}

fn installWindows(allocator: std.mem.Allocator, config: agent.Config, exe_path: []const u8) !Result {
    // 构造 binpath 值：带引号的可执行路径 + 服务参数
    const bin_val = try std.fmt.allocPrint(allocator, "\"{s}\" -s", .{exe_path});
    defer allocator.free(bin_val);

    // sc create <name> binpath= "<exe> -s" start= auto
    const create_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "sc",       "create", config.service_name,
            "binpath=", bin_val,  "start=",
            "auto",     "obj=",   "LocalSystem",
        },
    }) catch |err| {
        return Result{ .err = try std.fmt.allocPrint(allocator, "sc create 失败: {}", .{err}) };
    };
    defer allocator.free(create_result.stdout);
    defer allocator.free(create_result.stderr);

    if (create_result.term == .Exited and create_result.term.Exited != 0) {
        return Result{ .err = try std.fmt.allocPrint(
            allocator,
            "sc create 失败 (需要管理员权限, 退出码 {d}): {s}",
            .{ create_result.term.Exited, create_result.stderr },
        ) };
    }

    // sc description <name> "<desc>"
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sc", "description", config.service_name, config.description },
    }) catch {};

    // sc start <name>
    return runSc(allocator, "start", config.service_name);
}

fn uninstallWindows(allocator: std.mem.Allocator, config: agent.Config) !Result {
    // 先停止
    _ = try runSc(allocator, "stop", config.service_name);
    // 再删除
    return runSc(allocator, "delete", config.service_name);
}

fn restartWindows(allocator: std.mem.Allocator, config: agent.Config) !Result {
    _ = try runSc(allocator, "stop", config.service_name);
    std.Thread.sleep(2 * std.time.ns_per_s);
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
