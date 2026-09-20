// Derived from Stockfish search.cpp history updates; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const h = @import("history.zig");
const s = @import("search_support.zig");
const Position = @import("position.zig").Position;
/// Borrowed search histories and frames. Callers provide seven initialized
/// predecessor frames, as in the upstream worker's search stack.
pub const State = struct {
    main: *h.ButterflyHistory,
    low_ply: *h.LowPlyHistory,
    capture: *h.CapturePieceToHistory,
    shared: *h.SharedHistories,
    frames: []s.Stack,
    pub fn correctionValue(self: State, pos: *const Position, frame: usize) i32 {
        const side = @intFromEnum(pos.side);
        const pawn: i32 = self.shared.pawnCorrectionEntry(pos)[side].pawn.get();
        const minor: i32 = self.shared.minorCorrectionEntry(pos)[side].minor.get();
        const white: i32 = self.shared.nonPawnCorrectionEntry(pos, .white)[side].non_pawn_white.get();
        const black: i32 = self.shared.nonPawnCorrectionEntry(pos, .black)[side].non_pawn_black.get();
        const move = self.frames[frame - 1].current_move;
        var continuation: i32 = 80695;
        if (move.valid()) {
            const to = @intFromEnum(move.to());
            const pc = @intFromEnum(pos.pieceOn(move.to()));
            continuation = 7885 * (@as(i32, self.frames[frame - 2].continuation_correction_history.?[pc][to].get()) + self.frames[frame - 4].continuation_correction_history.?[pc][to].get()) + 6307 * @as(i32, self.frames[frame - 6].continuation_correction_history.?[pc][to].get());
        }
        return 13806 * pawn + 9512 * minor + 11615 * (white + black) + continuation;
    }
    pub fn updateCorrection(self: State, pos: *const Position, frame: usize, bonus: i32) void {
        const side = @intFromEnum(pos.side);
        self.shared.pawnCorrectionEntry(pos)[side].pawn.update(bonus);
        self.shared.minorCorrectionEntry(pos)[side].minor.update(@divTrunc(bonus * 150, 128));
        self.shared.nonPawnCorrectionEntry(pos, .white)[side].non_pawn_white.update(@divTrunc(bonus * 186, 128));
        self.shared.nonPawnCorrectionEntry(pos, .black)[side].non_pawn_black.update(@divTrunc(bonus * 186, 128));
        const move = self.frames[frame - 1].current_move;
        if (move.valid()) {
            const to = @intFromEnum(move.to());
            const pc = @intFromEnum(pos.pieceOn(move.to()));
            for ([_]usize{ 2, 4, 6 }, [_]i32{ 130, 70, 35 }) |back, weight| self.frames[frame - back].continuation_correction_history.?[pc][to].update(@divTrunc(bonus * weight, 128));
        }
    }
    pub fn updateQuiet(self: State, pos: *const Position, frame: usize, move: t.Move, bonus: i32) void {
        self.main[@intFromEnum(pos.side)][move.data].update(bonus);
        const ply = self.frames[frame].ply;
        std.debug.assert(ply >= 0);
        if (ply < h.low_ply_history_size) self.low_ply[@intCast(ply)][move.data].update(@divTrunc(bonus * 712, 1024));
        const pc = pos.pieceOn(move.from());
        s.updateContinuationHistories(self.frames, frame, pc, move.to(), @divTrunc(bonus * 750, 1024));
        self.shared.pawnEntry(pos)[@intFromEnum(pc)][@intFromEnum(move.to())].update(@divTrunc(bonus * @as(i32, if (bonus > -4) 1104 else 459), 1024));
    }
    pub fn updateAll(self: State, pos: *const Position, frame: usize, best: t.Move, prev_sq: t.Square, quiets: []const t.Move, captures: []const t.Move, depth: i32, tt_move: t.Move, pv_node: bool) void {
        const previous = &self.frames[frame - 1];
        var bonus = @min(133 * depth - 81, 1487) + @as(i32, if (best.data == tt_move.data) 364 else 0) + @divTrunc(previous.stat_score, 28);
        const malus = @min(968 * depth - 235, 2244);
        if (!pv_node) {
            // Preserve the upstream unsigned 64-bit multiply and narrowing.
            const unsigned: u64 = @bitCast(@as(i64, bonus));
            const extra: i32 = @bitCast(@as(u32, @truncate((unsigned *% (quiets.len + captures.len)) / 256)));
            bonus +%= extra;
        }
        if (!pos.captureStage(best)) {
            self.updateQuiet(pos, frame, best, @divTrunc(bonus * 899, 1024));
            var actual_malus = @divTrunc(malus * 1159, 1024);
            for (quiets) |move| {
                actual_malus = @divTrunc(actual_malus * 921, 1024);
                self.updateQuiet(pos, frame, move, -actual_malus);
            }
        } else self.capture[@intFromEnum(pos.pieceOn(best.from()))][@intFromEnum(best.to())][@intFromEnum(pos.pieceOn(best.to()).pieceType())].update(@divTrunc(bonus * 1427, 1024));
        if (prev_sq != .none and previous.move_count == 1 + @as(i32, @intFromBool(previous.tt_hit)) and pos.st.captured_piece == .none) s.updateContinuationHistories(self.frames, frame - 1, pos.pieceOn(prev_sq), prev_sq, @divTrunc(-malus * 713, 1024));
        for (captures) |move| self.capture[@intFromEnum(pos.pieceOn(move.from()))][@intFromEnum(move.to())][@intFromEnum(pos.pieceOn(move.to()).pieceType())].update(@divTrunc(-malus * 1489, 1024));
    }
};
