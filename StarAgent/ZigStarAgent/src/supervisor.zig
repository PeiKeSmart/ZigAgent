/// supervisor.zig — 进程守护器
///
/// 功能与 NewLife Stardust StarAgent 对应：
///   - 为每个 enable=true 的 ServiceInfo 独立启动一条守护线程
///   - 子进程意外退出后等待 delay_ms 毫秒再自动重启（看门狗）
///   - auto_stop=true 且退出码=0 时视为正常结束，不重启
///   - max_memory>0 时启动内存监控线程，超限强制 Kill 后重启（Linux/Windows）
///   - reload_on_change=true 时轮询工作目录 mtime，文件变化则立即重启
///   - 跨平台：Windows / Linux / macOS（macOS 内存监控暂不支持）
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const ServiceInfo = @import("config.zig").ServiceInfo;

// ─── 进程优先级 ───────────────────────────────────────────────────────────────

const Priority = enum {
    idle,
    below_normal,
    normal,
    above_normal,
    high,

    fn fromStr(s: []const u8) Priority {
        if (std.ascii.eqlIgnoreCase(s, "Idle")) return .idle;
        if (std.ascii.eqlIgnoreCase(s, "BelowNormal") or
            std.ascii.eqlIgnoreCase(s, "Low")) return .below_normal;
        if (std.ascii.eqlIgnoreCase(s, "AboveNormal")) return .above_normal;
        if (std.ascii.eqlIgnoreCase(s, "High") or
            std.ascii.eqlIgnoreCase(s, "RealTime")) return .high;
        return .normal;
    }
};

// ─── 平台相关类型 ─────────────────────────────────────────────────────────────

/// 子进程 ID 类型（Windows=HANDLE，POSIX=pid_t）
const ChildId = if (builtin.os.tag == .windows)
    std.os.windows.HANDLE
else
    std.posix.pid_t;

// ─── Supervisor 主结构 ────────────────────────────────────────────────────────

/// 进程守护管理器。
///
/// 用法：
/// ```zig
/// var sup = Supervisor.init(allocator, services, delay_ms, debug);
/// try sup.start();
/// // ... 等待停止信号 ...
/// sup.stopAndWait();
/// sup.deinit();
/// ```
pub const Supervisor = struct {
    allocator: Allocator,
    services: []const ServiceInfo,
    /// 子进程退出后重启前等待的毫秒数
    delay_ms: u32,
    /// 调试模式：true→子进程输出继承到当前终端
    debug: bool,
    /// 全局停止标志（原子，多线程可见）
    stop: std.atomic.Value(bool),
    /// 每个启用服务对应一条守护线程
    threads: []std.Thread,

    pub fn init(
        allocator: Allocator,
        services: []const ServiceInfo,
        delay_ms: u32,
        debug: bool,
    ) Supervisor {
        return .{
            .allocator = allocator,
            .services = services,
            .delay_ms = delay_ms,
            .debug = debug,
            .stop = std.atomic.Value(bool).init(false),
            .threads = &.{},
        };
    }

    /// 为每个 enable=true 的服务启动守护线程，立即返回（非阻塞）。
    pub fn start(self: *Supervisor) !void {
        var list: std.ArrayList(std.Thread) = .{};
        errdefer {
            for (list.items) |t| t.detach();
            list.deinit(self.allocator);
        }

        for (self.services) |*svc| {
            if (!svc.enable) continue;
            const ctx = try self.allocator.create(WorkerCtx);
            ctx.* = .{ .sup = self, .svc = svc };
            const t = try std.Thread.spawn(.{}, workerLoop, .{ctx});
            try list.append(self.allocator, t);
            std.log.info("[supervisor] 启动守护线程: {s}", .{svc.name});
        }

        self.threads = try list.toOwnedSlice(self.allocator);
        if (self.threads.len == 0) {
            std.log.info("[supervisor] 无已启用的服务（enable=false），守护器空闲", .{});
        } else {
            std.log.info("[supervisor] 共启动 {d} 个守护线程", .{self.threads.len});
        }
    }

    /// 发出停止信号并阻塞等待所有守护线程退出。
    pub fn stopAndWait(self: *Supervisor) void {
        self.stop.store(true, .release);
        for (self.threads) |t| t.join();
        std.log.info("[supervisor] 所有守护线程已退出", .{});
    }

    pub fn deinit(self: *Supervisor) void {
        self.allocator.free(self.threads);
    }
};

