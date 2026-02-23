/// main.zig — StarAgent 入口
///
/// 直接运行 → 显示交互式菜单
/// 传入 -s / --service → 以服务模式静默运行（由服务管理器调用）
/// 传入 --install / --uninstall 等 → 执行对应服务操作后退出
const std = @import("std");
const builtin = @import("builtin");

const zzig = @import("zzig");
const Console = zzig.Console;

const agent = @import("agent.zig");
const service = @import("service.zig");
const cfg_mod = @import("config.zig");
const logmod = @import("log.zig");
const input = zzig.Input; // 使用 zzig 库中的跨平台单键输入模块

// ─── 日志覆盖 ─────────────────────────────────────────────────────────────────
// 将所有 std.log.* 调用重定向到文件日志（服务模式下无控制台，需持久化）
pub const std_options: std.Options = .{ .logFn = logmod.logFn };

// ─── ANSI 颜色快捷 ───────────────────────────────────────────────────────────
const reset = "\x1b[0m";
const bold = "\x1b[1m";
const cyan = "\x1b[36m";
const yellow = "\x1b[33m";
const green = "\x1b[32m";
const red = "\x1b[31m";
const bright_yellow = "\x1b[93m";
const bright_cyan = "\x1b[96m";
const bright_green = "\x1b[92m";

// 菜单选项按安装状态动态构建，见 buildMenuItems()

