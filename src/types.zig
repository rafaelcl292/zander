// Derived from Stockfish types.h; GPL-3.0-or-later. See AUTHORS.stockfish.
const std = @import("std");
pub const Key = u64;
pub const Bitboard = u64;
pub const Value = i32;
pub const Depth = i32;
pub const max_moves = 256;
pub const max_ply = 246;
pub const value_none: Value = 32002;
pub const value_infinite: Value = 32001;
pub const value_mate: Value = 32000;
pub const Color = enum(u8) {
    white,
    black,
    pub fn opposite(self: Color) Color {
        return @fromBackingInt(@intCast(@backingInt(self) ^ 1));
    }
};
pub const PieceType = enum(u8) { none, pawn, knight, bishop, rook, queen, king };
pub const Piece = enum(u8) {
    none = 0,
    white_pawn = 1,
    white_knight,
    white_bishop,
    white_rook,
    white_queen,
    white_king,
    black_pawn = 9,
    black_knight,
    black_bishop,
    black_rook,
    black_queen,
    black_king,
    pub fn make(c: Color, pt: PieceType) Piece {
        std.debug.assert(pt != .none);
        return @fromBackingInt(@intCast((@backingInt(c) << 3) + @backingInt(pt)));
    }
    pub fn pieceType(self: Piece) PieceType {
        return @fromBackingInt(@intCast(@backingInt(self) & 7));
    }
    pub fn color(self: Piece) Color {
        std.debug.assert(self != .none);
        return @fromBackingInt(@intCast(@backingInt(self) >> 3));
    }
};
// Preserve the upstream byte-sized representation, including SQ_NONE = 64.
pub const Square = enum(u8) {
    none = 64,
    _,
    pub fn make(f: u3, r: u3) Square {
        return @fromBackingInt(@intCast((@as(u8, r) << 3) + f));
    }
    pub fn valid(self: Square) bool {
        return @backingInt(self) < 64;
    }
    pub fn file(self: Square) u3 {
        std.debug.assert(self.valid());
        return @truncate(@backingInt(self));
    }
    pub fn rank(self: Square) u3 {
        std.debug.assert(self.valid());
        return @intCast(@backingInt(self) >> 3);
    }
    pub fn relative(self: Square, c: Color) Square {
        std.debug.assert(self.valid());
        return @fromBackingInt(@intCast(@backingInt(self) ^ (@backingInt(c) * 56)));
    }
};
pub const MoveType = enum(u16) { normal = 0, promotion = 1 << 14, en_passant = 2 << 14, castling = 3 << 14 };
pub const Move = extern struct {
    data: u16,
    pub const none: Move = .{ .data = 0 };
    pub const null_move: Move = .{ .data = 65 };
    pub fn make(move_type: MoveType, origin: Square, destination: Square, promotion: PieceType) Move {
        std.debug.assert(origin.valid() and destination.valid());
        std.debug.assert(@backingInt(promotion) >= 2 and @backingInt(promotion) <= 5);
        return .{ .data = @backingInt(move_type) + ((@as(u16, @backingInt(promotion)) - 2) << 12) + (@as(u16, @backingInt(origin)) << 6) + @backingInt(destination) };
    }
    pub fn valid(self: Move) bool {
        return self.data != 0 and self.data != 65;
    }
    pub fn from(self: Move) Square {
        std.debug.assert(self.valid());
        return @fromBackingInt(@intCast((self.data >> 6) & 63));
    }
    pub fn to(self: Move) Square {
        std.debug.assert(self.valid());
        return @fromBackingInt(@intCast(self.data & 63));
    }
    pub fn kind(self: Move) MoveType {
        return @fromBackingInt(@intCast(self.data & 0xc000));
    }
    pub fn promotionType(self: Move) PieceType {
        return @fromBackingInt(@intCast(((self.data >> 12) & 3) + 2));
    }
};
pub fn makeKey(seed: u64) Key {
    return seed *% 6364136223846793005 +% 1442695040888963407;
}
comptime {
    std.debug.assert(@sizeOf(Move) == 2);
    std.debug.assert(@sizeOf(Square) == 1);
}
test "sentinels and square mapping" {
    try std.testing.expect(!Move.none.valid());
    try std.testing.expect(!Move.null_move.valid());
    try std.testing.expectEqual(@as(u8, 60), @backingInt(Square.make(4, 0).relative(.black)));
    try std.testing.expectEqual(Color.black, Piece.black_queen.color());
}