// ─── 守护线程 ─────────────────────────────────────────────────────────────────

/// 守护线程上下文（堆分配，线程持有所有权，退出时 destroy）
const WorkerCtx = struct {
    sup: *Supervisor,
    svc: *const ServiceInfo,
};

/// 每条守护线程的主循环
fn workerLoop(ctx: *WorkerCtx) void {
    defer ctx.sup.allocator.destroy(ctx);
    const svc = ctx.svc;
    const sup = ctx.sup;

    std.log.info("[supervisor/{s}] 守护启动 → {s} {s}", .{
        svc.name, svc.file_name, svc.arguments,
    });

    while (!sup.stop.load(.acquire)) {
        // ── 1. 启动子进程 ────────────────────────────────────────────────────
        var child = spawnChild(sup.allocator, svc, sup.debug) catch |err| {
            std.log.err("[supervisor/{s}] 启动失败: {} — {d}ms 后重试", .{
                svc.name, err, sup.delay_ms,
            });
            sleepInterruptible(sup.delay_ms, &sup.stop);
            continue;
        };

        std.log.info("[supervisor/{s}] 子进程已启动", .{svc.name});

        // ── 2. 可选：内存监控线程 ─────────────────────────────────────────────
        var mem_stop = std.atomic.Value(bool).init(false);
        var mem_thread: ?std.Thread = null;

        if (svc.max_memory > 0) {
            if (sup.allocator.create(MemCtx)) |mc| {
                mc.* = .{
                    .allocator = sup.allocator,
                    .pid = child.id,
                    .limit_mb = svc.max_memory,
                    .stop = &mem_stop,
                    .name = svc.name,
                };
                mem_thread = std.Thread.spawn(.{}, memMonitor, .{mc}) catch blk: {
                    sup.allocator.destroy(mc);
                    break :blk null;
                };
            } else |_| {}
        }

        // ── 3. 可选：文件变化监控线程 ─────────────────────────────────────────
        var reload_stop = std.atomic.Value(bool).init(false);
        var reload_fired = std.atomic.Value(bool).init(false);
        var reload_thread: ?std.Thread = null;

        if (svc.reload_on_change and svc.working_directory.len > 0) {
            if (sup.allocator.create(ReloadCtx)) |rc| {
                rc.* = .{
                    .allocator = sup.allocator,
                    .dir = svc.working_directory,
                    .stop = &reload_stop,
                    .fired = &reload_fired,
                    .name = svc.name,
                };
                reload_thread = std.Thread.spawn(.{}, reloadWatcher, .{rc}) catch blk: {
                    sup.allocator.destroy(rc);
                    break :blk null;
                };
            } else |_| {}
        }

        // ── 4. 等待子进程退出（同时监听 stop/reload/mem 信号） ────────────────
        const term = waitChild(sup.allocator, &child, &sup.stop, &reload_fired);

        // ── 5. 关闭辅助线程 ───────────────────────────────────────────────────
        mem_stop.store(true, .release);
        reload_stop.store(true, .release);
        if (mem_thread) |t| t.join();
        if (reload_thread) |t| t.join();

        // ── 6. 根据退出原因决策 ───────────────────────────────────────────────
        switch (term) {
            .stopped => {
                std.log.info("[supervisor/{s}] 收到停止信号，退出守护", .{svc.name});
                return;
            },
            .reloaded => {
                std.log.info("[supervisor/{s}] 文件变化，立即重启", .{svc.name});
                // 不等待延迟，直接进入下一轮
            },
            .exited => |code| {
                if (svc.auto_stop and code == 0) {
                    std.log.info(
                        "[supervisor/{s}] 进程正常退出(code=0)，auto_stop=true，停止守护",
                        .{svc.name},
                    );
                    return;
                }
                std.log.warn(
                    "[supervisor/{s}] 进程退出(code={d})，{d}ms 后重启",
                    .{ svc.name, code, sup.delay_ms },
                );
                sleepInterruptible(sup.delay_ms, &sup.stop);
            },
            .killed => {
                std.log.warn(
                    "[supervisor/{s}] 进程被强制终止（内存超限或外部信号），{d}ms 后重启",
                    .{ svc.name, sup.delay_ms },
                );
                sleepInterruptible(sup.delay_ms, &sup.stop);
            },
        }
    }

    std.log.info("[supervisor/{s}] 守护退出", .{svc.name});
}

