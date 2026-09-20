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
