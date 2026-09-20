// Derived from Stockfish Tablebases root probing; GPL-3.0-or-later.
const std = @import("std");
const Database = @import("database.zig").Database;
const p = @import("../position.zig");
const t = @import("../types.zig");
const RootMove = @import("../root_move.zig").RootMove;
const mg = @import("../movegen.zig");
pub const Abort = struct {
    context: ?*anyopaque = null,
    check: ?*const fn (?*anyopaque) bool = null,
    pub fn expired(self: Abort) bool {
        return if (self.check) |check| check(self.context) else false;
    }
    pub fn fromControl(control: ?*@import("../search_control.zig").Control) Abort {
        return if (control) |c| .{ .context = c, .check = stopped } else .{};
    }
    fn stopped(context: ?*anyopaque) bool {
        return @as(*@import("../search_control.zig").Control, @ptrCast(@alignCast(context.?))).stopped();
    }
};
pub const max_dtz = 1 << 18;
pub const Options = struct { limit: usize = 7, depth: i32 = 1, rule50: bool = true };
pub const Config = struct { cardinality: usize = 0, depth: i32 = 0, rule50: bool = true, root_in_tb: bool = false };
fn dtzIsDtm(pos: *const p.Position) bool {
    const count = @popCount(pos.pieces());
    return pos.by_type[1] == 0 and (count == 3 or (count == 4 and (pos.by_type[4] | pos.by_type[5]) == 0));
}
fn rankLess(_: void, a: RootMove, b: RootMove) bool {
    return a.tb_rank > b.tb_rank;
}
pub fn rank(db: *const Database, pos: *p.Position, roots: []RootMove, options: Options, abort: Abort, force_distance: bool) Config {
    var config: Config = .{ .cardinality = @min(options.limit, db.cardinality), .depth = if (options.limit > db.cardinality) 0 else options.depth, .rule50 = options.rule50 };
    if (roots.len == 0) return .{};
    var distance_available = true;
    if (config.cardinality >= @popCount(pos.pieces()) and pos.st.castling_rights == 0) {
        config.root_in_tb = rankDtz(db, pos, roots, options.rule50, force_distance or dtzIsDtm(pos), abort) catch false;
        if (!config.root_in_tb and !abort.expired()) {
            distance_available = false;
            config.root_in_tb = rankWdl(db, pos, roots, options.rule50) catch false;
        }
    }
    if (config.root_in_tb) {
        std.mem.sort(RootMove, roots, {}, rankLess);
        if (distance_available or roots[0].tb_score <= 0) config.cardinality = 0;
    } else {
        for (roots) |*root| root.tb_rank = 0;
    }
    return config;
}
pub fn rankWdl(db: *const Database, pos: *p.Position, roots: []RootMove, rule50: bool) !bool {
    const ranks = [_]i32{ -max_dtz, -max_dtz + 101, 0, max_dtz - 101, max_dtz };
    const values = [_]i32{ -t.value_mate + t.max_ply + 1, -2, 0, 2, t.value_mate - t.max_ply - 1 };
    for (roots) |*root| {
        var state: p.StateInfo = undefined;
        const move = root.pv.moves[0];
        pos.doMove(move, &state);
        var outcome: i32 = 0;
        if (!pos.isDraw(1)) {
            const probe = db.wdl(pos) catch |err| {
                pos.undoMove(move);
                return err;
            };
            outcome = -probe.value;
        }
        pos.undoMove(move);
        root.tb_rank = ranks[@intCast(outcome + 2)];
        if (!rule50) outcome = 2 * @as(i32, std.math.sign(outcome));
        root.tb_score = values[@intCast(outcome + 2)];
    }
    return true;
}
pub fn rankDtz(db: *const Database, pos: *p.Position, roots: []RootMove, rule50: bool, rank_distance: bool, abort: Abort) !bool {
    const count50 = pos.st.rule50;
    const repeated = pos.hasRepeated();
    const bound: i32 = if (rule50) max_dtz / 2 - 100 else 1;
    for (roots) |*root| {
        var state: p.StateInfo = undefined;
        const move = root.pv.moves[0];
        pos.doMove(move, &state);
        var distance: i32 = 0;
        if (pos.st.rule50 == 0) {
            const probe = db.wdl(pos) catch |err| {
                pos.undoMove(move);
                return err;
            };
            distance = Database.beforeZeroing(-probe.value);
        } else if (!((rule50 and pos.isDraw(1)) or pos.isRepetition(1))) {
            const probe = db.dtz(pos) catch |err| {
                pos.undoMove(move);
                return err;
            };
            distance = -probe + std.math.sign(-probe);
        }
        if (pos.st.checkers != 0 and distance == 2) {
            var replies: mg.MoveList = .{};
            mg.generate(.legal, pos, &replies);
            if (replies.len == 0) distance = 1;
        }
        pos.undoMove(move);
        if (abort.expired()) return false;
        const r = if (distance > 0)
            (if (distance + count50 <= 99 and !repeated) max_dtz - (if (rank_distance) distance else 0) else max_dtz / 2 - (distance + count50))
        else if (distance < 0)
            (if (-distance * 2 + count50 < 100) -max_dtz - (if (rank_distance) distance else 0) else -max_dtz / 2 + (-distance + count50))
        else
            @as(i32, 0);
        root.tb_rank = r;
        root.tb_score = if (r >= bound) t.value_mate - t.max_ply - 1 else if (r > 0)
            @divTrunc(@max(3, r - (max_dtz / 2 - 200)) * p.piece_value[1], 200)
        else if (r == 0) 0 else if (r > -bound)
            @divTrunc(@min(-3, r + (max_dtz / 2 - 200)) * p.piece_value[1], 200)
        else
            -t.value_mate + t.max_ply + 1;
    }
    return true;
}
