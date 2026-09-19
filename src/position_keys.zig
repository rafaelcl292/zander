// Derived from Stockfish Position::init in position.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const attacks = @import("attacks.zig");
const bb = @import("bitboard.zig");
const Prng = @import("prng.zig").Prng;

pub const pieces = [_]t.Piece{
    .white_pawn, .white_knight, .white_bishop, .white_rook, .white_queen, .white_king,
    .black_pawn, .black_knight, .black_bishop, .black_rook, .black_queen, .black_king,
};

/// Startup-only initialization; publish as immutable data to search workers.
pub const PositionKeys = struct {
    psq: [16][64]u64,
    enpassant: [8]u64,
    castling: [16]u64,
    side: u64,
    no_pawns: u64,
    cuckoo: [8192]u64,
    cuckoo_move: [8192]t.Move,

    pub fn h1(key: u64) usize {
        return @intCast(key & 0x1fff);
    }
    pub fn h2(key: u64) usize {
        return @intCast((key >> 16) & 0x1fff);
    }

    pub fn init(self: *PositionKeys) void {
        var rng = Prng.init(1070372);
        self.psq = @splat(@splat(0));
        for (pieces) |pc| {
            for (&self.psq[@intFromEnum(pc)]) |*key| key.* = rng.next();
        }
        @memset(self.psq[@intFromEnum(t.Piece.white_pawn)][56..64], 0);
        @memset(self.psq[@intFromEnum(t.Piece.black_pawn)][0..8], 0);
        for (&self.enpassant) |*key| key.* = rng.next();
        for (&self.castling) |*key| key.* = rng.next();
        self.side = rng.next();
        self.no_pawns = rng.next();
        self.cuckoo = @splat(0);
        self.cuckoo_move = @splat(t.Move.none);
        var count: usize = 0;
        for (pieces) |pc| {
            const pt = pc.pieceType();
            if (pt == .pawn) continue;
            for (0..64) |a| {
                for (a + 1..64) |b| {
                    if (attacks.pseudo[@intFromEnum(pt)][a] & bb.square(@enumFromInt(b)) == 0) continue;
                    var move = t.Move.make(.normal, @enumFromInt(a), @enumFromInt(b), .knight);
                    var key = self.psq[@intFromEnum(pc)][a] ^ self.psq[@intFromEnum(pc)][b] ^ self.side;
                    var index = h1(key);
                    while (true) {
                        std.mem.swap(u64, &self.cuckoo[index], &key);
                        std.mem.swap(t.Move, &self.cuckoo_move[index], &move);
                        if (move.data == t.Move.none.data) break;
                        index = if (index == h1(key)) h2(key) else h1(key);
                    }
                    count += 1;
                }
            }
        }
        std.debug.assert(count == 3668);
    }
};
