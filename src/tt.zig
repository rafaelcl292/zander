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
    key16: u16,
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
            .bound = @enumFromInt((@atomicLoad(u8, &self.gen_bound8, .monotonic) & 0x60) >> 5),
            .is_pv = @atomicLoad(u8, &self.gen_bound8, .monotonic) & 0x80 != 0,
        };
    }
    pub fn occupied(self: *const Entry) bool {
        return @atomicLoad(u8, &self.depth8, .monotonic) != 0;
    }
    pub fn relativeAge(self: *const Entry, generation: u8) u8 {
        return (generation -% @atomicLoad(u8, &self.gen_bound8, .monotonic)) & 31;
    }
    pub fn save(self: *Entry, key: u64, data: Data, generation: u8) void {
        const key16: u16 = @truncate(key);
        if (data.move.data != 0 or key16 != @atomicLoad(u16, &self.key16, .monotonic)) @atomicStore(u16, &self.move16, data.move.data, .monotonic);
        if (data.bound == .exact or key16 != @atomicLoad(u16, &self.key16, .monotonic) or data.depth - depth_none + 2 * @as(i32, @intFromBool(data.is_pv)) > @as(i32, @atomicLoad(u8, &self.depth8, .monotonic)) - 4 or self.relativeAge(generation) != 0) {
            std.debug.assert(data.depth > depth_none and data.depth - depth_none < 256 and generation <= 31);
            @atomicStore(u16, &self.key16, key16, .monotonic);
            @atomicStore(u8, &self.depth8, @intCast(data.depth - depth_none), .monotonic);
            @atomicStore(u8, &self.gen_bound8, generation | (@intFromEnum(data.bound) << 5) | (@as(u8, @intFromBool(data.is_pv)) << 7), .monotonic);
            @atomicStore(i16, &self.value16, @intCast(data.value), .monotonic);
            @atomicStore(i16, &self.eval16, @intCast(data.eval), .monotonic);
        } else if (@as(i32, @atomicLoad(u8, &self.depth8, .monotonic)) + depth_none >= 5 and (@atomicLoad(u8, &self.gen_bound8, .monotonic) & 0x60) >> 5 != @intFromEnum(Bound.exact)) {
            const v: i32 = @atomicLoad(i16, &self.value16, .monotonic);
            const tb_win_in_max_ply = t.value_mate - 2 * t.max_ply - 1;
            if (@abs(v) < t.value_infinite and @abs(v) >= tb_win_in_max_ply) self.penalize(1);
        }
    }
    pub fn penalize(self: *Entry, penalty: i32) void {
        std.debug.assert(penalty >= 0);
        @atomicStore(u8, &self.depth8, @intCast(@max(@as(i32, @atomicLoad(u8, &self.depth8, .monotonic)) - penalty, 0)), .monotonic);
    }
};
pub const Cluster = extern struct { entries: [3]Entry, padding: [2]u8 };
pub const Probe = struct { found: bool, data: Data, writer: *Entry };
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
        const entries = &self.clusters[self.clusterIndex(key)].entries;
        const key16: u16 = @truncate(key);
        for (entries) |*entry| {
            if (@atomicLoad(u16, &entry.key16, .monotonic) == key16) return .{ .found = entry.occupied(), .data = entry.read(), .writer = entry };
        }
        var replace: *Entry = &entries[0];
        for (entries[1..]) |*entry| {
            if (@as(i32, @atomicLoad(u8, &replace.depth8, .monotonic)) - 8 * @as(i32, replace.relativeAge(self.generation)) > @as(i32, @atomicLoad(u8, &entry.depth8, .monotonic)) - 8 * @as(i32, entry.relativeAge(self.generation))) replace = entry;
        }
        return .{ .found = false, .data = .{ .move = t.Move.none, .value = t.value_none, .eval = t.value_none, .depth = depth_none, .bound = .none, .is_pv = false }, .writer = replace };
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
    std.debug.assert(@sizeOf(Entry) == 10);
    std.debug.assert(@sizeOf(Cluster) == 32);
    std.debug.assert(@offsetOf(Entry, "move16") == 4);
}
