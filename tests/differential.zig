const std = @import("std");
const z = @import("zander");
extern fn sf_shift(u64, i8) u64;
extern fn sf_key(u64) u64;
extern fn sf_pawns(u64, u8) u64;
extern fn sf_decode(u16) u32;
extern fn sf_move(u8, u8, u8) u16;
test "all 65536 move encodings match Stockfish" {
    for (0..65536) |raw| {
        const m: z.types.Move = .{ .data = @intCast(raw) };
        var packed_value: u32 = @intFromBool(m.valid());
        packed_value |= @as(u32, @intFromEnum(m.kind())) << 1;
        packed_value |= @as(u32, @intFromEnum(m.promotionType())) << 17;
        if (m.valid()) {
            packed_value |= @as(u32, @intFromEnum(m.from())) << 20;
            packed_value |= @as(u32, @intFromEnum(m.to())) << 26;
        }
        try std.testing.expectEqual(sf_decode(@intCast(raw)), packed_value);
    }
}
test "every promotion encoding matches Stockfish" {
    for (0..64) |from| for (0..64) |to| for (2..6) |pt| {
        const m = z.types.Move.make(.promotion, @enumFromInt(from), @enumFromInt(to), @enumFromInt(pt));
        try std.testing.expectEqual(sf_move(@intCast(from), @intCast(to), @intCast(pt)), m.data);
    };
}
test "bitboard shifts, pawn attacks and wrapping keys match Stockfish" {
    var b: u64 = 0;
    for (0..10000) |i| {
        if (i < 64) {
            b = @as(u64, 1) << @as(u6, @intCast(i));
        }
        for ([_]i8{ 8, -8, 16, -16, 1, -1, 9, 7, -7, -9, 0 }) |d| {
            try std.testing.expectEqual(sf_shift(b, d), z.bitboard.shift(b, d));
        }
        inline for (.{ z.types.Color.white, z.types.Color.black }) |c| {
            try std.testing.expectEqual(sf_pawns(b, @intFromEnum(c)), z.bitboard.pawnAttacks(c, b));
        }
        try std.testing.expectEqual(sf_key(b), z.types.makeKey(b));
        b = z.types.makeKey(b);
    }
    try std.testing.expectEqual(sf_key(std.math.maxInt(u64)), z.types.makeKey(std.math.maxInt(u64)));
}

extern fn sf_attacks_init() void;
extern fn sf_attacks(u8, u8, u64) u64;
extern fn sf_geometry(u8, u8, u8) u64;
extern fn sf_magic(u8, u8) u64;
test "attack tables match upstream for every relevant occupancy and square pair" {
    const tables = try std.testing.allocator.create(z.attacks.Tables);
    defer std.testing.allocator.destroy(tables);
    tables.init();
    sf_attacks_init();
    for (0..64) |i| {
        const s: z.types.Square = @enumFromInt(i);
        for ([_]z.types.PieceType{ .bishop, .rook }) |pt| {
            const m = tables.magics[i][@intFromEnum(pt) - 3];
            try std.testing.expectEqual(sf_magic(@intFromEnum(pt), @intCast(i)), m.magic);
            var b: u64 = 0;
            while (true) {
                // Irrelevant bits include edges and the origin; they must not
                // affect lookup results, even when all of them are occupied.
                for ([_]u64{ b, b | ~m.mask }) |occupied| {
                    try std.testing.expectEqual(sf_attacks(@intFromEnum(pt), @intCast(i), occupied), tables.attacks(pt, s, occupied));
                }
                b = (b -% m.mask) & m.mask;
                if (b == 0) break;
            }
        }
        for (0..64) |j| {
            try std.testing.expectEqual(sf_geometry(0, @intCast(i), @intCast(j)), tables.line[i][j]);
            try std.testing.expectEqual(sf_geometry(1, @intCast(i), @intCast(j)), tables.between[i][j]);
            try std.testing.expectEqual(sf_geometry(2, @intCast(i), @intCast(j)), tables.ray_pass[i][j]);
        }
        var occupied = z.types.makeKey(i);
        for (0..128) |_| {
            for ([_]z.types.PieceType{ .knight, .king, .queen }) |pt| {
                try std.testing.expectEqual(sf_attacks(@intFromEnum(pt), @intCast(i), occupied), tables.attacks(pt, s, occupied));
            }
            occupied = z.types.makeKey(occupied);
        }
    }
}

