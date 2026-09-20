// Derived from Stockfish nnue/features scalar implementations; GPL-3.0-or-later.
const std = @import("std");
const t = @import("../types.zig");
const bb = @import("../bitboard.zig");
const attacks = @import("../attacks.zig");
const Position = @import("../position.zig").Position;
const dirty = @import("../dirty.zig");
const all_pieces = @import("../position_keys.zig").pieces;
pub fn IndexList(comptime capacity: usize) type {
    return struct {
        items: [capacity]u16 = undefined,
        len: usize = 0,
        prefetch_base: ?[*]const [1024]i8 = null,
        pub fn append(self: *@This(), index: u32) void {
            std.debug.assert(self.len < capacity and index <= std.math.maxInt(u16));
            if (self.prefetch_base) |base| @import("../prefetch.zig").readLow(&base[index]);
            self.items[self.len] = @intCast(index);
            self.len += 1;
        }
        pub fn slice(self: *const @This()) []const u16 {
            return self.items[0..self.len];
        }
    };
}
pub const SmallList = IndexList(32);
pub const ThreatList = IndexList(256);

pub const HalfKA = struct {
    pub const hash_value: u32 = 0x7f234cb8;
    pub const dimensions: u32 = 22528;
    pub fn makeIndex(perspective: t.Color, s: t.Square, pc: t.Piece, king: t.Square) u32 {
        const flip: u32 = 56 * @as(u32, @intFromEnum(perspective));
        const orient: u32 = if (king.file() < 4) 7 else 0;
        const relative = king.relative(perspective);
        const bucket = (7 - @as(u32, relative.rank())) * 4 + @min(@as(u32, relative.file()), 7 - @as(u32, relative.file()));
        const piece_offset: u32 = if (pc.pieceType() == .king) 640 else (@as(u32, @intFromEnum(pc.pieceType())) - 1) * 128 + @as(u32, @intFromBool(pc.color() != perspective)) * 64;
        return (@as(u32, @intFromEnum(s)) ^ orient ^ flip) + piece_offset + bucket * 704;
    }
    pub fn requiresRefresh(diff: dirty.DirtyPiece, perspective: t.Color) bool {
        return diff.pc == t.Piece.make(perspective, .king);
    }
    pub fn appendChanged(perspective: t.Color, king: t.Square, diff: dirty.DirtyPiece, removed: *SmallList, added: *SmallList) void {
        removed.append(makeIndex(perspective, diff.from, diff.pc, king));
        if (diff.to != .none) added.append(makeIndex(perspective, diff.to, diff.pc, king));
        if (diff.remove_sq != .none) removed.append(makeIndex(perspective, diff.remove_sq, diff.remove_pc, king));
        if (diff.add_sq != .none) added.append(makeIndex(perspective, diff.add_sq, diff.add_pc, king));
    }
};
fn orientation(perspective: t.Color, king: t.Square) u8 {
    return @as(u8, if (king.file() < 4) 0 else 7) ^ (56 * @intFromEnum(perspective));
}
fn pawnPair(s: t.Square) u64 {
    const file = bb.file_a << s.file();
    return (file | bb.shift(file, 1) | bb.shift(file, -1)) & ~@as(u64, 0xff000000000000ff) & ~bb.square(s);
}
pub const PawnPairs = struct {
    pub const hash_value: u32 = 0x86f2b1dd;
    pub const dimensions: u32 = 4560;
    pub const index_base: u32 = FullThreats.dimensions;
    pub fn makeIndex(perspective: t.Color, color: t.Color, from: t.Square, to: t.Square, paired: t.Color, king: t.Square) u32 {
        const orient = orientation(perspective, king);
        const id_a = 48 * @as(u32, @intFromEnum(color) ^ @intFromEnum(perspective)) + (@as(u32, @intFromEnum(from)) ^ orient) - 8;
        const id_b = 48 * @as(u32, @intFromEnum(paired) ^ @intFromEnum(perspective)) + (@as(u32, @intFromEnum(to)) ^ orient) - 8;
        const hi = @max(id_a, id_b);
        return hi * (hi - 1) / 2 + @min(id_a, id_b) + index_base;
    }
    pub fn appendActive(perspective: t.Color, pos: *const Position, active: *ThreatList) void {
        const king = pos.king(perspective);
        const white = pos.piecesOf(.white, .pawn);
        const black = pos.piecesOf(.black, .pawn);
        var b = white;
        while (b != 0) {
            const from = bb.popLsb(&b);
            const band = pawnPair(from);
            var ww = band & b;
            while (ww != 0) active.append(makeIndex(perspective, .white, from, bb.popLsb(&ww), .white, king));
            var wb = band & black;
            while (wb != 0) active.append(makeIndex(perspective, .white, from, bb.popLsb(&wb), .black, king));
        }
        b = black;
        while (b != 0) {
            const from = bb.popLsb(&b);
            var partners = pawnPair(from) & b;
            while (partners != 0) active.append(makeIndex(perspective, .black, from, bb.popLsb(&partners), .black, king));
        }
    }
    fn generate(perspective: t.Color, king: t.Square, updated_white: u64, updated_black: u64, white: u64, black: u64, out: *ThreatList) void {
        const unchanged = (white | black) & ~(updated_white | updated_black);
        var updated = updated_white | updated_black;
        while (updated != 0) {
            const from = bb.popLsb(&updated);
            const mask = pawnPair(from) & (unchanged | updated);
            const color: t.Color = if (black & bb.square(from) != 0) .black else .white;
            var b = black & mask;
            while (b != 0) out.append(makeIndex(perspective, color, from, bb.popLsb(&b), .black, king));
            b = white & mask;
            while (b != 0) out.append(makeIndex(perspective, color, from, bb.popLsb(&b), .white, king));
        }
    }
    pub fn appendChanged(perspective: t.Color, king: t.Square, before: [2]u64, after: [2]u64, removed: *ThreatList, added: *ThreatList) void {
        generate(perspective, king, after[0] & ~before[0], after[1] & ~before[1], after[0], after[1], added);
        generate(perspective, king, before[0] & ~after[0], before[1] & ~after[1], before[0], before[1], removed);
    }
    pub fn appendChangedBoth(kings: [2]t.Square, before: [2]u64, after: [2]u64, removed: *[2]ThreatList, added: *[2]ThreatList) void {
        generateBoth(kings, after[0] & ~before[0], after[1] & ~before[1], after[0], after[1], added);
        generateBoth(kings, before[0] & ~after[0], before[1] & ~after[1], before[0], before[1], removed);
    }
    fn generateBoth(kings: [2]t.Square, updated_white: u64, updated_black: u64, white: u64, black: u64, out: *[2]ThreatList) void {
        const unchanged = (white | black) & ~(updated_white | updated_black);
        var updated = updated_white | updated_black;
        while (updated != 0) {
            const from = bb.popLsb(&updated);
            const mask = pawnPair(from) & (unchanged | updated);
            const color: t.Color = if (black & bb.square(from) != 0) .black else .white;
            inline for (.{ t.Color.black, t.Color.white }) |paired| {
                var partners = (if (paired == .black) black else white) & mask;
                while (partners != 0) {
                    const to = bb.popLsb(&partners);
                    inline for (0..2) |side| out[side].append(makeIndex(@enumFromInt(side), color, from, to, paired, kings[side]));
                }
            }
        }
    }
};

