// Derived from Stockfish position.h/position.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const bb = @import("bitboard.zig");
const a = @import("attacks.zig");
const pk = @import("position_keys.zig");
const dirty = @import("dirty.zig");
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
    /// Speculative post-move key from Position::prefetch_key. Special moves
    /// intentionally approximate the destination; never use this for probing.
    pub fn prefetchKey(self: *const Position, move: t.Move) u64 {
        const from = @intFromEnum(move.from());
        const to = @intFromEnum(move.to());
        const piece = self.board[from];
        const captured = self.board[to];
        const value = self.st.key ^ self.keys.side ^ self.keys.psq[@intFromEnum(captured)][to] ^ self.keys.psq[@intFromEnum(piece)][to] ^ self.keys.psq[@intFromEnum(piece)][from];
        if (captured != .none or piece.pieceType() == .pawn or self.st.rule50 < 13) return value;
        return value ^ t.makeKey(@intCast(@divTrunc(self.st.rule50 - 13, 8)));
    }
    fn put(self: *Position, pc: Piece, s: Square) void {
        self.putWithThreats(pc, s, null);
    }
    fn putWithThreats(self: *Position, pc: Piece, s: Square, dts: ?*dirty.DirtyThreats) void {
        const bit = bb.square(s);
        std.debug.assert(self.pieceOn(s) == .none and pc != .none);
        self.board[@intFromEnum(s)] = pc;
        self.by_type[0] |= bit;
        self.by_type[@intFromEnum(pc.pieceType())] |= bit;
        self.by_color[@intFromEnum(pc.color())] |= bit;
        self.piece_count[@intFromEnum(pc)] += 1;
        self.piece_count[@as(usize, @intFromEnum(pc.color())) * 8] += 1;
        if (dts) |threats| self.updatePieceThreats(true, pc, true, s, threats, ~@as(u64, 0));
    }
    fn remove(self: *Position, s: Square) void {
        self.removeWithThreats(s, null);
    }
    fn removeWithThreats(self: *Position, s: Square, dts: ?*dirty.DirtyThreats) void {
        const pc = self.pieceOn(s);
        if (dts) |threats| self.updatePieceThreats(true, pc, false, s, threats, ~@as(u64, 0));
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
        // Upstream accepts omitted counters, but explicit malformed numbers remain errors.
        self.st.rule50 = std.fmt.parseInt(i32, fields.next() orelse "0", 10) catch return error.InvalidFen;
        const fullmove = std.fmt.parseInt(i32, fields.next() orelse "1", 10) catch return error.InvalidFen;
        if (self.st.rule50 < 0 or self.st.rule50 > 32767 or fullmove < 0 or fullmove > 100000) return error.UnsupportedPosition;
        self.game_ply = @max(2 * (fullmove - 1), 0) + @as(i32, @intFromEnum(self.side));
        self.setState();
        if (self.attackedBy(self.king(self.side.opposite()), self.pieces(), self.side)) return error.UnsupportedPosition;
    }
    pub fn capture(self: *const Position, m: t.Move) bool {
        return switch (m.kind()) {
            .normal, .promotion => self.pieceOn(m.to()) != .none,
            .en_passant => true,
            .castling => false,
        };
    }
    pub fn captureStage(self: *const Position, m: t.Move) bool {
        return self.capture(m) or (m.kind() == .promotion and m.promotionType() == .queen);
    }
    /// TT moves may be corrupt; reject sentinel and unused promotion bits before
    /// applying upstream pseudo-legality tests (which assert these preconditions).
    pub fn pseudoLegal(self: *const Position, m: t.Move) bool {
        if (!m.valid()) return false;
        const from = m.from();
        const to = m.to();
        const pc = self.pieceOn(from);
        const us = self.side;
        if (m.kind() != .normal) {
            const mg = @import("movegen.zig");
            var moves: mg.MoveList = undefined;
            if (self.st.checkers != 0) mg.generate(.evasions, self, &moves) else mg.generate(.non_evasions, self, &moves);
            for (moves.slice()) |candidate| if (candidate.data == m.data) return true;
            return false;
        }
        if (m.promotionType() != .knight) return false;
        if (pc == .none or pc.color() != us or self.by_color[@intFromEnum(us)] & bb.square(to) != 0) return false;
        if (pc.pieceType() == .pawn) {
            if (bb.square(to) & 0xff000000000000ff != 0) return false;
            const push: i16 = if (us == .white) 8 else -8;
            const delta = @as(i16, @intFromEnum(to)) - @as(i16, @intFromEnum(from));
            const captures = a.pseudo[@intFromEnum(us)][@intFromEnum(from)] & self.by_color[@intFromEnum(us.opposite())] & bb.square(to) != 0;
            const single = delta == push and self.pieceOn(to) == .none;
            const double = delta == 2 * push and from.relative(us).rank() == 1 and self.pieceOn(to) == .none and self.pieceOn(@enumFromInt(@as(i16, @intFromEnum(to)) - push)) == .none;
            if (!captures and !single and !double) return false;
        } else if (self.tables.attacks(pc.pieceType(), from, self.pieces()) & bb.square(to) == 0) return false;
        if (self.st.checkers != 0 and pc.pieceType() != .king) {
            if (bb.moreThanOne(self.st.checkers)) return false;
            if (self.tables.between[@intFromEnum(self.king(us))][@intFromEnum(bb.lsb(self.st.checkers))] & bb.square(to) == 0) return false;
        }
        return true;
    }
    /// Static exchange threshold test. Requires a pseudo-legal move.
    pub fn seeGe(self: *const Position, m: t.Move, threshold: i32) bool {
        if (m.kind() != .normal) return threshold <= 0;
        const from = m.from();
        const to = m.to();
        var swap = piece_value[@intFromEnum(self.pieceOn(to).pieceType())] - threshold;
        if (swap < 0) return false;
        swap = piece_value[@intFromEnum(self.pieceOn(from).pieceType())] - swap;
        if (swap <= 0) return true;
        var occupied = self.pieces() ^ bb.square(from) ^ bb.square(to);
        var stm = self.side;
        var attackers = self.attackersTo(to, occupied);
        var result: i32 = 1;
        while (true) {
            stm = stm.opposite();
            attackers &= occupied;
            var stm_attackers = attackers & self.by_color[@intFromEnum(stm)];
            if (stm_attackers == 0) break;
            if (self.st.pinners[@intFromEnum(stm.opposite())] & occupied != 0) {
                stm_attackers &= ~self.st.blockers_for_king[@intFromEnum(stm)];
                if (stm_attackers == 0) break;
            }
            result ^= 1;
            var selected: PieceType = .king;
            var candidates: u64 = 0;
            for ([_]PieceType{ .pawn, .knight, .bishop, .rook, .queen }) |pt| {
                candidates = stm_attackers & self.by_type[@intFromEnum(pt)];
                if (candidates != 0) {
                    selected = pt;
                    break;
                }
            }
            if (selected == .king) return (if (attackers & ~self.by_color[@intFromEnum(stm)] != 0) result ^ 1 else result) != 0;
            swap = piece_value[@intFromEnum(selected)] - swap;
            if (selected != .queen and swap < result) break;
            occupied ^= bb.square(bb.lsb(candidates));
            if (selected == .pawn or selected == .bishop or selected == .queen) attackers |= self.tables.attacks(.bishop, to, occupied) & (self.by_type[3] | self.by_type[5]);
            if (selected == .rook or selected == .queen) attackers |= self.tables.attacks(.rook, to, occupied) & (self.by_type[4] | self.by_type[5]);
        }
        return result != 0;
    }
    pub fn isRepetition(self: *const Position, ply: i32) bool {
        return self.st.repetition != 0 and self.st.repetition < ply;
    }
    /// Upstream search draw predicate; stalemate is handled by the search.
    pub fn isDraw(self: *const Position, ply: i32) bool {
        if (self.st.rule50 > 99) {
            if (self.st.checkers == 0) return true;
            const mg = @import("movegen.zig");
            var moves: mg.MoveList = undefined;
            mg.generate(.legal, self, &moves);
            if (moves.len != 0) return true;
        }
        return self.isRepetition(ply);
    }
    pub fn hasRepeated(self: *const Position) bool {
        var state = self.st;
        var end = @min(state.rule50, state.plies_from_null);
        while (end >= 4) : (end -= 1) {
            if (state.repetition != 0) return true;
            state = state.previous.?;
        }
        return false;
    }
    pub fn upcomingRepetition(self: *const Position, ply: i32) bool {
        const end = @min(self.st.rule50, self.st.plies_from_null);
        if (end < 3) return false;
        const original = self.st.key;
        var state = self.st.previous.?;
        var other = original ^ state.key ^ self.keys.side;
        var distance: i32 = 3;
        while (distance <= end) : (distance += 2) {
            state = state.previous.?;
            other ^= state.key ^ state.previous.?.key ^ self.keys.side;
            state = state.previous.?;
            if (other != 0) continue;
            const move_key = original ^ state.key;
            var index = pk.PositionKeys.h1(move_key);
            if (self.keys.cuckoo[index] != move_key) index = pk.PositionKeys.h2(move_key);
            if (self.keys.cuckoo[index] != move_key) continue;
            const move = self.keys.cuckoo_move[index];
            if ((self.tables.between[@intFromEnum(move.from())][@intFromEnum(move.to())] ^ bb.square(move.to())) & self.pieces() == 0) {
                if (ply > distance or state.repetition != 0) return true;
            }
        }
        return false;
    }

    pub fn givesCheck(self: *const Position, m: t.Move) bool {
        const from = m.from();
        const to = m.to();
        const them = self.side.opposite();
        if (self.st.check_squares[@intFromEnum(self.pieceOn(from).pieceType())] & bb.square(to) != 0) return true;
        if (self.st.blockers_for_king[@intFromEnum(them)] & bb.square(from) != 0) return self.tables.line[@intFromEnum(from)][@intFromEnum(to)] & self.piecesOf(them, .king) == 0 or m.kind() == .castling;
        return switch (m.kind()) {
            .normal => false,
            .promotion => self.tables.attacks(m.promotionType(), to, self.pieces() ^ bb.square(from)) & self.piecesOf(them, .king) != 0,
            .en_passant => blk: {
                const captured = Square.make(to.file(), from.rank());
                const occupied = (self.pieces() ^ bb.square(from) ^ bb.square(captured)) | bb.square(to);
                const k = self.king(them);
                break :blk ((self.tables.attacks(.rook, k, occupied) & (self.by_type[4] | self.by_type[5])) | (self.tables.attacks(.bishop, k, occupied) & (self.by_type[3] | self.by_type[5]))) & self.by_color[@intFromEnum(self.side)] != 0;
            },
            .castling => self.st.check_squares[4] & bb.square(Square.make(if (@intFromEnum(to) > @intFromEnum(from)) 5 else 3, 0).relative(self.side)) != 0,
        };
    }
    fn movePiece(self: *Position, from: Square, to: Square) void {
        self.movePieceWithThreats(from, to, null);
    }
    fn movePieceWithThreats(self: *Position, from: Square, to: Square, dts: ?*dirty.DirtyThreats) void {
        const pc = self.pieceOn(from);
        const bits = bb.square(from) | bb.square(to);
        std.debug.assert(pc != .none and self.pieceOn(to) == .none);
        if (dts) |threats| self.updatePieceThreats(true, pc, false, from, threats, bits);
        self.by_type[0] ^= bits;
        self.by_type[@intFromEnum(pc.pieceType())] ^= bits;
        self.by_color[@intFromEnum(pc.color())] ^= bits;
        self.board[@intFromEnum(from)] = .none;
        self.board[@intFromEnum(to)] = pc;
        if (dts) |threats| self.updatePieceThreats(true, pc, true, to, threats, bits);
    }
    fn addThreat(dts: *dirty.DirtyThreats, put_piece: bool, pc: Piece, threatened: Piece, from: Square, to: Square) void {
        dts.append(dirty.DirtyThreat.init(pc, threatened, from, to, put_piece));
    }
    fn processSliders(self: *const Position, pc: Piece, put_piece: bool, s: Square, dts: *dirty.DirtyThreats, no_rays: u64, sliders: u64, slider_attacks: u64, add_direct: bool) void {
        var b = sliders;
        while (b != 0) {
            const slider_sq = bb.popLsb(&b);
            const slider = self.pieceOn(slider_sq);
            const ray = self.tables.ray_pass[@intFromEnum(slider_sq)][@intFromEnum(s)];
            const discovered = ray & slider_attacks & (self.pieces() ^ self.by_type[6]);
            std.debug.assert(!bb.moreThanOne(discovered));
            if (discovered != 0 and (ray & no_rays) != no_rays) {
                const threatened_sq = bb.lsb(discovered);
                const threatened = self.pieceOn(threatened_sq);
                if (threatened.pieceType() != .queen or slider.pieceType() == .queen) addThreat(dts, !put_piece, slider, threatened, slider_sq, threatened_sq);
            }
            if (add_direct and (pc.pieceType() != .queen or slider.pieceType() == .queen)) addThreat(dts, put_piece, slider, pc, slider_sq, s);
        }
    }
    fn updatePieceThreats(self: *const Position, comptime compute_ray: bool, pc: Piece, put_piece: bool, s: Square, dts: *dirty.DirtyThreats, no_rays: u64) void {
        const occupied = self.pieces();
        const bishop_attacks = self.tables.attacks(.bishop, s, occupied);
        const rook_attacks = self.tables.attacks(.rook, s, occupied);
        const slider_attacks = bishop_attacks | rook_attacks;
        const occupied_no_king = occupied ^ self.by_type[6];
        const pt = pc.pieceType();
        const sliders = ((self.by_type[3] | self.by_type[5]) & bishop_attacks) | ((self.by_type[4] | self.by_type[5]) & rook_attacks);
        if (pt == .king) {
            if (compute_ray) self.processSliders(pc, put_piece, s, dts, no_rays, sliders, slider_attacks, false);
            return;
        }
        const targets = switch (pt) {
            .pawn => self.by_type[2] | self.by_type[4],
            .bishop, .rook => self.by_type[1] | self.by_type[2] | self.by_type[3] | self.by_type[4],
            else => occupied_no_king,
        };
        var threatened = targets & switch (pt) {
            .bishop => bishop_attacks,
            .rook => rook_attacks,
            .queen => slider_attacks,
            .pawn => a.pseudo[@intFromEnum(pc.color())][@intFromEnum(s)],
            else => a.pseudo[@intFromEnum(pt)][@intFromEnum(s)],
        };
        var incoming = a.pseudo[2][@intFromEnum(s)] & self.by_type[2];
        if (pt == .knight or pt == .rook) incoming |= (a.pseudo[0][@intFromEnum(s)] & self.piecesOf(.black, .pawn)) | (a.pseudo[1][@intFromEnum(s)] & self.piecesOf(.white, .pawn));
        while (threatened != 0) {
            const to = bb.popLsb(&threatened);
            addThreat(dts, put_piece, pc, self.pieceOn(to), s, to);
        }
        if (compute_ray) self.processSliders(pc, put_piece, s, dts, no_rays, sliders, slider_attacks, true) else incoming |= if (pt == .queen) sliders & self.by_type[5] else sliders;
        while (incoming != 0) {
            const from = bb.popLsb(&incoming);
            addThreat(dts, put_piece, self.pieceOn(from), pc, from, s);
        }
    }
    fn swapPiece(self: *Position, s: Square, pc: Piece, dts: ?*dirty.DirtyThreats) void {
        const old = self.pieceOn(s);
        self.remove(s);
        if (dts) |threats| self.updatePieceThreats(false, old, false, s, threats, ~@as(u64, 0));
        self.put(pc, s);
        if (dts) |threats| self.updatePieceThreats(false, pc, true, s, threats, ~@as(u64, 0));
    }

    /// Requires a legal move and a fresh state at a stable address.
    pub fn doMove(self: *Position, m: t.Move, next: *StateInfo) void {
        self.doMoveWithDirties(m, next, null);
    }
    /// Optional NNUE feature deltas preserve upstream scalar update ordering.
    pub fn doMoveWithDirties(self: *Position, m: t.Move, next: *StateInfo, dirties: ?*dirty.Dirties) void {
        const dts: ?*dirty.DirtyThreats = if (dirties) |d| &d.threats else null;
        if (dirties) |d| {
            d.* = .{};
            d.before = .{ self.piecesOf(.white, .pawn), self.piecesOf(.black, .pawn) };
        }
        std.debug.assert(next != self.st);
        const gives_check = self.givesCheck(m);
        const old = self.st;
        next.* = .{
            .material_key = old.material_key,
            .pawn_key = old.pawn_key,
            .minor_piece_key = old.minor_piece_key,
            .non_pawn_key = old.non_pawn_key,
            .non_pawn_material = old.non_pawn_material,
            .castling_rights = old.castling_rights,
            .rule50 = old.rule50 + 1,
            .plies_from_null = old.plies_from_null + 1,
            .ep_square = old.ep_square,
            .previous = old,
        };
        self.st = next;
        self.game_ply += 1;
        var k = old.key ^ self.keys.side;
        const us = self.side;
        const them = us.opposite();
        const ui = @intFromEnum(us);
        const ti = @intFromEnum(them);
        const from = m.from();
        var to = m.to();
        const pc = self.pieceOn(from);
        const pi = @intFromEnum(pc);
        if (dirties) |d| d.piece = .{ .pc = pc, .from = from, .to = to };
        var captured = if (m.kind() == .en_passant) Piece.make(them, .pawn) else self.pieceOn(to);
        const push: i16 = if (us == .white) 8 else -8;
        if (m.kind() == .castling) {
            const rfrom = to;
            const kingside = @intFromEnum(to) > @intFromEnum(from);
            const rto = Square.make(if (kingside) 5 else 3, 0).relative(us);
            to = Square.make(if (kingside) 6 else 2, 0).relative(us);
            if (dirties) |d| {
                d.piece.to = to;
                d.piece.remove_pc = Piece.make(us, .rook);
                d.piece.add_pc = Piece.make(us, .rook);
                d.piece.remove_sq = rfrom;
                d.piece.add_sq = rto;
            }
            self.removeWithThreats(from, dts);
            self.removeWithThreats(rfrom, dts);
            self.putWithThreats(Piece.make(us, .king), to, dts);
            self.putWithThreats(Piece.make(us, .rook), rto, dts);
            const delta = self.keys.psq[@intFromEnum(captured)][@intFromEnum(rfrom)] ^ self.keys.psq[@intFromEnum(captured)][@intFromEnum(rto)];
            k ^= delta;
            next.non_pawn_key[ui] ^= delta;
            captured = .none;
        } else if (captured != .none) {
            var capsq = to;
            const ci = @intFromEnum(captured);
            if (captured.pieceType() == .pawn) {
                if (m.kind() == .en_passant) {
                    capsq = @enumFromInt(@as(i16, @intFromEnum(to)) - push);
                    self.removeWithThreats(capsq, dts);
                }
                next.pawn_key ^= self.keys.psq[ci][@intFromEnum(capsq)];
            } else {
                next.non_pawn_material[ti] -= piece_value[@intFromEnum(captured.pieceType())];
                next.non_pawn_key[ti] ^= self.keys.psq[ci][@intFromEnum(capsq)];
                if (@intFromEnum(captured.pieceType()) <= 3) next.minor_piece_key ^= self.keys.psq[ci][@intFromEnum(capsq)];
            }
            if (dirties) |d| {
                d.piece.remove_pc = captured;
                d.piece.remove_sq = capsq;
            }
            k ^= self.keys.psq[ci][@intFromEnum(capsq)];
            next.material_key ^= self.keys.psq[ci][@intCast(8 + self.piece_count[ci] - @as(i32, @intFromBool(m.kind() != .en_passant)))];
            next.rule50 = 0;
        }
        k ^= self.keys.psq[pi][@intFromEnum(from)] ^ self.keys.psq[pi][@intFromEnum(to)];
        if (next.ep_square != .none) {
            k ^= self.keys.enpassant[next.ep_square.file()];
            next.ep_square = .none;
        }
        k ^= self.keys.castling[next.castling_rights];
        next.castling_rights &= ~(self.castling_mask[@intFromEnum(from)] | self.castling_mask[@intFromEnum(to)]);
        k ^= self.keys.castling[next.castling_rights];
        if (pc.pieceType() == .pawn) {
            if ((@intFromEnum(to) ^ @intFromEnum(from)) == 16) {
                const ep: Square = @enumFromInt(@as(i16, @intFromEnum(to)) - push);
                const pawns = a.pseudo[ui][@intFromEnum(ep)] & self.piecesOf(them, .pawn);
                if (pawns != 0) {
                    const king_sq = self.king(them);
                    const not_blockers = ~old.blockers_for_king[ti];
                    const no_discovery = bb.square(from) & not_blockers != 0 or from.file() == king_sq.file();
                    if (no_discovery and pawns & (not_blockers | self.tables.line[@intFromEnum(ep)][@intFromEnum(king_sq)]) != 0) {
                        next.ep_square = ep;
                        k ^= self.keys.enpassant[ep.file()];
                    }
                }
            } else if (m.kind() == .promotion) {
                const pt = m.promotionType();
                const promotion = @intFromEnum(Piece.make(us, pt));
                if (dirties) |d| {
                    d.piece.add_pc = @enumFromInt(promotion);
                    d.piece.add_sq = to;
                    d.piece.to = .none;
                }
                k ^= self.keys.psq[promotion][@intFromEnum(to)];
                next.material_key ^= self.keys.psq[promotion][@intCast(8 + self.piece_count[promotion])] ^ self.keys.psq[pi][@intCast(8 + self.piece_count[pi] - 1)];
                next.non_pawn_key[ui] ^= self.keys.psq[promotion][@intFromEnum(to)];
                if (@intFromEnum(pt) <= 3) next.minor_piece_key ^= self.keys.psq[promotion][@intFromEnum(to)];
                next.non_pawn_material[ui] += piece_value[@intFromEnum(pt)];
            }
            next.pawn_key ^= self.keys.psq[pi][@intFromEnum(from)] ^ self.keys.psq[pi][@intFromEnum(to)];
            next.rule50 = 0;
        } else {
            const delta = self.keys.psq[pi][@intFromEnum(from)] ^ self.keys.psq[pi][@intFromEnum(to)];
            next.non_pawn_key[ui] ^= delta;
            if (@intFromEnum(pc.pieceType()) <= 3) next.minor_piece_key ^= delta;
        }
        next.key = k;
        if (m.kind() != .castling) {
            const to_pc = if (m.kind() == .promotion) Piece.make(us, m.promotionType()) else pc;
            if (captured != .none and m.kind() != .en_passant) {
                self.removeWithThreats(from, dts);
                self.swapPiece(to, to_pc, dts);
            } else if (pc == to_pc) self.movePieceWithThreats(from, to, dts) else {
                self.removeWithThreats(from, dts);
                self.putWithThreats(to_pc, to, dts);
            }
        }
        next.captured_piece = captured;
        next.checkers = if (gives_check) self.attackersTo(self.king(them), self.pieces()) & self.by_color[ui] else 0;
        self.side = them;
        self.setCheckInfo();
        const end = @min(next.rule50, next.plies_from_null);
        if (end >= 4) {
            var prev = old.previous.?;
            var distance: i32 = 4;
            while (distance <= end) : (distance += 2) {
                prev = prev.previous.?.previous.?;
                if (prev.key == next.key) {
                    next.repetition = if (prev.repetition != 0) -distance else distance;
                    break;
                }
            }
        }
        if (dirties) |d| d.after = .{ self.piecesOf(.white, .pawn), self.piecesOf(.black, .pawn) };
    }
    pub fn undoMove(self: *Position, m: t.Move) void {
        self.side = self.side.opposite();
        const us = self.side;
        const from = m.from();
        const to = m.to();
        if (m.kind() == .promotion) {
            self.remove(to);
            self.put(Piece.make(us, .pawn), to);
        }
        if (m.kind() == .castling) {
            const kingside = @intFromEnum(to) > @intFromEnum(from);
            const kto = Square.make(if (kingside) 6 else 2, 0).relative(us);
            const rto = Square.make(if (kingside) 5 else 3, 0).relative(us);
            self.remove(kto);
            self.remove(rto);
            self.put(Piece.make(us, .king), from);
            self.put(Piece.make(us, .rook), to);
        } else {
            self.movePiece(to, from);
            if (self.st.captured_piece != .none) {
                const capsq: Square = if (m.kind() == .en_passant) Square.make(to.file(), from.rank()) else to;
                self.put(self.st.captured_piece, capsq);
            }
        }
        self.st = self.st.previous.?;
        self.game_ply -= 1;
    }
    pub fn doNullMove(self: *Position, next: *StateInfo) void {
        std.debug.assert(self.st.checkers == 0 and next != self.st);
        next.* = self.st.*;
        next.previous = self.st;
        self.st = next;
        if (next.ep_square != .none) {
            next.key ^= self.keys.enpassant[next.ep_square.file()];
            next.ep_square = .none;
        }
        next.key ^= self.keys.side;
        next.plies_from_null = 0;
        next.captured_piece = .none;
        self.side = self.side.opposite();
        self.setCheckInfo();
        next.repetition = 0;
    }
    pub fn undoNullMove(self: *Position) void {
        std.debug.assert(self.st.checkers == 0);
        self.st = self.st.previous.?;
        self.side = self.side.opposite();
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
