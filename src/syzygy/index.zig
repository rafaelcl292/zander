// Derived from Stockfish syzygy/tbprobe.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("../types.zig");
const Pairs = @import("pairs.zig").Pairs;
const Error = @import("pairs.zig").Error;
pub fn off(square: usize) i32 {
    return @as(i32, @intCast(square / 8)) - @as(i32, @intCast(square % 8));
}
pub const Maps = struct {
    pawns: [64]usize = @splat(0),
    below: [64]usize = @splat(0),
    triangle: [64]usize = @splat(0),
    kings: [10][64]u64 = @splat(@splat(0)),
    binomial: [6][64]u64 = @splat(@splat(0)),
    lead_index: [6][64]u64 = @splat(@splat(0)),
    lead_size: [6][4]u64 = @splat(@splat(0)),
    pub fn init() Maps {
        var self: Maps = .{};
        var code: usize = 0;
        for (0..64) |sq| if (off(sq) < 0) {
            self.below[sq] = code;
            code += 1;
        };
        code = 0;
        for (0..28) |sq| if (off(sq) < 0 and sq % 8 <= 3) {
            self.triangle[sq] = code;
            code += 1;
        };
        for (0..4) |rank| {
            self.triangle[rank * 9] = code;
            code += 1;
        }
        var diagonal: [64][2]usize = undefined;
        var diagonal_count: usize = 0;
        code = 0;
        for (0..10) |index| for (0..28) |first| {
            if (self.triangle[first] != index or (index == 0 and first != 1)) continue;
            for (0..64) |second| {
                const file_distance = @abs(@as(i32, @intCast(first % 8)) - @as(i32, @intCast(second % 8)));
                const rank_distance = @abs(@as(i32, @intCast(first / 8)) - @as(i32, @intCast(second / 8)));
                if (@max(file_distance, rank_distance) <= 1) continue;
                if (off(first) == 0 and off(second) > 0) continue;
                if (off(first) == 0 and off(second) == 0) {
                    diagonal[diagonal_count] = .{ index, second };
                    diagonal_count += 1;
                } else {
                    self.kings[index][second] = code;
                    code += 1;
                }
            }
        };
        for (diagonal[0..diagonal_count]) |pair| {
            self.kings[pair[0]][pair[1]] = code;
            code += 1;
        }
        self.binomial[0][0] = 1;
        for (1..64) |n| for (0..@min(6, n + 1)) |k| {
            self.binomial[k][n] = (if (k > 0) self.binomial[k - 1][n - 1] else 0) + (if (k < n) self.binomial[k][n - 1] else 0);
        };
        var available: i32 = 47;
        for (1..6) |count| for (0..4) |file| {
            var index: u64 = 0;
            for (1..7) |rank| {
                const square = rank * 8 + file;
                if (count == 1) {
                    self.pawns[square] = @intCast(available);
                    available -= 1;
                    self.pawns[square ^ 7] = @intCast(available);
                    available -= 1;
                }
                self.lead_index[count][square] = index;
                index += self.binomial[count - 1][self.pawns[square]];
            }
            self.lead_size[count][file] = index;
        };
        return self;
    }
};
pub const Material = struct {
    key: u64 = 0,
    reversed_key: u64 = 0,
    counts: [16]u8 = @splat(0),
    piece_count: usize = 0,
    has_pawns: bool = false,
    unique: bool = false,
    pawn_count: [2]usize = @splat(0),
    pub fn init(name: []const u8, keys: *const @import("../position_keys.zig").PositionKeys) !Material {
        var self: Material = .{};
        var color: usize = 0;
        var divided = false;
        for (name) |char| {
            if (char == 'v') {
                if (divided) return error.InvalidTablebaseName;
                divided = true;
                color = 8;
                continue;
            }
            const kind = std.mem.findScalar(u8, " PNBRQK", char) orelse return error.InvalidTablebaseName;
            if (kind == 0 or self.piece_count >= 7) return error.InvalidTablebaseName;
            self.counts[color + kind] += 1;
            self.piece_count += 1;
        }
        if (!divided or self.counts[6] != 1 or self.counts[14] != 1 or self.piece_count < 3) return error.InvalidTablebaseName;
        for (self.counts, 0..) |count, piece| {
            for (0..count) |n| {
                self.key ^= keys.psq[piece][8 + n];
                self.reversed_key ^= keys.psq[piece ^ 8][8 + n];
            }
            if (piece % 8 != 6 and count == 1) self.unique = true;
        }
        self.has_pawns = self.counts[1] + self.counts[9] != 0;
        const white_leads = self.counts[9] == 0 or (self.counts[1] != 0 and self.counts[9] >= self.counts[1]);
        self.pawn_count = if (white_leads) .{ self.counts[1], self.counts[9] } else .{ self.counts[9], self.counts[1] };
        return self;
    }
    pub fn setGroups(self: Material, maps: *const Maps, d: *Pairs, order: [2]usize, file: usize) Error!void {
        var group: usize = 0;
        var first: i32 = if (self.has_pawns) 0 else if (self.unique) 3 else 2;
        d.group_len[0] = 1;
        for (1..self.piece_count) |i| {
            first -= 1;
            if (first > 0 or d.pieces[i] == d.pieces[i - 1]) d.group_len[group] += 1 else {
                group += 1;
                d.group_len[group] = 1;
            }
        }
        const groups = group + 1;
        const pp = self.has_pawns and self.pawn_count[1] != 0;
        var next: usize = if (pp) 2 else 1;
        var free: usize = 64 - d.group_len[0] - (if (pp) d.group_len[1] else @as(usize, 0));
        var index: u64 = 1;
        var k: usize = 0;
        while (next < groups or k == order[0] or k == order[1]) : (k += 1) {
            if (k > 7) return error.CorruptTablebase;
            var factor: u64 = undefined;
            if (k == order[0]) {
                d.group_index[0] = index;
                if (d.group_len[0] > 5 and self.has_pawns) return error.CorruptTablebase;
                factor = if (self.has_pawns) maps.lead_size[d.group_len[0]][file] else if (self.unique) 31332 else 462;
            } else if (k == order[1]) {
                if (!pp or d.group_len[1] > 5) return error.CorruptTablebase;
                d.group_index[1] = index;
                factor = maps.binomial[d.group_len[1]][48 - d.group_len[0]];
            } else {
                if (next >= groups or d.group_len[next] > 5 or d.group_len[next] > free) return error.CorruptTablebase;
                d.group_index[next] = index;
                factor = maps.binomial[d.group_len[next]][free];
                free -= d.group_len[next];
                next += 1;
            }
            index = std.math.mul(u64, index, factor) catch return error.CorruptTablebase;
        }
        if (index == 0 or order[0] >= k or (pp and order[1] >= k)) return error.CorruptTablebase;
        d.group_index[groups] = index;
        d.total = index;
    }
};

