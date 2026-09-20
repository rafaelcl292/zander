const std = @import("std");
const builtin = @import("builtin");
var cached: std.atomic.Value(u8) = .init(0);

const Registers = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };
fn cpuid(leaf: u32, subleaf: u32) Registers {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
fn permitted(max_leaf: u32, leaf1_ecx: u32, xcr0: u32, leaf7_ebx: u32) bool {
    const avx_and_osxsave = (@as(u32, 1) << 28) | (@as(u32, 1) << 27);
    return max_leaf >= 7 and leaf1_ecx & avx_and_osxsave == avx_and_osxsave and xcr0 & 6 == 6 and leaf7_ebx & (1 << 5) != 0;
}
fn detect() bool {
    if (builtin.cpu.arch != .x86_64) return false;
    const max_leaf = cpuid(0, 0).eax;
    if (max_leaf < 7) return false;
    const flags = cpuid(1, 0).ecx;
    if (flags & ((1 << 27) | (1 << 28)) != ((1 << 27) | (1 << 28))) return false;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("xgetbv"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
        : [_] "{ecx}" (@as(u32, 0)),
    );
    return permitted(max_leaf, flags, lo, cpuid(7, 0).ebx);
}
/// Atomic caching permits simultaneous first use by independent workers.
pub fn hasAvx2() bool {
    const value = cached.load(.acquire);
    if (value != 0) return value == 2;
    const available = detect();
    cached.store(if (available) 2 else 1, .release);
    return available;
}
pub extern fn zander_affine_avx2(input: [*]const u8, weights: [*]const i8, biases: [*]const i32, output: [*]i32, inputs: usize, outputs: usize) void;

test "AVX2 dispatch requires OS context support and every instruction prerequisite" {
    const flags = (1 << 27) | (1 << 28);
    try std.testing.expect(permitted(7, flags, 6, 1 << 5));
    try std.testing.expect(!permitted(6, flags, 6, 1 << 5));
    try std.testing.expect(!permitted(7, 1 << 28, 6, 1 << 5));
    try std.testing.expect(!permitted(7, 1 << 27, 6, 1 << 5));
    try std.testing.expect(!permitted(7, flags, 2, 1 << 5));
    try std.testing.expect(!permitted(7, flags, 4, 1 << 5));
    try std.testing.expect(!permitted(7, flags, 6, 0));
    try std.testing.expectEqual(detect(), hasAvx2());
    try std.testing.expectEqual(detect(), hasAvx2());
}
