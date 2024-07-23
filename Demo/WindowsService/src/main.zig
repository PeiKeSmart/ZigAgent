const std = @import("std");
const c = @cImport({
    @cInclude("windows.h");
});
const windows = std.os.windows;

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

fn handlerFunction(dwControl: u32) callconv(windows.WINAPI) void {
    // 处理服务控制请求的逻辑
    std.debug.print("Service control request: {}\n", .{dwControl});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; // 安全的分配器，可以防止双重释放（double-free）、使用后释放（use-after-free），并且能够检测内存泄漏
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    //const allocator = std.heap.page_allocator; // 初始化一个全局可用的内存分配器实例

    const MyServiceName = "MyServiceName";
    const serviceNameSize = MyServiceName.len + 1; // 包括终止符
    const data = try allocator.alloc(u8, serviceNameSize);

    // 使用std.mem.copy来复制字符串
    std.mem.copyForwards(u8, data, MyServiceName);
    data[MyServiceName.len] = 0; // 添加字符串终止符

    // 这里可以对ServiceName进行操作
    defer allocator.free(data); // 使用完后记得释放内存

    const handler: everything.LPHANDLER_FUNCTION = handlerFunction;

    //const const_data: [*:0]const u8 = &data;
    const const_data: [*:0]const u8 = @ptrCast(data);

    // 注册控制处理程序
    const serviceHandle = everything.RegisterServiceCtrlHandlerA(const_data, handler);
    std.debug.print("Failed to register service control handler: {}\n", .{serviceHandle});
    // if (handler == null) {
    //     const err = GetLastError();
    //     std.debug.print("Failed to register service control handler: {}\n", .{err});
    //     return Error.RegisterServiceCtrlHandlerFailed;
    // }
}
