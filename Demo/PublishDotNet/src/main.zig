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

    var child = std.process.Child.init(&[_][]const u8{ "ping", "baidu.com" }, allocator);

    try child.spawn();
    const term = try child.wait();

    std.debug.print("Command failed with exit code {d}\n", .{term.Exited});

    child = std.process.Child.init(&[_][]const u8{ "dotnet", "restore" }, allocator);

    try child.spawn();
    const term1 = try child.wait();
    std.debug.print("Command failed with exit code {d}\n", .{term1.Exited});

    // // 处理文件夹的对象
    // const current = try std.fs.cwd().openDir(".", .{});
    // try std.io.getStdOut().writer().print("Current working directory: {}\n", .{current});

    // 获取当前工作目录的句柄
    const cwd = std.fs.cwd();
    // 获取当前工作目录的绝对路径
    const real_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(real_path);

    // 打印当前工作目录的路径
    try std.io.getStdOut().writer().print("Current working directory: {s}\n", .{real_path});

    // const stdout = std.io.getStdOut().writer();
    // try stdout.print("{s}", .{child.stdout});
}
