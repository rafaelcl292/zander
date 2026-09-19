// Derived from Stockfish attacks.h/attacks.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const bb = @import("bitboard.zig");

pub fn safeDestination(s: t.Square, step: i16) u64 {
    const dest = @as(i16, @intFromEnum(s)) + step;
    if (dest < 0 or dest >= 64) return 0;
    const to: t.Square = @enumFromInt(dest);
    return if (@abs(@as(i16, s.file()) - @as(i16, to.file())) <= 2) bb.square(to) else 0;
}
pub fn slidingAttack(pt: t.PieceType, s: t.Square, occupied: u64) u64 {
    std.debug.assert(pt == .bishop or pt == .rook);
    const dirs: [4]i16 = if (pt == .rook) .{ 8, -8, 1, -1 } else .{ 9, -7, -9, 7 };
    var result: u64 = 0;
    for (dirs) |d| {
        var cursor = s;
        while (true) {
            const dest = safeDestination(cursor, d);
            if (dest == 0) break;
            result |= dest;
            if (occupied & dest != 0) break;
            cursor = bb.lsb(dest);
        }
    }
    return result;
}
fn leaper(s: t.Square, steps: []const i16) u64 {
    var result: u64 = 0;
    for (steps) |d| result |= safeDestination(s, d);
    return result;
}
pub const pseudo = blk: {
    @setEvalBranchQuota(100000);
    var table: [8][64]u64 = @splat(@splat(0));
    for (0..64) |i| {
        const s: t.Square = @enumFromInt(i);
        table[0][i] = bb.pawnAttacks(.white, bb.square(s));
        table[1][i] = bb.pawnAttacks(.black, bb.square(s));
        table[2][i] = leaper(s, &.{ -17, -15, -10, -6, 6, 10, 15, 17 });
        table[3][i] = slidingAttack(.bishop, s, 0);
        table[4][i] = slidingAttack(.rook, s, 0);
        table[5][i] = table[3][i] | table[4][i];
        table[6][i] = leaper(s, &.{ -9, -8, -7, -1, 1, 7, 8, 9 });
    }
    break :blk table;
};

const Prng = @import("prng.zig").Prng;
pub const Magic = struct {
    mask: u64,
    attacks: [*]u64,
    magic: u64,
    shift: u6,
    pub fn index(self: Magic, occupied: u64) usize {
        return @intCast(((occupied & self.mask) *% self.magic) >> self.shift);
    }
};

/// Initialize in final storage before sharing with workers. Do not move or copy
/// after init: magic pointers refer into this object's fixed backing tables.
/// This ports upstream's generic 64-bit magic path, not AVX2/ARM HQ paths.
pub const Tables = struct {
    magics: [64][2]Magic align(64),
    rook: [0x19000]u64,
    bishop: [0x1480]u64,
    line: [64][64]u64,
    between: [64][64]u64,
    ray_pass: [64][64]u64,

    pub fn init(self: *Tables) void {
        self.initMagics(.rook, &self.rook);
        self.initMagics(.bishop, &self.bishop);
        self.line = @splat(@splat(0));
        self.between = @splat(@splat(0));
        self.ray_pass = @splat(@splat(0));
        for (0..64) |a| {
            const s1: t.Square = @enumFromInt(a);
            for ([_]t.PieceType{ .bishop, .rook }) |pt| {
                for (0..64) |b| {
                    const s2: t.Square = @enumFromInt(b);
                    if (pseudo[@intFromEnum(pt)][a] & bb.square(s2) != 0) {
                        self.line[a][b] = (self.attacks(pt, s1, 0) & self.attacks(pt, s2, 0)) | bb.square(s1) | bb.square(s2);
                        self.between[a][b] = self.attacks(pt, s1, bb.square(s2)) & self.attacks(pt, s2, bb.square(s1));
                        self.ray_pass[a][b] = self.attacks(pt, s1, 0) & (self.attacks(pt, s2, bb.square(s1)) | bb.square(s2));
                    }
                    self.between[a][b] |= bb.square(s2);
                }
            }
        }
    }
    pub fn attacks(self: *const Tables, pt: t.PieceType, s: t.Square, occupied: u64) u64 {
        std.debug.assert(s.valid() and pt != .pawn and pt != .none);
        return switch (pt) {
            .bishop, .rook => blk: {
                const m = self.magics[@intFromEnum(s)][@intFromEnum(pt) - 3];
                break :blk m.attacks[m.index(occupied)];
            },
            .queen => self.attacks(.bishop, s, occupied) | self.attacks(.rook, s, occupied),
            else => pseudo[@intFromEnum(pt)][@intFromEnum(s)],
        };
    }
    fn initMagics(self: *Tables, pt: t.PieceType, backing: []u64) void {
        const seeds = [_]u64{ 728, 10316, 55013, 32803, 12281, 15100, 16645, 255 };
        var occupancy: [4096]u64 = undefined;
        var reference: [4096]u64 = undefined;
        var epoch: [4096]u64 = @splat(0);
        var count: u64 = 0;
        var offset: usize = 0;
        for (0..64) |i| {
            const s: t.Square = @enumFromInt(i);
            const rank = @as(u64, 0xff) << (@as(u6, s.rank()) * 8);
            const file = bb.file_a << s.file();
            const edges = ((@as(u64, 0xff000000000000ff)) & ~rank) | ((bb.file_a | bb.file_h) & ~file);
            const m = &self.magics[i][@intFromEnum(pt) - 3];
            m.mask = slidingAttack(pt, s, 0) & ~edges;
            m.shift = @intCast(64 - @popCount(m.mask));
            m.attacks = backing[offset..].ptr;
            var size: usize = 0;
            var b: u64 = 0;
            while (true) {
                occupancy[size] = b;
                reference[size] = slidingAttack(pt, s, b);
                size += 1;
                b = (b -% m.mask) & m.mask;
                if (b == 0) break;
            }
            std.debug.assert(offset + size <= backing.len);
            var rng = Prng.init(seeds[s.rank()]);
            while (true) {
                m.magic = 0;
                while (@popCount((m.magic *% m.mask) >> 56) < 6) m.magic = rng.sparse();
                count += 1;
                var j: usize = 0;
                while (j < size) : (j += 1) {
                    const index = m.index(occupancy[j]);
                    if (epoch[index] < count) {
                        epoch[index] = count;
                        m.attacks[index] = reference[j];
                    } else if (m.attacks[index] != reference[j]) break;
                }
                if (j == size) break;
            }
            offset += size;
        }
        std.debug.assert(offset == backing.len);
    }
};
