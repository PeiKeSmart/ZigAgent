const std = @import("std");

pub fn main() void {
    const os = @import("builtin").os;
    switch (os.tag) {
        .linux => std.debug.print("Linux\n", .{}),
        .macos => std.debug.print("macOS\n", .{}),
        .windows => std.debug.print("Windows\n", .{}),
        else => std.debug.print("Unknown OS: {}\n", .{os.tag}),
    }
}