// ─── 等待子进程退出 ───────────────────────────────────────────────────────────

/// 等待结果
const WaitResult = union(enum) {
    /// Supervisor 主动停止
    stopped: void,
    /// reload_on_change 触发文件变化
    reloaded: void,
    /// 进程自然退出，携带退出码
    exited: i32,
    /// 进程被信号强制终止（内存超限 / 外部 SIGKILL）
    killed: void,
};

/// 等待线程上下文（堆分配）
const WaitCtx = struct {
    child: *std.process.Child,
    term: ?std.process.Child.Term = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn waitThreadFn(ctx: *WaitCtx) void {
    ctx.term = ctx.child.wait() catch null;
    ctx.done.store(true, .release);
}

/// 非阻塞等待：在独立线程中执行 wait()，主线程每 500ms 轮询 stop/reload 标志。
/// 若需要主动终止（stop 或 reload），先 kill() 子进程再 join 等待线程。
fn waitChild(
    allocator: Allocator,
    child: *std.process.Child,
    stop: *const std.atomic.Value(bool),
    reload_fired: *const std.atomic.Value(bool),
) WaitResult {
    const ctx = allocator.create(WaitCtx) catch {
        _ = child.wait() catch {};
        return .{ .exited = -1 };
    };
    defer allocator.destroy(ctx);
    ctx.* = .{ .child = child };

    const t = std.Thread.spawn(.{}, waitThreadFn, .{ctx}) catch {
        _ = child.wait() catch {};
        return .{ .exited = -1 };
    };

    // 轮询：每 500ms 检查一次信号，等待线程结束后退出
    while (!ctx.done.load(.acquire)) {
        std.Thread.sleep(500 * std.time.ns_per_ms);

        if (stop.load(.acquire)) {
            _ = child.kill() catch {};
            t.join();
            return .stopped;
        }

        if (reload_fired.load(.acquire)) {
            _ = child.kill() catch {};
            t.join();
            return .reloaded;
        }
    }

    t.join();

    return if (ctx.term) |term| switch (term) {
        .Exited => |code| .{ .exited = @as(i32, @intCast(code)) },
        .Signal, .Stopped, .Unknown => .killed,
    } else .{ .exited = -1 };
}

// ─── 子进程启动 ───────────────────────────────────────────────────────────────

fn spawnChild(allocator: Allocator, svc: *const ServiceInfo, debug_mode: bool) !std.process.Child {
    // ── 构建 argv ───────────────────────────────────────────────────────────
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    try argv.append(allocator, svc.file_name);
    if (svc.arguments.len > 0) {
        var it = std.mem.splitScalar(u8, svc.arguments, ' ');
        while (it.next()) |arg| {
            const a = std.mem.trim(u8, arg, " \t");
            if (a.len > 0) try argv.append(allocator, a);
        }
    }

    var child = std.process.Child.init(argv.items, allocator);

    // ── 工作目录 ────────────────────────────────────────────────────────────
    if (svc.working_directory.len > 0) child.cwd = svc.working_directory;

    // ── 标准流 ──────────────────────────────────────────────────────────────
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = if (debug_mode) .Inherit else .Ignore;
    child.stderr_behavior = if (debug_mode) .Inherit else .Ignore;

    // ── 环境变量：继承父进程 + 追加配置变量 ─────────────────────────────────
    if (svc.environments.len > 0) {
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit(); // spawn() 调用前已复制至子进程，可安全释放

        var it = std.mem.splitScalar(u8, svc.environments, ',');
        while (it.next()) |pair| {
            const p = std.mem.trim(u8, pair, " \t");
            if (std.mem.indexOfScalar(u8, p, '=')) |eq| {
                try env_map.put(p[0..eq], p[eq + 1 ..]);
            }
        }
        child.env_map = &env_map;
        try child.spawn();
        // spawn() 已完成，清除悬空指针（wait/kill 不使用 env_map）
        child.env_map = null;
    } else {
        try child.spawn();
    }

    // ── 进程优先级 ──────────────────────────────────────────────────────────
    applyPriority(child.id, Priority.fromStr(svc.priority));

    return child;
}

// ─── 进程优先级设置（跨平台） ─────────────────────────────────────────────────

fn applyPriority(pid: ChildId, prio: Priority) void {
    if (prio == .normal) return; // 默认优先级无需修改

    if (builtin.os.tag == .linux) {
        const nice: i32 = switch (prio) {
            .idle => 19,
            .below_normal => 10,
            .normal => 0,
            .above_normal => -5,
            .high => -10,
        };
        // PRIO_PROCESS = 0
        const rc = std.os.linux.syscall3(
            .setpriority,
            0,
            @intCast(@as(u32, @bitCast(pid))),
            @bitCast(@as(i32, nice)),
        );
        if (rc != 0) {
            std.log.warn("[supervisor] setpriority 失败: {d}", .{rc});
        }
    } else if (builtin.os.tag == .windows) {
        // SetPriorityClass 在 Zig 0.15.2 的 kernel32 绑定中未暴露，用 extern 声明。
        // 放在此 comptime-dead 分支内，非 Windows 平台不参与类型检查与链接。
        const S = struct {
            extern "kernel32" fn SetPriorityClass(
                hProcess: std.os.windows.HANDLE,
                dwPriorityClass: std.os.windows.DWORD,
            ) callconv(std.builtin.CallingConvention.winapi) std.os.windows.BOOL;
        };
        const class: std.os.windows.DWORD = switch (prio) {
            .idle => 0x00000040, // IDLE_PRIORITY_CLASS
            .below_normal => 0x00004000, // BELOW_NORMAL_PRIORITY_CLASS
            .normal => 0x00000020, // NORMAL_PRIORITY_CLASS
            .above_normal => 0x00008000, // ABOVE_NORMAL_PRIORITY_CLASS
            .high => 0x00000080, // HIGH_PRIORITY_CLASS
        };
        _ = S.SetPriorityClass(pid, class);
    }
    // macOS / 其他平台：暂不支持，忽略
}

// ─── 内存监控 ─────────────────────────────────────────────────────────────────

const MemCtx = struct {
    allocator: Allocator,
    pid: ChildId,
    /// 内存上限（MB）
    limit_mb: u64,
    stop: *std.atomic.Value(bool),
    name: []const u8,
};

/// 内存监控线程：每 5 秒检查一次，超限则强制 kill 子进程。
fn memMonitor(ctx: *MemCtx) void {
    defer ctx.allocator.destroy(ctx);

    while (!ctx.stop.load(.acquire)) {
        // 分 10 × 500ms 等待，保持对 stop 信号的响应
        var i: u32 = 0;
        while (i < 10 and !ctx.stop.load(.acquire)) : (i += 1) {
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
        if (ctx.stop.load(.acquire)) break;

        const mem_mb = queryMemoryMb(ctx.pid) catch continue;
        if (mem_mb > ctx.limit_mb) {
            std.log.warn(
                "[supervisor/{s}] 内存超限 {d}MB > {d}MB，强制终止子进程",
                .{ ctx.name, mem_mb, ctx.limit_mb },
            );
            killPid(ctx.pid);
            break;
        }
    }
}

/// 查询进程驻留内存（MB）
fn queryMemoryMb(pid: ChildId) !u64 {
    if (builtin.os.tag == .linux) {
        // 读取 /proc/{pid}/statm：第2列为 RSS（页面数）
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/statm", .{pid});
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        var buf: [128]u8 = undefined;
        const n = try f.read(&buf);
        var it = std.mem.splitScalar(u8, buf[0..n], ' ');
        _ = it.next(); // 忽略第1列（虚拟内存页数）
        const rss_str = std.mem.trim(u8, it.next() orelse return error.ParseFail, " \t\r\n");
        const rss_pages = try std.fmt.parseInt(u64, rss_str, 10);
        // 假设页面大小 4096 字节（ARM64 上可能是 16K，此处保守取 4K）
        return (rss_pages * 4096) / (1024 * 1024);
    } else if (builtin.os.tag == .windows) {
        var counters: PROCESS_MEMORY_COUNTERS = undefined;
        counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS);
        if (K32GetProcessMemoryInfo(pid, &counters, counters.cb) == 0) {
            return error.WinApiFail;
        }
        return counters.WorkingSetSize / (1024 * 1024);
    } else {
        return error.Unsupported;
    }
}

/// 强制终止指定 pid 的进程（仅用于内存监控，非 Child.kill()）
fn killPid(pid: ChildId) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.kill(pid, std.posix.SIG.KILL);
    } else if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.TerminateProcess(pid, 1);
    }
}

