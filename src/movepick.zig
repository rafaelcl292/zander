// Derived from Stockfish movepick.cpp (scalar path); GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const bb = @import("bitboard.zig");
const h = @import("history.zig");
const mg = @import("movegen.zig");
const position = @import("position.zig");
const Position = position.Position;
const ExtMove = struct { move: t.Move, value: i32 };
const Stage = enum {
    main_tt,
    capture_init,
    good_capture,
    quiet_init,
    good_quiet,
    bad_capture,
    bad_quiet,
    evasion_tt,
    evasion_init,
    evasion,
    probcut_tt,
    probcut_init,
    probcut,
    qsearch_tt,
    qcapture_init,
    qcapture,
};
fn partialSort(moves: []ExtMove, limit: i32) void {
    if (moves.len < 2) return;
    var sorted_end: usize = 0;
    for (1..moves.len) |p| {
        if (moves[p].value < limit) continue;
        const tmp = moves[p];
        sorted_end += 1;
        moves[p] = moves[sorted_end];
        var q = sorted_end;
        while (q > 0 and moves[q - 1].value < tmp.value) : (q -= 1) moves[q] = moves[q - 1];
        moves[q] = tmp;
    }
}
pub const Histories = struct {
    main: *const h.ButterflyHistory,
    low_ply: *const h.LowPlyHistory,
    capture: *const h.CapturePieceToHistory,
    // Quiescence evasions need only entry zero; main search needs six entries.
    continuation: []const *const h.PieceToHistory,
    shared: *const h.SharedHistories,
};
pub const MovePicker = struct {
    pos: *const Position,
    histories: ?Histories = null,
    capture: *const h.CapturePieceToHistory,
    tt_move: t.Move,
    stage: Stage,
    threshold: i32 = 0,
    depth: i32 = 0,
    ply: usize = 0,
    skip_quiets: bool = false,
    cur: usize = 0,
    end_cur: usize = 0,
    end_bad_captures: usize = 0,
    end_captures: usize = 0,
    end_generated: usize = 0,
    moves: [t.max_moves]ExtMove = undefined,
    pub fn init(pos: *const Position, tt_move: t.Move, depth: i32, histories: Histories, ply: usize) MovePicker {
        std.debug.assert(histories.continuation.len >= (if (depth > 0) @as(usize, 6) else 1));
        var picker: MovePicker = .{ .pos = pos, .histories = histories, .capture = histories.capture, .tt_move = tt_move, .stage = if (pos.st.checkers != 0) .evasion_tt else if (depth > 0) .main_tt else .qsearch_tt, .depth = depth, .ply = ply };
        if (tt_move.data == 0 or !pos.pseudoLegal(tt_move)) picker.advance();
        return picker;
    }
    pub fn initProbcut(pos: *const Position, tt_move: t.Move, threshold: i32, capture: *const h.CapturePieceToHistory) MovePicker {
        std.debug.assert(pos.st.checkers == 0);
        var picker: MovePicker = .{ .pos = pos, .capture = capture, .tt_move = tt_move, .stage = .probcut_tt, .threshold = threshold };
        if (!tt_move.valid() or !pos.captureStage(tt_move) or !pos.pseudoLegal(tt_move)) picker.advance();
        return picker;
    }
    fn advance(self: *MovePicker) void {
        self.stage = @enumFromInt(@intFromEnum(self.stage) + 1);
    }
    pub fn skipQuietMoves(self: *MovePicker) void {
        self.skip_quiets = true;
    }
    fn attacksBy(self: *const MovePicker, pt: t.PieceType, color: t.Color) u64 {
        var pieces = self.pos.piecesOf(color, pt);
        if (pt == .pawn) return bb.pawnAttacks(color, pieces);
        var result: u64 = 0;
        while (pieces != 0) result |= self.pos.tables.attacks(pt, bb.popLsb(&pieces), self.pos.pieces());
        return result;
    }
    fn score(self: *MovePicker, comptime kind: mg.GenType) usize {
        var list: mg.MoveList = undefined;
        mg.generate(kind, self.pos, &list);
        const us = self.pos.side;
        var lesser: [7]u64 = @splat(0);
        if (kind == .quiets) {
            lesser[2] = self.attacksBy(.pawn, us.opposite());
            lesser[3] = lesser[2];
            lesser[4] = self.attacksBy(.knight, us.opposite()) | self.attacksBy(.bishop, us.opposite()) | lesser[2];
            lesser[5] = self.attacksBy(.rook, us.opposite()) | lesser[4];
        }
        std.debug.assert(self.cur + list.len <= self.moves.len);
        for (list.slice(), self.cur..) |move, i| {
            const from = move.from();
            const to = move.to();
            const pc = @intFromEnum(self.pos.pieceOn(from));
            const pt = pc & 7;
            const dest = @intFromEnum(to);
            const captured = @intFromEnum(self.pos.pieceOn(to).pieceType());
            var value: i32 = 0;
            if (kind == .captures) {
                value = self.capture[pc][dest][captured].get() + 7 * position.piece_value[captured];
            } else if (kind == .quiets) {
                const histories = self.histories.?;
                value = 2 * @as(i32, histories.main[@intFromEnum(us)][move.data].get());
                value += 2 * @as(i32, histories.shared.pawnEntry(self.pos)[pc][dest].get());
                for ([_]usize{ 0, 1, 2, 3, 5 }) |j| value += histories.continuation[j][pc][dest].get();
                if (self.pos.st.check_squares[pt] & bb.square(to) != 0 and self.pos.seeGe(move, -75)) value += 16384;
                const threat_delta = @as(i32, @intFromBool(lesser[pt] & bb.square(from) != 0)) - @as(i32, @intFromBool(lesser[pt] & bb.square(to) != 0));
                value += position.piece_value[pt] * 20 * threat_delta;
                if (self.ply < h.low_ply_history_size) value += @divTrunc(8 * @as(i32, histories.low_ply[self.ply][move.data].get()), @as(i32, @intCast(1 + self.ply)));
            } else {
                const histories = self.histories.?;
                value = if (self.pos.captureStage(move)) position.piece_value[captured] + (1 << 28) else @as(i32, histories.main[@intFromEnum(us)][move.data].get()) + histories.continuation[0][pc][dest].get();
            }
            self.moves[i] = .{ .move = move, .value = value };
        }
        return self.cur + list.len;
    }
    const Filter = enum { all, good_capture, good_quiet, bad_quiet, probcut };
    fn select(self: *MovePicker, comptime filter: Filter) t.Move {
        while (self.cur < self.end_cur) {
            const i = self.cur;
            self.cur += 1;
            const m = self.moves[i];
            if (m.move.data == self.tt_move.data) continue;
            const accept = switch (filter) {
                .all => true,
                .good_quiet => m.value > -14000,
                .bad_quiet => m.value <= -14000,
                .probcut => self.pos.seeGe(m.move, self.threshold),
                .good_capture => self.pos.seeGe(m.move, @divTrunc(-m.value, 18)),
            };
            if (accept) return m.move;
            if (filter == .good_capture) {
                std.mem.swap(ExtMove, &self.moves[self.end_bad_captures], &self.moves[i]);
                self.end_bad_captures += 1;
            }
        }
        return .none;
    }
    pub fn next(self: *MovePicker) t.Move {
        while (true) switch (self.stage) {
            .main_tt, .evasion_tt, .qsearch_tt, .probcut_tt => {
                self.advance();
                return self.tt_move;
            },
            .capture_init, .probcut_init, .qcapture_init => {
                self.cur = 0;
                self.end_bad_captures = 0;
                self.end_cur = self.score(.captures);
                self.end_captures = self.end_cur;
                partialSort(self.moves[self.cur..self.end_cur], std.math.minInt(i32));
                self.advance();
            },
            .good_capture => {
                const move = self.select(.good_capture);
                if (move.data != 0) return move;
                self.advance();
            },
            .quiet_init => {
                if (!self.skip_quiets) {
                    self.end_cur = self.score(.quiets);
                    self.end_generated = self.end_cur;
                    partialSort(self.moves[self.cur..self.end_cur], -3560 * self.depth);
                }
                self.advance();
            },
            .good_quiet => {
                if (!self.skip_quiets) {
                    const move = self.select(.good_quiet);
                    if (move.data != 0) return move;
                }
                self.cur = 0;
                self.end_cur = self.end_bad_captures;
                self.advance();
            },
            .bad_capture => {
                const move = self.select(.all);
                if (move.data != 0) return move;
                self.cur = self.end_captures;
                self.end_cur = self.end_generated;
                self.advance();
            },
            .bad_quiet => return if (self.skip_quiets) .none else self.select(.bad_quiet),
            .evasion_init => {
                self.cur = 0;
                self.end_cur = self.score(.evasions);
                self.end_generated = self.end_cur;
                partialSort(self.moves[0..self.end_cur], std.math.minInt(i32));
                self.advance();
            },
            .evasion, .qcapture => return self.select(.all),
            .probcut => return self.select(.probcut),
        };
    }
};