test "Zobrist keys and every cuckoo slot match upstream Position init" {
    const reference = @import("position_reference");
    const keys = try std.testing.allocator.create(z.position_keys.PositionKeys);
    defer std.testing.allocator.destroy(keys);
    keys.init();
    var index: usize = 0;
    for (keys.psq) |row| {
        try std.testing.expectEqualSlices(u64, reference.keys[index..][0..64], &row);
        index += 64;
    }
    try std.testing.expectEqualSlices(u64, reference.keys[index..][0..8], &keys.enpassant);
    index += 8;
    try std.testing.expectEqualSlices(u64, reference.keys[index..][0..16], &keys.castling);
    index += 16;
    try std.testing.expectEqual(reference.keys[index], keys.side);
    try std.testing.expectEqual(reference.keys[index + 1], keys.no_pawns);
    try std.testing.expectEqualSlices(u64, &reference.cuckoo_keys, &keys.cuckoo);
    var occupied: usize = 0;
    for (keys.cuckoo_move, reference.cuckoo_moves, 0..) |move, expected, i| {
        try std.testing.expectEqual(expected, move.data);
        if (move.data != 0) {
            occupied += 1;
            try std.testing.expect(i == z.position_keys.PositionKeys.h1(keys.cuckoo[i]) or i == z.position_keys.PositionKeys.h2(keys.cuckoo[i]));
        }
    }
    try std.testing.expectEqual(@as(usize, 3668), occupied);
}

