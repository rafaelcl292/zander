// ARM NNUE kernels using Stockfish's four-input weight layout; GPL-3.0-or-later.
const std = @import("std");
const cpu = @import("builtin").cpu;
const Bytes = @Vector(16, i8);
const Sums = @Vector(4, i32);

/// Activations are clipped to 0..127, so signed dot products are exact.
/// Baseline ARM targets retain a vector fallback without requiring dotprod.
inline fn dot(acc: Sums, input: Bytes, weights: Bytes) Sums {
    if (comptime std.Target.aarch64.featureSetHas(cpu.features, .dotprod)) {
        return asm ("sdot %[result].4s, %[weights].16b, %[input].16b"
            : [result] "=w" (-> Sums),
            : [previous] "0" (acc),
              [weights] "w" (weights),
              [input] "w" (input),
        );
    }
    const products = @as(@Vector(16, i16), input) * @as(@Vector(16, i16), weights);
    const a: Sums = @shuffle(i16, products, undefined, @Vector(4, i32){ 0, 4, 8, 12 });
    const b: Sums = @shuffle(i16, products, undefined, @Vector(4, i32){ 1, 5, 9, 13 });
    const c: Sums = @shuffle(i16, products, undefined, @Vector(4, i32){ 2, 6, 10, 14 });
    const d: Sums = @shuffle(i16, products, undefined, @Vector(4, i32){ 3, 7, 11, 15 });
    return acc +% (a + b + c + d);
}

inline fn block(input: [*]const u8, index: usize) Bytes {
    const word = std.mem.readInt(u32, input[index * 4 ..][0..4], .little);
    return @bitCast(@as(@Vector(4, u32), @splat(word)));
}

pub fn sparse(input: [*]const u8, masks: [*]const u64, weights: [*]const i8, biases: [*]const i32, output: [*]i32) callconv(.c) void {
    var sums: [8]Sums = undefined;
    inline for (0..8) |i| sums[i] = biases[i * 4 ..][0..4].*;
    for (0..4) |part| {
        var bits = masks[part];
        while (bits != 0) {
            const index = part * 64 + @ctz(bits);
            bits &= bits - 1;
            const x = block(input, index);
            const row = weights + index * 128;
            inline for (0..8) |i| sums[i] = dot(sums[i], x, row[i * 16 ..][0..16].*);
        }
    }
    inline for (0..8) |i| output[i * 4 ..][0..4].* = sums[i];
}

pub fn hidden(input: [*]const u8, weights: [*]const i8, biases: [*]const i32, output: [*]i32) callconv(.c) void {
    var sums: [8]Sums = undefined;
    inline for (0..8) |i| sums[i] = biases[i * 4 ..][0..4].*;
    for (0..16) |index| {
        const x = block(input, index);
        const row = weights + index * 128;
        inline for (0..8) |i| sums[i] = dot(sums[i], x, row[i * 16 ..][0..16].*);
    }
    inline for (0..8) |i| output[i * 4 ..][0..4].* = sums[i];
}

pub fn final(input: [*]const u8, weights: [*]const i8, biases: [*]const i32, output: [*]i32) callconv(.c) void {
    var sums: [4]Sums = @splat(@splat(0));
    for (0..2) |group| {
        inline for (0..4) |i| {
            const offset = (group * 4 + i) * 16;
            sums[i] = dot(sums[i], @bitCast(input[offset..][0..16].*), weights[offset..][0..16].*);
        }
    }
    output[0] = biases[0] +% @reduce(.Add, sums[0] +% sums[1] +% sums[2] +% sums[3]);
}

/// Clip signed accumulator lanes to bytes before widening multiplication.
/// SQXTUN performs both lower/upper saturation in one instruction.
pub fn clippedProduct(a: @Vector(8, i16), b: @Vector(8, i16)) @Vector(8, u8) {
    const first = asm ("sqxtun %[result].8b, %[input].8h"
        : [result] "=w" (-> @Vector(8, u8)),
        : [input] "w" (a),
    );
    const second = asm ("sqxtun %[result].8b, %[input].8h"
        : [result] "=w" (-> @Vector(8, u8)),
        : [input] "w" (b),
    );
    return @intCast((@as(@Vector(8, u16), first) * @as(@Vector(8, u16), second)) >> @splat(9));
}
