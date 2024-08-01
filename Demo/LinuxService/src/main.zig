const std = @import("std");

const logz = @import("logz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; // 安全的分配器，可以防止双重释放（double-free）、使用后释放（use-after-free），并且能够检测内存泄漏
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    //const allocator = std.heap.page_allocator; // 初始化一个全局可用的内存分配器实例

    // 日志
    // initialize a logging pool
    try logz.setup(allocator, .{
        .level = .Warn,
        .pool_size = 100,
        .buffer_size = 4096,
        .large_buffer_count = 8,
        .large_buffer_size = 16384,
        .output = .{ .file = "/home/berin/log.log" },
        //.output = .stdout,
        .encoding = .logfmt,
    });
    defer logz.deinit();

    var logger = logz.loggerL(.Info)
        .stringSafe("ctx", "db.setup")
        .string("path", "test");
    defer logger.log();
    errdefer |err| _ = logger.err(err).level(.Fatal);

    logz.warn().string("LinuxService", "开始").log();

    // 交叉编译：zig build -Doptimize=ReleaseSmall  -Dtarget=x86_64-linux-gnu
    // 处理启动逻辑
    while (true) {
        std.time.sleep(5 * std.time.ns_per_s);
        // 服务运行的主要逻辑
        // 处理服务的具体任务
        logz.warn().string("LinuxService", "进行中").log();
    }
}
