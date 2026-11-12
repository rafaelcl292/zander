// Derived from Stockfish's paired widening accumulator updates; GPL-3.0-or-later.
const std = @import("std");
const cpu = @import("builtin").target.cpu;
pub const enabled = @import("backend").simd and cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(cpu.features, .avx2) and std.simd.suggestVectorLength(i16) == 16;
pub const Words = @Vector(16, i16);
const Bytes = @Vector(32, i8);

/// Swap the middle eight-byte blocks. This involution makes lane-local
/// unpack operations produce consecutive canonical accumulator values.
pub fn permute(bytes: []i8) void {
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 32) {
        const blocks: @Vector(4, u64) = @bitCast(bytes[offset..][0..32].*);
        bytes[offset..][0..32].* = @bitCast(@shuffle(u64, blocks, undefined, @Vector(4, i32){ 0, 2, 1, 3 }));
    }
}

inline fn unpack(comptime high: bool, a: Bytes, b: Bytes) Bytes {
    return asm (if (high) "vpunpckhbw %[b], %[a], %[out]" else "vpunpcklbw %[b], %[a], %[out]"
        : [out] "=x" (-> Bytes),
        : [a] "x" (a),
          [b] "x" (b),
    );
}

pub inline fn single(row: *const [32]i8) [2]Words {
    const bytes: Bytes = row.*;
    return .{
        @as(Words, @bitCast(unpack(false, @splat(0), bytes))) >> @splat(8),
        @as(Words, @bitCast(unpack(true, @splat(0), bytes))) >> @splat(8),
    };
}

pub inline fn sum(a: *const [32]i8, b: *const [32]i8) [2]Words {
    var result: [2]Words = undefined;
    inline for (0..2) |half| {
        const interleaved = unpack(half == 1, a.*, b.*);
        // Each pair is in [-256, 254], so maddubs cannot saturate.
        result[half] = asm ("vpmaddubsw %[rows], %[ones], %[out]"
            : [out] "=x" (-> Words),
            : [rows] "x" (interleaved),
              [ones] "x" (@as(@Vector(32, u8), @splat(1))),
        );
    }
    return result;
}

test "paired widening preserves signed extremes and canonical lane order" {
    if (!enabled) return;
    var a: [32]i8 = undefined;
    var b: [32]i8 = undefined;
    for (0..256) |x| {
        for (0..256) |y| {
            for (&a, &b, 0..) |*av, *bv, lane| {
                av.* = @bitCast(@as(u8, @truncate(x + lane)));
                bv.* = @bitCast(@as(u8, @truncate(y + lane * 7)));
            }
            const canonical_a = a;
            const canonical_b = b;
            permute(&a);
            permute(&b);
            const added: [32]i16 = @bitCast(sum(&a, &b));
            const widened: [32]i16 = @bitCast(single(&a));
            for (canonical_a, canonical_b, added, widened) |av, bv, actual, one| {
                try std.testing.expectEqual(@as(i16, av) + bv, actual);
                try std.testing.expectEqual(@as(i16, av), one);
            }
            permute(&a);
            try std.testing.expectEqualSlices(i8, &canonical_a, &a);
        }
    }
}
