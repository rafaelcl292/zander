// Derived from Stockfish syzygy/tbprobe.cpp; GPL-3.0-or-later.
const std = @import("std");
const coding = @import("pairs.zig");
const idx = @import("index.zig");
pub const Table = struct {
    mapping: std.Io.File.MemoryMap,
    material: idx.Material,
    dtz: bool,
    items: [2][4]coding.Pairs,
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8, material: idx.Material, maps: *const idx.Maps, dtz: bool) !*Table {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const size = std.math.cast(usize, stat.size) orelse return error.CorruptTablebase;
        if (size < 16 or size % 64 != 16) return error.CorruptTablebase;
        var mapping = try std.Io.File.MemoryMap.create(io, file, .{ .len = size, .protection = .{ .read = true, .write = false }, .populate = false });
        errdefer mapping.destroy(io);
        const self = try allocator.create(Table);
        errdefer allocator.destroy(self);
        self.mapping = mapping;
        self.material = material;
        self.dtz = dtz;
        for (&self.items) |*side| for (side) |*pair| {
            pair.* = .{};
        };
        var cursor: coding.Cursor = .{ .bytes = mapping.memory };
        const magic = try cursor.int(u32);
        if (magic != @as(u32, if (dtz) 0xa50c66d7 else 0x5d23e871)) return error.CorruptTablebase;
        const flags = try cursor.int(u8);
        if ((flags & 2 != 0) != material.has_pawns or (flags & 1 != 0) != (material.key != material.reversed_key)) return error.CorruptTablebase;
        const sides: usize = if (!dtz and material.key != material.reversed_key) 2 else 1;
        const files: usize = if (material.has_pawns) 4 else 1;
        const pp = material.has_pawns and material.pawn_count[1] != 0;
        for (0..files) |f| {
            const first = try cursor.int(u8);
            const second = if (pp) try cursor.int(u8) else @as(u8, 255);
            const pieces = try cursor.take(material.piece_count);
            for (0..sides) |side| {
                const pair = &self.items[side][f];
                var counts: [16]u8 = @splat(0);
                for (pieces, 0..) |piece, i| {
                    pair.pieces[i] = if (side == 0) piece & 15 else piece >> 4;
                    counts[pair.pieces[i]] += 1;
                }
                if (!std.mem.eql(u8, &counts, &material.counts)) return error.CorruptTablebase;
                const order: [2]usize = if (side == 0) .{ first & 15, second & 15 } else .{ first >> 4, second >> 4 };
                try material.setGroups(maps, pair, order, f);
            }
        }
        try cursor.alignTo(2);
        for (0..files) |f| for (0..sides) |side| {
            try self.items[side][f].readSizes(&cursor);
        };
        if (dtz) {
            for (0..files) |f| {
                const pair = &self.items[0][f];
                if (pair.flags & 2 == 0) continue;
                const wide = pair.flags & 16 != 0;
                if (wide) try cursor.alignTo(2);
                for (&pair.maps) |*map| {
                    const len: usize = if (wide) try cursor.int(u16) else try cursor.int(u8);
                    map.* = try cursor.take(len * @as(usize, if (wide) 2 else 1));
                }
            }
            try cursor.alignTo(2);
        }
        for (0..files) |f| for (0..sides) |side| {
            try self.items[side][f].readSparse(&cursor);
        };
        for (0..files) |f| for (0..sides) |side| {
            try self.items[side][f].readBlocks(&cursor);
        };
        for (0..files) |f| for (0..sides) |side| {
            try self.items[side][f].readData(&cursor);
        };
        return self;
    }
    pub fn destroy(self: *Table, allocator: std.mem.Allocator, io: std.Io) void {
        self.mapping.destroy(io);
        allocator.destroy(self);
    }
    pub fn probe(self: *const Table, pos: *const @import("../position.zig").Position, maps: *const idx.Maps, wdl: i32) !?i32 {
        const encoded = try idx.encode(pos, self.material, maps, &self.items, self.dtz);
        if (encoded.changed_side) return null;
        var value = try encoded.pair.decompress(encoded.index);
        if (!self.dtz) {
            if (value > 4) return error.CorruptTablebase;
            return value - 2;
        }
        const pair = encoded.pair;
        if (pair.flags & 2 != 0) {
            const map_index = [_]usize{ 1, 3, 0, 2, 0 };
            const map = pair.maps[map_index[@intCast(wdl + 2)]];
            const wide = pair.flags & 16 != 0;
            const offset: usize = @as(usize, @intCast(value)) * @as(usize, if (wide) 2 else 1);
            if (offset + @as(usize, if (wide) 2 else 1) > map.len) return error.CorruptTablebase;
            value = if (wide) std.mem.readInt(u16, map[offset..][0..2], .little) else map[offset];
        }
        if ((wdl == 2 and pair.flags & 4 == 0) or (wdl == -2 and pair.flags & 8 == 0) or @abs(wdl) == 1) value *= 2;
        return value + 1;
    }
};
