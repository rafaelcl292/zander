// Derived from Stockfish position.h/position.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const bb = @import("bitboard.zig");
const a = @import("attacks.zig");
const pk = @import("position_keys.zig");
const Square = t.Square;
const Color = t.Color;
const Piece = t.Piece;
const PieceType = t.PieceType;
pub const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
const piece_chars = " PNBRQK  pnbrqk";
pub const piece_value = [_]i32{ 0, 208, 781, 825, 1276, 2538, 0, 0 };
pub const StateInfo = struct {
    material_key: u64 = 0,
    pawn_key: u64 = 0,
    minor_piece_key: u64 = 0,
    non_pawn_key: [2]u64 = @splat(0),
    non_pawn_material: [2]i32 = @splat(0),
    castling_rights: u8 = 0,
    rule50: i32 = 0,
    plies_from_null: i32 = 0,
    ep_square: Square = .none,
    key: u64 = 0,
    checkers: u64 = 0,
    previous: ?*StateInfo = null,
    blockers_for_king: [2]u64 = @splat(0),
    pinners: [2]u64 = @splat(0),
    check_squares: [8]u64 = @splat(0),
    captured_piece: Piece = .none,
    repetition: i32 = 0,
};
pub const FenError = error{ InvalidFen, UnsupportedPosition };