pub const FullThreats = struct {
    pub const hash_value: u32 = 0x2e6b9d04;
    pub const dimensions: u32 = 59808;
    const valid_targets = [_]u32{ 0, 4, 10, 8, 8, 10, 0, 0, 0, 4, 10, 8, 8, 10, 0, 0 };
    const mapping = [_][6]i32{
        .{ -1, 0, -1, 1, -1, -1 }, .{ 0, 1, 2, 3, 4, -1 },
        .{ 0, 1, 2, 3, -1, -1 },   .{ 0, 1, 2, 3, -1, -1 },
        .{ 0, 1, 2, 3, 4, -1 },    .{ -1, -1, -1, -1, -1, -1 },
    };
    const lookup = blk: {
        @setEvalBranchQuota(2000000);
        var result: struct {
            offsets: [16][64]u32 = @splat(@splat(0)),
            index1: [16][16][2]u32 = @splat(@splat(@splat(0))),
            index2: [16][64][64]u8 = @splat(@splat(@splat(0))),
        } = .{};
        var cumulative: u32 = 0;
        var counts: [16]u32 = @splat(0);
        var bases: [16]u32 = @splat(0);
        for (all_pieces) |pc| {
            const p = @intFromEnum(pc);
            for (0..64) |from| {
                const pseudo = attacks.pseudo[if (pc.pieceType() == .pawn) @intFromEnum(pc.color()) else @intFromEnum(pc.pieceType())][from];
                result.offsets[p][from] = counts[p];
                if (pc.pieceType() != .pawn or (from >= 8 and from <= 55)) counts[p] += @popCount(pseudo);
                for (0..64) |to| result.index2[p][from][to] = @intCast(@popCount(((@as(u64, 1) << @as(u6, @intCast(to))) - 1) & pseudo));
            }
            bases[p] = cumulative;
            cumulative += valid_targets[p] * counts[p];
        }
        std.debug.assert(cumulative == dimensions);
        for (all_pieces) |attacker| {
            for (all_pieces) |attacked| {
                const p = @intFromEnum(attacker);
                const q = @intFromEnum(attacked);
                const pt = attacker.pieceType();
                const qt = attacked.pieceType();
                const mapped = mapping[@intFromEnum(pt) - 1][@intFromEnum(qt) - 1];
                const semi_excluded = pt == qt and ((p ^ q) == 8 or pt != .pawn);
                const feature = if (mapped < 0) dimensions else bases[p] + (@as(u32, @intFromEnum(attacked.color())) * (valid_targets[p] / 2) + @as(u32, @intCast(mapped))) * counts[p];
                result.index1[p][q] = .{ feature, if (mapped < 0 or semi_excluded) dimensions else feature };
            }
        }
        break :blk result;
    };
    pub fn makeIndex(perspective: t.Color, attacker: t.Piece, from: t.Square, to: t.Square, attacked: t.Piece, king: t.Square) u32 {
        const orient = orientation(perspective, king);
        const f = @intFromEnum(from) ^ orient;
        const dest = @intFromEnum(to) ^ orient;
        const pc = @intFromEnum(attacker) ^ (8 * @intFromEnum(perspective));
        const target = @intFromEnum(attacked) ^ (8 * @intFromEnum(perspective));
        return lookup.index1[pc][target][@intFromBool(f < dest)] + lookup.offsets[pc][f] + lookup.index2[pc][f][dest];
    }
    fn appendIfValid(list: *ThreatList, index: u32) void {
        if (index < dimensions) list.append(index);
    }
    pub fn appendActive(perspective: t.Color, pos: *const Position, active: *ThreatList) void {
        const king = pos.king(perspective);
        const pawn_targets = pos.by_type[2] | pos.by_type[4];
        const minor_targets = pos.by_type[1] | pos.by_type[2] | pos.by_type[3] | pos.by_type[4];
        const queen_targets = minor_targets | pos.by_type[5];
        for ([_]t.Color{ .white, .white, .black, .black }, [_]i8{ 9, 7, -9, -7 }) |c, dir| {
            var b = bb.shift(pos.piecesOf(c, .pawn), dir) & pawn_targets;
            while (b != 0) {
                const to = bb.popLsb(&b);
                const from: t.Square = @enumFromInt(@as(i16, @intFromEnum(to)) - dir);
                appendIfValid(active, makeIndex(perspective, t.Piece.make(c, .pawn), from, to, pos.pieceOn(to), king));
            }
        }
        for ([_]t.Color{ .white, .black }) |c| {
            for ([_]t.PieceType{ .knight, .bishop, .rook, .queen }) |pt| {
                var pieces = pos.piecesOf(c, pt);
                const targets = if (pt == .knight or pt == .queen) queen_targets else minor_targets;
                while (pieces != 0) {
                    const from = bb.popLsb(&pieces);
                    var b = pos.tables.attacks(pt, from, pos.pieces()) & targets;
                    while (b != 0) {
                        const to = bb.popLsb(&b);
                        appendIfValid(active, makeIndex(perspective, t.Piece.make(c, pt), from, to, pos.pieceOn(to), king));
                    }
                }
            }
        }
    }
    pub fn appendChanged(perspective: t.Color, king: t.Square, diff: *const dirty.DirtyThreats, removed: *ThreatList, added: *ThreatList) void {
        for (diff.list[0..diff.len]) |entry| {
            const raw = entry.data;
            const index = makeIndex(perspective, @enumFromInt((raw >> 20) & 15), @enumFromInt(raw & 255), @enumFromInt((raw >> 8) & 255), @enumFromInt((raw >> 16) & 15), king);
            appendIfValid(if (raw >> 31 != 0) added else removed, index);
        }
    }
    pub fn appendChangedBoth(kings: [2]t.Square, diff: *const dirty.DirtyThreats, removed: *[2]ThreatList, added: *[2]ThreatList) void {
        for (diff.list[0..diff.len]) |entry| {
            const raw = entry.data;
            const attacker: t.Piece = @enumFromInt((raw >> 20) & 15);
            const from: t.Square = @enumFromInt(raw & 255);
            const to: t.Square = @enumFromInt((raw >> 8) & 255);
            const attacked: t.Piece = @enumFromInt((raw >> 16) & 15);
            inline for (0..2) |side| {
                const index = makeIndex(@enumFromInt(side), attacker, from, to, attacked, kings[side]);
                appendIfValid(if (raw >> 31 != 0) &added[side] else &removed[side], index);
            }
        }
    }
};
