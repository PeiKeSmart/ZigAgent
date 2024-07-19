const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
});

const File = @import("zzig").File;
const XTrace = @import("zzig").XTrace;

pub fn main() !void {
    _ = c.SetConsoleOutputCP(c.CP_UTF8); // 输出中文时不乱码

    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; // 安全的分配器，可以防止双重释放（double-free）、使用后释放（use-after-free），并且能够检测内存泄漏
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    //const allocator = std.heap.page_allocator; // 初始化一个全局可用的内存分配器实例

    // var child = std.process.Child.init(&[_][]const u8{ "ping", "baidu.com" }, allocator);

    // try child.spawn();
    // const term = try child.wait();

    // std.debug.print("Command failed with exit code {d}\n", .{term.Exited});

    var child = std.process.Child.init(&[_][]const u8{ "dotnet", "restore" }, allocator);

    try child.spawn();
    const term1 = try child.wait();
    std.debug.print("Command failed with exit code {d}\n", .{term1.Exited});

    // // 处理文件夹的对象
    // const current = try std.fs.cwd().openDir(".", .{});
    // try std.io.getStdOut().writer().print("Current working directory: {}\n", .{current});

    // // 获取当前工作目录的绝对路径
    const real_path = try File.CurrentPath(allocator);
    defer allocator.free(real_path);

    // 打印当前工作目录的路径
    try std.io.getStdOut().writer().print("Current working directory: {s}\n", .{real_path});

    // 指定工作目录
    const working_dir = real_path;

    child = std.process.Child.init(&[_][]const u8{ "dotnet", "clean" }, allocator);

    // 设置工作目录
    child.cwd = working_dir;

    try child.spawn();
    const term2 = try child.wait();
    std.debug.print("Command failed with exit code {d}\n", .{term2.Exited});

    child = std.process.Child.init(&[_][]const u8{ "dotnet", "publish", "-c", "Release", "-r", "linux-x64", "-o", "./publish" }, allocator);

    try child.spawn();
    const term3 = try child.wait();
    std.debug.print("Command failed with exit code {d}\n", .{term3.Exited});

    // const stdout = std.io.getStdOut().writer();
    // try stdout.print("{s}", .{child.stdout});
}
