const std = @import("std");
const z = @import("zander");
const usage =
    \\Zander — incremental Stockfish port in Zig 0.16.0
    \\Usage:
    \\  zander perft <depth: 0..8> [--chess960] ["FEN"]
    \\  zander eval <network.nnue> [--chess960] ["FEN"]
    \\  zander help
    \\
    \\The default position is the standard initial position.
    \\Evaluation uses internal units from the side-to-move perspective.
    \\Main search and UCI are not implemented yet.
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
    if (!is_perft and !is_eval) return error.UnknownCommand;
    var depth: u8 = 0;
    if (is_perft) {
        depth = std.fmt.parseInt(u8, args[2], 10) catch return error.InvalidDepth;
        if (depth > 8) return error.DepthExceedsDiagnosticLimit;
    }
    var fen: ?[]const u8 = null;
    var chess960 = false;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--chess960") and !chess960) {
            chess960 = true;
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
        const score = network.evaluate(&pos, stack, caches);
        try writer.print("psqt {d}\npositional {d}\nraw {d}\n", .{ score.psqt, score.positional, score.psqt + score.positional });
        if (pos.st.checkers == 0) {
            try writer.print("adjusted {d}\n", .{network.evaluateAdjusted(&pos, stack, caches, 0)});
        } else try writer.writeAll("adjusted unavailable (in check)\n");
    }
    try writer.flush();
}
