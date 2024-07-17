const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
});

pub fn main() !void {
    _ = c.SetConsoleOutputCP(c.CP_UTF8); // 输出中文时不乱码
}
