// AVX2 byte packs operate independently in each 128-bit lane.
const std = @import("std");
const cpu = @import("builtin").cpu;
// Only targets that guarantee AVX2 use this layout. Generic targets retain
// canonical activations even when runtime dispatch selects an AVX2 kernel.
pub const native_pack = @import("backend").nnue_sparse and @import("backend").nnue_backend == .auto and cpu.arch == .x86_64 and std.Target.x86.featureSetHas(cpu.features, .avx2);
/// Map a physical activation offset to its canonical neuron. In each group
/// of 32: 0..7, 16..23, 8..15, 24..31. Four-byte sparsity blocks stay intact.
pub fn canonical(index: usize) usize {
    if (!native_pack) return index;
    return (index & ~@as(usize, 31)) | (index & 7) | ((index & 8) << 1) | ((index & 16) >> 1);
}
pub fn prepare(input: *const [1024]u8, output: *[1024]u8) void {
    for (output, 0..) |*value, i| value.* = input[canonical(i)];
}
