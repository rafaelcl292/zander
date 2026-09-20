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
            try expectDirties(&pos, child, &dirties);
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
            try expectDirties(&pos, step, &dirties);
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
        try expectDirties(&pos, step, &dirties);
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
    try expectActiveFeatures(pos, expected);
    var list: z.movegen.MoveList = .{};
    z.movegen.generate(.legal, pos, &list);
    try std.testing.expectEqual(expected.queries.len, list.len);
    for (list.slice(), expected.prefetch_keys) |move, key| try std.testing.expectEqual(key, pos.prefetchKey(move));
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

fn expectDirties(pos: *const z.position.Position, expected: @import("position_reference").Snapshot, actual: *const z.dirty.Dirties) !void {
    try expectChangedFeatures(pos, expected, actual);
    const d = actual.piece;
    const piece = [_]u8{ @intFromEnum(d.pc), @intFromEnum(d.from), @intFromEnum(d.to), @intFromEnum(d.remove_sq), @intFromEnum(d.add_sq), @intFromEnum(d.remove_pc), @intFromEnum(d.add_pc) };
    try std.testing.expectEqualSlices(u8, expected.dirty_piece, &piece);
    try std.testing.expectEqual(expected.dirty_threats.len, actual.threats.len);
    for (expected.dirty_threats, actual.threats.list[0..actual.threats.len]) |e, threat| try std.testing.expectEqual(e, threat.data);
    const pawns = actual.before ++ actual.after;
    try std.testing.expectEqualSlices(u64, expected.dirty_pawns, &pawns);
}

fn expectActiveFeatures(pos: *const z.position.Position, expected: @import("position_reference").Snapshot) !void {
    const features = z.nnue_features;
    for ([_]z.types.Color{ .white, .black }, expected.features) |c, ref| {
        var half: features.SmallList = .{};
        var occupied = pos.pieces();
        while (occupied != 0) {
            const square = z.bitboard.popLsb(&occupied);
            half.append(features.HalfKA.makeIndex(c, square, pos.pieceOn(square), pos.king(c)));
        }
        var threats: features.ThreatList = .{};
        var pawns: features.ThreatList = .{};
        features.FullThreats.appendActive(c, pos, &threats);
        features.PawnPairs.appendActive(c, pos, &pawns);
        try std.testing.expectEqualSlices(u16, ref.half, half.slice());
        try std.testing.expectEqualSlices(u16, ref.threats, threats.slice());
        try std.testing.expectEqualSlices(u16, ref.pawns, pawns.slice());
    }
}
fn expectChangedFeatures(pos: *const z.position.Position, expected: @import("position_reference").Snapshot, diff: *const z.dirty.Dirties) !void {
    const features = z.nnue_features;
    for ([_]z.types.Color{ .white, .black }, expected.features) |c, ref| {
        var hr: features.SmallList = .{};
        var ha: features.SmallList = .{};
        var tr: features.ThreatList = .{};
        var ta: features.ThreatList = .{};
        var pr: features.ThreatList = .{};
        var pa: features.ThreatList = .{};
        features.HalfKA.appendChanged(c, pos.king(c), diff.piece, &hr, &ha);
        features.FullThreats.appendChanged(c, pos.king(c), &diff.threats, &tr, &ta);
        features.PawnPairs.appendChanged(c, pos.king(c), diff.before, diff.after, &pr, &pa);
        try std.testing.expectEqualSlices(u16, ref.half_removed, hr.slice());
        try std.testing.expectEqualSlices(u16, ref.half_added, ha.slice());
        try std.testing.expectEqualSlices(u16, ref.threats_removed, tr.slice());
        try std.testing.expectEqualSlices(u16, ref.threats_added, ta.slice());
        try std.testing.expectEqualSlices(u16, ref.pawns_removed, pr.slice());
        try std.testing.expectEqualSlices(u16, ref.pawns_added, pa.slice());
        try std.testing.expectEqual(ref.refresh, features.HalfKA.requiresRefresh(diff.piece, c));
    }
}