pub fn main() !void {
    // 初始化内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化控制台（UTF-8 + ANSI）
    const console_result = Console.init(.{});
    defer Console.deinit(console_result);

    // 获取当前可执行路径
    const exe_path = std.fs.selfExePathAlloc(allocator) catch "<unknown>";
    defer if (!std.mem.eql(u8, exe_path, "<unknown>")) allocator.free(exe_path);

    // ── 初始化文件日志 ────────────────────────────────────────────────────────
    // 日志文件与可执行文件放在同一目录，命名为 StarAgent.log
    const app_dir: []const u8 = if (!std.mem.eql(u8, exe_path, "<unknown>"))
        (std.fs.path.dirname(exe_path) orelse ".")
    else
        ".";
    const log_path = std.fs.path.join(allocator, &.{ app_dir, "StarAgent.log" }) catch null;
    defer if (log_path) |p| allocator.free(p);
    if (log_path) |p| {
        // JSON 配置文件与日志文件同目录，名为 StarAgent.logger.json
        const cfg_json = std.fs.path.join(allocator, &.{ app_dir, "StarAgent.logger.json" }) catch null;
        defer if (cfg_json) |c| allocator.free(c);
        const json_path = cfg_json orelse "StarAgent.logger.json";
        // .both = 同时写文件和 stderr；服务模式无控制台时 stderr 部分静默失败，文件正常写入
        logmod.init(allocator, p, json_path, .both) catch |err| {
            std.debug.print("[main] 日志初始化失败: {}\n", .{err});
        };
    }
    defer logmod.deinit();

    // ── 加载 StarAgent.xml 配置文件 ───────────────────────────────────────────
    // 配置文件与可执行文件放在同一目录；首次运行自动生成默认配置
    const config_path = blk: {
        if (!std.mem.eql(u8, exe_path, "<unknown>")) {
            const dir = std.fs.path.dirname(exe_path) orelse ".";
            break :blk try std.fs.path.join(allocator, &.{ dir, "StarAgent.xml" });
        }
        break :blk try allocator.dupe(u8, "StarAgent.xml");
    };
    defer allocator.free(config_path);

    // 若不存在则生成默认配置文件
    cfg_mod.ensureDefault(allocator, config_path) catch |err| {
        std.log.warn("[main] 生成默认配置失败: {}", .{err});
    };

    // 加载配置
    var cfg_result = cfg_mod.load(allocator, config_path) catch |err| blk: {
        std.log.warn("[main] 加载配置失败 ({})，使用默认值", .{err});
        break :blk cfg_mod.ConfigResult{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .config = cfg_mod.Config{},
        };
    };
    defer cfg_result.deinit();
    const star_cfg = cfg_result.config;

    // 从 XML 配置构建 Agent 服务元数据
    const config = agent.Config{
        .debug = star_cfg.debug,
        .local_port = star_cfg.local_port,
        .delay_ms = star_cfg.delay,
        // services 生命周期由 cfg_result.arena 管理，在 main 返回前始终有效
        .services = star_cfg.services,
        // 以下字段保持默认（服务名/描述不随 XML 更改，保持平台注册稳定）
        .service_name = agent.default_config.service_name,
        .display_name = agent.default_config.display_name,
        .description = agent.default_config.description,
        .heartbeat_secs = agent.default_config.heartbeat_secs,
    };

    // ── 解析命令行参数 ─────────────────────────────────────────────────────────
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "-s") or std.mem.eql(u8, cmd, "--service")) {
            std.log.info("[main] StarAgent 以服务模式启动", .{});
            // 向 SCM 注册并运行（Windows），或直接运行（Linux/systemd）
            service.runAsService(allocator, config);
            return;
        } else if (std.mem.eql(u8, cmd, "--install") or std.mem.eql(u8, cmd, "-install") or std.mem.eql(u8, cmd, "-i")) {
            const r = try service.install(allocator, config, exe_path);
            std.process.exit(if (printResult(r)) 0 else 1);
        } else if (std.mem.eql(u8, cmd, "--uninstall") or std.mem.eql(u8, cmd, "-u")) {
            const r = try service.uninstall(allocator, config);
            std.process.exit(if (printResult(r)) 0 else 1);
        } else if (std.mem.eql(u8, cmd, "--stop") or std.mem.eql(u8, cmd, "-stop")) {
            const r = try service.stop(allocator, config);
            std.process.exit(if (printResult(r)) 0 else 1);
        } else if (std.mem.eql(u8, cmd, "--start") or std.mem.eql(u8, cmd, "-start")) {
            const r = try service.start(allocator, config);
            std.process.exit(if (printResult(r)) 0 else 1);
        } else if (std.mem.eql(u8, cmd, "--restart") or std.mem.eql(u8, cmd, "-restart")) {
            const r = try service.restart(allocator, config);
            std.process.exit(if (printResult(r)) 0 else 1);
        } else if (std.mem.eql(u8, cmd, "--status") or std.mem.eql(u8, cmd, "-status")) {
            const status_str = try service.getStatus(allocator, config);
            defer allocator.free(status_str);
            std.debug.print("状态：{s}\n", .{status_str});
            std.process.exit(0);
        } else if (std.mem.eql(u8, cmd, "--run") or std.mem.eql(u8, cmd, "-run")) {
            // 前台模拟运行（调试用）
            std.debug.print(bold ++ cyan ++ "[模拟运行] 按 Ctrl+C 停止\n" ++ reset, .{});
            agent.run(allocator, config);
            return;
        }
    }

    // ── 交互式菜单循环 ────────────────────────────────────────────────────────
    // Windows: 菜单需要管理员权限，若当前非管理员则整体重启为管理员后退出
    // Linux:   菜单需要 root 权限，若非 root 则用 sudo 整体重启
    // CLI 模式已在上方 return/exit，不会走到这里，故此处提权不影响 CLI 使用
    if (!service.isAdmin()) {
        std.debug.print(yellow ++ "需要管理员权限，正在请求提权...\n" ++ reset, .{});
        // wait=false(Windows): 新开管理员窗口，当前进程立即退出
        // wait=true(Linux):    sudo 在同一终端等待完成
        const wait = builtin.os.tag != .windows;
        const ok = try service.relaunchElevated(allocator, exe_path, "", wait);
        if (!ok) {
            std.debug.print(red ++ bold ++ "✘ 提权失败或用户取消\n" ++ reset, .{});
            pressEnter();
        }
        return; // 当前进程退出，提权的新进程接管菜单
    }

    while (true) {
        // 每轮刷新安装/运行状态
        const installed = service.isInstalled(allocator, config);
        const running = installed and service.isRunning(allocator, config);

        // 打印信息头
        try printHeader(allocator, config, exe_path);

        // 打印菜单标题
        std.debug.print(bold ++ bright_yellow ++ "序号  功能名称    命令行参数" ++ reset ++ "\n", .{});

        // 打印选项（根据安装/运行状态动态决定）
        std.debug.print("  1) " ++ bright_cyan ++ "显示状态" ++ reset ++ "    -status\n", .{});
        if (installed) {
            std.debug.print("  2) " ++ bright_cyan ++ "卸载服务" ++ reset ++ "    -u\n", .{});
            if (!running) {
                // 仅在已停止时显示"启动"
                std.debug.print("  3) " ++ bright_cyan ++ "启动服务" ++ reset ++ "    -start\n", .{});
            }
            if (running) {
                // 仅在运行中时显示"停止"
                std.debug.print("  4) " ++ bright_cyan ++ "停止服务" ++ reset ++ "    -stop\n", .{});
            }
            std.debug.print("  9) " ++ bright_cyan ++ "重启服务" ++ reset ++ "    -restart\n", .{});
        } else {
            std.debug.print("  2) " ++ bright_cyan ++ "安装服务" ++ reset ++ "    -i\n", .{});
        }
        std.debug.print("  5) " ++ bright_cyan ++ "模拟运行" ++ reset ++ "    -run\n", .{});
        std.debug.print("  0) " ++ bright_cyan ++ "退出" ++ reset ++ "\n", .{});
        std.debug.print("\n" ++ bright_cyan ++ "请选择: " ++ reset, .{});

        // 单键读取，无需按 Enter
        const ch = input.readKey() catch continue;
        // 回显选择并换行
        std.debug.print("{c}\n", .{ch});

        switch (ch) {
            '0' => {
                std.debug.print(yellow ++ "退出。\n" ++ reset, .{});
                return;
            },
            '1' => {
                const status_str = try service.getStatus(allocator, config);
                defer allocator.free(status_str);
                std.debug.print("\n" ++ bold ++ "状态：" ++ reset ++ "{s}\n", .{status_str});
                // 仅展示信息，直接刷新菜单
            },
            '2' => {
                // 菜单入口已统一确保 root/管理员权限，此处直接执行
                const r = if (installed)
                    try service.uninstall(allocator, config)
                else
                    try service.install(allocator, config, exe_path);
                if (printResult(r)) continue; // 成功：直接刷新菜单
                pressEnter(); // 失败：等用户确认
            },
            '3' => if (installed and !running) {
                const r = try service.start(allocator, config);
                if (!printResult(r)) pressEnter();
            },
            '4' => if (installed and running) {
                const r = try service.stop(allocator, config);
                if (!printResult(r)) pressEnter();
            },
            '9' => if (installed) {
                const r = try service.restart(allocator, config);
                if (!printResult(r)) pressEnter();
            },
            '5' => {
                // 只是提示，直接刷新菜单
                std.debug.print(yellow ++ "\n请在终端中以 -run 参数启动以模拟前台运行。\n" ++ reset, .{});
            },
            else => {
                std.debug.print(red ++ "无效选项，请重新选择。\n" ++ reset, .{});
            },
        }
    }
}

