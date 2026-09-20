const std = @import("std");
const z = @import("zander");
test "single-worker search, histories and node state match pinned Stockfish" {
    const allocator = std.testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, @import("options").network_path, allocator, .limited(200 * 1024 * 1024));
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqualStrings(z.nnue_network.default_sha256, &std.fmt.bytesToHex(digest, .lower));
    const network = try allocator.create(z.nnue_network.Network);
    defer allocator.destroy(network);
    _ = try network.load(bytes);
    const accumulators = try allocator.create(z.nnue_accumulator.Stack);
    defer allocator.destroy(accumulators);
    const caches = try allocator.create(z.nnue_accumulator.Caches);
    defer allocator.destroy(caches);
    caches.clear(&network.transformer);
    const tables = try allocator.create(z.attacks.Tables);
    defer allocator.destroy(tables);
    tables.init();
    const keys = try allocator.create(z.position_keys.PositionKeys);
    defer allocator.destroy(keys);
    keys.init();
    const main = try allocator.create(z.history.ButterflyHistory);
    defer allocator.destroy(main);
    z.history.fill(main, -5);
    const low = try allocator.create(z.history.LowPlyHistory);
    defer allocator.destroy(low);
    z.history.fill(low, 102);
    const capture = try allocator.create(z.history.CapturePieceToHistory);
    defer allocator.destroy(capture);
    z.history.fill(capture, -742);
    const correction = try allocator.alloc(z.history.CorrectionEntry, z.history.correction_history_base_size);
    defer allocator.free(correction);
    const pawn = try allocator.alloc(z.history.PawnEntry, z.history.pawn_history_base_size);
    defer allocator.free(pawn);
    const continuation = try allocator.create(z.history.ContinuationHistoryBlock);
    defer allocator.destroy(continuation);
    const continuation_correction = try allocator.create(z.history.ContinuationCorrectionHistory);
    defer allocator.destroy(continuation_correction);
    z.history.fill(continuation_correction, 5);
    var shared = try z.history.SharedHistories.init(1, correction, continuation, pawn);
    shared.clearRange(0, 1);
    const clusters = try allocator.alignedAlloc(z.tt.Cluster, .@"64", 32768);
    defer allocator.free(clusters);
    var table = z.tt.Table.init(clusters);
    const worker = try allocator.create(z.quiescence.Worker);
    defer allocator.destroy(worker);
    worker.* = .{ .network = network, .accumulators = accumulators, .caches = caches, .table = &table, .main_history = main, .low_ply_history = low, .capture_history = capture, .shared = &shared, .continuation_correction = continuation_correction };
    var lines: [100][]const u8 = undefined;
    var iter = std.mem.tokenizeScalar(u8, @embedFile("positions.txt"), '\n');
    var count: usize = 0;
    while (iter.next()) |line| : (count += 1) lines[count] = line;
    for (@import("reference").cases, 0..) |case, case_index| {
        errdefer std.debug.print("Quiescence case {d}, root {d}, warm {any}\n", .{ case_index, case.root, case.warm });
        var pos: z.position.Position = undefined;
        var states: [9]z.position.StateInfo = undefined;
        try pos.set(lines[case.root][2..], lines[case.root][0] == '1', &states[0], tables, keys);
        for (case.path, 1..) |move, i| pos.doMove(.{ .data = move }, &states[i]);
        const original_key = pos.key();
        if (!case.warm) {
            table.clear();
            table.newSearch();
        }
        var pv: z.search_support.PV = .{};
        const score = if (case.pv_node) worker.run(true, &pos, &pv, case.alpha, case.beta) else worker.run(false, &pos, &pv, case.alpha, case.beta);
        try std.testing.expectEqual(case.score, score);
        try std.testing.expectEqual(case.nodes, worker.nodes);
        try std.testing.expectEqual(case.sel_depth, worker.sel_depth);
        try std.testing.expectEqual(case.pv.len, pv.len);
        for (case.pv, pv.slice()) |expected, actual| try std.testing.expectEqual(expected, actual.data);
        var checksum: u64 = 14695981039346656037;
        for (std.mem.sliceAsBytes(clusters)) |byte| checksum = (checksum ^ byte) *% 1099511628211;
        try std.testing.expectEqual(case.tt_checksum, checksum);
        try std.testing.expectEqual(original_key, pos.key());
        try std.testing.expect(pos.st == &states[case.path.len]);
        try std.testing.expectEqual(@as(usize, 1), accumulators.size);
    }
    for (@import("reference").histories, 0..) |case, case_index| {
        errdefer std.debug.print("History update case {d}, root {d}, variant {d}\n", .{ case_index, case.root, case.variant });
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        try pos.set(lines[case.root][2..], lines[case.root][0] == '1', &state, tables, keys);
        const variant = case.variant;
        worker.frames = @splat(.{});
        worker.frames[7].ply = ([_]i32{ 0, 4, 5, 18 })[variant];
        worker.frames[7].in_check = variant == 1;
        for (0..7) |i| {
            worker.frames[6 - i].continuation_history = &continuation[0][0][0][i];
            worker.frames[6 - i].continuation_correction_history = &continuation_correction[0][i];
            worker.frames[6 - i].current_move = if ((i + variant) % 3 == 0) .null_move else .{ .data = (8 << 6) + 16 };
        }
        worker.frames[6].stat_score = ([_]i32{ 0, 280, -280, -2800 })[variant];
        worker.frames[6].tt_hit = variant % 2 != 0;
        worker.frames[6].move_count = if (variant < 3) 1 + @as(i32, @intFromBool(worker.frames[6].tt_hit)) else 3;
        const history = worker.histories();
        try std.testing.expectEqual(case.before, history.correctionValue(&pos, 7));
        const bonus = ([_]i32{ -1000, -4, -3, 1000 })[variant];
        history.updateCorrection(&pos, 7, bonus);
        if (case.quiet != 0) history.updateQuiet(&pos, 7, .{ .data = case.quiet }, bonus);
        var quiets: [8]z.types.Move = undefined;
        var captures: [8]z.types.Move = undefined;
        for (case.quiets, 0..) |move, j| quiets[j] = .{ .data = move };
        for (case.captures, 0..) |move, j| captures[j] = .{ .data = move };
        history.updateAll(&pos, 7, .{ .data = case.best }, if (variant % 2 != 0) .none else pos.king(pos.side), quiets[0..case.quiets.len], captures[0..case.captures.len], ([_]i32{ 1, 4, 12, 1 })[variant], .{ .data = if (variant == 2) case.best else 0 }, variant % 2 == 0);
        try std.testing.expectEqual(case.after, history.correctionValue(&pos, 7));
        const chunks = [_][]const u8{ std.mem.asBytes(main), std.mem.asBytes(low), std.mem.asBytes(capture), std.mem.asBytes(continuation), std.mem.asBytes(continuation_correction), std.mem.sliceAsBytes(correction), std.mem.asBytes(shared.pawnEntry(&pos)) };
        for (chunks, case.hashes, 0..) |chunk, expected, part| {
            errdefer std.debug.print("History component {d}\n", .{part});
            var checksum: u64 = 14695981039346656037;
            for (chunk) |byte| checksum = (checksum ^ byte) *% 1099511628211;
            try std.testing.expectEqual(expected, checksum);
        }
    }
    var reductions: z.search_support.Reductions = .{};
    reductions.init();
    try std.testing.expectEqualSlices(i32, &@import("reference").reductions, reductions.values[1..]);
    for (@import("reference").reduction_cases) |case| {
        var checksum: u64 = 14695981039346656037;
        for (1..z.types.max_ply) |depth| for (1..z.types.max_moves) |move_number| {
            const value = reductions.reduction(case.improving, depth, move_number, case.delta, case.root_delta);
            checksum = (checksum ^ @as(u32, @bitCast(value))) *% 1099511628211;
        };
        try std.testing.expectEqual(case.checksum, checksum);
    }
    for (@import("reference").worker_moves) |case| {
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        var next: z.position.StateInfo = undefined;
        try pos.set(lines[case.root][2..], lines[case.root][0] == '1', &state, tables, keys);
        const key = pos.key();
        worker.frames = @splat(.{});
        worker.frames[7].in_check = pos.st.checkers != 0;
        for (worker.frames[0..7]) |*frame| {
            frame.continuation_history = &continuation[0][0][0][0];
            frame.continuation_correction_history = &continuation_correction[0][0];
        }
        worker.nodes = 0;
        accumulators.reset();
        const move: z.types.Move = .{ .data = case.move };
        const is_null = move.data == z.types.Move.null_move.data;
        if (is_null) worker.doNullMove(&pos, &next, 7) else worker.doMove(&pos, move, &next, if (case.frame) 7 else null);
        try std.testing.expectEqual(case.key, pos.key());
        try std.testing.expectEqual(case.nodes, worker.nodes);
        try std.testing.expectEqual(case.size, accumulators.size);
        try std.testing.expectEqual(case.current, worker.frames[7].current_move.data);
        const actual_cont: i32 = if (worker.frames[7].continuation_history) |pointer| @intCast((@intFromPtr(pointer) - @intFromPtr(continuation)) / @sizeOf(z.history.PieceToHistory)) else -1;
        const actual_corr: i32 = if (worker.frames[7].continuation_correction_history) |pointer| @intCast((@intFromPtr(pointer) - @intFromPtr(continuation_correction)) / @sizeOf(z.history.PieceToCorrectionHistory)) else -1;
        try std.testing.expectEqual(case.continuation, actual_cont);
        try std.testing.expectEqual(case.correction, actual_corr);
        if (is_null) worker.undoNullMove(&pos) else worker.undoMove(&pos, move);
        try std.testing.expectEqual(key, pos.key());
        try std.testing.expect(pos.st == &state);
        try std.testing.expectEqual(@as(usize, 1), accumulators.size);
    }
    var search = z.search.Worker.init(worker);
    for (@import("reference").main_cases, 0..) |case, case_index| {
        errdefer std.debug.print("Main search case {d}, root {d}, depth {d}, mode {d}, warm {any}\n", .{ case_index, case.root, case.depth, case.mode, case.warm });
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        try pos.set(lines[case.root][2..], lines[case.root][0] == '1', &state, tables, keys);
        const key = pos.key();
        if (!case.warm) {
            z.history.fill(main, -5);
            z.history.fill(low, 102);
            z.history.fill(capture, -742);
            z.history.fill(continuation_correction, 5);
            shared.clearRange(0, 1);
            search.tt_move_history.set(0);
            caches.clear(&network.transformer);
            table.clear();
            table.newSearch();
        }
        var pv: z.search_support.PV = .{};
        const score = if (case.mode == 0) search.run(true, &pos, &pv, -32001, 32001, case.depth, false) else search.run(false, &pos, &pv, 99, 100, case.depth, case.mode == 1);
        try std.testing.expectEqual(case.score, score);
        try std.testing.expectEqual(case.nodes, worker.nodes);
        try std.testing.expectEqual(case.sel_depth, worker.sel_depth);
        try std.testing.expectEqual(case.tt_history, search.tt_move_history.get());
        if (case.history_hashes[0] != 0) {
            const chunks = [_][]const u8{ std.mem.asBytes(main), std.mem.asBytes(low), std.mem.asBytes(capture), std.mem.asBytes(continuation), std.mem.asBytes(continuation_correction), std.mem.sliceAsBytes(correction), std.mem.asBytes(shared.pawnEntry(&pos)) };
            for (chunks, case.history_hashes, 0..) |chunk, expected, part| {
                errdefer std.debug.print("Main search history component {d}\n", .{part});
                var history_checksum: u64 = 14695981039346656037;
                for (chunk) |byte| history_checksum = (history_checksum ^ byte) *% 1099511628211;
                try std.testing.expectEqual(expected, history_checksum);
            }
        }

        try std.testing.expectEqual(case.pv.len, pv.len);
        for (case.pv, pv.slice()) |expected, move| try std.testing.expectEqual(expected, move.data);
        var checksum: u64 = 14695981039346656037;
        for (std.mem.sliceAsBytes(clusters)) |byte| checksum = (checksum ^ byte) *% 1099511628211;
        try std.testing.expectEqual(case.tt_checksum, checksum);
        try std.testing.expectEqual(key, pos.key());
        try std.testing.expect(pos.st == &state);
        try std.testing.expectEqual(@as(usize, 1), accumulators.size);
    }
    const roots = try allocator.alloc(z.search.RootMove, z.types.max_moves);
    defer allocator.free(roots);
    for (@import("reference").root_cases, 0..) |case, case_index| {
        errdefer std.debug.print("Root search case {d}, root {d}, depth {d}, mode {d}, warm {any}\n", .{ case_index, case.root, case.depth, case.mode, case.warm });
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        try pos.set(lines[case.root][2..], lines[case.root][0] == '1', &state, tables, keys);
        const key = pos.key();
        if (!case.warm) {
            z.history.fill(main, -5);
            z.history.fill(low, 102);
            z.history.fill(capture, -742);
            z.history.fill(continuation_correction, 5);
            shared.clearRange(0, 1);
            search.tt_move_history.set(0);
            caches.clear(&network.transformer);
            table.clear();
            table.newSearch();
            var moves: z.movegen.MoveList = .{};
            z.movegen.generate(.legal, &pos, &moves);
            search.root_moves = roots[0..moves.len];
            for (moves.slice(), search.root_moves) |move, *rm| rm.* = z.search.RootMove.init(move);
            search.pv_idx = if (case.mode == 2 and moves.len > 1) 1 else 0;
            search.pv_last = if (case.mode == 2) @min(moves.len, search.pv_idx + 3) else moves.len;
        }
        var pv: z.search_support.PV = .{};
        worker.prepare(&pv);
        search.root_depth = case.depth;
        search.nmp_min_ply = 0;
        search.best_move_changes = 0;
        search.last_iteration_pv.clear();
        const score = search.searchRoot(&pos, if (case.mode == 0) -32001 else if (case.mode == 1) 99 else -101, if (case.mode == 0) 32001 else if (case.mode == 1) 100 else -100, case.depth);
        try std.testing.expectEqual(case.score, score);
        try std.testing.expectEqual(case.nodes, worker.nodes);
        try std.testing.expectEqual(case.sel_depth, worker.sel_depth);
        try std.testing.expectEqual(case.changes, search.best_move_changes);
        for (case.records, search.root_moves, 0..) |expected, actual, index| {
            errdefer std.debug.print("Root record {d}\n", .{index});
            try std.testing.expectEqual(expected.effort, actual.effort);
            try std.testing.expectEqual(expected.score, actual.score);
            try std.testing.expectEqual(expected.average, actual.average_score);
            try std.testing.expectEqual(expected.squared, actual.mean_squared_score);
            try std.testing.expectEqual(expected.uci, actual.uci_score);
            try std.testing.expectEqual(expected.lower, actual.inexact_lower);
            try std.testing.expectEqual(expected.upper, actual.inexact_upper);
            try std.testing.expectEqual(expected.sel_depth, actual.sel_depth);
            try std.testing.expectEqual(expected.pv.len, actual.pv.len);
            for (expected.pv, actual.pv.slice()) |a, c| try std.testing.expectEqual(a, c.data);
        }
        var checksum: u64 = 14695981039346656037;
        for (std.mem.sliceAsBytes(clusters)) |byte| checksum = (checksum ^ byte) *% 1099511628211;
        try std.testing.expectEqual(case.tt_checksum, checksum);
        try std.testing.expectEqual(key, pos.key());
        try std.testing.expect(pos.st == &state);
        try std.testing.expectEqual(@as(usize, 1), accumulators.size);
    }
    for (@import("reference").iteration_cases, 0..) |case, case_index| {
        errdefer std.debug.print("Iteration case {d}, root {d}, depth {d}, mode {d}, warm {any}\n", .{ case_index, case.root, case.depth, case.mode, case.warm });
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        try pos.set(lines[case.root][2..], lines[case.root][0] == '1', &state, tables, keys);
        const key = pos.key();
        if (!case.warm) {
            z.history.fill(main, -5);
            z.history.fill(capture, -742);
            z.history.fill(continuation_correction, 5);
            shared.clearRange(0, 1);
            search.tt_move_history.set(0);
            caches.clear(&network.transformer);
            table.clear();
        }
        var moves: z.movegen.MoveList = .{};
        z.movegen.generate(.legal, &pos, &moves);
        var selected: [z.types.max_moves]z.types.Move = undefined;
        var count_selected: usize = 0;
        for (moves.slice(), 0..) |move, index| {
            if (index % 2 != 0) continue;
            selected[count_selected] = move;
            count_selected += 1;
        }
        std.mem.reverse(z.types.Move, selected[0..count_selected]);
        const result = try search.iterativeDeepening(&pos, roots, .{ .depth = case.depth, .multi_pv = if (case.mode == 0) 1 else 3, .search_moves = if (case.mode == 2) selected[0..count_selected] else if (case.mode == 1) &.{ .none, .null_move } else &.{} });
        try std.testing.expectEqual(case.depth, result.depth);
        try std.testing.expectEqual(case.records[0].score, result.score);
        try std.testing.expectEqual(case.records[0].pv[0], result.best_move.data);
        try std.testing.expectEqual(case.nodes, result.nodes);
        try std.testing.expectEqual(case.sel_depth, worker.sel_depth);
        try std.testing.expectEqual(case.tt_history, search.tt_move_history.get());
        try std.testing.expectEqual(case.records.len, search.root_moves.len);
        for (case.records, search.root_moves, 0..) |expected, actual, index| {
            errdefer std.debug.print("Iteration root record {d}\n", .{index});
            try std.testing.expectEqual(expected.effort, actual.effort);
            try std.testing.expectEqual(expected.score, actual.score);
            try std.testing.expectEqual(expected.average, actual.average_score);
            try std.testing.expectEqual(expected.squared, actual.mean_squared_score);
            try std.testing.expectEqual(expected.uci, actual.uci_score);
            try std.testing.expectEqual(expected.lower, actual.inexact_lower);
            try std.testing.expectEqual(expected.upper, actual.inexact_upper);
            try std.testing.expectEqual(expected.sel_depth, actual.sel_depth);
            try std.testing.expectEqual(expected.pv.len, actual.pv.len);
            for (expected.pv, actual.pv.slice()) |a, c| try std.testing.expectEqual(a, c.data);
            try std.testing.expectEqual(case.previous_scores[index], actual.previous_score);
            try std.testing.expectEqual(case.previous_exact[index], actual.previous_score_exact);
            try std.testing.expectEqual(case.previous_pvs[index].len, actual.previous_pv.len);
            for (case.previous_pvs[index], actual.previous_pv.slice()) |a, c| try std.testing.expectEqual(a, c.data);
        }
        var checksum: u64 = 14695981039346656037;
        for (std.mem.sliceAsBytes(clusters)) |byte| checksum = (checksum ^ byte) *% 1099511628211;
        try std.testing.expectEqual(case.tt_checksum, checksum);
        try std.testing.expectEqual(key, pos.key());
        try std.testing.expect(pos.st == &state);
        try std.testing.expectEqual(@as(usize, 1), accumulators.size);
    }
    for (lines[0..count]) |line| {
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        pos.set(line[2..], line[0] == '1', &state, tables, keys) catch continue;
        var moves: z.movegen.MoveList = .{};
        z.movegen.generate(.legal, &pos, &moves);
        if (moves.len != 0) continue;
        const result = try search.iterativeDeepening(&pos, roots, .{ .depth = 4 });
        try std.testing.expectEqual(@as(u16, 0), result.best_move.data);
        try std.testing.expectEqual(@as(i32, if (pos.st.checkers != 0) -z.types.value_mate else 0), result.score);
        try std.testing.expectEqual(@as(u64, 0), result.nodes);
        try std.testing.expectEqual(@as(i32, 0), result.depth);
        try std.testing.expectEqual(@as(usize, 0), search.root_moves.len);
    }
    {
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        try pos.set(z.position.start_fen, false, &state, tables, keys);
        try std.testing.expectError(error.InvalidDepth, search.iterativeDeepening(&pos, roots, .{ .depth = 0 }));
        try std.testing.expectError(error.InvalidDepth, search.iterativeDeepening(&pos, roots, .{ .depth = z.types.max_ply }));
        try std.testing.expectError(error.InvalidMultiPV, search.iterativeDeepening(&pos, roots, .{ .depth = 1, .multi_pv = 0 }));
        try std.testing.expectError(error.InvalidMultiPV, search.iterativeDeepening(&pos, roots, .{ .depth = 1, .multi_pv = z.types.max_moves + 1 }));
        const duplicates = [_]z.types.Move{z.types.Move.make(.normal, z.types.Square.make(4, 1), z.types.Square.make(4, 3), .knight)} ** (z.types.max_moves + 1);
        try std.testing.expectError(error.TooManyRootMoves, search.iterativeDeepening(&pos, roots, .{ .depth = 1, .search_moves = &duplicates }));
        try std.testing.expectError(error.InsufficientRootStorage, search.iterativeDeepening(&pos, roots[0..19], .{ .depth = 1 }));
    }
    for (@import("reference").time_cases) |case| {
        var adjustment: f64 = -1;
        const budget = z.time_management.Budget.init(.{ .time = .{ case.own, case.other }, .increment = .{ case.increment, 0 }, .moves_to_go = case.moves }, 0, case.ply, 10, case.ponder, &adjustment);
        try std.testing.expectEqual(case.optimum, budget.optimum);
        try std.testing.expectEqual(case.maximum, budget.maximum);
    }
    const Clock = struct {
        fn now(_: ?*anyopaque) i64 {
            return 0;
        }
    };
    var control: z.search_control.Control = .{ .clock = Clock.now };
    worker.control = &control;
    defer worker.control = null;
    for ([_]u64{ 1, 64, 512, 4096 }) |limit| {
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        try pos.set(z.position.start_fen, false, &state, tables, keys);
        const key = pos.key();
        control.reset(.{ .nodes = limit }, .{});
        const result = try search.iterativeDeepening(&pos, roots, .{ .depth = 64, .multi_pv = 3 });
        try std.testing.expect(control.stopped());
        try std.testing.expect(result.nodes >= limit);
        try std.testing.expect(pos.legal(result.best_move));
        try std.testing.expectEqual(key, pos.key());
        try std.testing.expect(pos.st == &state);
        try std.testing.expectEqual(@as(usize, 1), accumulators.size);
        try std.testing.expectEqual(@as(i32, 0), search.nmp_min_ply);
        for (worker.frames) |frame| try std.testing.expectEqual(@as(u16, 0), frame.excluded_move.data);
    }
    for (@import("reference").notation_cases) |case| {
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        try pos.set(lines[case.root][2..], lines[case.root][0] == '1', &state, tables, keys);
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try z.notation.writeScore(&writer, case.value, &pos);
        try std.testing.expectEqualStrings(case.score, writer.buffered());
        writer = std.Io.Writer.fixed(&buffer);
        const wdl = z.notation.wdl(case.value, &pos);
        try writer.print("{d} {d} {d}", .{ wdl[0], wdl[1], wdl[2] });
        try std.testing.expectEqualStrings(case.wdl, writer.buffered());
    }
    for (@import("reference").notation_moves) |case| {
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        try pos.set(lines[case.root][2..], lines[case.root][0] == '1', &state, tables, keys);
        var buffer: [6]u8 = undefined;
        try std.testing.expectEqualStrings(case.text, z.notation.moveText(.{ .data = case.move }, pos.chess960, &buffer));
        try std.testing.expectEqual(case.move, z.notation.parseMove(&pos, case.text).?.data);
    }
}