// Windows PROCESS_MEMORY_COUNTERS（kernel32 K32GetProcessMemoryInfo，Vista+）
const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: u32,
    PageFaultCount: u32,
    PeakWorkingSetSize: usize,
    /// 当前工作集大小（字节）
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
};

extern "kernel32" fn K32GetProcessMemoryInfo(
    Process: std.os.windows.HANDLE,
    ppsmemCounters: *PROCESS_MEMORY_COUNTERS,
    cb: u32,
) callconv(std.builtin.CallingConvention.winapi) std.os.windows.BOOL;

// ─── 文件变化监控 ─────────────────────────────────────────────────────────────

const ReloadCtx = struct {
    allocator: Allocator,
    /// 监视的工作目录路径
    dir: []const u8,
    stop: *std.atomic.Value(bool),
    /// 检测到变化时置 true，由 waitChild 消费
    fired: *std.atomic.Value(bool),
    name: []const u8,
};

/// 文件变化监控线程：每 2 秒轮询目录 mtime，发生变化则设置 fired。
///
/// 实现说明：使用 mtime 轮询而非 inotify/FSEvents/ReadDirectoryChangesW，
/// 避免引入平台特定 API，代价是 2 秒延迟，对于部署场景可接受。
fn reloadWatcher(ctx: *ReloadCtx) void {
    defer ctx.allocator.destroy(ctx);

    var last_mtime: i128 = getDirMtime(ctx.dir) catch 0;

    while (!ctx.stop.load(.acquire)) {
        // 分 4 × 500ms 等待（共 2s），保持对 stop 信号的响应
        var i: u32 = 0;
        while (i < 4 and !ctx.stop.load(.acquire)) : (i += 1) {
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
        if (ctx.stop.load(.acquire)) break;

        const mtime = getDirMtime(ctx.dir) catch continue;
        if (mtime != last_mtime) {
            std.log.info(
                "[supervisor/{s}] 目录 '{s}' 文件发生变化，触发重载",
                .{ ctx.name, ctx.dir },
            );
            ctx.fired.store(true, .release);
            last_mtime = mtime;
            // 已触发，等待 waitChild 消费；继续监视（下次变化再次触发）
        }
    }
}

/// 获取目录的最近修改时间（纳秒时间戳）
fn getDirMtime(dir_path: []const u8) !i128 {
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    const stat = try dir.stat();
    return stat.mtime;
}

// ─── 工具函数 ─────────────────────────────────────────────────────────────────

/// 可中断睡眠：每 100ms 检查一次 stop 标志。
fn sleepInterruptible(ms: u32, stop: *const std.atomic.Value(bool)) void {
    const total_ns: u64 = @as(u64, ms) * std.time.ns_per_ms;
    var elapsed: u64 = 0;
    const step_ns: u64 = 100 * std.time.ns_per_ms;

    while (elapsed < total_ns and !stop.load(.acquire)) {
        const sleep_ns = @min(step_ns, total_ns - elapsed);
        std.Thread.sleep(sleep_ns);
        elapsed += sleep_ns;
    }
}