test "FEN positions match upstream board, keys, checks, pins and castling" {
    const reference = @import("position_reference");
    const tables = try std.testing.allocator.create(z.attacks.Tables);
    defer std.testing.allocator.destroy(tables);
    const keys = try std.testing.allocator.create(z.position_keys.PositionKeys);
    defer std.testing.allocator.destroy(keys);
    tables.init();
    keys.init();
    var lines = std.mem.tokenizeScalar(u8, @embedFile("positions.txt"), '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        const expected = reference.positions[n];
        var pos: z.position.Position = undefined;
        var state: z.position.StateInfo = undefined;
        pos.set(line[2..], line[0] == '1', &state, tables, keys) catch |err| {
            if (expected.valid) std.debug.print("Unexpected FEN rejection: {s}: {}\n", .{ line, err });
            try std.testing.expect(!expected.valid);
            continue;
        };
        try std.testing.expect(expected.valid);
        try expectQueries(&pos, expected);
        var normal_pseudo: [4096]u16 = undefined;
        var normal_count: usize = 0;
        for (1..4096) |raw| {
            if (pos.pseudoLegal(.{ .data = @intCast(raw) })) {
                normal_pseudo[normal_count] = @intCast(raw);
                normal_count += 1;
            }
        }
        try std.testing.expectEqualSlices(u16, expected.normal_pseudo, normal_pseudo[0..normal_count]);
        var list: z.movegen.MoveList = .{};
        z.movegen.generate(.legal, &pos, &list);
        try expectMoves(expected.legal, list.slice());
        if (pos.st.checkers != 0) z.movegen.generate(.evasions, &pos, &list) else z.movegen.generate(.non_evasions, &pos, &list);
        try expectMoves(expected.pseudo, list.slice());
        if (pos.st.checkers == 0) {
            z.movegen.generate(.captures, &pos, &list);
            try expectMoves(expected.captures, list.slice());
            z.movegen.generate(.quiets, &pos, &list);
            try expectMoves(expected.quiets, list.slice());
        }
        var fen_buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&fen_buffer);
        try pos.writeFen(&writer);
        try std.testing.expectEqualStrings(expected.fen, writer.buffered());
        var snapshot: [256]u64 = undefined;
        const actual = snapshotPosition(&pos, &snapshot);
        if (!std.mem.eql(u64, expected.data, actual)) std.debug.print("FEN mismatch: {s}\n", .{line});
        try std.testing.expectEqualSlices(u64, expected.data, actual);
        const board_before = pos.board;
        const counts_before = pos.piece_count;
        for (expected.children) |child| {
            var next: z.position.StateInfo = undefined;
            const move: z.types.Move = .{ .data = child.move };
            const gives_check = pos.givesCheck(move);
            var dirties: z.dirty.Dirties = undefined;
            pos.doMoveWithDirties(move, &next, &dirties);
            try expectDirties(child, &dirties);
            try std.testing.expectEqual(gives_check, pos.st.checkers != 0);
            try expectQueries(&pos, child);
            try std.testing.expectEqualSlices(u64, child.data, snapshotPosition(&pos, &snapshot));
            z.movegen.generate(.legal, &pos, &list);
            try expectMoves(child.legal, list.slice());
            pos.undoMove(move);
            try std.testing.expectEqualSlices(u64, expected.data, snapshotPosition(&pos, &snapshot));
            try std.testing.expectEqualSlices(z.types.Piece, &board_before, &pos.board);
            try std.testing.expectEqualSlices(i32, &counts_before, &pos.piece_count);
            try std.testing.expect(pos.st == &state);
        }
        var walk_states: [48]z.position.StateInfo = undefined;
        for (expected.walk, 0..) |step, i| {
            var dirties: z.dirty.Dirties = undefined;
            pos.doMoveWithDirties(.{ .data = step.move }, &walk_states[i], &dirties);
            try expectDirties(step, &dirties);
            try expectQueries(&pos, step);
            try std.testing.expectEqualSlices(u64, step.data, snapshotPosition(&pos, &snapshot));
            z.movegen.generate(.legal, &pos, &list);
            try expectMoves(step.legal, list.slice());
        }
        var undone = expected.walk.len;
        while (undone > 0) {
            undone -= 1;
            pos.undoMove(.{ .data = expected.walk[undone].move });
            const prior = if (undone == 0) expected.data else expected.walk[undone - 1].data;
            try std.testing.expectEqualSlices(u64, prior, snapshotPosition(&pos, &snapshot));
        }
        for (expected.null_state) |null_state| {
            var next: z.position.StateInfo = undefined;
            pos.doNullMove(&next);
            try expectQueries(&pos, null_state);
            try std.testing.expectEqualSlices(u64, null_state.data, snapshotPosition(&pos, &snapshot));
            pos.undoNullMove();
            try std.testing.expectEqualSlices(u64, expected.data, snapshotPosition(&pos, &snapshot));
        }
        try std.testing.expectEqual(expected.nodes, z.perft.count(&pos, 3));
        try std.testing.expectEqualSlices(u64, expected.data, snapshotPosition(&pos, &snapshot));
    }
    try std.testing.expectEqual(reference.positions.len, n);
    var pos: z.position.Position = undefined;
    var history: [13]z.position.StateInfo = undefined;
    try pos.set(z.position.start_fen, false, &history[0], tables, keys);
    for (reference.repetition, 0..) |step, i| {
        var dirties: z.dirty.Dirties = undefined;
        pos.doMoveWithDirties(.{ .data = step.move }, &history[i + 1], &dirties);
        try expectDirties(step, &dirties);
        try expectQueries(&pos, step);
        var snapshot: [256]u64 = undefined;
        try std.testing.expectEqualSlices(u64, step.data, snapshotPosition(&pos, &snapshot));
    }
    try std.testing.expect(pos.st.repetition < 0);
    try pos.set(z.position.start_fen, false, &history[0], tables, keys);
    try std.testing.expectEqual(@as(u64, 197281), z.perft.count(&pos, 4));
}
fn snapshotPosition(pos: *const z.position.Position, buffer: *[256]u64) []const u64 {
    var n: usize = 0;
    for (pos.board) |pc| {
        buffer[n] = @intFromEnum(pc);
        n += 1;
    }
    for (pos.by_type) |v| {
        buffer[n] = v;
        n += 1;
    }
    for (pos.by_color) |v| {
        buffer[n] = v;
        n += 1;
    }
    const st = pos.st;
    const values = [_]u64{ pos.key(), st.key, st.material_key, st.pawn_key, st.minor_piece_key, st.non_pawn_key[0], st.non_pawn_key[1], @intCast(st.non_pawn_material[0]), @intCast(st.non_pawn_material[1]), st.castling_rights, @intCast(st.rule50), @intCast(st.plies_from_null), @intFromEnum(st.ep_square), st.checkers };
    for (values) |v| {
        buffer[n] = v;
        n += 1;
    }
    for (st.blockers_for_king) |v| {
        buffer[n] = v;
        n += 1;
    }
    for (st.pinners) |v| {
        buffer[n] = v;
        n += 1;
    }
    for (st.check_squares[1..7]) |v| {
        buffer[n] = v;
        n += 1;
    }
    for ([_]u64{ @intFromEnum(st.captured_piece), @bitCast(@as(i64, st.repetition)), @intCast(pos.game_ply), @intFromEnum(pos.side) }) |v| {
        buffer[n] = v;
        n += 1;
    }
    for ([_]u8{ 1, 2, 4, 8 }) |cr| {
        const can = st.castling_rights & cr != 0;
        buffer[n] = @intFromBool(can);
        n += 1;
        buffer[n] = if (can) @intFromEnum(pos.castling_rook[cr]) else 64;
        n += 1;
        buffer[n] = @intFromBool(can and pos.pieces() & pos.castling_path[cr] != 0);
        n += 1;
    }
    for (0..64) |i| {
        buffer[n] = pos.attackersTo(@enumFromInt(i), pos.pieces());
        n += 1;
    }
    return buffer[0..n];
}

