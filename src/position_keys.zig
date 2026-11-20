// Derived from Stockfish Zobrist keys and repetition table in position.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const attacks = @import("attacks.zig");
const bb = @import("bitboard.zig");
const Prng = @import("prng.zig").Prng;

pub const pieces = [_]t.Piece{
    .white_pawn, .white_knight, .white_bishop, .white_rook, .white_queen, .white_king,
    .black_pawn, .black_knight, .black_bishop, .black_rook, .black_queen, .black_king,
};

pub const repetition_table_size = 8192;
pub const repetition_table_mask = repetition_table_size - 1;

/// Startup-only initialization; publish as immutable data to search workers.
pub const PositionKeys = struct {
    psq: [16][64]u64,
    enpassant: [8]u64,
    castling: [16]u64,
    /// Robin Hood table of reversible-move keys for upcoming-repetition detection.
    repetition_keys: [repetition_table_size]u64,
    repetition_moves: [repetition_table_size]t.Move,
    /// Zero marks an empty slot; occupied probe distances are one-based.
    repetition_distances: [repetition_table_size]u8,

    /// The least significant bit of every key stores the side to move.
    pub const side: u64 = 1;

    pub fn repetitionHash(key: u64) usize {
        return @intCast(key & repetition_table_mask);
    }

    pub fn init(self: *PositionKeys) void {
        var rng = Prng.init(1070372);
        self.psq = @splat(@splat(0));
        for (pieces) |pc| {
            for (&self.psq[@backingInt(pc)]) |*key| key.* = rng.next() << 1;
        }
        @memset(self.psq[@backingInt(t.Piece.white_pawn)][56..64], 0);
        @memset(self.psq[@backingInt(t.Piece.black_pawn)][0..8], 0);
        for (&self.enpassant) |*key| key.* = rng.next() << 1;
        for (&self.castling) |*key| key.* = rng.next() << 1;
        self.repetition_keys = @splat(0);
        self.repetition_moves = @splat(t.Move.none);
        self.repetition_distances = @splat(0);
        var count: usize = 0;
        for (pieces) |pc| {
            const pt = pc.pieceType();
            if (pt == .pawn) continue;
            for (0..64) |a| {
                for (a + 1..64) |b| {
                    if (attacks.pseudo[@backingInt(pt)][a] & bb.square(@fromBackingInt(@intCast(b))) == 0) continue;
                    var move = t.Move.make(
                        .normal,
                        @fromBackingInt(@intCast(a)),
                        @fromBackingInt(@intCast(b)),
                        .knight,
                    );
                    var key = self.psq[@backingInt(pc)][a] ^ self.psq[@backingInt(pc)][b] ^ side;
                    var index = repetitionHash(key);
                    var distance: u32 = 1;
                    while (true) {
                        // Upstream rejects tables whose displacement exceeds one byte at compile time.
                        std.debug.assert(distance <= 255);
                        if (self.repetition_distances[index] == 0) {
                            self.repetition_keys[index] = key;
                            self.repetition_moves[index] = move;
                            self.repetition_distances[index] = @intCast(distance);
                            break;
                        }
                        if (self.repetition_distances[index] < distance) {
                            std.mem.swap(u64, &self.repetition_keys[index], &key);
                            std.mem.swap(t.Move, &self.repetition_moves[index], &move);
                            const displaced = self.repetition_distances[index];
                            self.repetition_distances[index] = @intCast(distance);
                            distance = displaced;
                        }
                        distance += 1;
                        index = (index + 1) & repetition_table_mask;
                    }
                    count += 1;
                }
            }
        }
        std.debug.assert(count == 3668);
    }
};
