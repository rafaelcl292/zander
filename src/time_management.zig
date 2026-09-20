// Derived from Stockfish timeman.cpp, wall-clock mode; GPL-3.0-or-later.
const std = @import("std");
pub const Limits = struct {
    time: [2]i64 = .{ 0, 0 },
    increment: [2]i64 = .{ 0, 0 },
    moves_to_go: i32 = 0,
    move_time: i64 = 0,
    nodes: u64 = 0,
    mate: i32 = 0,
    infinite: bool = false,
    ponder: bool = false,
    pub fn managed(self: Limits) bool {
        return self.time[0] != 0 or self.time[1] != 0;
    }
};
pub const Budget = struct {
    optimum: i64 = std.math.maxInt(i64) / 2,
    maximum: i64 = std.math.maxInt(i64) / 2,
    pub fn init(limits: Limits, us: usize, ply: i32, overhead: i64, ponder_option: bool, original_adjust: *f64) Budget {
        if (limits.time[us] == 0) return .{};
        const scaled = @max(1, limits.time[us]);
        var mtg: i64 = if (limits.moves_to_go != 0) @min(limits.moves_to_go, 50) else 50;
        if (scaled < 1000 and limits.moves_to_go == 0) mtg = @intFromFloat(@as(f64, @floatFromInt(scaled)) * 0.05);
        const left = @as(f64, @floatFromInt(@max(1, limits.time[us] + limits.increment[us] * (mtg - 1) - overhead * (2 + mtg))));
        const time: f64 = @floatFromInt(limits.time[us]);
        const game_ply: f64 = @floatFromInt(ply);
        var opt_scale: f64 = undefined;
        var max_scale: f64 = undefined;
        if (limits.moves_to_go == 0) {
            if (original_adjust.* < 0) original_adjust.* = 0.3272 * @log10(left) - 0.4141;
            const log_time = @log10(@as(f64, @floatFromInt(scaled)) / 1000.0);
            const opt_constant = @min(0.0029869 + 0.00033554 * log_time, 0.004905);
            const max_constant = @max(3.3744 + 3.0608 * log_time, 3.1441);
            opt_scale = @min(0.012112 + std.math.pow(f64, game_ply + 3.22713, 0.46866) * opt_constant, 0.19404 * time / left) * original_adjust.*;
            max_scale = @min(6.873, max_constant + game_ply / 12.352);
        } else {
            opt_scale = @min((0.88 + game_ply / 116.4) / @as(f64, @floatFromInt(mtg)), 0.88 * time / left);
            max_scale = 1.3 + 0.11 * @as(f64, @floatFromInt(mtg));
        }
        if (limits.moves_to_go != 1) {
            const advantage = @as(f64, @floatFromInt(limits.time[us] - limits.time[us ^ 1])) / @as(f64, @floatFromInt(1 + limits.time[us] + limits.time[us ^ 1]));
            opt_scale *= 1 + 0.9 * @min(advantage, 0);
        }
        var result: Budget = .{ .optimum = @intFromFloat(@max(1, opt_scale * left)) };
        result.maximum = @intFromFloat(@max(@as(f64, @floatFromInt(result.optimum)), @min(0.8097 * time - @as(f64, @floatFromInt(overhead)), max_scale * @as(f64, @floatFromInt(result.optimum)))));
        if (ponder_option) result.optimum += @divTrunc(result.optimum, 4);
        return result;
    }
};
