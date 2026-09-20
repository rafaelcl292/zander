// Derived from Stockfish syzygy_extend_pv; GPL-3.0-or-later.
const std = @import("std");
const t = @import("../types.zig");
const p = @import("../position.zig");
const mg = @import("../movegen.zig");
const RootMove = @import("../root_move.zig").RootMove;
const root = @import("root.zig");
const Database = @import("database.zig").Database;
const Control = @import("../search_control.zig").Control;
const Deadline = struct {
    control: *const Control,
    start: i64,
    overhead: i64,
    multi_pv: usize,
    fn expired(context: ?*anyopaque) bool {
        const self: *const Deadline = @ptrCast(@alignCast(context.?));
        return self.control.limits.npmsec == 0 and self.control.limits.managed() and
            2 * @as(i64, @intCast(self.multi_pv)) * (self.control.elapsed() - self.start) >= self.overhead;
    }
};
fn records(pos: *p.Position, storage: *[t.max_moves]RootMove) []RootMove {
    var moves: mg.MoveList = .{};
    mg.generate(.legal, pos, &moves);
    for (moves.slice(), storage[0..moves.len]) |move, *record| record.* = RootMove.init(move);
    return storage[0..moves.len];
}
fn less(_: void, a: RootMove, b: RootMove) bool {
    return a.tb_rank > b.tb_rank;
}
/// Validates and extends within fixed PV capacity. Return true when a deadline
/// or the capacity bound prevented completing the extension.
pub fn extend(db: *const Database, options: root.Options, control: *const Control, pos: *p.Position, root_move: *RootMove, value: *i32, multi_pv: usize, overhead: i64) bool {
    var deadline: Deadline = .{ .control = control, .start = control.elapsed(), .overhead = overhead, .multi_pv = multi_pv };
    const abort: root.Abort = .{ .context = &deadline, .check = Deadline.expired };
    if (abort.expired() or root_move.pv.len == 0) return abort.expired();
    var states: [t.max_ply + 1]p.StateInfo = undefined;
    var storage: [t.max_moves]RootMove = undefined;
    pos.doMove(root_move.pv.moves[0], &states[0]);
    var ply: usize = 1;
    while (ply < root_move.pv.len) {
        const move = root_move.pv.moves[ply];
        const legal = records(pos, &storage);
        if (legal.len == 0) break;
        const config = root.rank(db, pos, legal, options, abort, false);
        var matching: ?*RootMove = null;
        for (legal) |*record| if (record.pv.moves[0].data == move.data) {
            matching = record;
            break;
        };
        if (matching == null or matching.?.tb_rank != legal[0].tb_rank) break;
        pos.doMove(move, &states[ply]);
        ply += 1;
        if (config.root_in_tb and ((options.rule50 and pos.isDraw(@intCast(ply))) or pos.isRepetition(@intCast(ply)))) {
            pos.undoMove(move);
            ply -= 1;
            break;
        }
        if (config.root_in_tb and abort.expired()) break;
    }
    root_move.pv.resize(ply);
    var capped = false;
    while (!(options.rule50 and pos.isDraw(0))) {
        if (abort.expired()) break;
        if (ply == states.len) {
            capped = true;
            break;
        }
        const legal = records(pos, &storage);
        if (legal.len == 0) break;
        for (legal) |*record| {
            const move = record.pv.moves[0];
            var temporary: p.StateInfo = undefined;
            pos.doMove(move, &temporary);
            var replies: mg.MoveList = .{};
            mg.generate(.legal, pos, &replies);
            for (replies.slice()) |reply| record.tb_rank -= @as(i32, if (pos.capture(reply)) 100 else 1);
            pos.undoMove(move);
        }
        std.mem.sort(RootMove, legal, {}, less);
        const config = root.rank(db, pos, legal, options, abort, true);
        if (!config.root_in_tb or config.cardinality > 0) break;
        const move = legal[0].pv.moves[0];
        root_move.pv.append(move);
        pos.doMove(move, &states[ply]);
        ply += 1;
    }
    if (pos.isDraw(0)) value.* = 0;
    while (ply > 0) {
        ply -= 1;
        pos.undoMove(root_move.pv.moves[ply]);
    }
    return capped or abort.expired();
}
