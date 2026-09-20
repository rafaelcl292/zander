const std = @import("std");
const z = @import("zander");
test "persistent engine retains state and replaces resources transactionally" {
    const engine = try z.engine.Engine.create(std.testing.allocator, std.testing.io, 1);
    defer engine.destroy();
    try engine.loadNetwork(@import("options").network_path);
    const network = engine.network.?;
    const original_clusters = engine.clusters.ptr;
    try engine.prepareSearch(.{ .depth = 4, .multi_pv = 3 }, .{}, 10, false);
    const result = try engine.runSearch();
    try std.testing.expectEqual(@as(u64, 1475), result.nodes);
    var text: [6]u8 = undefined;
    try std.testing.expectEqualStrings("d2d4", z.notation.moveText(result.best_move, false, &text));
    const generation = engine.table.generation;
    try engine.prepareSearch(.{ .depth = 2 }, .{}, 10, false);
    _ = try engine.runSearch();
    try std.testing.expect(engine.table.generation != generation);
    try std.testing.expectEqual(original_clusters, engine.clusters.ptr);
    try std.testing.expectEqual(network, engine.network.?);
    try engine.setPosition(z.position.start_fen, false, &.{ "g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8" });
    try std.testing.expect(engine.position.isDraw(0));
    const key = engine.position.key();
    const state = engine.position.st;
    try std.testing.expectError(error.IllegalMove, engine.setPosition(z.position.start_fen, false, &.{"e2e5"}));
    try std.testing.expectEqual(key, engine.position.key());
    try std.testing.expectEqual(state, engine.position.st);
    try std.testing.expectError(error.InvalidHashSize, engine.resizeHash(0));
    try std.testing.expectEqual(original_clusters, engine.clusters.ptr);
    engine.loadNetwork("tests/positions.txt") catch {};
    try std.testing.expectEqual(network, engine.network.?);
    try std.testing.expectEqual(state, engine.position.st);
    try engine.resizeHash(2);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), std.mem.sliceAsBytes(engine.clusters).len);
    try std.testing.expectEqual(@as(u32, 0), engine.table.hashfull(0));
    engine.base.main_history[0][0].set(100);
    engine.newGame();
    try std.testing.expectEqual(@as(i16, -5), engine.base.main_history[0][0].get());
    try std.testing.expectEqual(@as(f64, -1), engine.original_time_adjust);
    try engine.loadNetwork(@import("options").network_path);
    try engine.setPosition(z.position.start_fen, false, &.{ "e2e4", "e7e5" });
    try engine.prepareSearch(.{ .depth = 32 }, .{ .nodes = 64 }, 10, false);
    _ = try engine.runSearch();
    try std.testing.expect(engine.control.stopped());
    try std.testing.expectEqual(@as(usize, 1), engine.accumulators.size);
    try engine.resizeThreads(3);
    const original_position = engine.position.key();
    try engine.prepareSearch(.{ .depth = 8 }, .{ .nodes = 4096 }, 10, false);
    const parallel = try engine.runSearch();
    try std.testing.expect(parallel.nodes >= 4096);
    try std.testing.expectEqual(original_position, engine.position.key());
    for (engine.helpers) |helper| {
        try std.testing.expect(helper.base.nodes > 0);
        try std.testing.expectEqual(original_position, helper.position.key());
        try std.testing.expectEqual(@as(usize, 1), helper.base.accumulators.size);
    }
    if (engine.topology.available) {
        // Exercise multiple allocation groups on a one-node CI host too.
        // This tests ownership and routing, not physical remote-node latency.
        const topology = engine.topology;
        engine.topology.count = 2;
        engine.topology.nodes[1] = engine.topology.nodes[0];
        engine.numa_policy = .system;
        try engine.resizeThreads(2);
        try std.testing.expectEqual(@as(usize, 2), engine.groups.len);
        try std.testing.expect(engine.groups[0].network.? != engine.groups[1].network.?);
        try std.testing.expect(engine.groups[0].shared.pawn.ptr != engine.groups[1].shared.pawn.ptr);
        try engine.prepareSearch(.{ .depth = 4 }, .{}, 10, false);
        _ = try engine.runSearch();
        try engine.loadNetwork(@import("options").network_path);
        try engine.prepareSearch(.{ .depth = 2 }, .{}, 10, false);
        _ = try engine.runSearch();
        engine.topology = topology;
        engine.numa_policy = .auto;
    }
    try engine.resizeThreads(1);
    try engine.setPosition(z.position.start_fen, false, &.{});
    try engine.prepareSearch(.{ .depth = 4, .multi_pv = 3 }, .{}, 10, false);
    const single = try engine.runSearch();
    try std.testing.expectEqual(@as(u64, 1475), single.nodes);
}
