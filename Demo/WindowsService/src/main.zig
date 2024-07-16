const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
});

// 手动实现 isWhiteSpace 函数
fn isWhiteSpace(s: u8) bool {
    return s == ' ' or s == '\t' or s == '\n' or s == '\r';
}

// 手动实现 trim 函数
fn trim(s: []u8) []u8 {
    var start = 0;
    var end = s.len;

    while (start < end and isWhiteSpace(s[start])) {
        start += 1;
    }

    while (end > start and isWhiteSpace(s[end - 1])) {
        end -= 1;
    }

    return s[start..end];
}

pub fn main() !void {
    // 获取标准输入输出
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    var input_buffer: [256]u8 = undefined;

    _ = c.SetConsoleOutputCP(c.CP_UTF8); // 输出中文时不乱码

    while (true) {
        const menu = "请选择一个选项:\n" ++
            "1. 选项一\n" ++
            "2. 选项二\n" ++
            "3. 退出\n";
        try stdout.print("{s}\n", .{menu});

        const input = try stdin.readUntilDelimiterOrEof(&input_buffer, '\n');
        if (input) |valid_input| {
            const input_str = trim(input_buffer[0..valid_input.len]);

            if (std.mem.eql(u8, input_str, "1")) {
                try stdout.print("{s}\n", .{"你选择了选项一"});
            } else if (std.mem.eql(u8, input_str, "2")) {
                try stdout.print("{s}\n", .{"你选择了选项二"});
            } else if (std.mem.eql(u8, input_str, "3")) {
                try stdout.print("{s}\n", .{"退出..."});
                return;
            } else {
                try stdout.print("{s}\n", .{"无效的选项，请重新选择"});
            }
        } else {
            try stdout.print("{s}\n", .{"读取输入时出错，请重试"});
        }
    }
}
