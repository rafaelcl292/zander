// Derived from Stockfish Search::Worker::qsearch; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const h = @import("history.zig");
const s = @import("search_support.zig");
const p = @import("position.zig");
const mg = @import("movegen.zig");
const mp = @import("movepick.zig");
const tt = @import("tt.zig");
const nn = @import("nnue/network.zig");
const acc = @import("nnue/accumulator.zig");
const bb = @import("bitboard.zig");

/// Single-worker quiescence state. All referenced storage is supplied and
/// initialized by the owner; no search operation allocates.
pub const Worker = struct {
    network: *const nn.Network,
    accumulators: *acc.Stack,
    caches: *acc.Caches,
    table: *tt.Table,
    main_history: *h.ButterflyHistory,
    low_ply_history: *h.LowPlyHistory,
    capture_history: *h.CapturePieceToHistory,
    shared: *h.SharedHistories,
    continuation_correction: *h.ContinuationCorrectionHistory,
    frames: [t.max_ply + 10]s.Stack = @splat(.{}),
    control: ?*@import("search_control.zig").Control = null,
    nodes: u64 = 0,
    publish_nodes: bool = false,
    helper: bool = false,
    published_nodes: std.atomic.Value(u64) = .init(0),
    sel_depth: i32 = 0,
    optimism: [2]i32 = @splat(0),
    pub fn stopped(self: *const Worker) bool {
        return if (self.control) |control| (control.stopped() or (self.helper and control.helpers_stop.load(.acquire))) else false;
    }
    /// Start a fresh diagnostic root. TT and history contents are retained;
    /// the owner decides when to clear them or advance the TT generation.
    pub fn run(self: *Worker, comptime pv_node: bool, pos: *p.Position, pv: *s.PV, alpha: i32, beta: i32) i32 {
        self.prepare(pv);
        return self.search(pv_node, pos, 7, alpha, beta);
    }
    pub fn prepare(self: *Worker, pv: *s.PV) void {
        self.nodes = 0;
        self.published_nodes.store(0, .monotonic);
        self.sel_depth = 0;
        self.accumulators.reset();
        self.frames = @splat(.{});
        for (self.frames[0..7]) |*frame| {
            frame.continuation_history = &self.shared.continuation[0][0][0][0];
            frame.continuation_correction_history = &self.continuation_correction[0][0];
            frame.static_eval = t.value_none;
        }
        for (self.frames[7..], 0..) |*frame, ply| frame.ply = @intCast(ply);
        pv.clear();
        self.frames[7].pv = pv;
    }
    /// Frames must already have their in-check flag and sentinel histories set.
    pub fn doMove(self: *Worker, pos: *p.Position, move: t.Move, state: *p.StateInfo, frame: ?usize) void {
        const capture = pos.captureStage(move);
        self.nodes += 1;
        if (self.publish_nodes) self.published_nodes.store(self.nodes, .monotonic);
        const dirties = self.accumulators.push();
        pos.doMoveWithDirties(move, state, dirties);
        if (frame) |index| {
            const ss = &self.frames[index];
            ss.current_move = move;
            ss.continuation_history = &self.shared.continuation[@intFromBool(ss.in_check)][@intFromBool(capture)][@intFromEnum(dirties.piece.pc)][@intFromEnum(move.to())];
            ss.continuation_correction_history = &self.continuation_correction[@intFromEnum(dirties.piece.pc)][@intFromEnum(move.to())];
        }
    }
    pub fn undoMove(self: *Worker, pos: *p.Position, move: t.Move) void {
        pos.undoMove(move);
        self.accumulators.pop();
    }
    pub fn doNullMove(self: *Worker, pos: *p.Position, state: *p.StateInfo, frame: usize) void {
        pos.doNullMove(state);
        const ss = &self.frames[frame];
        ss.current_move = .null_move;
        ss.continuation_history = &self.shared.continuation[0][0][0][0];
        ss.continuation_correction_history = &self.continuation_correction[0][0];
    }
    pub fn undoNullMove(_: *Worker, pos: *p.Position) void {
        pos.undoNullMove();
    }
    pub fn evaluate(self: *Worker, pos: *const p.Position) i32 {
        return self.network.evaluateAdjusted(pos, self.accumulators, self.caches, self.optimism[@intFromEnum(pos.side)]);
    }
    pub fn histories(self: *Worker) @import("search_history.zig").State {
        return .{ .main = self.main_history, .low_ply = self.low_ply_history, .capture = self.capture_history, .shared = self.shared, .frames = &self.frames };
    }
    fn decisive(value: i32) bool {
        return value >= s.tb_win_in_max_ply or value <= -s.tb_win_in_max_ply;
    }
    fn hasBound(bound: tt.Bound, lower: bool) bool {
        return @intFromEnum(bound) & @intFromEnum(if (lower) tt.Bound.lower else tt.Bound.upper) != 0;
    }
    pub fn save(self: *Worker, writer: *tt.Entry, key: u64, value: i32, is_pv: bool, bound: tt.Bound, depth: i32, move: t.Move, eval: i32) void {
        writer.save(key, .{ .move = move, .value = value, .eval = eval, .depth = depth, .bound = bound, .is_pv = is_pv }, self.table.generation);
    }
    pub fn search(self: *Worker, comptime pv_node: bool, pos: *p.Position, frame: usize, initial_alpha: i32, beta: i32) i32 {
        std.debug.assert(initial_alpha >= -t.value_infinite and initial_alpha < beta and beta <= t.value_infinite);
        std.debug.assert(pv_node or initial_alpha == beta - 1);
        if (self.stopped()) return 0;
        const ss = &self.frames[frame];
        var alpha = initial_alpha;
        if (alpha < 0 and pos.upcomingRepetition(ss.ply)) {
            alpha = s.drawValue(@intCast(self.nodes));
            if (alpha >= beta) return alpha;
        }
        var pv: s.PV = .{};
        if (pv_node) {
            self.frames[frame + 1].pv = &pv;
            ss.pv.?.clear();
        }
        var best_move: t.Move = .none;
        ss.in_check = pos.st.checkers != 0;
        var move_count: i32 = 0;
        if (pv_node and self.sel_depth < ss.ply + 1) self.sel_depth = ss.ply + 1;
        if (pos.isDraw(ss.ply) or ss.ply >= t.max_ply) return if (ss.ply >= t.max_ply and !ss.in_check) self.evaluate(pos) else 0;
        const key = pos.key();
        const probe = self.table.probe(key);
        ss.tt_hit = probe.found;
        const tt_move: t.Move = if (probe.found) probe.data.move else .none;
        const tt_value = if (probe.found) s.valueFromTT(probe.data.value, ss.ply, pos.st.rule50) else t.value_none;
        const pv_hit = probe.found and probe.data.is_pv;
        if (!pv_node and probe.data.depth >= 0 and tt_value != t.value_none and hasBound(probe.data.bound, tt_value >= beta)) return tt_value;
        var unadjusted_eval: i32 = t.value_none;
        var best_value: i32 = -t.value_infinite;
        var futility_base: i32 = -t.value_infinite;
        if (!ss.in_check) {
            const correction = self.histories().correctionValue(pos, frame);
            unadjusted_eval = if (probe.found) probe.data.eval else t.value_none;
            if (unadjusted_eval == t.value_none) unadjusted_eval = self.evaluate(pos);
            best_value = s.correctedStaticEval(unadjusted_eval, correction);
            ss.static_eval = best_value;
            if (probe.found and tt_value != t.value_none and !decisive(tt_value) and hasBound(probe.data.bound, tt_value > best_value)) best_value = tt_value;
            if (best_value >= beta) {
                if (!decisive(best_value)) best_value = @divTrunc(441 * best_value + 583 * beta, 1024);
                if (!probe.found) self.save(probe.writer, key, t.value_none, false, .lower, -2, .none, unadjusted_eval);
                return best_value;
            }
            if (best_value > alpha) alpha = best_value;
            futility_base = ss.static_eval + 306;
        }
        const continuation = [_]*const h.PieceToHistory{self.frames[frame - 1].continuation_history.?};
        const prev_move = self.frames[frame - 1].current_move;
        const prev_sq: t.Square = if (prev_move.valid()) prev_move.to() else .none;
        var picker = mp.MovePicker.init(pos, tt_move, 0, .{ .main = self.main_history, .low_ply = self.low_ply_history, .capture = self.capture_history, .continuation = &continuation, .shared = self.shared }, @intCast(ss.ply));
        while (true) {
            const move = picker.next();
            if (move.data == 0) break;
            if (!pos.legal(move)) continue;
            const gives_check = pos.givesCheck(move);
            const capture = pos.captureStage(move);
            move_count += 1;
            if (best_value > -s.tb_win_in_max_ply) {
                if (!gives_check and move.to() != prev_sq and futility_base > -s.tb_win_in_max_ply and move.kind() != .promotion) {
                    if (move_count > 2) continue;
                    const futility_value = futility_base + p.piece_value[@intFromEnum(pos.pieceOn(move.to()).pieceType())];
                    if (futility_value <= alpha) {
                        best_value = @max(best_value, futility_value);
                        continue;
                    }
                    if (!pos.seeGe(move, alpha - futility_base)) {
                        best_value = @max(best_value, @min(alpha, futility_base));
                        continue;
                    }
                }
                if (!capture or !pos.seeGe(move, -74)) continue;
            }
            var state: p.StateInfo = undefined;
            self.doMove(pos, move, &state, frame);
            const value = -self.search(pv_node, pos, frame + 1, -beta, -alpha);
            self.undoMove(pos, move);
            if (self.stopped()) return 0;
            std.debug.assert(value > -t.value_infinite and value < t.value_infinite);
            if (value > best_value) {
                best_value = value;
                if (value > alpha) {
                    best_move = move;
                    if (pv_node) ss.pv.?.update(move, self.frames[frame + 1].pv);
                    if (value < beta) alpha = value else break;
                }
            }
        }
        if (move_count == 0) {
            if (ss.in_check) return -t.value_mate + ss.ply;
            const pushes = bb.shift(pos.piecesOf(pos.side, .pawn), if (pos.side == .white) 8 else -8) & ~pos.pieces();
            if (pushes == 0 and pos.st.non_pawn_material[@intFromEnum(pos.side)] == 0 and @intFromEnum(pos.st.captured_piece.pieceType()) >= @intFromEnum(t.PieceType.knight)) {
                var legal: mg.MoveList = .{};
                mg.generate(.legal, pos, &legal);
                if (legal.len == 0) best_value = 0;
            }
        }
        if (!decisive(best_value) and best_value > beta) best_value = @divTrunc(462 * best_value + 562 * beta, 1024);
        self.save(probe.writer, key, s.valueToTT(best_value, ss.ply), pv_hit, if (best_value >= beta) .lower else .upper, 0, best_move, unadjusted_eval);
        std.debug.assert(best_value > -t.value_infinite and best_value < t.value_infinite);
        return best_value;
    }
};
