// Separately compiled AVX2 object; callable only after CPU and OS checks.
export fn zander_affine_avx2(input: [*]const u8, weights: [*]const i8, biases: [*]const i32, output: [*]i32, inputs: usize, outputs: usize) void {
    for (0..outputs) |row| {
        var sums: @Vector(8, i32) = @splat(0);
        var offset: usize = 0;
        while (offset < inputs) : (offset += 16) {
            const x: @Vector(16, u8) = input[offset..][0..16].*;
            const w: @Vector(16, i8) = weights[row * inputs + offset ..][0..16].*;
            const products = asm ("vpmaddwd %[weights], %[input], %[result]"
                : [result] "=x" (-> @Vector(8, i32)),
                : [input] "x" (@as(@Vector(16, i16), @intCast(x))),
                  [weights] "x" (@as(@Vector(16, i16), w)),
            );
            sums +%= products;
        }
        output[row] = biases[row] +% @reduce(.Add, sums);
    }
}
