// Derived from Stockfish tt.h/tt.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
pub const Bound = enum(u8) { none, upper, lower, exact };
pub const depth_none: i32 = -3;
pub const Data = struct {
    move: t.Move,
    value: i32,
    eval: i32,
    depth: i32,
    bound: Bound,
    is_pv: bool,
};
/// Individual fields are relaxed atomics, matching upstream. A whole-entry
/// snapshot is deliberately not atomic and may contain inconsistent fields.
pub const Entry = extern struct {
    depth8: u8,
    gen_bound8: u8,
    move16: u16,
    value16: i16,
    eval16: i16,

    pub fn read(self: *const Entry) Data {
        return .{
            .move = .{ .data = @atomicLoad(u16, &self.move16, .monotonic) },
            .value = @atomicLoad(i16, &self.value16, .monotonic),
            .eval = @atomicLoad(i16, &self.eval16, .monotonic),
            .depth = depth_none + @as(i32, @atomicLoad(u8, &self.depth8, .monotonic)),
            .bound = @fromBackingInt(@intCast((@atomicLoad(u8, &self.gen_bound8, .monotonic) & 0x60) >> 5)),
            .is_pv = @atomicLoad(u8, &self.gen_bound8, .monotonic) & 0x80 != 0,
        };
    }
    pub fn occupied(self: *const Entry) bool {
        return @atomicLoad(u8, &self.depth8, .monotonic) != 0;
    }
    pub fn relativeAge(self: *const Entry, generation: u8) u8 {
        return (generation -% @atomicLoad(u8, &self.gen_bound8, .monotonic)) & 31;
    }
    pub fn penalize(self: *Entry, penalty: i32) void {
        std.debug.assert(penalty >= 0);
        @atomicStore(u8, &self.depth8, @intCast(@max(@as(i32, @atomicLoad(u8, &self.depth8, .monotonic)) - penalty, 0)), .monotonic);
    }
};
const key_mask: u64 = (1 << 21) - 1;
// Three 21-bit key fragments share one relaxed atomic word; the entire
// 32-byte cluster still fits in half a cache line.
pub const Cluster = extern struct { keys: u64, entries: [3]Entry };
pub const Writer = struct {
    cluster: *Cluster,
    index: usize,
    pub fn read(self: Writer) Data {
        return self.cluster.entries[self.index].read();
    }
    pub fn penalize(self: Writer, penalty: i32) void {
        self.cluster.entries[self.index].penalize(penalty);
    }
    pub fn save(self: Writer, key: u64, data: Data, generation: u8) void {
        const entry = &self.cluster.entries[self.index];
        const shift: u6 = @intCast(21 * self.index);
        var keys = @atomicLoad(u64, &self.cluster.keys, .monotonic);
        const old_key = (keys >> shift) & key_mask;
        const key21 = key & key_mask;
        if (data.move.data != 0 or key21 != old_key) @atomicStore(u16, &entry.move16, data.move.data, .monotonic);
        if (data.bound == .exact or key21 != old_key or data.depth - depth_none + 2 * @as(i32, @intFromBool(data.is_pv)) > @as(i32, @atomicLoad(u8, &entry.depth8, .monotonic)) - 4 or entry.relativeAge(generation) != 0) {
            std.debug.assert(data.depth > depth_none and data.depth - depth_none < 256 and generation <= 31);
            keys = (keys & ~(key_mask << shift)) | (key21 << shift);
            @atomicStore(u64, &self.cluster.keys, keys, .monotonic);
            @atomicStore(u8, &entry.depth8, @intCast(data.depth - depth_none), .monotonic);
            @atomicStore(u8, &entry.gen_bound8, generation | (@backingInt(data.bound) << 5) | (@as(u8, @intFromBool(data.is_pv)) << 7), .monotonic);
            @atomicStore(i16, &entry.value16, @intCast(data.value), .monotonic);
            @atomicStore(i16, &entry.eval16, @intCast(data.eval), .monotonic);
        } else if (@as(i32, @atomicLoad(u8, &entry.depth8, .monotonic)) + depth_none >= 5 and (@atomicLoad(u8, &entry.gen_bound8, .monotonic) & 0x60) >> 5 != @backingInt(Bound.exact)) {
            const v: i32 = @atomicLoad(i16, &entry.value16, .monotonic);
            const tb_win_in_max_ply = t.value_mate - 2 * t.max_ply - 1;
            if (@abs(v) < t.value_infinite and @abs(v) >= tb_win_in_max_ply) self.penalize(1);
        }
    }
};
pub const Probe = struct { found: bool, data: Data, writer: Writer };
/// Storage is allocated by the owner before search. clear/newSearch require
/// exclusive control; probe/save/penalize support the upstream relaxed races.
pub const Table = struct {
    clusters: []align(64) Cluster,
    generation: u8 = 0,
    pub fn init(storage: []align(64) Cluster) Table {
        std.debug.assert(storage.len >= 1000);
        var table: Table = .{ .clusters = storage };
        table.clear();
        return table;
    }
    pub fn clear(self: *Table) void {
        self.generation = 0;
        @memset(std.mem.sliceAsBytes(self.clusters), 0);
    }
    pub fn prefetch(self: *const Table, key: u64) void {
        @import("prefetch.zig").read(&self.clusters[self.clusterIndex(key)]);
    }
    pub fn newSearch(self: *Table) void {
        self.generation = (self.generation + 1) & 31;
    }
    pub fn clusterIndex(self: *const Table, key: u64) usize {
        return @intCast((@as(u128, key) * self.clusters.len) >> 64);
    }
    pub fn probe(self: *const Table, key: u64) Probe {
        const cluster = &self.clusters[self.clusterIndex(key)];
        const entries = &cluster.entries;
        const key21 = key & key_mask;
        const key_lsb: u64 = 1 | (1 << 21) | (1 << 42);
        const key_msb = key_lsb << 20;
        const key_xors = @atomicLoad(u64, &cluster.keys, .monotonic) ^ (key_lsb * key21);
        // Later lanes may contain borrow artifacts; only the first match counts.
        const matches = (key_xors -% key_lsb) & ~key_xors & key_msb;
        if (matches != 0) {
            const index = @ctz(matches) / 21;
            return .{ .found = entries[index].occupied(), .data = entries[index].read(), .writer = .{ .cluster = cluster, .index = index } };
        }
        var replace: usize = 0;
        for (1..3) |i| {
            if (@as(i32, @atomicLoad(u8, &entries[replace].depth8, .monotonic)) - 8 * @as(i32, entries[replace].relativeAge(self.generation)) > @as(i32, @atomicLoad(u8, &entries[i].depth8, .monotonic)) - 8 * @as(i32, entries[i].relativeAge(self.generation))) replace = i;
        }
        return .{ .found = false, .data = .{ .move = t.Move.none, .value = t.value_none, .eval = t.value_none, .depth = depth_none, .bound = .none, .is_pv = false }, .writer = .{ .cluster = cluster, .index = replace } };
    }
    pub fn hashfull(self: *const Table, max_age: i32) u32 {
        var count: u32 = 0;
        for (self.clusters[0..1000]) |*cluster| {
            for (&cluster.entries) |*entry| {
                if (entry.occupied() and entry.relativeAge(self.generation) <= max_age) count += 1;
            }
        }
        return count / 3;
    }
};
comptime {
    std.debug.assert(@sizeOf(Entry) == 8);
    std.debug.assert(@sizeOf(Cluster) == 32);
    std.debug.assert(@offsetOf(Entry, "move16") == 2);
}

