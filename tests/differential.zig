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
