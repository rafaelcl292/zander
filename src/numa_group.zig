const std = @import("std");
const numa = @import("numa.zig");
const h = @import("history.zig");
const memory = @import("memory.zig");
const Network = @import("nnue/network.zig").Network;

/// Per-node histories and an immutable network replica, created before search.
pub const Group = struct {
    arena: std.heap.ArenaAllocator,
    mask: ?numa.Mask,
    shared: h.SharedHistories,
    replica: ?memory.Region = null,
    network: ?*const Network,
    pub fn create(allocator: std.mem.Allocator, mask: ?numa.Mask, count: usize, network: ?*const Network) !*Group {
        const guard = try numa.Guard.bind(if (mask) |*cpus| cpus else null);
        defer guard.restore();
        const self = try allocator.create(Group);
        errdefer allocator.destroy(self);
        // Independent OS allocations preserve first-touch placement rather than
        // recycling pages from a general allocator's previous NUMA node.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const capacity = try std.math.ceilPowerOfTwo(usize, count);
        self.* = .{ .arena = arena, .mask = mask, .network = network, .shared = undefined };
        self.shared = try h.SharedHistories.init(capacity, try a.alloc(h.CorrectionEntry, capacity * h.correction_history_base_size), try a.create(h.ContinuationHistoryBlock), try a.alloc(h.PawnEntry, capacity * h.pawn_history_base_size));
        // ArenaAllocator is a value type; retain the updated allocation state.
        self.arena = arena;
        self.shared.clearRange(0, 1);
        if (network) |net| self.replica = try self.copyNetwork(allocator, net);
        if (self.replica) |region| self.network = @ptrCast(region.bytes.ptr);
        return self;
    }
    pub fn copyNetwork(self: *const Group, allocator: std.mem.Allocator, network: *const Network) !?memory.Region {
        if (self.mask == null) return null;
        const guard = try numa.Guard.bind(&self.mask.?);
        defer guard.restore();
        const region = try memory.Region.allocate(allocator, @sizeOf(Network), .transparent);
        @memcpy(region.bytes, std.mem.asBytes(network));
        return region;
    }
    pub fn replaceNetwork(self: *Group, network: *const Network, replica: ?memory.Region) void {
        if (self.replica) |*old| old.deinit();
        self.replica = replica;
        self.network = if (replica) |region| @ptrCast(region.bytes.ptr) else network;
    }
    pub fn destroy(self: *Group, allocator: std.mem.Allocator) void {
        if (self.replica) |*region| region.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }
};
