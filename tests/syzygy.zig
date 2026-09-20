const std = @import("std");
const z = @import("zander");
test "native WDL and DTZ probes match pinned Stockfish tables" {
    const tables = try std.testing.allocator.create(z.attacks.Tables);
    defer std.testing.allocator.destroy(tables);
    tables.init();
    var keys: z.position_keys.PositionKeys = undefined;
    keys.init();
    const database = try z.syzygy.Database.create(std.testing.allocator, std.testing.io, @import("options").tablebase_path, &keys);
    defer database.destroy();
    const roots = try std.testing.allocator.alloc(z.search.RootMove, z.types.max_moves);
    defer std.testing.allocator.free(roots);
    var checked: usize = 0;
    for (@import("reference").cases) |case| {
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        try pos.set(case.fen, false, &state, tables, &keys);
        const key = pos.key();
        if (case.wdl_state == 0) {
            try std.testing.expectError(error.MissingTablebase, database.wdl(&pos));
        } else {
            const result = database.wdl(&pos) catch |err| {
                std.debug.print("WDL failure for {s}: {s}\n", .{ case.fen, @errorName(err) });
                return err;
            };
            if (result.value != case.wdl) std.debug.print("WDL mismatch for {s}\n", .{case.fen});
            try std.testing.expectEqual(case.wdl, result.value);
            try std.testing.expectEqual(case.wdl_state == 2, result.zeroing);
        }
        if (case.dtz_state == 0) {
            try std.testing.expectError(error.MissingTablebase, database.dtz(&pos));
        } else {
            const result = database.dtz(&pos) catch |err| {
                std.debug.print("DTZ failure for {s}: {s}\n", .{ case.fen, @errorName(err) });
                return err;
            };
            if (result != case.dtz) std.debug.print("DTZ mismatch for {s}\n", .{case.fen});
            try std.testing.expectEqual(case.dtz, result);
        }
        if (case.roots.len != 0) {
            const records = roots[0..case.roots.len];
            for (records, case.roots) |*record, expected| record.* = z.search.RootMove.init(.{ .data = expected.move });
            const distance_ok = z.syzygy_root.rankDtz(database, &pos, records, case.rule50, case.rank_distance, .{}) catch false;
            try std.testing.expectEqual(case.dtz_ok, distance_ok);
            if (distance_ok) for (records, case.roots) |record, expected| {
                try std.testing.expectEqual(expected.dtz_rank, record.tb_rank);
                try std.testing.expectEqual(expected.dtz_score, record.tb_score);
            };
            const outcome_ok = z.syzygy_root.rankWdl(database, &pos, records, case.rule50) catch false;
            try std.testing.expectEqual(case.wdl_ok, outcome_ok);
            if (outcome_ok) for (records, case.roots) |record, expected| {
                try std.testing.expectEqual(expected.wdl_rank, record.tb_rank);
                try std.testing.expectEqual(expected.wdl_score, record.tb_score);
            };
        }
        try std.testing.expectEqual(key, pos.key());
        try std.testing.expectEqual(&state, pos.st);
        checked += 1;
    }
    try std.testing.expect(checked > 2000);
}
