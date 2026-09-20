// Derived from Stockfish search.h/search.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const h = @import("history.zig");
pub const mate_in_max_ply = t.value_mate - t.max_ply;
pub const value_tb = mate_in_max_ply - 1;
pub const tb_win_in_max_ply = value_tb - t.max_ply;

pub const PV = struct {
    moves: [t.max_ply + 1]t.Move = undefined,
    len: usize = 0,
    pub fn slice(self: *const PV) []const t.Move {
        return self.moves[0..self.len];
    }
    pub fn clear(self: *PV) void {
        self.len = 0;
    }
    pub fn append(self: *PV, move: t.Move) void {
        std.debug.assert(self.len < self.moves.len);
        self.moves[self.len] = move;
        self.len += 1;
    }
    pub fn resize(self: *PV, length: usize) void {
        std.debug.assert(length <= self.len);
        self.len = length;
    }
    pub fn update(self: *PV, move: t.Move, child: ?*const PV) void {
        self.len = if (child) |pv| pv.len else 0;
        std.debug.assert(self.len <= t.max_ply);
        if (child) |pv| {
            std.debug.assert(pv != self);
            @memcpy(self.moves[1 .. self.len + 1], pv.slice());
        }
        self.moves[0] = move;
        self.len += 1;
    }
    pub fn assignRoot(self: *PV, root: []const t.Move) void {
        self.len = @min(root.len, t.max_ply);
        @memcpy(self.moves[0..self.len], root[0..self.len]);
    }
};

/// Search frames retain the upstream fields. Sentinels and history pointers
/// must be initialized by the worker before search begins.
pub const Stack = struct {
    pv: ?*PV = null,
    continuation_history: ?*h.PieceToHistory = null,
    continuation_correction_history: ?*h.PieceToCorrectionHistory = null,
    ply: i32 = 0,
    current_move: t.Move = .none,
    excluded_move: t.Move = .none,
    static_eval: i32 = 0,
    stat_score: i32 = 0,
    move_count: i32 = 0,
    in_check: bool = false,
    tt_pv: bool = false,
    tt_hit: bool = false,
    follow_pv: bool = false,
    cutoff_count: i32 = 0,
    reduction: i32 = 0,
    prior_nmp_fail_high: i32 = 0,
};

pub fn valueToTT(value: i32, ply: i32) i32 {
    std.debug.assert(value != t.value_none);
    return if (value >= tb_win_in_max_ply) value + ply else if (value <= -tb_win_in_max_ply) value - ply else value;
}
pub fn valueFromTT(value: i32, ply: i32, rule50: i32) i32 {
    if (value == t.value_none) return t.value_none;
    if (value >= tb_win_in_max_ply) {
        if (value >= mate_in_max_ply and t.value_mate - value > 100 - rule50) return tb_win_in_max_ply - 1;
        if (value_tb - value > 100 - rule50) return tb_win_in_max_ply - 1;
        return value - ply;
    }
    if (value <= -tb_win_in_max_ply) {
        if (value <= -mate_in_max_ply and t.value_mate + value > 100 - rule50) return -tb_win_in_max_ply + 1;
        if (value_tb + value > 100 - rule50) return -tb_win_in_max_ply + 1;
        return value + ply;
    }
    return value;
}
pub fn correctedStaticEval(value: i32, correction: i32) i32 {
    return std.math.clamp(value + @divTrunc(correction, 131072), -tb_win_in_max_ply + 1, tb_win_in_max_ply - 1);
}
pub fn drawValue(nodes: usize) i32 {
    return -1 + @as(i32, @intCast(nodes & 2));
}
pub fn lmrDivisor(depth: i32) i32 {
    const d = @min(depth, 16);
    return 3000 + 7 * (d - 8) * (d - 8);
}
pub fn updateContinuationHistories(frames: []Stack, current: usize, pc: t.Piece, to: t.Square, bonus: i32) void {
    std.debug.assert(current >= 6 and current < frames.len);
    const weights = [_]i32{ 520, 390, 145, 251, 66, 209 };
    const multipliers = [_]i32{ 94, 103, 110, 106, 119, 126, 121 };
    var positive_count: usize = 0;
    for (weights, 1..) |weight, i| {
        if (frames[current].in_check and i > 2) break;
        const prior = &frames[current - i];
        if (prior.current_move.valid()) {
            const entry = &prior.continuation_history.?[@intFromEnum(pc)][@intFromEnum(to)];
            if (entry.get() > 0) positive_count += 1;
            entry.update(@divTrunc(bonus * weight * multipliers[positive_count], 65536) + @as(i32, if (i < 2) 73 else 0));
        }
    }
}

pub const Reductions = struct {
    values: [t.max_moves]i32 = @splat(0),
    pub fn init(self: *Reductions) void {
        for (self.values[1..], 1..) |*value, i| value.* = @intFromFloat((2872.0 / 128.0) * @log(@as(f64, @floatFromInt(i))));
    }
    pub fn reduction(self: *const Reductions, improving: bool, depth: usize, move_number: usize, delta: i32, root_delta: i32) i32 {
        std.debug.assert(depth > 0 and depth < self.values.len and move_number > 0 and move_number < self.values.len and root_delta > 0);
        const scale = self.values[depth] * self.values[move_number];
        return scale - @divTrunc(delta * 577, root_delta) + @divTrunc(@as(i32, if (improving) 0 else 1) * scale * 197, 512) + 982;
    }
};
