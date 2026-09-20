// Derived from Stockfish Search::Worker::search; GPL-3.0-or-later.
// Root/PV/NonPV kernels: fixed-depth, one worker, tablebases disabled.
const std = @import("std");
const t = @import("types.zig");
const s = @import("search_support.zig");
const p = @import("position.zig");
const mp = @import("movepick.zig");
const h = @import("history.zig");
const tt = @import("tt.zig");
const QWorker = @import("quiescence.zig").Worker;
fn b(value: bool) i32 {
    return @intFromBool(value);
}
fn div(a: i32, d: i32) i32 {
    return @divTrunc(a, d);
}
fn win(v: i32) bool {
    return v >= s.tb_win_in_max_ply;
}
fn loss(v: i32) bool {
    return v <= -s.tb_win_in_max_ply;
}
fn decisive(v: i32) bool {
    return win(v) or loss(v);
}
fn bound(value: tt.Bound, lower: bool) bool {
    return @intFromEnum(value) & @intFromEnum(if (lower) tt.Bound.lower else tt.Bound.upper) != 0;
}
fn pieceValue(pc: t.Piece) i32 {
    return p.piece_value[@intFromEnum(pc.pieceType())];
}
const Searched = struct {
    moves: [32]t.Move = undefined,
    len: usize = 0,
    fn append(self: *Searched, move: t.Move) void {
        std.debug.assert(self.len < 32);
        self.moves[self.len] = move;
        self.len += 1;
    }
    fn slice(self: *const Searched) []const t.Move {
        return self.moves[0..self.len];
    }
};
pub const RootMove = @import("root_move.zig").RootMove;
const NodeType = enum { root, pv, non_pv };
pub const Worker = struct {
    base: *QWorker,
    reductions: s.Reductions,
    tt_move_history: h.TTMoveHistory = .{ .value = 0 },
    root_depth: i32 = 0,
    root_delta: i32 = 1,
    root_score: i32 = 0,
    root_moves: []RootMove = &.{},
    pv_idx: usize = 0,
    pv_last: usize = 0,
    best_move_changes: usize = 0,
    nmp_min_ply: i32 = 0,
    last_iteration_pv: s.PV = .{},
    pub fn init(base: *QWorker) Worker {
        var self: Worker = .{ .base = base, .reductions = .{} };
        self.reductions.init();
        return self;
    }
    /// Diagnostic non-root entry. Retain histories and TT between calls.
    pub fn run(self: *Worker, comptime pv_node: bool, pos: *p.Position, pv: *s.PV, alpha: i32, beta: i32, depth: i32, cut_node: bool) i32 {
        self.base.prepare(pv);
        self.root_depth = depth;
        self.root_delta = beta - alpha;
        self.nmp_min_ply = 0;
        return self.search(pv_node, pos, 7, alpha, beta, depth, cut_node);
    }
    fn shuffling(self: *Worker, move: t.Move, frame: usize, pos: *const p.Position) bool {
        if (pos.captureStage(move) or pos.st.rule50 < 10 or pos.st.plies_from_null < 6 or self.base.frames[frame].ply < 20) return false;
        return move.from() == self.base.frames[frame - 2].current_move.to() and self.base.frames[frame - 2].current_move.from() == self.base.frames[frame - 4].current_move.to();
    }
    pub fn search(self: *Worker, comptime pv_node: bool, pos: *p.Position, frame: usize, initial_alpha: i32, initial_beta: i32, initial_depth: i32, cut_node: bool) i32 {
        return self.searchNode(if (pv_node) .pv else .non_pv, pos, frame, initial_alpha, initial_beta, initial_depth, cut_node);
    }
    /// Search the selected root range. Frames and root records must be initialized.
    pub fn searchRoot(self: *Worker, pos: *p.Position, alpha: i32, beta: i32, depth: i32) i32 {
        std.debug.assert(self.pv_idx < self.pv_last and self.pv_last <= self.root_moves.len);
        self.root_delta = beta - alpha;
        return self.searchNode(.root, pos, 7, alpha, beta, depth, false);
    }
    fn searchNode(self: *Worker, comptime node_type: NodeType, pos: *p.Position, frame: usize, initial_alpha: i32, initial_beta: i32, initial_depth: i32, cut_node: bool) i32 {
        const pv_node = node_type != .non_pv;
        const root_node = node_type == .root;
        const w = self.base;
        const ss = &w.frames[frame];
        const prev = &w.frames[frame - 1];
        const all_node = !(pv_node or cut_node);
        const seek_mate = self.root_depth >= 16 and @abs(if (self.root_moves.len != 0) self.root_moves[self.pv_idx].score else self.root_score) >= 2000;
        if (initial_depth <= 0) return w.search(pv_node, pos, frame, initial_alpha, initial_beta);
        var depth = @min(initial_depth, t.max_ply - 1);
        var alpha = initial_alpha;
        var beta = initial_beta;
        if (!root_node and alpha < 0 and pos.upcomingRepetition(ss.ply)) {
            alpha = s.drawValue(@intCast(w.nodes));
            if (alpha >= beta) return alpha;
        }
        std.debug.assert(alpha >= -t.value_infinite and alpha < beta and beta <= t.value_infinite);
        std.debug.assert(pv_node or alpha == beta - 1);
        std.debug.assert(!(pv_node and cut_node));
        var pv: s.PV = .{};
        var state: p.StateInfo = undefined;
        var captures: Searched = .{};
        var quiets: Searched = .{};
        ss.in_check = pos.st.checkers != 0;
        const prior_capture = pos.st.captured_piece != .none;
        const us = @intFromEnum(pos.side);
        ss.move_count = 0;
        var best_value: i32 = -t.value_infinite;
        ss.follow_pv = root_node or (prev.follow_pv and ss.ply > 0 and @as(usize, @intCast(ss.ply - 1)) < self.last_iteration_pv.len and prev.current_move.data == self.last_iteration_pv.moves[@intCast(ss.ply - 1)].data);
        if (pv_node and w.sel_depth < ss.ply + 1) w.sel_depth = ss.ply + 1;
        if (!root_node) {
            if (pos.isDraw(ss.ply) or ss.ply >= t.max_ply) return if (ss.ply >= t.max_ply and !ss.in_check) w.evaluate(pos) else s.drawValue(@intCast(w.nodes));
            alpha = @max(-t.value_mate + ss.ply, alpha);
            beta = @min(t.value_mate - ss.ply - 1, beta);
            if (alpha >= beta) return alpha;
        }
        const prev_sq: t.Square = if (prev.current_move.valid()) prev.current_move.to() else .none;
        var best_move: t.Move = .none;
        const prior_reduction = prev.reduction;
        prev.reduction = 0;
        ss.stat_score = 0;
        w.frames[frame + 2].cutoff_count = 0;
        w.frames[frame + 1].prior_nmp_fail_high = 0;
        const histories = w.histories();
        const correction = histories.correctionValue(pos, frame);
        const excluded = ss.excluded_move;
        const key = pos.key();
        const probe = w.table.probe(key);
        var data = probe.data;
        ss.tt_hit = probe.found;
        data.move = if (root_node) self.root_moves[self.pv_idx].pv.moves[0] else if (probe.found) data.move else .none;
        data.value = if (probe.found) s.valueFromTT(data.value, ss.ply, pos.st.rule50) else t.value_none;
        ss.tt_pv = if (excluded.data != 0) ss.tt_pv else pv_node or (probe.found and data.is_pv);
        const tt_capture = data.move.data != 0 and pos.captureStage(data.move);
        var unadjusted: i32 = t.value_none;
        var eval: i32 = undefined;
        if (ss.in_check) {
            ss.static_eval = w.frames[frame - 2].static_eval;
            eval = ss.static_eval;
        } else if (excluded.data != 0) {
            unadjusted = ss.static_eval;
            eval = unadjusted;
        } else {
            unadjusted = if (probe.found) data.eval else t.value_none;
            if (unadjusted == t.value_none) unadjusted = w.evaluate(pos);
            ss.static_eval = s.correctedStaticEval(unadjusted, correction);
            eval = ss.static_eval;
            if (probe.found) {
                if (data.value != t.value_none and bound(data.bound, data.value > eval)) eval = data.value;
            } else w.save(probe.writer, key, t.value_none, ss.tt_pv, .none, -2, .none, unadjusted);
        }
        var improving = ss.static_eval > w.frames[frame - 2].static_eval;
        const opponent_worsening = ss.static_eval > -prev.static_eval;
        if (prior_reduction >= 3 and !opponent_worsening) depth += 1;
        if (prior_reduction >= 2 and depth >= 2 and ss.static_eval + prev.static_eval > 166) depth -= 1;
        if (!pv_node and excluded.data == 0 and data.value != t.value_none and data.depth > depth - b(data.value <= beta)) {
            if (bound(data.bound, data.value >= beta) and (cut_node == (data.value >= beta) or depth > 4)) {
                if (data.move.data != 0 and data.value >= beta) {
                    if (!tt_capture) histories.updateQuiet(pos, frame, data.move, 131 * depth);
                    if (prev_sq != .none and prev.move_count < 5 and !prior_capture) s.updateContinuationHistories(&w.frames, frame - 1, pos.pieceOn(prev_sq), prev_sq, -2210);
                }
                if (pos.st.rule50 < 96) {
                    if (depth >= 7 and data.move.data != 0 and pos.pseudoLegal(data.move) and pos.legal(data.move) and !decisive(data.value)) {
                        pos.doMove(data.move, &state);
                        const next = w.table.probe(pos.key());
                        pos.undoMove(data.move);
                        if (next.data.value == t.value_none or (data.value >= beta) == (-next.data.value >= beta)) return data.value;
                    } else return data.value;
                }
            } else if (data.bound != .exact and bound(data.bound, data.value < beta) and depth > 5) probe.writer.penalize(1);
        }
        if (!ss.in_check) {
            if (prev.current_move.valid() and !prev.in_check and !prior_capture) {
                const diff = std.math.clamp(-(prev.static_eval + ss.static_eval), -189, 194) + 60;
                w.main_history[us ^ 1][prev.current_move.data].update(diff * 11);
                if (!probe.found and pos.pieceOn(prev_sq).pieceType() != .pawn and prev.current_move.kind() != .promotion) w.shared.pawnEntry(pos)[@intFromEnum(pos.pieceOn(prev_sq))][@intFromEnum(prev_sq)].update(diff * 13);
            }
            if (all_node and eval < alpha - 342 * depth and !seek_mate) return w.search(false, pos, frame, alpha, beta);
            if (!ss.tt_pv and depth < @as(i32, if (seek_mate) 6 else 19) and eval >= beta and (data.move.data == 0 or tt_capture) and !loss(beta) and !win(eval)) {
                const mult = @min(45 + depth * 4, 85) - 20 * b(!ss.tt_hit);
                const margin = mult * depth - div((2789 * b(improving) + 335 * b(opponent_worsening)) * mult, 1024) + @as(i32, @intCast(@abs(correction) / 198435));
                if (eval - margin >= beta) return div(661 * beta + 363 * eval, 1024);
            }
            if (cut_node and ss.static_eval + 50 * ss.prior_nmp_fail_high >= beta - 13 * depth - 47 * b(improving) + 365 and excluded.data == 0 and pos.st.non_pawn_material[us] != 0 and ss.ply >= self.nmp_min_ply and beta >= -2000) {
                std.debug.assert(prev.current_move.data != t.Move.null_move.data);
                const reduction = 7 + div(depth, 3) + @max(div(ss.static_eval - beta, 256), 0);
                w.doNullMove(pos, &state, frame);
                const value = -self.search(false, pos, frame + 1, -beta, -beta + 1, depth - reduction, false);
                w.undoNullMove(pos);
                if (value >= beta and !win(value)) {
                    if (self.nmp_min_ply != 0 or depth < 16) {
                        ss.prior_nmp_fail_high += 1;
                        return value;
                    }
                    self.nmp_min_ply = ss.ply + div(3 * (depth - reduction), 4);
                    const verified = self.search(false, pos, frame, beta - 1, beta, depth - reduction, false);
                    self.nmp_min_ply = 0;
                    if (verified >= beta) {
                        ss.prior_nmp_fail_high += 1;
                        return value;
                    }
                }
            }
            improving = improving or ss.static_eval >= beta;
            if (!ss.follow_pv and !all_node and depth >= 6 and data.move.data == 0) depth -= 1;
            const prob_beta = beta + 241 - 64 * b(improving);
            if (depth >= 3 and !decisive(beta) and !(data.value != t.value_none and data.value < prob_beta)) {
                var picker = mp.MovePicker.initProbcut(pos, data.move, prob_beta - ss.static_eval, w.capture_history);
                const prob_depth = depth - @as(i32, if (improving) 5 else 3);
                while (true) {
                    const move = picker.next();
                    if (move.data == 0) break;
                    if (move.data == excluded.data or !pos.legal(move)) continue;
                    w.doMove(pos, move, &state, frame);
                    var value = -w.search(false, pos, frame + 1, -prob_beta, -prob_beta + 1);
                    if (value >= prob_beta and prob_depth > 0) value = -self.search(false, pos, frame + 1, -prob_beta, -prob_beta + 1, prob_depth, !cut_node);
                    w.undoMove(pos, move);
                    if (value >= prob_beta) {
                        w.save(probe.writer, key, s.valueToTT(value, ss.ply), ss.tt_pv, .lower, prob_depth + 1, move, unadjusted);
                        if (!decisive(value)) return value - (prob_beta - beta);
                    }
                }
            }
        }
        const small_prob_beta = beta + 428;
        if (bound(data.bound, true) and data.depth >= depth - 4 and data.value >= small_prob_beta and !decisive(beta) and data.value != t.value_none and !decisive(data.value)) return small_prob_beta;
        const cont = [_]*const h.PieceToHistory{ prev.continuation_history.?, w.frames[frame - 2].continuation_history.?, w.frames[frame - 3].continuation_history.?, w.frames[frame - 4].continuation_history.?, w.frames[frame - 5].continuation_history.?, w.frames[frame - 6].continuation_history.? };
        var picker = mp.MovePicker.init(pos, data.move, depth, .{ .main = w.main_history, .low_ply = w.low_ply_history, .capture = w.capture_history, .continuation = &cont, .shared = w.shared }, @intCast(ss.ply));
        var value = best_value;
        var move_count: i32 = 0;
        while (true) {
            const move = picker.next();
            if (move.data == 0) break;
            if (move.data == excluded.data or !pos.legal(move)) continue;
            if (root_node) {
                var included = false;
                for (self.root_moves[self.pv_idx..self.pv_last]) |*rm| {
                    if (rm.pv.moves[0].data == move.data) {
                        included = true;
                        break;
                    }
                }
                if (!included) continue;
            }
            move_count += 1;
            ss.move_count = move_count;
            if (pv_node) w.frames[frame + 1].pv = null;
            var extension: i32 = 0;
            const capture = pos.captureStage(move);
            const pc = pos.pieceOn(move.from());
            const pci = @intFromEnum(pc);
            const to = @intFromEnum(move.to());
            const check = pos.givesCheck(move);
            var new_depth = depth - 1;
            var r = self.reductions.reduction(improving, @intCast(depth), @intCast(move_count), beta - alpha, self.root_delta);
            if (ss.tt_pv) r += 929;
            if (!root_node and pos.st.non_pawn_material[us] != 0 and !loss(best_value)) {
                if (move_count >= div(3 + depth * depth, 2 - b(improving))) picker.skipQuietMoves();
                var lmr_depth = new_depth - div(r, 1024);
                if (capture or check) {
                    const captured = pos.pieceOn(move.to());
                    const capt_hist: i32 = w.capture_history[pci][to][@intFromEnum(captured.pieceType())].get();
                    if (!check and lmr_depth < 8 and ss.static_eval + 234 + 247 * lmr_depth + pieceValue(captured) + div(134 * capt_hist, 1024) <= alpha) continue;
                    const margin = 177 * depth + div(capt_hist * 34, 1024);
                    if ((alpha >= 0 or pos.st.non_pawn_material[us] != pieceValue(pc)) and !pos.seeGe(move, -margin)) continue;
                } else if (!ss.follow_pv or !pv_node) {
                    var history = @as(i32, cont[0][pci][to].get()) + cont[1][pci][to].get() + w.shared.pawnEntry(pos)[pci][to].get();
                    if (history < -4136 * depth) continue;
                    history += div(69 * @as(i32, w.main_history[us][move.data].get()), 32);
                    lmr_depth += div(history, s.lmrDivisor(depth));
                    const futility = ss.static_eval + 119 * lmr_depth + 90 * b(ss.static_eval > alpha) + 164;
                    if (!ss.in_check and lmr_depth < 12 and futility <= alpha) {
                        if (best_value <= futility and !decisive(best_value) and !win(futility)) best_value = futility;
                        continue;
                    }
                    lmr_depth = @max(lmr_depth, 0);
                    if (!pos.seeGe(move, -23 * lmr_depth * lmr_depth)) continue;
                }
            }
            if (!root_node and move.data == data.move.data and excluded.data == 0 and depth >= 6 + b(ss.tt_pv) and data.value != t.value_none and !decisive(data.value) and bound(data.bound, true) and data.depth >= depth - 3 and !self.shuffling(move, frame, pos) and !seek_mate) {
                const singular_beta = data.value - div((59 + 66 * b(ss.tt_pv and !pv_node)) * depth, 63);
                const singular_depth = div(new_depth, 2);
                ss.excluded_move = move;
                value = self.search(false, pos, frame, singular_beta - 1, singular_beta, singular_depth, cut_node);
                ss.excluded_move = .none;
                if (value < singular_beta) {
                    const adj: @TypeOf(correction) = @intCast(@abs(correction) / 198368);
                    const double_margin = -2 + 204 * b(pv_node) - 152 * b(!tt_capture) - adj - div(1175 * @as(i32, self.tt_move_history.get()), 114178) - 38 * b(ss.ply > self.root_depth);
                    const triple_margin = 70 + 279 * b(pv_node) - 188 * b(!tt_capture) + 81 * b(ss.tt_pv) - adj - 43 * b(ss.ply > self.root_depth);
                    extension = 1 + b(value < singular_beta - double_margin) + b(value < singular_beta - triple_margin);
                    depth += 1;
                } else if (value >= beta and !decisive(value)) {
                    self.tt_move_history.update(-421 - 110 * depth);
                    if (!ss.in_check and value > ss.static_eval) histories.updateCorrection(pos, frame, std.math.clamp(div((value - ss.static_eval) * singular_depth * 177, 1024), -256, 256));
                    return value;
                } else if (data.value >= beta or cut_node) extension = -3;
            }
            const node_count = if (root_node) w.nodes else 0;
            w.doMove(pos, move, &state, frame);
            new_depth += extension;
            if (ss.tt_pv) r -= 3023 + 1004 * b(pv_node) + 885 * b(data.value > alpha) + b(data.depth >= depth) * (816 + 940 * b(cut_node));
            r += 697;
            r -= move_count * 65;
            r -= @intCast(@abs(correction) / 26310);
            if (cut_node) r += 4026 + 933 * b(data.move.data == 0);
            if (tt_capture) r += 1079;
            if (w.frames[frame + 1].cutoff_count > 1) r += 264 + 1095 * b(w.frames[frame + 1].cutoff_count > 2) + 1138 * b(all_node) else if (move.data == data.move.data) r -= 2179;
            if (capture) ss.stat_score = div(873 * pieceValue(pos.st.captured_piece), 128) + w.capture_history[pci][to][@intFromEnum(pos.st.captured_piece.pieceType())].get() else ss.stat_score = div(2252 * @as(i32, w.main_history[us][move.data].get()) + 1126 * @as(i32, cont[0][pci][to].get()) + 1093 * @as(i32, cont[1][pci][to].get()), 1024);
            r -= div(ss.stat_score * 439, 4096);
            if (!capture and !decisive(alpha)) r += 3 * std.math.clamp(alpha - eval, -64, 96);
            if (all_node) r += div(r * 276, 256 * depth + 268);
            if (depth >= 2 and move_count > 1) {
                const d = @max(1, new_depth + @min(div(-r, 1024), @as(i32, if (ss.ply < 2 * self.root_depth) 2 else 0))) + b(pv_node);
                ss.reduction = new_depth - d;
                value = -self.search(false, pos, frame + 1, -(alpha + 1), -alpha, d, true);
                ss.reduction = 0;
                if (value > alpha) {
                    new_depth += b(d < new_depth and value > best_value + 53) - b(value < best_value + 8);
                    if (new_depth > d) value = -self.search(false, pos, frame + 1, -(alpha + 1), -alpha, new_depth, !cut_node);
                    s.updateContinuationHistories(&w.frames, frame, pc, move.to(), 1334);
                }
            } else if (!pv_node or move_count > 1) {
                if (data.move.data == 0) r += 1127;
                value = -self.search(false, pos, frame + 1, -(alpha + 1), -alpha, new_depth - b(r > 5234) - b(r > 5487 and new_depth > 2), !cut_node);
            }
            if (pv_node and (move_count == 1 or value > alpha)) {
                w.frames[frame + 1].pv = &pv;
                pv.clear();
                if (move.data == data.move.data and ((data.value != t.value_none and decisive(data.value) and data.depth > 0) or data.depth > 1)) new_depth = @max(new_depth, 1);
                value = -self.search(true, pos, frame + 1, -beta, -alpha, new_depth, false);
            }
            w.undoMove(pos, move);
            std.debug.assert(value > -t.value_infinite and value < t.value_infinite);
            if (root_node) {
                for (self.root_moves) |*rm| {
                    if (rm.pv.moves[0].data != move.data) continue;
                    rm.record(value, alpha, beta, move_count, w.sel_depth, w.nodes - node_count, w.frames[frame + 1].pv);
                    if ((move_count == 1 or value > alpha) and move_count > 1 and self.pv_idx == 0) self.best_move_changes += 1;
                    break;
                }
            }
            const inc = b(value == best_value and ss.ply + 2 >= self.root_depth and w.nodes & 14 == 0 and !win(@as(i32, @intCast(@abs(value))) + 1));
            if (value + inc > best_value) {
                best_value = value;
                if (value + inc > alpha) {
                    best_move = move;
                    if (pv_node and !root_node) ss.pv.?.update(move, w.frames[frame + 1].pv);
                    if (value >= beta) {
                        ss.cutoff_count += b(extension < 2 or pv_node);
                        break;
                    }
                    if (depth > 3 and depth < 12 and !decisive(value)) depth -= 3;
                    alpha = value;
                }
            }
            if (move.data != best_move.data and move_count <= 32) {
                if (capture) captures.append(move) else quiets.append(move);
            }
        }
        if (best_value >= beta and !decisive(best_value) and !decisive(alpha)) best_value = div(best_value * depth + beta, depth + 1);
        if (move_count == 0) best_value = if (excluded.data != 0) alpha else if (ss.in_check) -t.value_mate + ss.ply else 0 else if (best_move.data != 0) {
            histories.updateAll(pos, frame, best_move, prev_sq, quiets.slice(), captures.slice(), depth, data.move, pv_node);
            if (!pv_node) self.tt_move_history.update(if (best_move.data == data.move.data) 918 else -747);
        } else if (!prior_capture and prev_sq != .none) {
            var scale: i32 = -241 - div(prev.stat_score, 98) + @min(59 * depth, 420) + 186 * b(prev.move_count > 9) + 142 * b(!ss.in_check and best_value <= ss.static_eval - 106) + 159 * b(!prev.in_check and best_value <= -prev.static_eval - 68);
            scale = @max(scale, 0);
            const bonus = @min(150 * depth - 85, 1337) * scale;
            s.updateContinuationHistories(&w.frames, frame - 1, pos.pieceOn(prev_sq), prev_sq, div(bonus * 263, 16384));
            w.main_history[us ^ 1][prev.current_move.data].update(div(bonus * 215, 32768));
            if (pos.pieceOn(prev_sq).pieceType() != .pawn and prev.current_move.kind() != .promotion) w.shared.pawnEntry(pos)[@intFromEnum(pos.pieceOn(prev_sq))][@intFromEnum(prev_sq)].update(div(bonus * 324, 8192));
        } else if (prior_capture and prev_sq != .none) w.capture_history[@intFromEnum(pos.pieceOn(prev_sq))][@intFromEnum(prev_sq)][@intFromEnum(pos.st.captured_piece.pieceType())].update(892);
        if (best_value <= alpha) ss.tt_pv = ss.tt_pv or prev.tt_pv;
        if (excluded.data == 0 and !(root_node and self.pv_idx != 0)) w.save(probe.writer, key, s.valueToTT(best_value, ss.ply), ss.tt_pv, if (best_value >= beta) .lower else if (pv_node and best_move.data != 0) .exact else .upper, if (move_count != 0) depth else @min(t.max_ply - 1, depth + 6), best_move, unadjusted);
        if (!ss.in_check and !(best_move.data != 0 and pos.capture(best_move)) and (best_value > ss.static_eval) == (best_move.data != 0)) histories.updateCorrection(pos, frame, div(1061 * std.math.clamp(div((best_value - ss.static_eval) * depth * @as(i32, if (best_move.data != 0) 12 else 18), 128), -256, 256), 1024));
        std.debug.assert(best_value > -t.value_infinite and best_value < t.value_infinite);
        return best_value;
    }
};
