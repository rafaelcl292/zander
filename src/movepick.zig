// Derived from Stockfish movepick.cpp (scalar path); GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const bb = @import("bitboard.zig");
const h = @import("history.zig");
const mg = @import("movegen.zig");
const position = @import("position.zig");
const Position = position.Position;
const ExtMove = struct { move: t.Move, value: i32 };
const Stage = enum { tt, init_first, good_capture, good_quiet, bad_moves, qsearch, evasion, probcut };
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
    first_stage: Stage,
    threshold: i32 = 0,
    depth: i32 = 0,
    ply: usize = 0,
    skip_quiets: bool = false,
    cur: usize = 0,
    end_cur: usize = 0,
    end_bad_captures: usize = 0,
    end_bad_moves: usize = 0,
    moves: [t.max_moves]ExtMove = undefined,
    pub fn init(pos: *const Position, tt_move: t.Move, depth: i32, histories: Histories, ply: usize) MovePicker {
        std.debug.assert(histories.continuation.len >= (if (depth > 0) @as(usize, 6) else 1));
        return .{
            .pos = pos,
            .histories = histories,
            .capture = histories.capture,
            .tt_move = tt_move,
            .first_stage = if (pos.st.checkers != 0) .evasion else if (depth > 0) .good_capture else .qsearch,
            .stage = if (tt_move.data != 0 and pos.legal(tt_move)) .tt else .init_first,
            .depth = depth,
            .ply = ply,
        };
    }
    pub fn initProbcut(
        pos: *const Position,
        tt_move: t.Move,
        threshold: i32,
        capture: *const h.CapturePieceToHistory,
    ) MovePicker {
        std.debug.assert(pos.st.checkers == 0);
        return .{
            .pos = pos,
            .capture = capture,
            .tt_move = tt_move,
            .stage = if (tt_move.valid() and pos.captureStage(tt_move) and pos.legal(tt_move)) .tt else .init_first,
            .first_stage = .probcut,
            .threshold = threshold,
        };
    }
    pub fn skipQuietMoves(self: *MovePicker) void {
        self.skip_quiets = true;
        if (self.stage == .bad_moves or self.stage == .good_quiet) {
            self.end_cur = self.end_bad_captures;
            self.end_bad_moves = self.end_bad_captures;
        }
    }
    fn score(self: *MovePicker, comptime kind: mg.GenType) usize {
        var list: mg.MoveList = undefined;
        mg.generate(kind, self.pos, &list);
        const us = self.pos.side;
        var lesser: [7]u64 = @splat(0);
        if (kind == .quiets) {
            lesser[2] = self.pos.threatsBy(.pawn);
            lesser[3] = lesser[2];
            lesser[4] = self.pos.threatsBy(.knight) | self.pos.threatsBy(.bishop) | lesser[2];
            lesser[5] = self.pos.threatsBy(.rook) | lesser[4];
        }
        std.debug.assert(self.cur + list.len <= self.moves.len);
        // Hoist history rows out of the scoring loop, as upstream does.
        const main_hist = if (kind != .captures) &self.histories.?.main[@backingInt(us)] else undefined;
        const pawn_hist = if (kind == .quiets) self.histories.?.shared.pawnEntry(self.pos) else undefined;
        const low_ply_hist = if (kind == .quiets and self.ply < h.low_ply_history_size)
            &self.histories.?.low_ply[self.ply]
        else
            null;
        for (list.slice(), self.cur..) |move, i| {
            const from = move.from();
            const to = move.to();
            const pc = @backingInt(self.pos.pieceOn(from));
            const pt = pc & 7;
            const dest = @backingInt(to);
            const captured = @backingInt(self.pos.pieceOn(to).pieceType());
            var value: i32 = 0;
            if (kind == .captures) {
                value = self.capture[pc][dest][captured].get() + 7 * position.piece_value[captured];
            } else if (kind == .quiets) {
                const histories = self.histories.?;
                value = 2 * @as(i32, main_hist[move.data].get());
                value += 2 * @as(i32, pawn_hist[pc][dest].get());
                inline for ([_]usize{ 0, 1, 2, 3, 5 }) |j| value += histories.continuation[j][pc][dest].get();
                const threat_delta = @as(i32, @intFromBool(lesser[pt] & bb.square(from) != 0)) -
                    @as(i32, @intFromBool(lesser[pt] & bb.square(to) != 0));
                value += position.piece_value[pt] * 20 * threat_delta;
                if (low_ply_hist) |row| {
                    value += @divTrunc(8 * @as(i32, row[move.data].get()), @as(i32, @intCast(1 + self.ply)));
                }
                if (self.pos.st.check_squares[pt] & bb.square(to) != 0 and self.pos.seeGe(move, -75)) value += 16384;
            } else {
                const histories = self.histories.?;
                value = if (self.pos.captureStage(move))
                    position.piece_value[captured] + (1 << 28)
                else
                    @as(i32, main_hist[move.data].get()) + histories.continuation[0][pc][dest].get();
            }
            self.moves[i] = .{ .move = move, .value = value };
        }
        return self.cur + list.len;
    }
    const Filter = enum { all, good_capture, good_quiet, probcut };
    fn select(self: *MovePicker, comptime filter: Filter) t.Move {
        while (self.cur < self.end_cur) {
            const i = self.cur;
            self.cur += 1;
            const m = self.moves[i];
            if (m.move.data == self.tt_move.data) continue;
            const accept = switch (filter) {
                .all => true,
                .good_quiet => m.value > -14000,
                .probcut => self.pos.seeGe(m.move, self.threshold),
                .good_capture => self.pos.seeGe(m.move, @divTrunc(-m.value, 18)),
            };
            if (accept) return m.move;
            if (filter == .good_capture or filter == .good_quiet) {
                self.moves[self.end_bad_moves] = m;
                self.end_bad_moves += 1;
            }
        }
        return .none;
    }
    pub fn next(self: *MovePicker) t.Move {
        while (true) switch (self.stage) {
            .tt => {
                self.stage = .init_first;
                return self.tt_move;
            },
            .init_first => {
                self.cur = 0;
                self.end_bad_moves = 0;
                self.end_cur = if (self.first_stage == .evasion) self.score(.evasions) else self.score(.captures);
                partialSort(self.moves[0..self.end_cur], std.math.minInt(i32));
                self.stage = self.first_stage;
            },
            .good_capture => {
                const move = self.select(.good_capture);
                if (move.data != 0) return move;
                self.end_bad_captures = self.end_bad_moves;
                if (!self.skip_quiets) {
                    self.cur = self.end_bad_moves;
                    self.end_cur = self.score(.quiets);
                    partialSort(self.moves[self.cur..self.end_cur], -3560 * self.depth);
                    self.stage = .good_quiet;
                } else self.prepareBadMoves();
            },
            .good_quiet => {
                const move = self.select(.good_quiet);
                if (move.data != 0) return move;
                self.prepareBadMoves();
            },
            .bad_moves, .evasion, .qsearch => return self.select(.all),
            .probcut => return self.select(.probcut),
        };
    }
    fn prepareBadMoves(self: *MovePicker) void {
        self.cur = 0;
        self.end_cur = self.end_bad_moves;
        self.stage = .bad_moves;
    }
};
