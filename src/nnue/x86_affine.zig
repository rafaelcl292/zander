// ISA-specific object. Dispatch checks both CPU features and OS register state.
const kind = @import("kernel_options").kind;
const dot_product = kind == .avxvnni or kind == .vnni512;
const lanes = switch (kind) {
    .avx2 => 16,
    .avx512 => 32,
    .avxvnni => 32,
    .vnni512 => 64,
};
const sums_count = lanes / (if (dot_product) 4 else 2);
comptime {
    @export(&affine, .{ .name = "zander_affine_" ++ @tagName(kind) });
}
fn affine(input: [*]const u8, weights: [*]const i8, biases: [*]const i32, output: [*]i32, inputs: usize, outputs: usize) callconv(.c) void {
    for (0..outputs) |row| {
        var sums: @Vector(sums_count, i32) = @splat(0);
        var offset: usize = 0;
        while (offset + lanes <= inputs) : (offset += lanes) {
            const x: @Vector(lanes, u8) = input[offset..][0..lanes].*;
            const w: @Vector(lanes, i8) = weights[row * inputs + offset ..][0..lanes].*;
            if (dot_product) {
                sums = asm ("vpdpbusd %[weights], %[input], %[result]"
                    : [result] "=x" (-> @Vector(sums_count, i32)),
                    : [input] "x" (x),
                      [weights] "x" (w),
                      [previous] "0" (sums),
                );
            } else {
                const products = asm ("vpmaddwd %[weights], %[input], %[result]"
                    : [result] "=x" (-> @Vector(sums_count, i32)),
                    : [input] "x" (@as(@Vector(lanes, i16), @intCast(x))),
                      [weights] "x" (@as(@Vector(lanes, i16), w)),
                );
                sums +%= products;
            }
        }
        var sum = biases[row] +% @reduce(.Add, sums);
        while (offset < inputs) : (offset += 1) sum +%= @as(i32, input[offset]) * weights[row * inputs + offset];
        output[row] = sum;
    }
}

// Derived from Stockfish affine_transform_sparse_input.h; GPL-3.0-or-later.
// Activations are bounded to 0..127 by the feature transformer, so adjacent
// unsigned-byte/signed-byte products cannot saturate the intermediate i16 sum.
comptime {
    @export(&sparse, .{ .name = "zander_sparse_" ++ @tagName(kind) });
}
fn sparse(input: [*]const u8, masks: [*]const u64, weights: [*]const i8, biases: [*]const i32, output: [*]i32) callconv(.c) void {
    const bytes = if (kind == .avx512 or kind == .vnni512) 64 else 32;
    const width = bytes / 4;
    const Vec = @Vector(width, i32);
    var accumulators: [32 / width]Vec = undefined;
    inline for (0..32 / width) |i| accumulators[i] = biases[i * width ..][0..width].*;
    for (0..4) |group| {
        var bits = masks[group];
        while (bits != 0) {
            const block = group * 64 + @ctz(bits);
            bits &= bits - 1;
            const input_word = @import("std").mem.readInt(u32, input[block * 4 ..][0..4], .little);
            const x: @Vector(bytes, u8) = @bitCast(@as(@Vector(width, u32), @splat(input_word)));
            inline for (0..32 / width) |i| {
                const w: @Vector(bytes, i8) = weights[block * 128 + i * bytes ..][0..bytes].*;
                if (dot_product) {
                    accumulators[i] = asm ("vpdpbusd %[weights], %[input], %[result]"
                        : [result] "=x" (-> Vec),
                        : [input] "x" (x),
                          [weights] "x" (w),
                          [previous] "0" (accumulators[i]),
                    );
                } else {
                    const pairs = asm ("vpmaddubsw %[weights], %[input], %[result]"
                        : [result] "=x" (-> @Vector(bytes / 2, i16)),
                        : [input] "x" (x),
                          [weights] "x" (w),
                    );
                    const products = asm ("vpmaddwd %[ones], %[pairs], %[result]"
                        : [result] "=x" (-> Vec),
                        : [pairs] "x" (pairs),
                          [ones] "x" (@as(@Vector(bytes / 2, i16), @splat(1))),
                    );
                    accumulators[i] +%= products;
                }
            }
        }
    }
    inline for (0..32 / width) |i| output[i * width ..][0..width].* = accumulators[i];
}

// Packed 64-input hidden layer; canonical activation order is retained.
comptime {
    @export(&hidden, .{ .name = "zander_hidden_" ++ @tagName(kind) });
}
fn hidden(input: [*]const u8, weights: [*]const i8, biases: [*]const i32, output: [*]i32) callconv(.c) void {
    const bytes = if (kind == .avx512 or kind == .vnni512) 64 else 32;
    const width = bytes / 4;
    const Vec = @Vector(width, i32);
    var accumulators: [32 / width]Vec = undefined;
    inline for (0..32 / width) |i| accumulators[i] = biases[i * width ..][0..width].*;
    for (0..16) |block| {
        const input_word = @import("std").mem.readInt(u32, input[block * 4 ..][0..4], .little);
        const x: @Vector(bytes, u8) = @bitCast(@as(@Vector(width, u32), @splat(input_word)));
        inline for (0..32 / width) |i| {
            const w: @Vector(bytes, i8) = weights[block * 128 + i * bytes ..][0..bytes].*;
            if (dot_product) {
                accumulators[i] = asm ("vpdpbusd %[weights], %[input], %[result]"
                    : [result] "=x" (-> Vec),
                    : [input] "x" (x),
                      [weights] "x" (w),
                      [previous] "0" (accumulators[i]),
                );
            } else {
                const pairs = asm ("vpmaddubsw %[weights], %[input], %[result]"
                    : [result] "=x" (-> @Vector(bytes / 2, i16)),
                    : [input] "x" (x),
                      [weights] "x" (w),
                );
                const products = asm ("vpmaddwd %[ones], %[pairs], %[result]"
                    : [result] "=x" (-> Vec),
                    : [pairs] "x" (pairs),
                      [ones] "x" (@as(@Vector(bytes / 2, i16), @splat(1))),
                );
                accumulators[i] +%= products;
            }
        }
    }
    inline for (0..32 / width) |i| output[i * width ..][0..width].* = accumulators[i];
}

comptime {
    @export(&outputLayer, .{ .name = "zander_output_" ++ @tagName(kind) });
}
fn outputLayer(input: [*]const u8, weights: [*]const i8, biases: [*]const i32, output: [*]i32) callconv(.c) void {
    // The reference single-output path reduces four 256-bit byte products.
    var sums: @Vector(8, i32) = @splat(0);
    inline for (0..4) |i| {
        const x: @Vector(32, u8) = input[i * 32 ..][0..32].*;
        const w: @Vector(32, i8) = weights[i * 32 ..][0..32].*;
        const pairs = asm ("vpmaddubsw %[weights], %[input], %[result]"
            : [result] "=x" (-> @Vector(16, i16)),
            : [input] "x" (x),
              [weights] "x" (w),
        );
        sums +%= asm ("vpmaddwd %[ones], %[pairs], %[result]"
            : [result] "=x" (-> @Vector(8, i32)),
            : [pairs] "x" (pairs),
              [ones] "x" (@as(@Vector(16, i16), @splat(1))),
        );
    }
    output[0] = biases[0] +% @reduce(.Add, sums);
}