test "21-bit keys distinguish old 16-bit collisions and preserve neighboring entries" {
    var storage: [1024]Cluster align(64) = undefined;
    var table = Table.init(&storage);
    const keys = [_]u64{ 0x1234, 0x11234, 0x101234 };
    for (keys, 0..) |key, i| {
        const probe = table.probe(key);
        try std.testing.expect(!probe.found);
        probe.writer.save(key, .{ .move = .{ .data = @intCast(i + 1) }, .value = @intCast(i), .eval = 0, .depth = 1, .bound = .exact, .is_pv = false }, table.generation);
    }
    for (keys, 0..) |key, i| {
        const probe = table.probe(key);
        try std.testing.expect(probe.found);
        try std.testing.expectEqual(i, probe.writer.index);
        try std.testing.expectEqual(@as(i32, @intCast(i)), probe.data.value);
    }
    // Bits above the stored 21-bit fragment do not distinguish this cluster.
    try std.testing.expect(table.probe(keys[0] | (1 << 21)).found);
    // The SWAR subtraction may borrow into later lanes; the first match wins.
    storage[0].keys = 7 | (@as(u64, 6) << 21) | (@as(u64, 7) << 42);
    try std.testing.expectEqual(@as(usize, 0), table.probe(7).writer.index);
    try std.testing.expectEqual(@as(usize, 1), table.probe(6).writer.index);
    storage[0].keys = 7 | (@as(u64, 6) << 21);
    try std.testing.expectEqual(@as(usize, 2), table.probe(0).writer.index);
}
