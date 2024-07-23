const std = @import("std");
const windows = std.os.windows;

const c = @cImport({
    @cInclude("windows.h");
});
const logz = @import("logz");

const everything = @import("win32.zig").everything;

// 定义 c_void 作为 *u8 类型
const c_void = *u8;

// 自定义错误类型
const Error = error{
    OpenSCManagerFailed,
    CreateServiceFailed,
    RegisterServiceCtrlHandlerFailed,
    SetServiceStatusFailed,
};

extern "kernel32" fn GetLastError() u32;

const SERVICE_CONTROL_STOP = 0x00000001;

var ServiceName: [*:0]u8 = undefined;

fn handlerFunction(dwControl: u32) callconv(windows.WINAPI) void {
    // 处理服务控制请求的逻辑
    std.debug.print("Service control request: {}\n", .{dwControl});
}

fn ServiceMain(argc: u32, argv: ?*?[*:0]u8) callconv(windows.WINAPI) void {
    std.debug.print("{any}\n", .{argc});
    std.debug.print("{any}\n", .{argv});

    // const serviceHandle = everything.RegisterServiceCtrlHandlerA(ServiceName, handlerFunction);

    // std.debug.print("{any}\n", .{serviceHandle});

    // // 初始化服务
    // // 处理启动逻辑
    // while (true) {
    //     // 服务运行的主要逻辑
    //     // 处理服务的具体任务
    // }
}

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
        .output = .{ .file = "log.log" },
        //.output = .stdout,
        .encoding = .logfmt,
    });
    defer logz.deinit();

    var logger = logz.loggerL(.Info)
        .stringSafe("ctx", "db.setup")
        .string("path", "test");
    defer logger.log();
    errdefer |err| _ = logger.err(err).level(.Fatal);

    const MyServiceName = "zigTest";
    const serviceNameSize = MyServiceName.len + 1; // 包括终止符
    const data = try allocator.alloc(u8, serviceNameSize);

    logz.warn().string("MyServiceName", MyServiceName).log();

    // 使用std.mem.copy来复制字符串
    std.mem.copyForwards(u8, data, MyServiceName);
    data[MyServiceName.len] = 0; // 添加字符串终止符

    // 这里可以对ServiceName进行操作
    defer allocator.free(data); // 使用完后记得释放内存

    const const_data: [*:0]u8 = @ptrCast(data);
    ServiceName = const_data;

    const serviceTable: [1]everything.SERVICE_TABLE_ENTRYA = .{
        .{ .lpServiceName = ServiceName, .lpServiceProc = ServiceMain },
    };

    const ss = everything.StartServiceCtrlDispatcherA(&serviceTable[0]);

    std.debug.print("value:{d}\n", .{ss});

    if (ss == 0) {
        const err = GetLastError();
        std.debug.print("{any}\n", .{err});
    }

    // if (everything.StartServiceCtrlDispatcherA(&serviceTable[0])) {
    //     // 处理错误
    // }

    // // 注册控制处理程序
    // const serviceHandle = everything.RegisterServiceCtrlHandlerA(const_data, handler);
    // std.debug.print("Failed to register service control handler: {}\n", .{serviceHandle});
    // // if (handler == null) {
    // //     const err = GetLastError();
    // //     std.debug.print("Failed to register service control handler: {}\n", .{err});
    // //     return Error.RegisterServiceCtrlHandlerFailed;
    // // }
}
