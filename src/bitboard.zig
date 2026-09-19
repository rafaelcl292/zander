// Derived from Stockfish bitboard.h; GPL-3.0-or-later. See AUTHORS.stockfish.
const std = @import("std");
const t = @import("types.zig");
pub const file_a: u64 = 0x0101010101010101;
pub const file_h: u64 = file_a << 7;
pub fn square(s: t.Square) u64 {
    std.debug.assert(s.valid());
    return @as(u64, 1) << @as(u6, @intCast(@intFromEnum(s)));
}
pub fn shift(b: u64, dir: i8) u64 {
    return switch (dir) {
        8 => b << 8,
        -8 => b >> 8,
        16 => b << 16,
        -16 => b >> 16,
        1 => (b & ~file_h) << 1,
        -1 => (b & ~file_a) >> 1,
        9 => (b & ~file_h) << 9,
        7 => (b & ~file_a) << 7,
        -7 => (b & ~file_h) >> 7,
        -9 => (b & ~file_a) >> 9,
        else => 0,
    };
}
pub fn pawnAttacks(c: t.Color, b: u64) u64 {
    return if (c == .white) shift(b, 7) | shift(b, 9) else shift(b, -7) | shift(b, -9);
}
pub fn moreThanOne(b: u64) bool {
    return b & (b -% 1) != 0;
}
pub fn lsb(b: u64) t.Square {
    std.debug.assert(b != 0);
    return @enumFromInt(@ctz(b));
}
pub fn msb(b: u64) t.Square {
    std.debug.assert(b != 0);
    return @enumFromInt(63 - @clz(b));
}
pub fn popLsb(b: *u64) t.Square {
    const s = lsb(b.*);
    b.* &= b.* - 1;
    return s;
}
test "edge shifts never wrap and pop clears exactly one bit" {
    try std.testing.expectEqual(@as(u64, 0), shift(file_h, 1));
    try std.testing.expectEqual(@as(u64, 0), shift(file_a, -1));
    var b: u64 = 0x8000000000000001;
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(popLsb(&b)));
    try std.testing.expectEqual(@as(u8, 63), @intFromEnum(popLsb(&b)));
    try std.testing.expectEqual(@as(u64, 0), b);
}
