const std = @import("std");
const z = @import("zander");
const reference = @import("reference");
test "real NNUE loading and incremental evaluation match pinned Stockfish" {
    const allocator = std.testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, @import("options").network_path, allocator, .limited(200 * 1024 * 1024));
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqualStrings(z.nnue_network.default_sha256, &std.fmt.bytesToHex(digest, .lower));
    const network = try allocator.create(z.nnue_network.Network);
    defer allocator.destroy(network);
    _ = try network.load(bytes);
    const stack = try allocator.create(z.nnue_accumulator.Stack);
    defer allocator.destroy(stack);
    const cache = try allocator.create(z.nnue_accumulator.Caches);
    defer allocator.destroy(cache);
    cache.clear(&network.transformer);
    const tables = try allocator.create(z.attacks.Tables);
    defer allocator.destroy(tables);
    tables.init();
    const keys = try allocator.create(z.position_keys.PositionKeys);
    defer allocator.destroy(keys);
    keys.init();
    var lines: [100][]const u8 = undefined;
    var iter = std.mem.tokenizeScalar(u8, @embedFile("positions.txt"), '\n');
    var count: usize = 0;
    while (iter.next()) |line| : (count += 1) lines[count] = line;
    var root: usize = std.math.maxInt(usize);
    var pos: z.position.Position = undefined;
    var states: [50]z.position.StateInfo = undefined;
    var ply: usize = 0;
    for (reference.events, 0..) |event, event_index| {
        if (event.root != root) {
            root = event.root;
            ply = 0;
            try pos.set(lines[root][2..], lines[root][0] == '1', &states[0], tables, keys);
            stack.reset();
        } else if (event.move == z.types.Move.null_move.data) {
            if (event.pop) pos.undoNullMove() else pos.doNullMove(&states[1]);
        } else if (event.pop) {
            pos.undoMove(.{ .data = event.move });
            stack.pop();
            ply -= 1;
        } else {
            ply += 1;
            pos.doMoveWithDirties(.{ .data = event.move }, &states[ply], stack.push());
        }
        if (!event.evaluate) continue;
        errdefer std.debug.print("NNUE event {d}, root {d}, ply {d}\n", .{ event_index, root, ply });
        const output = network.evaluate(&pos, stack, cache);
        var checksum: u64 = 14695981039346656037;
        for (stack.latest().accumulation) |perspective| for (perspective) |v| {
            checksum = (checksum ^ @as(u16, @bitCast(v))) *% 1099511628211;
        };
        for (stack.latest().psqt) |perspective| for (perspective) |v| {
            checksum = (checksum ^ @as(u32, @bitCast(v))) *% 1099511628211;
        };
        try std.testing.expectEqual(event.checksum, checksum);
        try std.testing.expectEqual(event.psqt, output.psqt);
        try std.testing.expectEqual(event.positional, output.positional);
        if (pos.st.checkers == 0) for ([_]i32{ 0, 17, -13 }, event.adjusted) |optimism, expected| {
            try std.testing.expectEqual(expected, network.evaluateAdjusted(&pos, stack, cache, optimism));
        };
    }
    try std.testing.expectError(error.UnsupportedVersion, network.load(&.{ 0, 0, 0, 0 }));
    try std.testing.expect(!network.initialized);
}
