// Derived from Stockfish RootMove and root score bookkeeping; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const s = @import("search_support.zig");

/// Root PV storage is bounded for searches without tablebase PV extension.
pub const RootMove = struct {
    effort: u64 = 0,
    score: i32 = -t.value_infinite,
    previous_score: i32 = -t.value_infinite,
    average_score: i32 = -t.value_infinite,
    mean_squared_score: i32 = -t.value_infinite * t.value_infinite,
    uci_score: i32 = -t.value_infinite,
    inexact_lower: bool = false,
    inexact_upper: bool = false,
    previous_score_exact: bool = false,
    sel_depth: i32 = 0,
    tb_rank: i32 = 0,
    tb_score: i32 = 0,
    pv: s.PV = .{},
    previous_pv: s.PV = .{},

    pub fn init(move: t.Move) RootMove {
        var result: RootMove = .{};
        result.pv.append(move);
        return result;
    }
    pub fn lessThan(_: void, a: RootMove, c: RootMove) bool {
        return if (a.score != c.score) a.score > c.score else a.previous_score > c.previous_score;
    }
    pub fn isExactLoss(self: *const RootMove) bool {
        return self.score != -t.value_infinite and self.score <= -s.tb_win_in_max_ply and !self.isInexact();
    }
    pub fn isInexact(self: *const RootMove) bool {
        return self.inexact_lower or self.inexact_upper;
    }
    pub fn unsetInexact(self: *RootMove) void {
        self.inexact_lower = false;
        self.inexact_upper = false;
    }
    // The reference mixes signed scores with unsigned weights, then narrows
    // the quotient. Preserve that conversion, including negative rounding.
    fn weighted(value: i64, previous: i64, weight: u64) i32 {
        const sum = @as(u64, @bitCast(value)) *% weight +% @as(u64, @bitCast(previous)) *% (32 - weight);
        return @bitCast(@as(u32, @truncate(sum / 32)));
    }
    pub fn record(self: *RootMove, value: i32, alpha: i32, beta: i32, move_count: i32, sel_depth: i32, nodes: u64, child: ?*const s.PV) void {
        const prior_effort = @max(1, self.effort);
        self.effort += nodes;
        const weight = std.math.clamp(64 * nodes / (2 * nodes + 3 * prior_effort), 12, 24);
        self.average_score = if (self.average_score == -t.value_infinite) value else weighted(value, self.average_score, weight);
        const squared = @as(i64, value) * @as(i64, @intCast(@abs(value)));
        self.mean_squared_score = if (self.mean_squared_score == -t.value_infinite * t.value_infinite) @intCast(squared) else weighted(squared, self.mean_squared_score, @min(weight, 16));
        if (move_count == 1 or value > alpha) {
            self.score = value;
            self.uci_score = value;
            self.sel_depth = sel_depth;
            self.unsetInexact();
            if (value >= beta) {
                self.inexact_lower = true;
                self.uci_score = beta;
            } else if (value <= alpha) {
                self.inexact_upper = true;
                self.uci_score = alpha;
            }
            std.debug.assert(child != null);
            self.pv.update(self.pv.moves[0], child);
        } else self.score = -t.value_infinite;
    }
};
