//! Diagnostic trace replay, not a whole-engine speed or strength benchmark.
const std = @import("std");
const z = @import("zander");
const Mode = enum { nnue, movegen, move_ordering, tt };

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("microbench: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // network, mode, iterations, chess960, FEN, then zero or more legal UCI moves.
    if (args.len < 6) return error.ExpectedNetworkModeIterationsChess960Fen;
    const mode = std.meta.stringToEnum(Mode, args[2]) orelse return error.UnknownMode;
    const iterations = try std.fmt.parseInt(usize, args[3], 10);
    if (iterations == 0 or iterations > 100_000_000) return error.InvalidIterations;
    if (!std.mem.eql(u8, args[4], "0") and !std.mem.eql(u8, args[4], "1")) return error.InvalidChess960;
    if (args.len - 6 >= z.types.max_ply) return error.TraceTooLong;
    const engine = try z.engine.Engine.create(init.gpa, init.io, 16);
    defer engine.destroy();
    if (mode == .nnue) try engine.loadNetwork(args[1]);
    try engine.setPosition(args[5], std.mem.eql(u8, args[4], "1"), &.{});
    var moves: [z.types.max_ply]z.types.Move = undefined;
    var states: [z.types.max_ply]z.position.StateInfo = undefined;
    const count = args.len - 6;
    for (args[6..], 0..) |text, index| {
        moves[index] = z.notation.parseMove(&engine.position, text) orelse return error.IllegalTraceMove;
        engine.position.doMove(moves[index], &states[index]);
    }
    var remaining = count;
    while (remaining > 0) {
        remaining -= 1;
        engine.position.undoMove(moves[remaining]);
    }
    const trace = moves[0..count];
    // Warm caches and code before starting the clock. Allocation and parsing are excluded.
    _ = replay(engine, mode, trace, &states, 10);
    const begin = std.Io.Clock.awake.now(init.io).toNanoseconds();
    const checksum = replay(engine, mode, trace, &states, iterations);
    const elapsed = std.Io.Clock.awake.now(init.io).toNanoseconds() - begin;
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    try output.interface.print("{{\"mode\":\"{s}\",\"iterations\":{d},\"positions_per_iteration\":{d},\"elapsed_ns\":{d},\"checksum\":{d}}}\n", .{ @tagName(mode), iterations, count + 1, elapsed, checksum });
    try output.interface.flush();
}

noinline fn replay(engine: *z.engine.Engine, mode: Mode, moves: []const z.types.Move, states: []z.position.StateInfo, iterations: usize) u64 {
    var checksum: u64 = 0;
    const pos = &engine.position;
    for (0..iterations) |_| {
        engine.accumulators.reset();
        for (0..moves.len + 1) |ply| {
            std.mem.doNotOptimizeAway(pos);
            switch (mode) {
                .nnue => {
                    const value = engine.network.?.evaluate(pos, engine.accumulators, engine.caches);
                    checksum +%= @as(u32, @bitCast(value));
                },
                .movegen => {
                    var list: z.movegen.MoveList = undefined;
                    z.movegen.generate(.legal, pos, &list);
                    for (list.slice()) |move| checksum +%= move.data;
                },
                .move_ordering => {
                    const continuation: [6]*const z.history.PieceToHistory = @splat(&engine.shared.continuation[0][0][0][0]);
                    var picker = z.movepick.MovePicker.init(pos, z.types.Move.none, 8, .{ .main = engine.base.main_history, .low_ply = engine.base.low_ply_history, .capture = engine.base.capture_history, .continuation = &continuation, .shared = &engine.shared }, 0);
                    while (true) {
                        const move = picker.next();
                        if (move.data == 0) break;
                        checksum +%= move.data;
                    }
                },
                .tt => {
                    const key = pos.key();
                    const probe = engine.table.probe(key);
                    checksum +%= @intFromBool(probe.found);
                    probe.writer.save(key, .{ .move = if (ply < moves.len) moves[ply] else z.types.Move.none, .value = 12, .eval = 10, .depth = 4, .bound = .exact, .is_pv = false }, engine.table.generation);
                    checksum +%= engine.table.probe(key).data.move.data;
                },
            }
            if (ply < moves.len) {
                if (mode == .nnue) pos.doMoveWithDirties(moves[ply], &states[ply], engine.accumulators.push()) else pos.doMove(moves[ply], &states[ply]);
            }
        }
        var ply = moves.len;
        while (ply > 0) {
            ply -= 1;
            pos.undoMove(moves[ply]);
            if (mode == .nnue) engine.accumulators.pop();
        }
    }
    return checksum;
}