fn expectMoves(expected: []const u16, actual: []const z.types.Move) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, m| try std.testing.expectEqual(e, m.data);
}

fn expectQueries(pos: *const z.position.Position, expected: @import("position_reference").Snapshot) !void {
    var list: z.movegen.MoveList = .{};
    z.movegen.generate(.legal, pos, &list);
    try std.testing.expectEqual(expected.queries.len, list.len);
    for (list.slice(), expected.queries) |move, flags| {
        var actual: u32 = @intFromBool(pos.capture(move));
        actual |= @as(u32, @intFromBool(pos.captureStage(move))) << 1;
        actual |= @as(u32, @intFromBool(pos.givesCheck(move))) << 2;
        actual |= @as(u32, @intFromBool(pos.pseudoLegal(move))) << 3;
        for ([_]i32{ -3000, -1276, -825, -208, -1, 0, 1, 208, 781, 825, 1276, 2538, 3000 }, 4..) |threshold, bit| {
            actual |= @as(u32, @intFromBool(pos.seeGe(move, threshold))) << @as(u5, @intCast(bit));
        }
        try std.testing.expectEqual(flags, actual);
    }
    for ([_]i32{ 0, 1, 2, 3, 4, 5, 8, 32 }, expected.draw_flags) |ply, flags| {
        var actual: u8 = @intFromBool(pos.isDraw(ply));
        actual |= @as(u8, @intFromBool(pos.isRepetition(ply))) << 1;
        actual |= @as(u8, @intFromBool(pos.hasRepeated())) << 2;
        actual |= @as(u8, @intFromBool(pos.upcomingRepetition(ply))) << 3;
        try std.testing.expectEqual(flags, actual);
    }
}

