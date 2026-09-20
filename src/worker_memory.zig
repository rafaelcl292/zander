//! Fixed-capacity private search storage. One allocation owns every payload;
//! search borrows typed pointers and cannot grow this storage.
const std = @import("std");
const t = @import("types.zig");
const h = @import("history.zig");
const acc = @import("nnue/accumulator.zig");

pub const Storage = struct {
    base: @import("quiescence.zig").Worker,
    accumulators: acc.Stack,
    caches: acc.Caches,
    main_history: h.ButterflyHistory,
    low_ply_history: h.LowPlyHistory,
    capture_history: h.CapturePieceToHistory,
    continuation_correction: h.ContinuationCorrectionHistory,
    roots: [t.max_moves]@import("root_move.zig").RootMove,

    /// Leaves payloads uninitialized, just as individually allocated storage.
    /// The owner must initialize histories, frames and network-dependent caches
    /// before they are read. No allocator is retained in this object.
    pub fn create(allocator: std.mem.Allocator) !*Storage {
        return allocator.create(Storage);
    }

    /// Only the owner may release storage, after all borrowing workers stop.
    pub fn destroy(self: *Storage, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

/// Exact payload budget including compiler-required internal/tail padding.
/// Excludes helper control objects, OS thread stacks, allocator page rounding,
/// shared histories, network replicas, TT, position history and UCI buffers.
pub const Plan = struct {
    pub const bytes_per_worker = @sizeOf(Storage);
    pub const alignment = @alignOf(Storage);
    pub const root_capacity = t.max_moves;
    pub const frame_capacity = t.max_ply + 10;
    pub const accumulator_capacity = t.max_ply + 1;

    pub fn bytesForWorkers(count: usize) error{Overflow}!usize {
        return std.math.mul(usize, count, bytes_per_worker);
    }

    pub fn write(writer: *std.Io.Writer, count: usize) !void {
        const total = try bytesForWorkers(count);
        try writer.print("{{\n\"workers\":{d},\"bytes_per_worker\":{d},\"total_payload_bytes\":{d},\"alignment\":{d},\n", .{ count, bytes_per_worker, total, alignment });
        try writer.print("\"frame_capacity\":{d},\"accumulator_capacity\":{d},\"root_capacity\":{d},\n\"components\":[", .{ frame_capacity, accumulator_capacity, root_capacity });
        inline for (@typeInfo(Storage).@"struct".fields, 0..) |field, i| {
            if (i != 0) try writer.writeAll(",");
            try writer.print("{{\"name\":\"{s}\",\"offset\":{d},\"bytes\":{d},\"alignment\":{d}}}", .{ field.name, @offsetOf(Storage, field.name), @sizeOf(field.type), @alignOf(field.type) });
        }
        try writer.writeAll("]\n}\n");
    }
};

test "worker storage has a single bounded allocation and releases its owner" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const storage = try Storage.create(allocator.allocator());
    defer storage.destroy(allocator.allocator());
    try std.testing.expectEqual(@as(usize, 1), allocator.allocations);
    try std.testing.expectEqual(Plan.bytes_per_worker, allocator.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(storage) % Plan.alignment);
    const start = @intFromPtr(storage);
    inline for (@typeInfo(Storage).@"struct".fields) |field| {
        const address = @intFromPtr(&@field(storage, field.name));
        try std.testing.expect(address >= start);
        try std.testing.expect(address + @sizeOf(field.type) <= start + Plan.bytes_per_worker);
        try std.testing.expectEqual(@as(usize, 0), address % @alignOf(field.type));
    }
    // Exercise both ends of independent writable buffers without another
    // allocation. Allocation failure must not affect already reserved payloads.
    storage.roots[0] = .init(.none);
    storage.roots[t.max_moves - 1] = .init(.null_move);
    storage.accumulators.reset();
    try std.testing.expectEqual(@as(usize, 1), storage.accumulators.size);
    try std.testing.expectError(error.OutOfMemory, Storage.create(allocator.allocator()));
    try std.testing.expectEqual(t.Move.null_move.data, storage.roots[t.max_moves - 1].pv.moves[0].data);
}

test "worker budget rejects overflow and allocation failure leaks nothing" {
    try std.testing.expectEqual(@as(usize, 0), try Plan.bytesForWorkers(0));
    try std.testing.expectEqual(3 * Plan.bytes_per_worker, try Plan.bytesForWorkers(3));
    try std.testing.expectError(error.Overflow, Plan.bytesForWorkers(std.math.maxInt(usize)));
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Storage.create(allocator.allocator()));
    try std.testing.expectEqual(@as(usize, 0), allocator.allocated_bytes);
}