pub fn encode(pos: *const @import("../position.zig").Position, material: Material, maps: *const Maps, items: *const [2][4]Pairs, dtz: bool) Error!struct { pair: *const Pairs, index: u64, changed_side: bool } {
    var squares: [7]usize = undefined;
    var pieces: [7]u8 = undefined;
    const symmetric_black = material.key == material.reversed_key and pos.side == .black;
    const black_stronger = pos.st.material_key != material.key;
    const flip = symmetric_black or black_stronger;
    const color: u8 = if (flip) 8 else 0;
    const square_flip: usize = if (flip) 56 else 0;
    const side = @intFromEnum(pos.side) ^ @as(usize, @intFromBool(flip));
    var count: usize = 0;
    var leading: u64 = 0;
    var file: usize = 0;
    if (material.has_pawns) {
        const piece = items[0][0].pieces[0] ^ color;
        leading = pos.piecesOf(@enumFromInt(piece / 8), .pawn);
        var bits = leading;
        while (bits != 0) {
            squares[count] = @ctz(bits) ^ square_flip;
            bits &= bits - 1;
            count += 1;
        }
        if (count == 0 or count > 5) return error.CorruptTablebase;
        for (1..count) |i| if (maps.pawns[squares[i]] > maps.pawns[squares[0]]) std.mem.swap(usize, &squares[0], &squares[i]);
        file = @min(squares[0] % 8, 7 - squares[0] % 8);
    }
    const lead_count = count;
    const d = &items[if (dtz) 0 else side][file];
    if (dtz and (d.flags & 1) != side and !(material.key == material.reversed_key and !material.has_pawns)) return .{ .pair = d, .index = 0, .changed_side = true };
    var bits = pos.pieces() ^ leading;
    while (bits != 0) {
        const square: usize = @ctz(bits);
        bits &= bits - 1;
        if (count >= 7) return error.CorruptTablebase;
        squares[count] = square ^ square_flip;
        pieces[count] = @as(u8, @intCast(@intFromEnum(pos.board[square]))) ^ color;
        count += 1;
    }
    if (count != material.piece_count) return error.CorruptTablebase;
    for (lead_count..count - 1) |i| for (i + 1..count) |j| {
        if (d.pieces[i] == pieces[j]) {
            std.mem.swap(u8, &pieces[i], &pieces[j]);
            std.mem.swap(usize, &squares[i], &squares[j]);
            break;
        }
    };
    if (squares[0] % 8 > 3) for (squares[0..count]) |*square| {
        square.* ^= 7;
    };
    var index: u64 = undefined;
    if (material.has_pawns) {
        index = maps.lead_index[lead_count][squares[0]];
        const Context = struct {
            fn less(context: *const Maps, a: usize, b: usize) bool {
                return context.pawns[a] < context.pawns[b];
            }
        };
        std.mem.sort(usize, squares[1..lead_count], maps, Context.less);
        for (1..lead_count) |i| index += maps.binomial[i][maps.pawns[squares[i]]];
    } else {
        if (squares[0] / 8 > 3) for (squares[0..count]) |*square| {
            square.* ^= 56;
        };
        for (0..d.group_len[0]) |i| {
            if (off(squares[i]) == 0) continue;
            if (off(squares[i]) > 0) for (squares[i..count]) |*square| {
                square.* = ((square.* >> 3) | (square.* << 3)) & 63;
            };
            break;
        }
        const a = squares[0];
        const b = squares[1];
        if (material.unique) {
            const c = squares[2];
            const adjust1: usize = @intFromBool(b > a);
            const adjust2: usize = @as(usize, @intFromBool(c > a)) + @intFromBool(c > b);
            index = if (off(a) != 0) (maps.triangle[a] * 63 + b - adjust1) * 62 + c - adjust2 else if (off(b) != 0) (6 * 63 + a / 8 * 28 + maps.below[b]) * 62 + c - adjust2 else if (off(c) != 0) 6 * 63 * 62 + 4 * 28 * 62 + a / 8 * 7 * 28 + (b / 8 - adjust1) * 28 + maps.below[c] else 6 * 63 * 62 + 4 * 28 * 62 + 4 * 7 * 28 + a / 8 * 7 * 6 + (b / 8 - adjust1) * 6 + c / 8 - adjust2;
        } else index = maps.kings[maps.triangle[a]][b];
    }
    index *= d.group_index[0];
    var start = d.group_len[0];
    var group: usize = 1;
    var remaining_pawns = material.has_pawns and material.pawn_count[1] != 0;
    while (d.group_len[group] != 0) : (group += 1) {
        const len = d.group_len[group];
        std.mem.sort(usize, squares[start..][0..len], {}, std.sort.asc(usize));
        var n: u64 = 0;
        for (0..len) |i| {
            var adjust: usize = 0;
            for (squares[0..start]) |square| adjust += @intFromBool(squares[start + i] > square);
            const rank = squares[start + i] - adjust - @as(usize, if (remaining_pawns) 8 else 0);
            n += maps.binomial[i + 1][rank];
        }
        remaining_pawns = false;
        index += n * d.group_index[group];
        start += len;
    }
    return .{ .pair = d, .index = index, .changed_side = false };
}
