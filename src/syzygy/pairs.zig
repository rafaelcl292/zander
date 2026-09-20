// Derived from Stockfish syzygy/tbprobe.cpp; GPL-3.0-or-later.
const std = @import("std");
pub const Error = error{CorruptTablebase};
pub const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,
    pub fn take(self: *Cursor, count: usize) Error![]const u8 {
        if (self.offset > self.bytes.len or count > self.bytes.len - self.offset) return error.CorruptTablebase;
        const data = self.bytes[self.offset..][0..count];
        self.offset += count;
        return data;
    }
    pub fn int(self: *Cursor, comptime T: type) Error!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    pub fn alignTo(self: *Cursor, alignment: usize) Error!void {
        const padding = (alignment - self.offset % alignment) % alignment;
        _ = try self.take(padding);
    }
};
pub const Symbol = struct {
    left: u16 = 0,
    right: u16 = 0xfff,
};
pub const Pairs = struct {
    flags: u8 = 0,
    min_length: u8 = 0,
    max_length: u8 = 0,
    block_size: usize = 0,
    span: usize = 0,
    block_count: usize = 0,
    length_count: usize = 0,
    sparse_count: usize = 0,
    bases: [64]u64 = @splat(0),
    lowest: [64]u16 = @splat(0),
    tree: [4096]Symbol = @splat(.{}),
    lengths: [4096]u8 = @splat(0),
    pieces: [7]u8 = @splat(0),
    group_len: [8]usize = @splat(0),
    group_index: [8]u64 = @splat(0),
    total: u64 = 0,
    maps: [4][]const u8 = @splat(&.{}),
    sparse: []const u8 = &.{},
    blocks: []const u8 = &.{},
    data: []const u8 = &.{},

    pub fn readSizes(self: *Pairs, cursor: *Cursor) Error!void {
        self.flags = try cursor.int(u8);
        if (self.flags & 128 != 0) {
            self.min_length = try cursor.int(u8);
            return;
        }
        const block_shift = try cursor.int(u8);
        const span_shift = try cursor.int(u8);
        if (block_shift >= @bitSizeOf(usize) or span_shift >= @bitSizeOf(usize)) return error.CorruptTablebase;
        self.block_size = @as(usize, 1) << @intCast(block_shift);
        self.span = @as(usize, 1) << @intCast(span_shift);
        self.sparse_count = @intCast(self.total / self.span + @intFromBool(self.total % self.span != 0));
        const padding = try cursor.int(u8);
        self.block_count = try cursor.int(u32);
        self.length_count = std.math.add(usize, self.block_count, padding) catch return error.CorruptTablebase;
        if (self.length_count == 0) return error.CorruptTablebase;
        self.max_length = try cursor.int(u8);
        self.min_length = try cursor.int(u8);
        if (self.min_length == 0 or self.min_length > self.max_length or self.max_length >= 64) return error.CorruptTablebase;
        const count: usize = self.max_length - self.min_length + 1;
        for (self.lowest[0..count]) |*value| value.* = try cursor.int(u16);
        var i = count - 1;
        while (i > 0) {
            i -= 1;
            const sum = self.bases[i + 1] + self.lowest[i];
            if (sum < self.lowest[i + 1]) return error.CorruptTablebase;
            self.bases[i] = (sum - self.lowest[i + 1]) / 2;
            if (self.bases[i] * 2 < self.bases[i + 1]) return error.CorruptTablebase;
        }
        for (self.bases[0..count], 0..) |*base, index| base.* <<= @intCast(64 - index - self.min_length);
        const symbols = try cursor.int(u16);
        if (symbols > self.tree.len) return error.CorruptTablebase;
        for (self.tree[0..symbols]) |*symbol| {
            const bytes = try cursor.take(3);
            symbol.* = .{ .left = (@as(u16, bytes[1] & 15) << 8) | bytes[0], .right = (@as(u16, bytes[2]) << 4) | (bytes[1] >> 4) };
        }
        var colors: [4096]u2 = @splat(0);
        for (0..symbols) |symbol| _ = try self.symbolLength(symbol, &colors);
        _ = try cursor.take(symbols & 1);
    }
    fn symbolLength(self: *Pairs, symbol: usize, colors: *[4096]u2) Error!u8 {
        if (colors[symbol] == 1) return error.CorruptTablebase;
        if (colors[symbol] == 2) return self.lengths[symbol];
        colors[symbol] = 1;
        const children = self.tree[symbol];
        if (children.right != 0xfff) {
            const left = try self.symbolLength(children.left, colors);
            const right = try self.symbolLength(children.right, colors);
            const length = @as(u16, left) + right + 1;
            if (length > 255) return error.CorruptTablebase;
            self.lengths[symbol] = @intCast(length);
        }
        colors[symbol] = 2;
        return self.lengths[symbol];
    }
    pub fn readSparse(self: *Pairs, cursor: *Cursor) Error!void {
        self.sparse = try cursor.take(std.math.mul(usize, self.sparse_count, 6) catch return error.CorruptTablebase);
    }
    pub fn readBlocks(self: *Pairs, cursor: *Cursor) Error!void {
        self.blocks = try cursor.take(std.math.mul(usize, self.length_count, 2) catch return error.CorruptTablebase);
    }
    pub fn readData(self: *Pairs, cursor: *Cursor) Error!void {
        try cursor.alignTo(64);
        self.data = try cursor.take(std.math.mul(usize, self.block_count, self.block_size) catch return error.CorruptTablebase);
    }
    fn blockLength(self: *const Pairs, block: usize) i64 {
        return std.mem.readInt(u16, self.blocks[block * 2 ..][0..2], .little);
    }
    pub fn decompress(self: *const Pairs, index: u64) Error!i32 {
        if (index >= self.total) return error.CorruptTablebase;
        if (self.flags & 128 != 0) return self.min_length;
        const k: usize = @intCast(index / self.span);
        if (k >= self.sparse_count) return error.CorruptTablebase;
        const sparse = self.sparse[k * 6 ..][0..6];
        var block: usize = @min(std.mem.readInt(u32, sparse[0..4], .little), self.length_count - 1);
        var offset: i64 = @as(i64, std.mem.readInt(u16, sparse[4..6], .little)) + @as(i64, @intCast(index % self.span)) - @as(i64, @intCast(self.span / 2));
        while (offset < 0 and block > 0) {
            block -= 1;
            offset += self.blockLength(block) + 1;
        }
        while (offset > self.blockLength(block) and block + 1 < self.length_count) {
            offset -= self.blockLength(block) + 1;
            block += 1;
        }
        if (offset < 0 or offset > self.blockLength(block) or block >= self.block_count) return error.CorruptTablebase;
        var pointer = block * self.block_size;
        var bits: u64 = if (pointer + 8 <= self.data.len) std.mem.readInt(u64, self.data[pointer..][0..8], .big) else 0;
        pointer += 8;
        var available: i32 = 64;
        var symbol: usize = undefined;
        while (true) {
            var length: usize = 0;
            while (bits < self.bases[length]) {
                length += 1;
                if (length > self.max_length - self.min_length) return error.CorruptTablebase;
            }
            const raw = ((bits - self.bases[length]) >> @intCast(64 - length - self.min_length)) + self.lowest[length];
            symbol = @intCast(raw & 4095);
            if (offset <= self.lengths[symbol]) break;
            offset -= @as(i64, self.lengths[symbol]) + 1;
            length += self.min_length;
            bits <<= @intCast(length);
            available -= @intCast(length);
            if (available <= 32) {
                available += 32;
                if (pointer + 4 <= self.data.len) bits |= @as(u64, std.mem.readInt(u32, self.data[pointer..][0..4], .big)) << @intCast(64 - available);
                pointer += 4;
            }
        }
        while (self.lengths[symbol] != 0) {
            const left = self.tree[symbol].left;
            if (offset <= self.lengths[left]) symbol = left else {
                offset -= @as(i64, self.lengths[left]) + 1;
                symbol = self.tree[symbol].right;
            }
        }
        return self.tree[symbol].left;
    }
};

test "constant table and truncated metadata are checked" {
    const pair = try std.testing.allocator.create(Pairs);
    defer std.testing.allocator.destroy(pair);
    pair.* = .{ .total = 100 };
    var cursor: Cursor = .{ .bytes = &.{ 128, 4 } };
    try pair.readSizes(&cursor);
    try std.testing.expectEqual(@as(i32, 4), try pair.decompress(99));
    try std.testing.expectError(error.CorruptTablebase, pair.decompress(100));
    pair.* = .{ .total = 100 };
    cursor = .{ .bytes = &.{ 0, 6 } };
    try std.testing.expectError(error.CorruptTablebase, pair.readSizes(&cursor));
}