// ─── 辅助函数 ─────────────────────────────────────────────────────────────────

/// 打印信息头（仿照截图格式）
fn printHeader(allocator: std.mem.Allocator, config: agent.Config, exe_path: []const u8) !void {
    const status_str = try service.getStatus(allocator, config);
    defer allocator.free(status_str);

    std.debug.print("\n", .{});
    std.debug.print(bright_yellow ++ bold ++ "服务：" ++ reset ++ "{s}\n", .{config.display_name});
    std.debug.print(bright_cyan ++ "描述：" ++ reset ++ "{s}\n", .{config.description});
    std.debug.print(bright_green ++ "状态：" ++ reset ++ "{s}\n", .{status_str});
    std.debug.print(bright_cyan ++ "路径：" ++ reset ++ "{s} -s\n", .{exe_path});
    std.debug.print(bright_cyan ++ "端口：" ++ reset ++ "{d}  调试：{s}\n", .{
        config.local_port,
        if (config.debug) (green ++ "开" ++ reset) else (yellow ++ "关" ++ reset),
    });
    std.debug.print("\n", .{});
}

/// 打印操作结果，返回 true 表示成功
fn printResult(r: service.Result) bool {
    switch (r) {
        .ok => |msg| {
            std.debug.print(green ++ bold ++ "✔ {s}\n" ++ reset, .{msg});
            return true;
        },
        .err => |msg| {
            std.debug.print(red ++ bold ++ "✘ {s}\n" ++ reset, .{msg});
            return false;
        },
    }
}

/// 等待用户按任意键（仅在出错时调用，让用户有时间阅读错误信息）
fn pressEnter() void {
    std.debug.print(yellow ++ "\n按任意键继续..." ++ reset, .{});
    _ = zzig.Input.readKey() catch {};
}
