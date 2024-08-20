const std = @import("std");
const posix = std.posix;

const log = @import("zzig").DebugLog;

pub fn main() !void {
    try daemon();
}

fn daemon() !void {
    // 创建子进程
    const pid = try posix.fork(); // 使用 try 来捕获错误

    if (pid == 0) {
        // 这是子进程的代码
        std.debug.print("This is the child process with PID: {}\n", .{pid});
    } else {
        // 这是父进程的代码
        std.debug.print("This is the parent process with child PID: {}\nend\n", .{pid});
    }
}
