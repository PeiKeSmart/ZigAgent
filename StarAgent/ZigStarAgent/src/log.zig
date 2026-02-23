/// log.zig — 日志适配层
///
/// 将 std.log.* 调用桥接到 zzig.AsyncLogger，实现文件+控制台双路输出。
/// AsyncLogger 负责异步写入、日志滚动、线程安全等所有重型逻辑，
/// 此文件仅做初始化管理和 std_options.logFn 接口适配。
///
/// 使用方式（main.zig 顶层）：
///   pub const std_options: std.Options = .{ .logFn = @import("log.zig").logFn };
///
/// 初始化（main() 中，尽早调用）：
///   try @import("log.zig").init(allocator, log_path, json_cfg_path, .both);
///   defer @import("log.zig").deinit();
const std = @import("std");
const zzig = @import("zzig");

// zzig AsyncLogger 的模块别名
const AL = zzig.AsyncLogger;
/// AsyncLogger 实例类型（堆分配，由 init 返回）
pub const AsyncLoggerT = AL.AsyncLogger;
/// 输出目标枚举：.console / .file / .both
pub const OutputTarget = AL.ConfigOutputTarget;

// ─── 全局实例 ─────────────────────────────────────────────────────────────────
var g_logger: ?*AsyncLoggerT = null;

// ─── 公开 API ─────────────────────────────────────────────────────────────────

/// 初始化 AsyncLogger。
///
/// allocator    — 用于创建 AsyncLogger 实例（生命周期贯穿程序）
/// log_path     — 日志文件绝对路径，如 "C:\...\StarAgent.log"
/// cfg_path     — AsyncLogger JSON 配置文件路径（首次运行自动生成）
/// target       — 输出目标：.console / .file / .both
pub fn init(
    allocator: std.mem.Allocator,
    log_path: []const u8,
    cfg_path: []const u8,
    target: OutputTarget,
) !void {
    // Windows 路径中的 \ 在 JSON 中必须转义为 \\，但部分 JSON 实现处理不一致。
    // 最稳健的方案：将路径中的 \ 统一转为 /，Windows 所有文件 API 均支持正斜杠。
    const log_path_fwd = try allocator.dupe(u8, log_path);
    defer allocator.free(log_path_fwd);
    for (log_path_fwd) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    // 每次启动都重新写入配置，确保 output_target / log_file_path 与代码逻辑一致，
    // 不依赖旧配置文件残留值。
    const cfg = AL.ConfigFile{
        .allocator = allocator,
        .output_target = target,
        .log_file_path = log_path_fwd,
        .min_level = .debug,
        .queue_capacity = 16384,
    };
    cfg.saveToFile(cfg_path) catch |err| {
        std.debug.print("[log] 写入日志配置文件失败 '{s}': {s}\n", .{ cfg_path, @errorName(err) });
    };

    const logger = try AsyncLoggerT.initFromConfigFile(allocator, cfg_path);
    if (g_logger) |old| old.deinit();
    g_logger = logger;
}

/// 释放 AsyncLogger 资源（刷盘 + 停止后台线程）
pub fn deinit() void {
    if (g_logger) |logger| {
        logger.deinit();
        g_logger = null;
    }
}

// ─── std_options.logFn 适配 ───────────────────────────────────────────────────

/// 注册给 std_options.logFn 的回调，所有 std.log.* 均路由至此。
/// 若 AsyncLogger 尚未初始化（init 前或 deinit 后），回退到 stderr。
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.default),
    comptime format: []const u8,
    args: anytype,
) void {
    // 将 std.log.Level → AsyncLogger.Level
    const al_level: AL.Level = comptime switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
    // scope 前缀：default 不显示，其余显示 "(scope) "
    const scope_prefix = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    if (g_logger) |logger| {
        logger.log(al_level, scope_prefix ++ format, args);
    } else {
        // 兜底：AsyncLogger 未就绪时直接写 stderr
        std.debug.print("[" ++ @tagName(level) ++ "] " ++ scope_prefix ++ format ++ "\n", args);
    }
}