test "NNUE index spaces match C++ across kings, pieces, threats and pawn pairs" {
    const f = z.nnue_features;
    var hashes: [3]u64 = @splat(14695981039346656037);
    for ([_]z.types.Color{ .white, .black }) |c| {
        for (0..64) |k| for (0..64) |s| for (z.position_keys.pieces) |pc| {
            hashes[0] = (hashes[0] ^ f.HalfKA.makeIndex(c, @enumFromInt(s), pc, @enumFromInt(k))) *% 1099511628211;
        };
        // FullThreats and PP orientation depends only on king file half.
        for ([_]u8{ 0, 7 }) |k| {
            for (z.position_keys.pieces) |pc| for (0..64) |from| {
                var targets = z.attacks.pseudo[if (pc.pieceType() == .pawn) @intFromEnum(pc.color()) else @intFromEnum(pc.pieceType())][from];
                while (targets != 0) {
                    const to = z.bitboard.popLsb(&targets);
                    for (z.position_keys.pieces) |target| {
                        hashes[1] = (hashes[1] ^ f.FullThreats.makeIndex(c, pc, @enumFromInt(from), to, target, @enumFromInt(k))) *% 1099511628211;
                    }
                }
            };
            for (0..96) |first| for (first + 1..96) |second| {
                const color: z.types.Color = @enumFromInt(first / 48);
                const paired: z.types.Color = @enumFromInt(second / 48);
                const from: z.types.Square = @enumFromInt(first % 48 + 8);
                const to: z.types.Square = @enumFromInt(second % 48 + 8);
                hashes[2] = (hashes[2] ^ f.PawnPairs.makeIndex(c, color, from, to, paired, @enumFromInt(k))) *% 1099511628211;
            };
        }
    }
    try std.testing.expectEqualSlices(u64, &@import("position_reference").index_checksums, &hashes);
}

test "NNUE scalar layers and compressed parameters match C++" {
    const reference = @import("nnue_reference");
    var reader: z.nnue_reader.Reader = .{ .bytes = &reference.parameters };
    var network: z.nnue_layers.Architecture = undefined;
    try network.read(&reader);
    try std.testing.expectEqual(reference.parameters.len, reader.offset);
    try std.testing.expectEqual(reference.architecture_hash, z.nnue_layers.Architecture.hash());
    for (&reference.cases) |*case| {
        var buffer: z.nnue_layers.Architecture.Buffer = undefined;
        try std.testing.expectEqual(case.result, network.propagate(&case.input, &buffer));
        try std.testing.expectEqualSlices(i32, &case.fc0, &buffer.fc0);
        try std.testing.expectEqualSlices(u8, &case.concat, &buffer.concat);
        try std.testing.expectEqualSlices(i32, &case.fc1, &buffer.fc1);
        try std.testing.expectEqual(case.fc2, buffer.fc2[0]);
    }
    reader = .{ .bytes = &reference.compressed };
    var shorts: [8]i16 = undefined;
    var longs: [8]i32 = undefined;
    try reader.leb128(i16, &shorts);
    try reader.leb128(i32, &longs);
    try std.testing.expectEqualSlices(i16, &.{ -32768, -8192, -65, -1, 0, 64, 8192, 32767 }, &shorts);
    try std.testing.expectEqualSlices(i32, &.{ std.math.minInt(i32), -2097152, -8193, -1, 0, 8192, 2097152, std.math.maxInt(i32) }, &longs);
    try std.testing.expectEqual(reference.compressed.len, reader.offset);
    reader = .{ .bytes = reference.parameters[0 .. reference.parameters.len - 1] };
    try std.testing.expectError(error.Truncated, network.read(&reader));
}

test "history saturation, atomic entries and storage sizes match Stockfish" {
    const reference = @import("history_reference");
    inline for (.{ .{ 7183, false }, .{ 10692, false }, .{ 30000, true }, .{ 8192, true }, .{ 8192, false }, .{ 1024, true }, .{ 1024, false } }) |spec| {
        var value: z.history.StatsEntry(spec[0], spec[1]) = undefined;
        for (reference.cases) |case| {
            if (case.limit != spec[0] or case.shared != spec[1]) continue;
            if (case.bonus == std.math.minInt(i32)) value.set(case.initial);
            value.update(case.bonus);
            try std.testing.expectEqual(case.result, value.get());
        }
    }
    inline for (.{ z.history.ButterflyHistory, z.history.LowPlyHistory, z.history.CapturePieceToHistory, z.history.PieceToHistory, z.history.ContinuationHistoryBlock, z.history.CorrectionBundle, z.history.PieceToCorrectionHistory, z.history.ContinuationCorrectionHistory }, 0..) |T, i| {
        try std.testing.expectEqual(reference.sizes[i], @sizeOf(T));
    }
}

