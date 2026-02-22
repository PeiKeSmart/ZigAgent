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

/// 运行 Agent 主循环（阻塞，直到收到停止信号）
pub fn run(config: Config) void {
    std.log.info("[{s}] Agent 启动，心跳间隔 {d}s", .{ config.service_name, config.heartbeat_secs });

    while (true) {
        std.Thread.sleep(config.heartbeat_secs * std.time.ns_per_s);
        // 此处放置实际的 Agent 任务：
        // - 上报节点状态
        // - 接收远程指令
        // - 拉取并执行发布任务
        std.log.info("[{s}] 心跳中...", .{config.service_name});
    }
}
