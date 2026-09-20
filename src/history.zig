// Derived from Stockfish history.h; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const Position = @import("position.zig").Position;
pub const pawn_history_base_size = 8192;
pub const correction_history_base_size = 65536;
pub const low_ply_history_size = 5;
pub const correction_history_limit = 1024;

pub fn StatsEntry(comptime limit: i32, comptime shared: bool) type {
    std.debug.assert(limit > 0 and limit <= std.math.maxInt(i16));
    return extern struct {
        value: i16,
        pub fn get(self: *const @This()) i16 {
            return if (shared) @atomicLoad(i16, &self.value, .monotonic) else self.value;
        }
        pub fn set(self: *@This(), value: i16) void {
            if (shared) @atomicStore(i16, &self.value, value, .monotonic) else self.value = value;
        }
        /// Like upstream, shared updates are a relaxed load/store, not a
        /// read-modify-write operation: concurrent updates may be lost.
        pub fn update(self: *@This(), bonus: i32) void {
            const clamped = std.math.clamp(bonus, -limit, limit);
            const value: i32 = self.get();
            self.set(@intCast(value + clamped - @divTrunc(value * @as(i32, @intCast(@abs(clamped))), limit)));
            std.debug.assert(@abs(self.get()) <= limit);
        }
    };
}

pub const ButterflyHistory = [2][65536]StatsEntry(7183, false);
pub const LowPlyHistory = [low_ply_history_size][65536]StatsEntry(7183, false);
pub const CapturePieceToHistory = [16][64][8]StatsEntry(10692, false);
pub const PieceToHistory = [16][64]StatsEntry(30000, true);
pub const ContinuationHistory = [16][64]PieceToHistory;
pub const ContinuationHistoryBlock = [2][2]ContinuationHistory;
pub const PawnEntry = [16][64]StatsEntry(8192, true);
pub const PieceToCorrectionHistory = [16][64]StatsEntry(correction_history_limit, false);
pub const ContinuationCorrectionHistory = [16][64]PieceToCorrectionHistory;
pub const TTMoveHistory = StatsEntry(8192, false);
pub const CorrectionBundle = extern struct {
    pawn: StatsEntry(correction_history_limit, true),
    minor: StatsEntry(correction_history_limit, true),
    non_pawn_white: StatsEntry(correction_history_limit, true),
    non_pawn_black: StatsEntry(correction_history_limit, true),
    pub fn set(self: *CorrectionBundle, value: i16) void {
        self.pawn.set(value);
        self.minor.set(value);
        self.non_pawn_white.set(value);
        self.non_pawn_black.set(value);
    }
};
pub const CorrectionEntry = [2]CorrectionBundle;

pub fn fill(table: anytype, value: i16) void {
    const Child = std.meta.Child(@TypeOf(table));
    switch (@typeInfo(Child)) {
        .array => for (table) |*entry| fill(entry, value),
        else => table.set(value),
    }
}

/// Views of storage supplied by the owner before search. Allocation policy and
/// NUMA placement are outside this module; upstream capacities are preserved.
pub const SharedHistories = struct {
    correction: []CorrectionEntry,
    continuation: *ContinuationHistoryBlock,
    pawn: []PawnEntry,
    pub fn init(thread_count: usize, correction: []CorrectionEntry, continuation: *ContinuationHistoryBlock, pawn: []PawnEntry) !SharedHistories {
        if (thread_count == 0 or !std.math.isPowerOfTwo(thread_count)) return error.InvalidThreadCount;
        const correction_size = std.math.mul(usize, correction_history_base_size, thread_count) catch return error.InvalidThreadCount;
        const pawn_size = std.math.mul(usize, pawn_history_base_size, thread_count) catch return error.InvalidThreadCount;
        if (correction.len != correction_size or pawn.len != pawn_size) return error.InvalidStorageSize;
        return .{ .correction = correction, .continuation = continuation, .pawn = pawn };
    }
    /// Each worker clears its disjoint dynamic range. Worker zero clears the
    /// continuation block. Join all workers before using these histories.
    pub fn clearRange(self: *SharedHistories, thread_index: usize, numa_total: usize) void {
        std.debug.assert(numa_total > 0 and thread_index < numa_total and numa_total <= self.pawn.len);
        const correction_begin = thread_index * self.correction.len / numa_total;
        const correction_end = (thread_index + 1) * self.correction.len / numa_total;
        for (self.correction[correction_begin..correction_end]) |*entry| fill(entry, -5);
        const pawn_begin = thread_index * self.pawn.len / numa_total;
        const pawn_end = (thread_index + 1) * self.pawn.len / numa_total;
        for (self.pawn[pawn_begin..pawn_end]) |*entry| fill(entry, -1338);
        if (thread_index == 0) fill(self.continuation, -586);
    }
    pub fn pawnEntry(self: *const SharedHistories, pos: *const Position) *PawnEntry {
        return &self.pawn[pos.st.pawn_key & (self.pawn.len - 1)];
    }
    pub fn pawnCorrectionEntry(self: *const SharedHistories, pos: *const Position) *CorrectionEntry {
        return &self.correction[pos.st.pawn_key & (self.correction.len - 1)];
    }
    pub fn minorCorrectionEntry(self: *const SharedHistories, pos: *const Position) *CorrectionEntry {
        return &self.correction[pos.st.minor_piece_key & (self.correction.len - 1)];
    }
    pub fn nonPawnCorrectionEntry(self: *const SharedHistories, pos: *const Position, color: t.Color) *CorrectionEntry {
        return &self.correction[pos.st.non_pawn_key[@intFromEnum(color)] & (self.correction.len - 1)];
    }
};
