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
    }
    try std.testing.expectEqual(reference.positions.len, n);
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
    for (st.check_squares) |v| {
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
