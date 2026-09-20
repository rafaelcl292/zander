// Derived from Stockfish movegen.cpp (scalar path); GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const bb = @import("bitboard.zig");
const a = @import("attacks.zig");
const Position = @import("position.zig").Position;
pub const GenType = enum { captures, quiets, evasions, non_evasions, legal };
pub const MoveList = struct {
    moves: [t.max_moves]t.Move = undefined,
    len: usize = 0,
    pub fn slice(self: *const MoveList) []const t.Move {
        return self.moves[0..self.len];
    }
    fn append(self: *MoveList, m: t.Move) void {
        std.debug.assert(self.len < self.moves.len);
        self.moves[self.len] = m;
        self.len += 1;
    }
};
fn offset(s: t.Square, delta: i16) t.Square {
    return @enumFromInt(@as(i16, @intFromEnum(s)) + delta);
}
fn splat(list: *MoveList, from: t.Square, targets: u64) void {
    var b = targets;
    while (b != 0) list.append(t.Move.make(.normal, from, bb.popLsb(&b), .knight));
}
fn pawnSplat(list: *MoveList, targets: u64, delta: i16) void {
    var b = targets;
    while (b != 0) {
        const to = bb.popLsb(&b);
        list.append(t.Move.make(.normal, offset(to, -delta), to, .knight));
    }
}
fn promotions(comptime kind: GenType, list: *MoveList, to: t.Square, delta: i16, enemy: bool) void {
    const all = kind == .evasions or kind == .non_evasions;
    if (kind == .captures or all) list.append(t.Move.make(.promotion, offset(to, -delta), to, .queen));
    if ((kind == .captures and enemy) or (kind == .quiets and !enemy) or all) {
        for ([_]t.PieceType{ .rook, .bishop, .knight }) |pt| list.append(t.Move.make(.promotion, offset(to, -delta), to, pt));
    }
}
fn pawns(comptime kind: GenType, pos: *const Position, list: *MoveList, target: u64) void {
    const us = pos.side;
    const them = us.opposite();
    const rank7: u64 = if (us == .white) 0x00ff000000000000 else 0x000000000000ff00;
    const rank3: u64 = if (us == .white) 0x0000000000ff0000 else 0x0000ff0000000000;
    const up: i8 = if (us == .white) 8 else -8;
    const right: i8 = if (us == .white) 9 else -9;
    const left: i8 = if (us == .white) 7 else -7;
    const empty = ~pos.pieces();
    const enemies = if (kind == .evasions) pos.st.checkers else pos.by_color[@intFromEnum(them)];
    const on7 = pos.piecesOf(us, .pawn) & rank7;
    const not7 = pos.piecesOf(us, .pawn) & ~rank7;
    if (kind != .captures) {
        var b1 = bb.shift(not7, up) & empty;
        var b2 = bb.shift(b1 & rank3, up) & empty;
        if (kind == .evasions) {
            b1 &= target;
            b2 &= target;
        }
        pawnSplat(list, b1, up);
        pawnSplat(list, b2, @as(i16, up) * 2);
    }
    if (on7 != 0) {
        var b1 = bb.shift(on7, right) & enemies;
        var b2 = bb.shift(on7, left) & enemies;
        var b3 = bb.shift(on7, up) & empty;
        if (kind == .evasions) b3 &= target;
        while (b1 != 0) promotions(kind, list, bb.popLsb(&b1), right, true);
        while (b2 != 0) promotions(kind, list, bb.popLsb(&b2), left, true);
        while (b3 != 0) promotions(kind, list, bb.popLsb(&b3), up, false);
    }
    if (kind == .captures or kind == .evasions or kind == .non_evasions) {
        pawnSplat(list, bb.shift(not7, right) & enemies, right);
        pawnSplat(list, bb.shift(not7, left) & enemies, left);
        if (pos.st.ep_square != .none) {
            if (kind == .evasions and target & bb.square(offset(pos.st.ep_square, up)) != 0) return;
            var b = not7 & a.pseudo[@intFromEnum(them)][@intFromEnum(pos.st.ep_square)];
            while (b != 0) list.append(t.Move.make(.en_passant, bb.popLsb(&b), pos.st.ep_square, .knight));
        }
    }
}
/// Preserves upstream scalar move order, including swap-removal of illegal moves.
/// Initializes the list length and generated prefix; prior storage may be undefined.
pub fn generate(comptime kind: GenType, pos: *const Position, list: *MoveList) void {
    if (kind == .legal) {
        if (pos.st.checkers != 0) generate(.evasions, pos, list) else generate(.non_evasions, pos, list);
        const pinned = pos.st.blockers_for_king[@intFromEnum(pos.side)] & pos.by_color[@intFromEnum(pos.side)];
        const king = pos.king(pos.side);
        var i: usize = 0;
        while (i < list.len) {
            const m = list.moves[i];
            if ((pinned & bb.square(m.from()) != 0 or m.from() == king or m.kind() == .en_passant) and !pos.legal(m)) {
                list.len -= 1;
                list.moves[i] = list.moves[list.len];
            } else i += 1;
        }
        return;
    }
    std.debug.assert((kind == .evasions) == (pos.st.checkers != 0));
    list.len = 0;
    const us = pos.side;
    const k = pos.king(us);
    var target: u64 = 0;
    if (kind != .evasions or !bb.moreThanOne(pos.st.checkers)) {
        target = switch (kind) {
            .evasions => pos.tables.between[@intFromEnum(k)][@intFromEnum(bb.lsb(pos.st.checkers))],
            .non_evasions => ~pos.by_color[@intFromEnum(us)],
            .captures => pos.by_color[@intFromEnum(us.opposite())],
            .quiets => ~pos.pieces(),
            .legal => unreachable,
        };
        pawns(kind, pos, list, target);
        for ([_]t.PieceType{ .knight, .bishop, .rook, .queen }) |pt| {
            var pieces = pos.piecesOf(us, pt);
            while (pieces != 0) {
                const from = bb.popLsb(&pieces);
                splat(list, from, pos.tables.attacks(pt, from, pos.pieces()) & target);
            }
        }
    }
    splat(list, k, a.pseudo[6][@intFromEnum(k)] & (if (kind == .evasions) ~pos.by_color[@intFromEnum(us)] else target));
    if (kind == .quiets or kind == .non_evasions) {
        const shift: u3 = @intCast(@intFromEnum(us) * 2);
        for ([_]u8{ @as(u8, 1) << shift, @as(u8, 2) << shift }) |cr| {
            if (pos.st.castling_rights & cr != 0 and pos.pieces() & pos.castling_path[cr] == 0) list.append(t.Move.make(.castling, k, pos.castling_rook[cr], .knight));
        }
    }
}