/// Position and StateInfo storage is supplied by the caller. The tables and
/// keys must remain alive and immutable; states must remain at stable addresses.
pub const Position = struct {
    board: [64]Piece = @splat(.none),
    by_type: [8]u64 = @splat(0),
    by_color: [2]u64 = @splat(0),
    piece_count: [16]i32 = @splat(0),
    castling_mask: [64]u8 = @splat(0),
    castling_rook: [16]Square = @splat(.none),
    castling_path: [16]u64 = @splat(0),
    st: *StateInfo,
    game_ply: i32 = 0,
    side: Color = .white,
    chess960: bool = false,
    tables: *const a.Tables,
    keys: *const pk.PositionKeys,

    pub fn pieces(self: *const Position) u64 {
        return self.by_type[0];
    }
    pub fn piecesOf(self: *const Position, c: Color, pt: PieceType) u64 {
        return self.by_color[@intFromEnum(c)] & self.by_type[@intFromEnum(pt)];
    }
    pub fn pieceOn(self: *const Position, s: Square) Piece {
        return self.board[@intFromEnum(s)];
    }
    pub fn king(self: *const Position, c: Color) Square {
        return bb.lsb(self.piecesOf(c, .king));
    }
    pub fn key(self: *const Position) u64 {
        return if (self.st.rule50 < 14) self.st.key else self.st.key ^ t.makeKey(@intCast(@divTrunc(self.st.rule50 - 14, 8)));
    }
    fn put(self: *Position, pc: Piece, s: Square) void {
        const bit = bb.square(s);
        std.debug.assert(self.pieceOn(s) == .none and pc != .none);
        self.board[@intFromEnum(s)] = pc;
        self.by_type[0] |= bit;
        self.by_type[@intFromEnum(pc.pieceType())] |= bit;
        self.by_color[@intFromEnum(pc.color())] |= bit;
        self.piece_count[@intFromEnum(pc)] += 1;
        self.piece_count[@as(usize, @intFromEnum(pc.color())) * 8] += 1;
    }
    fn remove(self: *Position, s: Square) void {
        const pc = self.pieceOn(s);
        const bit = bb.square(s);
        std.debug.assert(pc != .none);
        self.board[@intFromEnum(s)] = .none;
        self.by_type[0] ^= bit;
        self.by_type[@intFromEnum(pc.pieceType())] ^= bit;
        self.by_color[@intFromEnum(pc.color())] ^= bit;
        self.piece_count[@intFromEnum(pc)] -= 1;
        self.piece_count[@as(usize, @intFromEnum(pc.color())) * 8] -= 1;
    }
    pub fn attackersTo(self: *const Position, s: Square, occupied: u64) u64 {
        const i = @intFromEnum(s);
        return (self.tables.attacks(.rook, s, occupied) & (self.by_type[4] | self.by_type[5])) | (self.tables.attacks(.bishop, s, occupied) & (self.by_type[3] | self.by_type[5])) | (a.pseudo[1][i] & self.piecesOf(.white, .pawn)) | (a.pseudo[0][i] & self.piecesOf(.black, .pawn)) | (a.pseudo[2][i] & self.by_type[2]) | (a.pseudo[6][i] & self.by_type[6]);
    }
    pub fn attackedBy(self: *const Position, s: Square, occupied: u64, c: Color) bool {
        return self.attackersTo(s, occupied) & self.by_color[@intFromEnum(c)] != 0;
    }
    fn setCastlingRight(self: *Position, c: Color, rook: Square) void {
        const k = self.king(c);
        const kingside = @intFromEnum(k) < @intFromEnum(rook);
        const cr: u8 = @as(u8, if (kingside) 1 else 2) << (@as(u3, @intCast(@intFromEnum(c))) * 2);
        self.st.castling_rights |= cr;
        self.castling_mask[@intFromEnum(k)] |= cr;
        self.castling_mask[@intFromEnum(rook)] |= cr;
        self.castling_rook[cr] = rook;
        const kto = Square.make(if (kingside) 6 else 2, 0).relative(c);
        const rto = Square.make(if (kingside) 5 else 3, 0).relative(c);
        self.castling_path[cr] = (self.tables.between[@intFromEnum(rook)][@intFromEnum(rto)] | self.tables.between[@intFromEnum(k)][@intFromEnum(kto)]) & ~(bb.square(k) | bb.square(rook));
    }
    fn setCheckInfo(self: *Position) void {
        for ([_]Color{ .white, .black }) |c| {
            const ci = @intFromEnum(c);
            const them = @intFromEnum(c.opposite());
            const k = @intFromEnum(self.king(c));
            self.st.blockers_for_king[ci] = 0;
            self.st.pinners[them] = 0;
            var snipers = ((a.pseudo[4][k] & (self.by_type[4] | self.by_type[5])) | (a.pseudo[3][k] & (self.by_type[3] | self.by_type[5]))) & self.by_color[them];
            const occupied = self.pieces() ^ snipers;
            while (snipers != 0) {
                const sniper = bb.popLsb(&snipers);
                const blockers = self.tables.between[k][@intFromEnum(sniper)] & occupied;
                if (blockers != 0 and !bb.moreThanOne(blockers)) {
                    self.st.blockers_for_king[ci] |= blockers;
                    if (blockers & self.by_color[ci] != 0) self.st.pinners[them] |= bb.square(sniper);
                }
            }
        }
        const k = self.king(self.side.opposite());
        self.st.check_squares[1] = a.pseudo[@intFromEnum(self.side.opposite())][@intFromEnum(k)];
        self.st.check_squares[2] = a.pseudo[2][@intFromEnum(k)];
        self.st.check_squares[3] = self.tables.attacks(.bishop, k, self.pieces());
        self.st.check_squares[4] = self.tables.attacks(.rook, k, self.pieces());
        self.st.check_squares[5] = self.st.check_squares[3] | self.st.check_squares[4];
        self.st.check_squares[6] = 0;
    }
    fn setState(self: *Position) void {
        self.st.key = 0;
        self.st.material_key = 0;
        self.st.minor_piece_key = 0;
        self.st.non_pawn_key = @splat(0);
        self.st.pawn_key = self.keys.no_pawns;
        self.st.non_pawn_material = @splat(0);
        self.st.checkers = self.attackersTo(self.king(self.side), self.pieces()) & self.by_color[@intFromEnum(self.side.opposite())];
        self.setCheckInfo();
        var occupied = self.pieces();
        while (occupied != 0) {
            const s = bb.popLsb(&occupied);
            const pc = self.pieceOn(s);
            const k = self.keys.psq[@intFromEnum(pc)][@intFromEnum(s)];
            self.st.key ^= k;
            if (pc.pieceType() == .pawn) self.st.pawn_key ^= k else {
                self.st.non_pawn_key[@intFromEnum(pc.color())] ^= k;
                if (pc.pieceType() != .king) {
                    self.st.non_pawn_material[@intFromEnum(pc.color())] += piece_value[@intFromEnum(pc.pieceType())];
                    if (@intFromEnum(pc.pieceType()) <= 3) self.st.minor_piece_key ^= k;
                }
            }
        }
        if (self.st.ep_square != .none) self.st.key ^= self.keys.enpassant[self.st.ep_square.file()];
        if (self.side == .black) self.st.key ^= self.keys.side;
        self.st.key ^= self.keys.castling[self.st.castling_rights];
        for (pk.pieces) |pc| {
            const p = @intFromEnum(pc);
            for (0..@intCast(self.piece_count[p])) |n| self.st.material_key ^= self.keys.psq[p][8 + n];
        }
    }
    /// On failure, discard the partially initialized position and state.
    pub fn set(self: *Position, fen: []const u8, chess960: bool, state: *StateInfo, tables: *const a.Tables, keys: *const pk.PositionKeys) FenError!void {
        state.* = .{};
        self.* = .{ .st = state, .tables = tables, .keys = keys, .chess960 = chess960 };
        var fields = std.mem.tokenizeAny(u8, fen, " \t\r\n\x0b\x0c");
        const placement = fields.next() orelse return error.InvalidFen;
        var rank: i8 = 7;
        var file: u8 = 0;
        var count: usize = 0;
        for (placement) |ch| {
            if (ch >= '1' and ch <= '8') {
                file += ch - '0';
                if (file > 8) return error.InvalidFen;
            } else if (ch == '/') {
                if (file != 8 or rank == 0) return error.InvalidFen;
                rank -= 1;
                file = 0;
            } else {
                if (file >= 8) return error.InvalidFen;
                const pi = std.mem.indexOfScalar(u8, piece_chars, ch) orelse return error.InvalidFen;
                if (pi == 0 or pi == 7 or pi == 8) return error.InvalidFen;
                count += 1;
                if (count > 32) return error.UnsupportedPosition;
                self.put(@enumFromInt(pi), Square.make(@intCast(file), @intCast(rank)));
                file += 1;
            }
        }
        if (rank != 0 or file != 8) return error.InvalidFen;
        if (self.by_type[1] & 0xff000000000000ff != 0) return error.UnsupportedPosition;
        for ([_]Color{ .white, .black }) |c| {
            if (@popCount(self.piecesOf(c, .king)) != 1) return error.UnsupportedPosition;
            const pawns = @popCount(self.piecesOf(c, .pawn));
            if (pawns > 8) return error.UnsupportedPosition;
            var additional: i32 = 0;
            for ([_]PieceType{ .knight, .bishop, .rook, .queen }) |pt| {
                additional += @max(self.piece_count[@intFromEnum(Piece.make(c, pt))] - @as(i32, if (pt == .queen) 1 else 2), 0);
            }
            if (additional > 8 - @as(i32, pawns)) return error.UnsupportedPosition;
        }
        const side = fields.next() orelse return error.InvalidFen;
        self.side = if (std.mem.eql(u8, side, "w")) .white else if (std.mem.eql(u8, side, "b")) .black else return error.InvalidFen;
        const castle = fields.next() orelse return error.InvalidFen;
        if (!std.mem.eql(u8, castle, "-")) {
            if (castle.len > 4) return error.InvalidFen;
            for (castle) |ch| {
                const c: Color = if (std.ascii.isLower(ch)) .black else .white;
                const token = std.ascii.toUpper(ch);
                var rook: Square = .none;
                var k: Square = .none;
                if (token == 'K' or token == 'Q') {
                    const dir: i16 = if (token == 'K') -1 else 1;
                    var sq: i16 = @intFromEnum(Square.make(if (token == 'K') 7 else 0, 0).relative(c));
                    for (0..7) |_| {
                        const s: Square = @enumFromInt(sq);
                        const pc = self.pieceOn(s);
                        if (pc == Piece.make(c, .king)) {
                            k = s;
                            break;
                        }
                        if (pc == Piece.make(c, .rook) and rook == .none) rook = s;
                        sq += dir;
                    }
                } else if (token >= 'A' and token <= 'H') {
                    const candidate = Square.make(@intCast(token - 'A'), 0).relative(c);
                    if (self.pieceOn(candidate) == Piece.make(c, .rook)) rook = candidate;
                    const king_sq = self.king(c);
                    if (king_sq.relative(c).rank() == 0 and king_sq.file() >= 1 and king_sq.file() <= 6) k = king_sq;
                } else return error.InvalidFen;
                if (k != .none and rook != .none) self.setCastlingRight(c, rook);
            }
        }
        const ep = fields.next() orelse return error.InvalidFen;
        if (!std.mem.eql(u8, ep, "-")) {
            if (ep.len != 2 or ep[0] < 'a' or ep[0] > 'h' or ep[1] != @as(u8, if (self.side == .white) '6' else '3')) return error.InvalidFen;
            const s = Square.make(@intCast(ep[0] - 'a'), @intCast(ep[1] - '1'));
            const push: i16 = if (self.side == .white) 8 else -8;
            const captured: Square = @enumFromInt(@as(i16, @intFromEnum(s)) - push);
            const behind: Square = @enumFromInt(@as(i16, @intFromEnum(s)) + push);
            var pawns = a.pseudo[@intFromEnum(self.side.opposite())][@intFromEnum(s)] & self.piecesOf(self.side, .pawn);
            const target = self.piecesOf(self.side.opposite(), .pawn) & bb.square(captured);
            if (pawns != 0 and target != 0 and self.pieces() & (bb.square(s) | bb.square(behind)) == 0) {
                const occ = self.pieces() ^ target ^ bb.square(s);
                while (pawns != 0) {
                    const p = bb.popLsb(&pawns);
                    if (self.attackersTo(self.king(self.side), occ ^ bb.square(p)) & self.by_color[@intFromEnum(self.side.opposite())] & ~target == 0) self.st.ep_square = s;
                }
            }
        }
        // Canonical six-field FEN input. Reject malformed numeric tokens.
        self.st.rule50 = std.fmt.parseInt(i32, fields.next() orelse return error.InvalidFen, 10) catch return error.InvalidFen;
        const fullmove = std.fmt.parseInt(i32, fields.next() orelse return error.InvalidFen, 10) catch return error.InvalidFen;
        if (self.st.rule50 < 0 or self.st.rule50 > 32767 or fullmove < 0 or fullmove > 100000) return error.UnsupportedPosition;
        self.game_ply = @max(2 * (fullmove - 1), 0) + @as(i32, @intFromEnum(self.side));
        self.setState();
        if (self.attackedBy(self.king(self.side.opposite()), self.pieces(), self.side)) return error.UnsupportedPosition;
    }
    /// Requires a pseudo-legal move generated for this position.
    pub fn legal(self: *const Position, m: t.Move) bool {
        const from = m.from();
        var to = m.to();
        const us = self.side;
        if (m.kind() == .castling) {
            to = Square.make(if (@intFromEnum(to) > @intFromEnum(from)) 6 else 2, 0).relative(us);
            const step: i16 = if (@intFromEnum(to) > @intFromEnum(from)) -1 else 1;
            var sq: i16 = @intFromEnum(to);
            while (sq != @intFromEnum(from)) : (sq += step) {
                if (self.attackedBy(@enumFromInt(sq), self.pieces(), us.opposite())) return false;
            }
            return !self.chess960 or self.st.blockers_for_king[@intFromEnum(us)] & bb.square(m.to()) == 0;
        }
        if (self.pieceOn(from).pieceType() == .king) return !self.attackedBy(to, self.pieces() ^ bb.square(from), us.opposite());
        return self.st.blockers_for_king[@intFromEnum(us)] & bb.square(from) == 0 or self.tables.line[@intFromEnum(from)][@intFromEnum(to)] & self.piecesOf(us, .king) != 0;
    }
    pub fn writeFen(self: *const Position, writer: *std.Io.Writer) !void {
        for (0..8) |r| {
            var empty: u8 = 0;
            for (0..8) |f| {
                const pc = self.pieceOn(Square.make(@intCast(f), @intCast(7 - r)));
                if (pc == .none) {
                    empty += 1;
                    continue;
                }
                if (empty != 0) {
                    try writer.writeByte('0' + empty);
                    empty = 0;
                }
                try writer.writeByte(piece_chars[@intFromEnum(pc)]);
            }
            if (empty != 0) try writer.writeByte('0' + empty);
            if (r != 7) try writer.writeByte('/');
        }
        try writer.writeAll(if (self.side == .white) " w " else " b ");
        for ([_]u8{ 1, 2, 4, 8 }, "KQkq") |cr, ch| {
            if (self.st.castling_rights & cr != 0) {
                try writer.writeByte(if (self.chess960) @as(u8, if (cr < 4) 'A' else 'a') + self.castling_rook[cr].file() else ch);
            }
        }
        if (self.st.castling_rights == 0) try writer.writeByte('-');
        if (self.st.ep_square == .none) try writer.writeAll(" - ") else {
            try writer.print(" {c}{c} ", .{ @as(u8, 'a') + self.st.ep_square.file(), @as(u8, '1') + self.st.ep_square.rank() });
        }
        try writer.print("{d} {d}", .{ self.st.rule50, 1 + @divTrunc(self.game_ply - @as(i32, @intFromEnum(self.side)), 2) });
    }
};
