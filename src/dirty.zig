// Derived from Stockfish types.h; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
pub const DirtyPiece = struct {
    pc: t.Piece = .none,
    from: t.Square = .none,
    to: t.Square = .none,
    remove_sq: t.Square = .none,
    add_sq: t.Square = .none,
    remove_pc: t.Piece = .none,
    add_pc: t.Piece = .none,
};
pub const DirtyThreat = extern struct {
    data: u32,
    pub fn init(pc: t.Piece, threatened_pc: t.Piece, pc_sq: t.Square, threatened_sq: t.Square, add: bool) DirtyThreat {
        return .{ .data = (@as(u32, @intFromBool(add)) << 31) | (@as(u32, @intFromEnum(pc)) << 20) | (@as(u32, @intFromEnum(threatened_pc)) << 16) | (@as(u32, @intFromEnum(threatened_sq)) << 8) | @intFromEnum(pc_sq) };
    }
};
pub const DirtyThreats = struct {
    // Upstream bound: 80 changed features plus 16 SIMD-store padding entries.
    list: [96]DirtyThreat = undefined,
    len: usize = 0,
    pub fn append(self: *DirtyThreats, threat: DirtyThreat) void {
        std.debug.assert(self.len < self.list.len);
        self.list[self.len] = threat;
        self.len += 1;
    }
};
pub const Dirties = struct {
    piece: DirtyPiece = .{},
    threats: DirtyThreats = .{},
    before: [2]u64 = @splat(0),
    after: [2]u64 = @splat(0),
};
comptime {
    std.debug.assert(@sizeOf(DirtyThreat) == 4);
}
