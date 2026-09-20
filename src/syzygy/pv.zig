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
/// Output-only extension may allocate; the recursive search keeps fixed storage.
/// Return true when the time budget prevented completing the extension.
pub fn extend(allocator: std.mem.Allocator, pv: *std.ArrayList(t.Move), db: *const Database, options: root.Options, control: *const Control, pos: *p.Position, value: *i32, multi_pv: usize, overhead: i64) !bool {
    var deadline: Deadline = .{ .control = control, .start = control.elapsed(), .overhead = overhead, .multi_pv = multi_pv };
    const abort: root.Abort = .{ .context = &deadline, .check = Deadline.expired };
    if (abort.expired() or pv.items.len == 0) return abort.expired();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const states = arena.allocator();
    var storage: [t.max_moves]RootMove = undefined;
    pos.doMove(pv.items[0], try states.create(p.StateInfo));
    var ply: usize = 1;
    defer while (ply > 0) {
        ply -= 1;
        pos.undoMove(pv.items[ply]);
    };
    while (ply < pv.items.len) {
        const move = pv.items[ply];
        const legal = records(pos, &storage);
        if (legal.len == 0) break;
        const config = root.rank(db, pos, legal, options, abort, false);
        var matching: ?*RootMove = null;
        for (legal) |*record| if (record.pv.moves[0].data == move.data) {
            matching = record;
            break;
        };
        if (matching == null or matching.?.tb_rank != legal[0].tb_rank) break;
        pos.doMove(move, try states.create(p.StateInfo));
        ply += 1;
        if (config.root_in_tb and ((options.rule50 and pos.isDraw(@intCast(ply))) or pos.isRepetition(@intCast(ply)))) {
            pos.undoMove(move);
            ply -= 1;
            break;
        }
        if (config.root_in_tb and abort.expired()) break;
    }
    pv.shrinkRetainingCapacity(ply);
    while (!(options.rule50 and pos.isDraw(0))) {
        if (abort.expired()) break;
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
        const state = try states.create(p.StateInfo);
        try pv.append(allocator, move);
        pos.doMove(move, state);
        ply += 1;
    }
    if (pos.isDraw(0)) value.* = 0;
    return abort.expired();
}

fn exerciseLongLine(allocator: std.mem.Allocator, pos: *p.Position, db: *const Database) !void {
    var line: std.ArrayList(t.Move) = .empty;
    defer line.deinit(allocator);
    const cycle = [_]t.Move{
        t.Move.make(.normal, t.Square.make(6, 0), t.Square.make(5, 2), .knight),
        t.Move.make(.normal, t.Square.make(6, 7), t.Square.make(5, 5), .knight),
        t.Move.make(.normal, t.Square.make(5, 2), t.Square.make(6, 0), .knight),
        t.Move.make(.normal, t.Square.make(5, 5), t.Square.make(6, 7), .knight),
    };
    for (0..80) |_| try line.appendSlice(allocator, &cycle);
    const initial_state = pos.st;
    const initial_key = pos.key();
    defer {
        std.testing.expectEqual(initial_state, pos.st) catch @panic("PV failure leaked position state");
        std.testing.expectEqual(initial_key, pos.key()) catch @panic("PV failure changed position key");
    }
    const Clock = struct {
        fn now(_: ?*anyopaque) i64 {
            return 0;
        }
    };
    const control: Control = .{ .clock = Clock.now };
    var value: i32 = 1;
    try std.testing.expect(!try extend(allocator, &line, db, .{ .limit = 0 }, &control, pos, &value, 1, 10));
    try std.testing.expectEqual(@as(usize, 320), line.items.len);
    try std.testing.expectEqual(@as(i32, 0), value);
}

test "output PV exceeds search capacity and restores position on allocation failures" {
    const tables = try std.testing.allocator.create(@import("../attacks.zig").Tables);
    defer std.testing.allocator.destroy(tables);
    tables.init();
    var keys: @import("../position_keys.zig").PositionKeys = undefined;
    keys.init();
    const db = try Database.create(std.testing.allocator, std.testing.io, "", &keys);
    defer db.destroy();
    var pos: p.Position = undefined;
    var state: p.StateInfo = undefined;
    try pos.set(p.start_fen, false, &state, tables, &keys);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseLongLine, .{ &pos, db });
}
