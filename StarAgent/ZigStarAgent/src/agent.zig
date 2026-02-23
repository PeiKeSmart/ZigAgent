/// agent.zig — StarAgent 核心守护逻辑
/// 负责 Agent 的实际工作循环，无论以服务还是前台方式运行都调用 run()
const std = @import("std");

const sup_mod = @import("supervisor.zig");
pub const Supervisor = sup_mod.Supervisor;
/// 重新导出 ServiceInfo，使调用方（main.zig / service.zig）无需直接引用 supervisor.zig
pub const ServiceInfo = sup_mod.ServiceInfo;

/// Agent 运行配置
pub const Config = struct {
    /// 服务名称（用于系统服务注册，不跟随 XML 变化保持平台注册稳定）
    service_name: []const u8 = "StarAgent",
    /// 服务显示名称
    display_name: []const u8 = "星尘代理(StarAgent)",
    /// 服务描述
    description: []const u8 = "星尘分布式资源调度，部署于每一个节点，连接服务端，支持节点监控、远程发布。",
    /// 心跳间隔（秒）
    heartbeat_secs: u64 = 10,
    /// 调试模式（true=输出详细日志，对应 XML <Debug>）
    debug: bool = true,
    /// 本地监听端口（对应 XML <LocalPort>）
    local_port: u16 = 5500,
    /// 托管应用服务列表（对应 XML <Services>，生命周期由调用方 ConfigResult.arena 管理）
    services: []const ServiceInfo = &.{},
    /// 子进程重启延迟（ms，对应 XML <Delay>）
    delay_ms: u32 = 3000,
};

/// 全局默认配置
pub const default_config = Config{};

/// 全局停止信号（由 Windows SCM 控制处理器或 SIGTERM 设置）
/// 使用 atomic 确保跨线程可见性
pub var stop_signal = std.atomic.Value(bool).init(false);

/// 运行 Agent 主循环（阻塞，直到 stop_signal 被设置或进程退出）
///
/// 流程：
///   1. 启动 Supervisor，为每个 enable=true 的 ServiceInfo 拉起并守护子进程
///   2. 主线程执行心跳循环（上报状态、接收指令等）
///   3. stop_signal 被设置后，通知 Supervisor 停止所有子进程并等待退出
pub fn run(allocator: std.mem.Allocator, config: Config) void {
    std.log.info("[{s}] Agent 启动 — 端口:{d}  调试:{}  托管服务:{d}个", .{
        config.service_name,
        config.local_port,
        config.debug,
        config.services.len,
    });

    // ── 启动进程守护器 ────────────────────────────────────────────────────────
    var supervisor = Supervisor.init(
        allocator,
        config.services,
        config.delay_ms,
        config.debug,
    );
    supervisor.start() catch |err| {
        std.log.err("[{s}] Supervisor 启动失败: {} — Agent 仅运行心跳循环", .{
            config.service_name, err,
        });
    };
    defer {
        // 主循环退出时通知所有守护线程停止，并等待子进程退出
        supervisor.stopAndWait();
        supervisor.deinit();
    }

    // ── 主心跳循环 ────────────────────────────────────────────────────────────
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
            // - 上报节点状态至星尘服务端
            // - 接收远程指令（发布、重启、更新等）
            // - 拉取并执行发布任务
            if (config.debug) {
                std.log.debug("[{s}] 心跳（调试）port={d}  托管服务={d}个", .{
                    config.service_name,
                    config.local_port,
                    config.services.len,
                });
            } else {
                std.log.info("[{s}] 心跳中...", .{config.service_name});
            }
        }
    }

    std.log.info("[{s}] Agent 收到停止信号，正在停止所有子进程...", .{config.service_name});
    // defer 处的 supervisor.stopAndWait() 在此之后立即执行
}
