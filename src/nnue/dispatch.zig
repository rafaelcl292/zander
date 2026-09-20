const std = @import("std");
const builtin = @import("builtin");
pub const Kernel = enum(u8) { sse2 = 1, avx2, avx512, avxvnni, vnni512 };
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
fn selectFeatures(max_leaf: u32, leaf1: u32, xcr0: u32, leaf7: Registers, leaf71_eax: u32) Kernel {
    if (!permitted(max_leaf, leaf1, xcr0, leaf7.ebx)) return .sse2;
    const avx512_bits = (@as(u32, 1) << 16) | (@as(u32, 1) << 30);
    if (xcr0 & 0xe6 == 0xe6 and leaf7.ebx & avx512_bits == avx512_bits) {
        if (leaf7.ecx & (1 << 11) != 0) return .vnni512;
        return .avx512;
    }
    if (leaf7.eax >= 1 and leaf71_eax & (1 << 4) != 0) return .avxvnni;
    return .avx2;
}
fn detect() Kernel {
    if (builtin.cpu.arch != .x86_64) return .sse2;
    const max_leaf = cpuid(0, 0).eax;
    if (max_leaf < 7) return .sse2;
    const flags = cpuid(1, 0).ecx;
    if (flags & ((1 << 27) | (1 << 28)) != ((1 << 27) | (1 << 28))) return .sse2;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("xgetbv"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
        : [_] "{ecx}" (@as(u32, 0)),
    );
    const leaf7 = cpuid(7, 0);
    return selectFeatures(max_leaf, flags, lo, leaf7, if (leaf7.eax >= 1) cpuid(7, 1).eax else 0);
}
/// Atomic caching permits simultaneous first use by independent workers.
pub fn selected() Kernel {
    const value = cached.load(.acquire);
    if (value != 0) return @enumFromInt(value);
    const kernel = detect();
    cached.store(@intFromEnum(kernel), .release);
    return kernel;
}
const Affine = *const fn ([*]const u8, [*]const i8, [*]const i32, [*]i32, usize, usize) callconv(.c) void;
pub extern fn zander_affine_avx2([*]const u8, [*]const i8, [*]const i32, [*]i32, usize, usize) void;
extern fn zander_affine_avx512([*]const u8, [*]const i8, [*]const i32, [*]i32, usize, usize) void;
extern fn zander_affine_avxvnni([*]const u8, [*]const i8, [*]const i32, [*]i32, usize, usize) void;
extern fn zander_affine_vnni512([*]const u8, [*]const i8, [*]const i32, [*]i32, usize, usize) void;
pub fn function(kernel: Kernel) ?Affine {
    return switch (kernel) {
        .sse2 => null,
        .avx2 => &zander_affine_avx2,
        .avx512 => &zander_affine_avx512,
        .avxvnni => &zander_affine_avxvnni,
        .vnni512 => &zander_affine_vnni512,
    };
}

test "AVX2 dispatch requires OS context support and every instruction prerequisite" {
    const flags = (1 << 27) | (1 << 28);
    try std.testing.expect(permitted(7, flags, 6, 1 << 5));
    try std.testing.expect(!permitted(6, flags, 6, 1 << 5));
    try std.testing.expect(!permitted(7, 1 << 28, 6, 1 << 5));
    try std.testing.expect(!permitted(7, 1 << 27, 6, 1 << 5));
    try std.testing.expect(!permitted(7, flags, 2, 1 << 5));
    try std.testing.expect(!permitted(7, flags, 4, 1 << 5));
    try std.testing.expect(!permitted(7, flags, 6, 0));
    try std.testing.expectEqual(detect(), selected());
    try std.testing.expectEqual(detect(), selected());
}

test "extended dispatch requires complete AVX512 state and VNNI leaves" {
    const flags = (1 << 27) | (1 << 28);
    const leaf: Registers = .{ .eax = 1, .ebx = (1 << 5) | (1 << 16) | (1 << 30), .ecx = 1 << 11, .edx = 0 };
    try std.testing.expectEqual(Kernel.vnni512, selectFeatures(7, flags, 0xe6, leaf, 1 << 4));
    try std.testing.expectEqual(Kernel.avxvnni, selectFeatures(7, flags, 6, leaf, 1 << 4));
    try std.testing.expectEqual(Kernel.avx2, selectFeatures(7, flags, 6, leaf, 0));
    var no_dot = leaf;
    no_dot.ecx = 0;
    try std.testing.expectEqual(Kernel.avx512, selectFeatures(7, flags, 0xe6, no_dot, 0));
    no_dot.ebx &= ~(@as(u32, 1) << 30);
    try std.testing.expectEqual(Kernel.avx2, selectFeatures(7, flags, 0xe6, no_dot, 0));
}

const Sparse = *const fn ([*]const u8, [*]const i8, [*]const i32, [*]i32) callconv(.c) void;
extern fn zander_sparse_avx2([*]const u8, [*]const i8, [*]const i32, [*]i32) void;
extern fn zander_sparse_avx512([*]const u8, [*]const i8, [*]const i32, [*]i32) void;
extern fn zander_sparse_avxvnni([*]const u8, [*]const i8, [*]const i32, [*]i32) void;
extern fn zander_sparse_vnni512([*]const u8, [*]const i8, [*]const i32, [*]i32) void;
pub fn sparseFunction(kernel: Kernel) ?Sparse {
    return switch (kernel) {
        .sse2 => null,
        .avx2 => &zander_sparse_avx2,
        .avx512 => &zander_sparse_avx512,
        .avxvnni => &zander_sparse_avxvnni,
        .vnni512 => &zander_sparse_vnni512,
    };
}
