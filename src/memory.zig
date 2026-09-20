const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
pub const PagePolicy = enum { auto, small, transparent, huge2m, huge1g };
pub const Backing = enum { allocator, small, transparent_hint, huge2m, huge1g };

/// A separately owned mapping prevents general allocator arena reuse from
/// silently retaining placement from a previous engine configuration.
pub const Region = struct {
    bytes: []align(64) u8,
    mapped_length: usize = 0,
    backing: Backing,
    allocator: std.mem.Allocator,
    pub fn allocate(allocator: std.mem.Allocator, size: usize, policy: PagePolicy) !Region {
        if (size == 0) return error.InvalidAllocationSize;
        if (builtin.os.tag == .linux) {
            const huge_size: usize = if (policy == .huge2m) 2 * 1024 * 1024 else 1024 * 1024 * 1024;
            if (policy == .huge2m or policy == .huge1g or (policy == .auto and size >= huge_size)) {
                const length = std.mem.alignForward(usize, size, huge_size);
                const base_flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .HUGETLB = true };
                const shift: u32 = if (policy == .huge2m) 21 else 30;
                const flags: linux.MAP = @bitCast(@as(u32, @bitCast(base_flags)) | (shift << 26));
                if (map(length, flags)) |ptr| return .{ .bytes = ptr[0..size], .mapped_length = length, .backing = if (policy == .huge2m) .huge2m else .huge1g, .allocator = allocator };
            }
            const transparent = policy == .auto or policy == .transparent;
            const alignment: usize = if (transparent) 2 * 1024 * 1024 else std.heap.pageSize();
            const length = std.mem.alignForward(usize, size, alignment);
            const reserve = try std.math.add(usize, length, alignment);
            const raw = map(reserve, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }) orelse return error.OutOfMemory;
            const start = std.mem.alignForward(usize, @intFromPtr(raw), alignment);
            const prefix = start - @intFromPtr(raw);
            const suffix = reserve - prefix - length;
            if (prefix != 0) _ = linux.munmap(raw, prefix);
            const ptr: [*]align(64) u8 = @ptrFromInt(start);
            if (suffix != 0) _ = linux.munmap(ptr + length, suffix);
            const advice: u32 = if (transparent) linux.MADV.HUGEPAGE else linux.MADV.NOHUGEPAGE;
            const advised = linux.errno(linux.madvise(ptr, length, advice)) == .SUCCESS;
            return .{ .bytes = ptr[0..size], .mapped_length = length, .backing = if (transparent and advised) .transparent_hint else .small, .allocator = allocator };
        }
        return .{ .bytes = try allocator.alignedAlloc(u8, .@"64", size), .backing = .allocator, .allocator = allocator };
    }
    fn map(size: usize, flags: linux.MAP) ?[*]align(64) u8 {
        const result = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, flags, -1, 0);
        if (linux.errno(result) != .SUCCESS) return null;
        return @ptrFromInt(result);
    }
    pub fn deinit(self: *Region) void {
        if (builtin.os.tag == .linux and self.mapped_length != 0) {
            _ = linux.munmap(self.bytes.ptr, self.mapped_length);
        } else self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

test "page policies retain requested capacity and alignment with fallback" {
    for ([_]PagePolicy{ .small, .transparent, .huge2m }) |policy| {
        var region = try Region.allocate(std.testing.allocator, 1024 * 1024 + 17, policy);
        defer region.deinit();
        try std.testing.expectEqual(@as(usize, 1024 * 1024 + 17), region.bytes.len);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(region.bytes.ptr) % 64);
        if (region.backing == .transparent_hint) try std.testing.expectEqual(@as(usize, 0), @intFromPtr(region.bytes.ptr) % (2 * 1024 * 1024));
        region.bytes[0] = 12;
        region.bytes[region.bytes.len - 1] = 34;
        try std.testing.expectEqual(@as(u8, 12), region.bytes[0]);
        try std.testing.expectEqual(@as(u8, 34), region.bytes[region.bytes.len - 1]);
    }
}
