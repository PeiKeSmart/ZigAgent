const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
});

pub fn main() !void {
    _ = c.SetConsoleOutputCP(c.CP_UTF8); // 输出中文时不乱码

    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; // 安全的分配器，可以防止双重释放（double-free）、使用后释放（use-after-free），并且能够检测内存泄漏
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    //const allocator = std.heap.page_allocator; // 初始化一个全局可用的内存分配器实例

    var child = std.process.Child.init(&[_][]const u8{ "dotnet", "restore" }, allocator);

    try child.spawn();

    // const stdout = std.io.getStdOut().writer();
    // try stdout.print("{s}", .{child.stdout});
}
