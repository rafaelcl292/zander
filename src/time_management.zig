// Derived from Stockfish timeman.cpp; GPL-3.0-or-later.
const std = @import("std");
pub const Limits = struct {
    time: [2]i64 = .{ 0, 0 },
    increment: [2]i64 = .{ 0, 0 },
    moves_to_go: i32 = 0,
    move_time: i64 = 0,
    nodes: u64 = 0,
    npmsec: i64 = 0,
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
        const scaled = @max(1, @divTrunc(limits.time[us], if (limits.npmsec != 0) limits.npmsec else 1));
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
        if (limits.npmsec == 0 and limits.moves_to_go != 1) {
            const advantage = @as(f64, @floatFromInt(limits.time[us] - limits.time[us ^ 1])) / @as(f64, @floatFromInt(1 + limits.time[us] + limits.time[us ^ 1]));
            opt_scale *= 1 + 0.9 * @min(advantage, 0);
        }
        var result: Budget = .{ .optimum = @intFromFloat(@max(1, opt_scale * left)) };
        result.maximum = @intFromFloat(@max(@as(f64, @floatFromInt(result.optimum)), @min(0.8097 * time - @as(f64, @floatFromInt(overhead)), max_scale * @as(f64, @floatFromInt(result.optimum)))));
        if (ponder_option) result.optimum += @divTrunc(result.optimum, 4);
        return result;
    }
};

/// Persistent nodes-as-time accounting from TimeManagement::init/advance_nodes_time.
pub const NodeTime = struct {
    available: i64 = -1,
    previous_moves_to_go: i32 = 0,
    cyclic_budget: i64 = 0,
    pub fn prepare(self: *NodeTime, original: Limits, us: usize, rate: i64, overhead: *i64) Limits {
        var limits = original;
        if (rate == 0) return limits;
        limits.move_time *= rate;
        if (limits.time[us] == 0) return limits;
        limits.npmsec = rate;
        if (self.available == -1) {
            self.available = rate * limits.time[us];
            self.cyclic_budget = rate * (limits.time[us] - limits.increment[us]);
        } else if (limits.moves_to_go > 0 and limits.moves_to_go > self.previous_moves_to_go and self.cyclic_budget > 0) self.available += self.cyclic_budget;
        self.previous_moves_to_go = limits.moves_to_go;
        limits.time[us] = self.available;
        limits.increment[us] *= rate;
        overhead.* *= rate;
        return limits;
    }
    pub fn advance(self: *NodeTime, nodes: i64, increment: i64) void {
        self.available = @max(0, self.available - (nodes - increment));
    }
};

test "node time retains game budget and replenishes cyclic controls" {
    var state: NodeTime = .{};
    var overhead: i64 = 10;
    const first = state.prepare(.{ .time = .{ 1000, 1000 }, .increment = .{ 20, 20 }, .moves_to_go = 2 }, 0, 10, &overhead);
    try std.testing.expectEqual(@as(i64, 10000), first.time[0]);
    try std.testing.expectEqual(@as(i64, 200), first.increment[0]);
    try std.testing.expectEqual(@as(i64, 100), overhead);
    state.advance(1000, first.increment[0]);
    overhead = 10;
    const second = state.prepare(.{ .time = .{ 900, 900 }, .moves_to_go = 1 }, 0, 10, &overhead);
    try std.testing.expectEqual(@as(i64, 9200), second.time[0]);
    overhead = 10;
    const next_cycle = state.prepare(.{ .time = .{ 1800, 1800 }, .moves_to_go = 2 }, 0, 10, &overhead);
    try std.testing.expectEqual(@as(i64, 19000), next_cycle.time[0]);
    state.advance(100000, 0);
    try std.testing.expectEqual(@as(i64, 0), state.available);
}

test "movetime node mode does not initialize a persistent game budget" {
    var state: NodeTime = .{};
    var overhead: i64 = 10;
    const limits = state.prepare(.{ .time = .{ 0, 1000 }, .move_time = 100 }, 0, 10, &overhead);
    try std.testing.expectEqual(@as(i64, 1000), limits.move_time);
    try std.testing.expectEqual(@as(i64, 0), limits.npmsec);
    try std.testing.expectEqual(@as(i64, -1), state.available);
    try std.testing.expectEqual(@as(i64, 10), overhead);
}