test "TT layout, probe, replacement, aging and hashfull match C++ trace" {
    const reference = @import("tt_reference");
    var storage: [1024]z.tt.Cluster align(64) = undefined;
    var table = z.tt.Table.init(&storage);
    for (reference.events, 0..) |event, i| {
        if (i % 37 == 0) table.newSearch();
        const probe = table.probe(event.key);
        try std.testing.expectEqual(event.found, probe.found);
        const base = &table.clusters[table.clusterIndex(event.key)].entries[0];
        const slot = (@intFromPtr(probe.writer) - @intFromPtr(base)) / @sizeOf(z.tt.Entry);
        try std.testing.expectEqual(event.slot, slot);
        try std.testing.expectEqualSlices(i32, &event.before, &ttData(probe.data));
        const signed_i: i32 = @intCast(i);
        probe.writer.save(event.key, .{
            .value = if (i % 11 == 0) 31900 else @mod(signed_i, 4000) - 2000,
            .is_pv = i % 3 == 0,
            .bound = @enumFromInt(i % 4),
            .depth = @mod(signed_i, 32) - 2,
            .move = .{ .data = @intCast(if (i % 5 == 0) 0 else 1 + i % 4094) },
            .eval = @mod(signed_i, 2000) - 1000,
        }, table.generation);
        if (i % 7 == 0) probe.writer.penalize(@intCast(i % 17));
        try std.testing.expectEqualSlices(i32, &event.after, &ttData(probe.writer.read()));
        try std.testing.expectEqual(event.generation, table.generation);
        for ([_]i32{ 0, 3, 31 }, event.hashfull) |age, expected| try std.testing.expectEqual(expected, table.hashfull(age));
    }
    var entry: z.tt.Entry = std.mem.zeroes(z.tt.Entry);
    const commands = [_]struct { key: u64, value: i32, bound: z.tt.Bound, depth: i32, move: u16, eval: i32, generation: u8 }{
        .{ .key = 1, .value = 31900, .bound = .lower, .depth = 12, .move = 123, .eval = 7, .generation = 0 },
        .{ .key = 1, .value = 20, .bound = .lower, .depth = 1, .move = 0, .eval = 8, .generation = 0 },
        .{ .key = 1, .value = 20, .bound = .exact, .depth = -2, .move = 0, .eval = 8, .generation = 0 },
        .{ .key = 2, .value = -31900, .bound = .upper, .depth = 5, .move = 0, .eval = 9, .generation = 31 },
        .{ .key = 2, .value = 100, .bound = .upper, .depth = 0, .move = 42, .eval = 10, .generation = 0 },
    };
    for (commands, 0..) |cmd, i| {
        entry.save(cmd.key, .{ .move = .{ .data = cmd.move }, .value = cmd.value, .eval = cmd.eval, .depth = cmd.depth, .bound = cmd.bound, .is_pv = false }, cmd.generation);
        try std.testing.expectEqualSlices(i32, &reference.edge_cases[i], &ttData(entry.read()));
    }
    entry.penalize(300);
    try std.testing.expectEqualSlices(i32, &reference.edge_cases[5], &ttData(entry.read()));
    table.clear();
    try std.testing.expectEqual(@as(u8, 0), table.generation);
    try std.testing.expectEqual(@as(u32, 0), table.hashfull(31));
}
fn ttData(data: z.tt.Data) [6]i32 {
    return .{ data.move.data, data.value, data.eval, data.depth, @intFromEnum(data.bound), @intFromBool(data.is_pv) };
}

fn expectDirties(expected: @import("position_reference").Snapshot, actual: *const z.dirty.Dirties) !void {
    const d = actual.piece;
    const piece = [_]u8{ @intFromEnum(d.pc), @intFromEnum(d.from), @intFromEnum(d.to), @intFromEnum(d.remove_sq), @intFromEnum(d.add_sq), @intFromEnum(d.remove_pc), @intFromEnum(d.add_pc) };
    try std.testing.expectEqualSlices(u8, expected.dirty_piece, &piece);
    try std.testing.expectEqual(expected.dirty_threats.len, actual.threats.len);
    for (expected.dirty_threats, actual.threats.list[0..actual.threats.len]) |e, threat| try std.testing.expectEqual(e, threat.data);
    const pawns = actual.before ++ actual.after;
    try std.testing.expectEqualSlices(u64, expected.dirty_pawns, &pawns);
}