test "shared history storage partitions and key masks preserve capacities" {
    const h = z.history;
    const allocator = std.testing.allocator;
    const correction = try allocator.alloc(h.CorrectionEntry, h.correction_history_base_size * 2);
    defer allocator.free(correction);
    const pawn = try allocator.alloc(h.PawnEntry, h.pawn_history_base_size * 2);
    defer allocator.free(pawn);
    const continuation = try allocator.create(h.ContinuationHistoryBlock);
    defer allocator.destroy(continuation);
    try std.testing.expectError(error.InvalidThreadCount, h.SharedHistories.init(0, correction, continuation, pawn));
    try std.testing.expectError(error.InvalidThreadCount, h.SharedHistories.init(3, correction, continuation, pawn));
    try std.testing.expectError(error.InvalidStorageSize, h.SharedHistories.init(1, correction, continuation, pawn));
    var shared = try h.SharedHistories.init(2, correction, continuation, pawn);
    for (correction) |*entry| h.fill(entry, 123);
    for (pawn) |*entry| h.fill(entry, 456);
    // A non-divisor worker count exercises integer partition boundaries.
    shared.clearRange(1, 3);
    for (correction, 0..) |*entry, i| for (entry) |*bundle| {
        const expected: i16 = if (i >= correction.len / 3 and i < correction.len * 2 / 3) -5 else 123;
        try std.testing.expectEqual(expected, bundle.pawn.get());
        try std.testing.expectEqual(expected, bundle.minor.get());
        try std.testing.expectEqual(expected, bundle.non_pawn_white.get());
        try std.testing.expectEqual(expected, bundle.non_pawn_black.get());
    };
    for (pawn, 0..) |*entry, i| for (entry) |*piece| for (piece) |*value| {
        try std.testing.expectEqual(@as(i16, if (i >= pawn.len / 3 and i < pawn.len * 2 / 3) -1338 else 456), value.get());
    };
    shared.clearRange(0, 3);
    shared.clearRange(2, 3);
    try std.testing.expectEqual(@as(i16, -586), continuation[1][1][15][63][15][63].get());
    var state: z.position.StateInfo = undefined;
    var pos: z.position.Position = undefined;
    pos.st = &state;
    for ([_]u64{ 0, 8191, 8192, 16383, 65535, 65536, 131071, std.math.maxInt(u64) }) |key| {
        state.pawn_key = key;
        state.minor_piece_key = key ^ 42;
        state.non_pawn_key = .{ key ^ 65536, key ^ 12345 };
        try std.testing.expect(shared.pawnEntry(&pos) == &pawn[key & 16383]);
        try std.testing.expect(shared.pawnCorrectionEntry(&pos) == &correction[key & 131071]);
        try std.testing.expect(shared.minorCorrectionEntry(&pos) == &correction[(key ^ 42) & 131071]);
        try std.testing.expect(shared.nonPawnCorrectionEntry(&pos, .white) == &correction[(key ^ 65536) & 131071]);
        try std.testing.expect(shared.nonPawnCorrectionEntry(&pos, .black) == &correction[(key ^ 12345) & 131071]);
    }
}

