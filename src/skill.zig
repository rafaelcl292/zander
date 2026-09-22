// Derived from Stockfish Search::Skill; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const RootMove = @import("root_move.zig").RootMove;
const Prng = @import("prng.zig").Prng;
pub const Skill = struct {
    level: f64,
    best: t.Move = .none,
    pub fn init(level: i32, elo: i32) Skill {
        if (elo == 0) return .{ .level = @floatFromInt(level) };
        const e = @as(f64, @floatFromInt(elo - 1320)) / (3190 - 1320);
        return .{ .level = std.math.clamp(((37.2473 * e - 40.8525) * e + 22.2943) * e - 0.311438, 0, 19) };
    }
    pub fn enabled(self: Skill) bool {
        return self.level < 20;
    }
    pub fn timeToPick(self: Skill, depth: i32) bool {
        return depth == 1 + @as(i32, @trunc(self.level));
    }
    pub fn pick(self: *Skill, roots: []const RootMove, rng: *Prng) t.Move {
        std.debug.assert(roots.len != 0);
        var top = roots[0].score;
        var minimum = top;
        for (roots[1..]) |root| {
            top = @max(top, root.score);
            minimum = @min(minimum, root.score);
        }
        const delta = @min(top - minimum, @import("position.zig").piece_value[1]);
        var maximum: i32 = -t.value_infinite;
        const weakness = 120 - 2 * self.level;
        for (roots) |root| {
            const random: u32 = @truncate(rng.next());
            const noise: i32 = @intCast(random % @as(u32, @trunc(weakness)));
            const push = @divTrunc(@as(i32, @trunc(weakness * @as(f64, @floatFromInt(top - root.score)) + @as(f64, @floatFromInt(delta * noise)))), 128);
            if (root.score + push >= maximum) {
                maximum = root.score + push;
                self.best = root.pv.moves[0];
            }
        }
        return self.best;
    }
};

test "strength mapping and selection preserve legal candidates" {
    try std.testing.expect(!Skill.init(20, 0).enabled());
    try std.testing.expectEqual(@as(f64, 0), Skill.init(20, 1320).level);
    try std.testing.expectApproxEqAbs(@as(f64, 18.377662), Skill.init(20, 3190).level, 0.00000001);
    try std.testing.expect(Skill.init(7, 0).timeToPick(8));
    var roots: [4]RootMove = undefined;
    for (&roots, 0..) |*root, i| {
        root.* = RootMove.init(.{ .data = @intCast(i + 100) });
        root.score = @as(i32, @intCast(i)) * 80 - 120;
    }
    var a: Prng = .init(42);
    var b: Prng = .init(42);
    var weak = Skill.init(0, 0);
    var repeat = Skill.init(0, 0);
    for (0..100) |_| {
        const choice = weak.pick(&roots, &a);
        try std.testing.expectEqual(choice.data, repeat.pick(&roots, &b).data);
        try std.testing.expect(choice.data >= 100 and choice.data <= 103);
    }
}
