const std = @import("std");
const builtin = @import("builtin");

const root = @import("root");
pub const UnicodeMode = enum { ansi, wide, unspecified };
pub const unicode_mode: UnicodeMode = if (@hasDecl(root, "UNICODE")) (if (root.UNICODE) .wide else .ansi) else .unspecified;

const is_zig_0_11 = std.mem.eql(u8, builtin.zig_version_string, "0.11.0");

pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub usingnamespace switch (unicode_mode) {
    .ansi => struct {
        pub const TCHAR = u8;
        pub fn _T(comptime str: []const u8) *const [str.len:0]u8 {
            return str;
        }
    },
    .wide => struct {
        pub const TCHAR = u16;
        pub const _T = L;
    },
    .unspecified => if (builtin.is_test) struct {} else struct {
        pub const TCHAR = @compileError("'TCHAR' requires that UNICODE be set to true or false in the root module");
        pub const _T = @compileError("'_T' requires that UNICODE be set to true or false in the root module");
    },
};

// TODO: this should probably be in the standard lib somewhere?
pub const Guid = extern union {
    Ints: extern struct {
        a: u32,
        b: u16,
        c: u16,
        d: [8]u8,
    },
    Bytes: [16]u8,

    const big_endian_hex_offsets = [16]u6{ 0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34 };
    const little_endian_hex_offsets = [16]u6{ 6, 4, 2, 0, 11, 9, 16, 14, 19, 21, 24, 26, 28, 30, 32, 34 };

    const hex_offsets = if (is_zig_0_11) switch (builtin.target.cpu.arch.endian()) {
        .Big => big_endian_hex_offsets,
        .Little => little_endian_hex_offsets,
    } else switch (builtin.target.cpu.arch.endian()) {
        .big => big_endian_hex_offsets,
        .little => little_endian_hex_offsets,
    };

    pub fn initString(s: []const u8) Guid {
        var guid = Guid{ .Bytes = undefined };
        for (hex_offsets, 0..) |hex_offset, i| {
            //guid.Bytes[i] = decodeHexByte(s[offset..offset+2]);
            guid.Bytes[i] = decodeHexByte([2]u8{ s[hex_offset], s[hex_offset + 1] });
        }
        return guid;
    }
};
comptime {
    std.debug.assert(@sizeOf(Guid) == 16);
}

// TODO: is this in the standard lib somewhere?
fn hexVal(c: u8) u4 {
    if (c <= '9') return @as(u4, @intCast(c - '0'));
    if (c >= 'a') return @as(u4, @intCast(c + 10 - 'a'));
    return @as(u4, @intCast(c + 10 - 'A'));
}

// TODO: is this in the standard lib somewhere?
fn decodeHexByte(hex: [2]u8) u8 {
    return @as(u8, @intCast(hexVal(hex[0]))) << 4 | hexVal(hex[1]);
}