fn historySample(seed: u64, index: usize, limit: i32) i16 {
    return @intCast(@as(i32, @intCast((z.types.makeKey(seed ^ index) >> 32) % @as(u32, @intCast(2 * limit + 1)))) - limit);
}
test "staged move ordering matches Stockfish with varied histories and TT moves" {
    const h = z.history;
    const allocator = std.testing.allocator;
    const main = try allocator.create(h.ButterflyHistory);
    defer allocator.destroy(main);
    const low = try allocator.create(h.LowPlyHistory);
    defer allocator.destroy(low);
    const capture = try allocator.create(h.CapturePieceToHistory);
    defer allocator.destroy(capture);
    const continuation = try allocator.create([6]h.PieceToHistory);
    defer allocator.destroy(continuation);
    var ch: [6]*const h.PieceToHistory = undefined;
    const correction = try allocator.alloc(h.CorrectionEntry, h.correction_history_base_size);
    defer allocator.free(correction);
    const pawn = try allocator.alloc(h.PawnEntry, h.pawn_history_base_size);
    defer allocator.free(pawn);
    const block = try allocator.create(h.ContinuationHistoryBlock);
    defer allocator.destroy(block);
    var shared = try h.SharedHistories.init(1, correction, block, pawn);
    const tables = try allocator.create(z.attacks.Tables);
    defer allocator.destroy(tables);
    tables.init();
    const keys = try allocator.create(z.position_keys.PositionKeys);
    defer allocator.destroy(keys);
    keys.init();
    var current_pattern: ?bool = null;
    for (@import("movepick_reference").cases, 0..) |case, case_index| {
        if (current_pattern == null or current_pattern.? != case.flat) {
            current_pattern = case.flat;
            for (main, 0..) |*color, c| for (color, 0..) |*entry, m| entry.set(if (case.flat) 0 else historySample(11, c * 65536 + m, 7183));
            for (low, 0..) |*ply, p| for (ply, 0..) |*entry, m| entry.set(if (case.flat) 0 else historySample(22, p * 65536 + m, 7183));
            for (capture, 0..) |*piece, pc| for (piece, 0..) |*dest, to| for (dest, 0..) |*entry, cap| entry.set(if (case.flat) 0 else historySample(33, (pc * 64 + to) * 8 + cap, 10692));
            for (continuation, 0..) |*table, j| {
                ch[j] = table;
                for (table, 0..) |*piece, pc| for (piece, 0..) |*entry, to| entry.set(if (case.flat) 0 else historySample(44, (j * 16 + pc) * 64 + to, 30000));
            }
        }

        errdefer std.debug.print("Move ordering case {d}, FEN {s}\n", .{ case_index, case.fen });
        var state: z.position.StateInfo = undefined;
        var pos: z.position.Position = undefined;
        try pos.set(case.fen, case.chess960, &state, tables, keys);
        for (shared.pawnEntry(&pos), 0..) |*piece, pc| for (piece, 0..) |*entry, to| entry.set(if (case.flat) 0 else historySample(55, pc * 64 + to, 8192));
        var picker = if (case.probcut) z.movepick.MovePicker.initProbcut(&pos, .{ .data = case.tt }, case.threshold, capture) else z.movepick.MovePicker.init(&pos, .{ .data = case.tt }, case.depth, .{ .main = main, .low_ply = low, .capture = capture, .continuation = if (case.depth > 0) &ch else ch[0..1], .shared = &shared }, case.ply);
        for (case.moves, 0..) |expected, i| {
            if (i == case.skip_after) picker.skipQuietMoves();
            try std.testing.expectEqual(expected, picker.next().data);
        }
        if (case.moves.len == case.skip_after) picker.skipQuietMoves();
        try std.testing.expectEqual(@as(u16, 0), picker.next().data);
        try std.testing.expectEqual(@as(u16, 0), picker.next().data);
    }
}

test "search score conversion, continuation bonuses and PVs match Stockfish" {
    const reference = @import("search_reference");
    const search = z.search_support;
    for (reference.scores) |case| {
        if (case.score != z.types.value_none) try std.testing.expectEqual(case.stored, search.valueToTT(case.score, case.ply));
        try std.testing.expectEqual(case.restored, search.valueFromTT(case.score, case.ply, case.rule50));
    }
    for (reference.corrections) |case| try std.testing.expectEqual(case.result, search.correctedStaticEval(case.value, case.correction));
    for (reference.divisors, 0..) |expected, depth| try std.testing.expectEqual(expected, search.lmrDivisor(@intCast(depth)));
    const tables = try std.testing.allocator.create([6]z.history.PieceToHistory);
    defer std.testing.allocator.destroy(tables);
    var frames: [7]search.Stack = @splat(.{});
    for (reference.continuations) |case| {
        frames[6].in_check = case.in_check;
        for (tables, case.initial, 0..) |*table, initial, i| {
            table[2][18].set(initial);
            frames[5 - i].continuation_history = table;
            frames[5 - i].current_move = if (case.valid & (@as(u8, 1) << @as(u3, @intCast(i))) != 0) .{ .data = (8 << 6) + 16 } else .null_move;
        }
        search.updateContinuationHistories(&frames, 6, .white_knight, @enumFromInt(18), case.bonus);
        for (tables, case.result) |*table, expected| try std.testing.expectEqual(expected, table[2][18].get());
    }
    var child: search.PV = .{};
    var pv: search.PV = .{};
    for (0..z.types.max_ply) |i| child.append(.{ .data = @intCast(i + 100) });
    pv.update(.{ .data = 400 }, &child);
    for (reference.pv, pv.slice()) |expected, move| try std.testing.expectEqual(expected, move.data);
    child.assignRoot(pv.slice());
    try std.testing.expectEqual(z.types.max_ply, child.len);
    try std.testing.expectEqual(@as(u16, 400), child.moves[0].data);
    pv.resize(1);
    try std.testing.expectEqual(@as(usize, 1), pv.len);
    pv.clear();
    try std.testing.expectEqual(@as(usize, 0), pv.len);
    pv.update(.{ .data = 123 }, null);
    try std.testing.expectEqual(@as(usize, 1), pv.len);
    try std.testing.expectEqual(@as(u16, 123), pv.moves[0].data);
    for (0..100) |nodes| try std.testing.expectEqual(@as(i32, if (nodes % 4 < 2) -1 else 1), search.drawValue(nodes));
}
