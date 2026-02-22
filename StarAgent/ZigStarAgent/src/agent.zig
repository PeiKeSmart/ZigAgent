/// agent.zig — StarAgent 核心守护逻辑
/// 负责 Agent 的实际工作循环，无论以服务还是前台方式运行都调用 run()
const std = @import("std");

/// Agent 配置（可从配置文件或命令行覆盖）
pub const Config = struct {
    /// Agent 服务名称
    service_name: []const u8 = "StarAgent",
    /// Agent 显示名称
    display_name: []const u8 = "星尘代理(StarAgent)",
    /// 服务描述
    description: []const u8 = "星尘分布式资源调度，部署于每一个节点，连接服务端，支持节点监控、远程发布。",
    /// 心跳间隔（秒）
    heartbeat_secs: u64 = 10,
};

/// 全局默认配置
pub const default_config = Config{};

/// 全局停止信号（由 Windows SCM 控制处理器或 SIGTERM 设置）
/// 使用 atomic 确保跨线程可见性
pub var stop_signal = std.atomic.Value(bool).init(false);

/// 运行 Agent 主循环（阻塞，直到 stop_signal 被设置或进程退出）
pub fn run(config: Config) void {
    std.log.info("[{s}] Agent 启动，心跳间隔 {d}s", .{ config.service_name, config.heartbeat_secs });

    // 将心跳间隔拆分为 500ms 小片段，以便及时响应停止信号
    const tick_ns: u64 = 500 * std.time.ns_per_ms;
    const ticks_per_heartbeat = (config.heartbeat_secs * std.time.ns_per_s) / tick_ns;
    var tick_count: u64 = 0;

    while (!stop_signal.load(.acquire)) {
        std.Thread.sleep(tick_ns);
        tick_count += 1;

        if (tick_count >= ticks_per_heartbeat) {
            tick_count = 0;
            // 此处放置实际的 Agent 任务：
            // - 上报节点状态
            // - 接收远程指令
            // - 拉取并执行发布任务
            std.log.info("[{s}] 心跳中...", .{config.service_name});
        }
    }

    std.log.info("[{s}] Agent 收到停止信号，退出。", .{config.service_name});
}
