const std = @import("std");
const z = @import("zander");
const usage =
    \\Zander — incremental Stockfish port in Zig 0.16.0
    \\Usage:
    \\  zander perft <depth: 0..8> [--chess960] ["FEN"]
    \\  zander eval <network.nnue> [--chess960] ["FEN"]
    \\  zander search <network.nnue> <depth: 1..245> [--multipv=N] [--chess960] ["FEN"]
    \\  zander help
    \\
    \\The default position is the standard initial position.
    \\Scores use internal units from the side-to-move perspective.
    \\Search uses one worker and a fixed depth. UCI is not implemented yet.
    \\
;
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("zander: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    if (args.len == 1 or (args.len == 2 and (std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")))) {
        try writer.writeAll(usage);
        try writer.flush();
        return;
    }
    if (args.len < 3) return error.ExpectedCommandAndArgument;
    const is_perft = std.mem.eql(u8, args[1], "perft");
    const is_eval = std.mem.eql(u8, args[1], "eval");
    const is_search = std.mem.eql(u8, args[1], "search");
    if (!is_perft and !is_eval and !is_search) return error.UnknownCommand;
    var depth: u8 = 0;
    if (is_perft) {
        depth = std.fmt.parseInt(u8, args[2], 10) catch return error.InvalidDepth;
        if (depth > 8) return error.DepthExceedsDiagnosticLimit;
    }
    if (is_search) {
        if (args.len < 4) return error.ExpectedSearchDepth;
        depth = std.fmt.parseInt(u8, args[3], 10) catch return error.InvalidDepth;
        if (depth == 0 or depth >= z.types.max_ply) return error.InvalidDepth;
    }
    var multi_pv: usize = 1;
    var multi_pv_set = false;
    var fen: ?[]const u8 = null;
    var chess960 = false;
    for (args[if (is_search) @as(usize, 4) else 3..]) |arg| {
        if (std.mem.eql(u8, arg, "--chess960") and !chess960) {
            chess960 = true;
        } else if (is_search and !multi_pv_set and std.mem.startsWith(u8, arg, "--multipv=")) {
            multi_pv = std.fmt.parseInt(usize, arg[10..], 10) catch return error.InvalidMultiPV;
            if (multi_pv == 0 or multi_pv > z.types.max_moves) return error.InvalidMultiPV;
            multi_pv_set = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidOption;
        } else if (fen == null) {
            fen = arg;
        } else return error.UnexpectedArgument;
    }
    const allocator = init.arena.allocator();
    const tables = try allocator.create(z.attacks.Tables);
    tables.init();
    const keys = try allocator.create(z.position_keys.PositionKeys);
    keys.init();
    var state: z.position.StateInfo = undefined;
    var pos: z.position.Position = undefined;
    try pos.set(fen orelse z.position.start_fen, chess960, &state, tables, keys);
    if (is_perft) {
        const nodes = z.perft.count(&pos, depth);
        try writer.print("depth {d}\nnodes {d}\n", .{ depth, nodes });
    } else {
        const network = try allocator.create(z.nnue_network.Network);
        {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], init.gpa, .limited(200 * 1024 * 1024));
            defer init.gpa.free(bytes);
            _ = try network.load(bytes);
        }
        const stack = try allocator.create(z.nnue_accumulator.Stack);
        const caches = try allocator.create(z.nnue_accumulator.Caches);
        stack.reset();
        caches.clear(&network.transformer);
        if (is_search) {
            try searchPosition(allocator, network, stack, caches, &pos, depth, multi_pv, writer);
            try writer.flush();
            return;
        }
        const score = network.evaluate(&pos, stack, caches);
        try writer.print("psqt {d}\npositional {d}\nraw {d}\n", .{ score.psqt, score.positional, score.psqt + score.positional });
        if (pos.st.checkers == 0) {
            try writer.print("adjusted {d}\n", .{network.evaluateAdjusted(&pos, stack, caches, 0)});
        } else try writer.writeAll("adjusted unavailable (in check)\n");
    }
    try writer.flush();
}

fn searchPosition(allocator: std.mem.Allocator, network: *const z.nnue_network.Network, stack: *z.nnue_accumulator.Stack, caches: *z.nnue_accumulator.Caches, pos: *z.position.Position, depth: i32, multi_pv: usize, writer: *std.Io.Writer) !void {
    const main_history = try allocator.create(z.history.ButterflyHistory);
    z.history.fill(main_history, -5);
    const low = try allocator.create(z.history.LowPlyHistory);
    z.history.fill(low, 102);
    const capture = try allocator.create(z.history.CapturePieceToHistory);
    z.history.fill(capture, -742);
    const correction = try allocator.alloc(z.history.CorrectionEntry, z.history.correction_history_base_size);
    const pawn = try allocator.alloc(z.history.PawnEntry, z.history.pawn_history_base_size);
    const continuation = try allocator.create(z.history.ContinuationHistoryBlock);
    const continuation_correction = try allocator.create(z.history.ContinuationCorrectionHistory);
    z.history.fill(continuation_correction, 5);
    var shared = try z.history.SharedHistories.init(1, correction, continuation, pawn);
    shared.clearRange(0, 1);
    const clusters = try allocator.alignedAlloc(z.tt.Cluster, .@"64", 32768);
    var table = z.tt.Table.init(clusters);
    const base = try allocator.create(z.quiescence.Worker);
    base.* = .{ .network = network, .accumulators = stack, .caches = caches, .table = &table, .main_history = main_history, .low_ply_history = low, .capture_history = capture, .shared = &shared, .continuation_correction = continuation_correction };
    var worker = z.search.Worker.init(base);
    const roots = try allocator.alloc(z.search.RootMove, z.types.max_moves);
    const result = try worker.iterativeDeepening(pos, roots, .{ .depth = depth, .multi_pv = multi_pv });
    try writer.print("depth {d}\nnodes {d}\n", .{ result.depth, result.nodes });
    for (worker.root_moves[0..@min(multi_pv, worker.root_moves.len)], 1..) |*rm, index| {
        try writer.print("multipv {d} score {d} seldepth {d} pv", .{ index, rm.score, rm.sel_depth });
        for (rm.pv.slice()) |move| {
            try writer.writeByte(' ');
            try writeMove(writer, move, pos.chess960);
        }
        try writer.writeByte('\n');
    }
    if (worker.root_moves.len == 0) try writer.print("score {d}\n", .{result.score});
    try writer.writeAll("bestmove ");
    try writeMove(writer, result.best_move, pos.chess960);
    try writer.writeByte('\n');
}

fn writeMove(writer: *std.Io.Writer, move: z.types.Move, chess960: bool) !void {
    if (move.data == 0) return writer.writeAll("(none)");
    if (move.data == z.types.Move.null_move.data) return writer.writeAll("0000");
    const from = move.from();
    var to = move.to();
    if (move.kind() == .castling and !chess960) to = @enumFromInt(@as(u8, from.rank()) * 8 + @as(u8, if (@intFromEnum(to) > @intFromEnum(from)) 6 else 2));
    const squares = [4]u8{ 'a' + @as(u8, from.file()), '1' + @as(u8, from.rank()), 'a' + @as(u8, to.file()), '1' + @as(u8, to.rank()) };
    try writer.writeAll(&squares);
    if (move.kind() == .promotion) try writer.writeByte(" pnbrqk"[@intFromEnum(move.promotionType())]);
}
