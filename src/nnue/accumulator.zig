// Derived from Stockfish nnue_accumulator.h/.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("../types.zig");
const bb = @import("../bitboard.zig");
const dirty = @import("../dirty.zig");
const Position = @import("../position.zig").Position;
const f = @import("features.zig");
const FT = @import("transformer.zig").FeatureTransformer;
pub const Accumulator = struct {
    accumulation: [2][1024]i16 align(64),
    psqt: [2][8]i32 align(64),
    computed: [2]bool = @splat(false),
    dirties: dirty.Dirties = .{},
};
pub const CacheEntry = struct {
    accumulation: [1024]i16 align(64),
    psqt: [8]i32 = @splat(0),
    pieces: [64]t.Piece = @splat(.none),
    piece_bb: u64 = 0,
};
pub const Caches = struct {
    entries: [64][2]CacheEntry,
    pub fn clear(self: *Caches, ft: *const FT) void {
        for (&self.entries) |*row| for (row) |*entry| {
            entry.* = .{ .accumulation = ft.biases };
        };
    }
};
pub const Stack = struct {
    accumulators: [t.max_ply + 1]Accumulator,
    size: usize = 1,
    pub fn reset(self: *Stack) void {
        self.size = 1;
        self.accumulators[0].dirties = .{};
        self.accumulators[0].computed = @splat(false);
    }
    pub fn latest(self: *Stack) *Accumulator {
        return &self.accumulators[self.size - 1];
    }
    pub fn push(self: *Stack) *dirty.Dirties {
        std.debug.assert(self.size < self.accumulators.len);
        const state = &self.accumulators[self.size];
        state.computed = @splat(false);
        state.dirties = .{};
        self.size += 1;
        return &state.dirties;
    }
    pub fn pop(self: *Stack) void {
        std.debug.assert(self.size > 1);
        self.size -= 1;
    }
    fn lastUsable(self: *const Stack, c: t.Color) usize {
        var i = self.size - 1;
        while (i > 0) : (i -= 1) {
            const state = &self.accumulators[i];
            if (state.computed[@intFromEnum(c)] or f.HalfKA.requiresRefresh(state.dirties.piece, c)) return i;
        }
        return 0;
    }
    pub fn evaluate(self: *Stack, pos: *const Position, ft: *const FT, cache: *Caches) void {
        const last = [2]usize{ self.lastUsable(.white), self.lastUsable(.black) };
        if (self.accumulators[last[0]].computed[0] and self.accumulators[last[1]].computed[1]) {
            const shared = @max(last[0], last[1]);
            for ([_]t.Color{ .white, .black }) |c| {
                for (last[@intFromEnum(c)] + 1..shared + 1) |i| incremental(true, c, pos.king(c), ft, &self.accumulators[i], &self.accumulators[i - 1]);
            }
            for (shared + 1..self.size) |i| {
                for ([_]t.Color{ .white, .black }) |c| incremental(true, c, pos.king(c), ft, &self.accumulators[i], &self.accumulators[i - 1]);
            }
        } else for ([_]t.Color{ .white, .black }) |c| {
            const begin = last[@intFromEnum(c)];
            if (self.accumulators[begin].computed[@intFromEnum(c)]) {
                for (begin + 1..self.size) |i| incremental(true, c, pos.king(c), ft, &self.accumulators[i], &self.accumulators[i - 1]);
            } else {
                const dp = self.latest().dirties.piece;
                if (dp.pc == t.Piece.make(c, .king) and self.size > 1 and self.accumulators[self.size - 2].computed[@intFromEnum(c)] and @popCount(pos.pieces()) >= 15 and (@intFromEnum(dp.from) & 4) == (@intFromEnum(dp.to) & 4) and dp.add_sq == .none) {
                    hybrid(c, pos, ft, self.latest(), &self.accumulators[self.size - 2], cache);
                } else {
                    refresh(c, pos, ft, self.latest(), cache);
                    var i = self.size - 1;
                    while (i > begin) {
                        i -= 1;
                        incremental(false, c, pos.king(c), ft, &self.accumulators[i], &self.accumulators[i + 1]);
                    }
                }
            }
        }
    }
};
fn incremental(comptime forward: bool, c: t.Color, king: t.Square, ft: *const FT, target: *Accumulator, computed: *const Accumulator) void {
    const side = @intFromEnum(c);
    const diff = if (forward) &target.dirties else &computed.dirties;
    // Match the reference list constructor: initialize the length only.
    // Aggregate empty literals can lower to full-buffer clears in hot paths.
    var pr: f.SmallList = undefined;
    pr.len = 0;
    var pa: f.SmallList = undefined;
    pa.len = 0;
    var tr: f.ThreatList = undefined;
    tr.len = 0;
    var ta: f.ThreatList = undefined;
    ta.len = 0;
    f.HalfKA.appendChanged(c, king, diff.piece, if (forward) &pr else &pa, if (forward) &pa else &pr);
    f.FullThreats.appendChanged(c, king, &diff.threats, if (forward) &tr else &ta, if (forward) &ta else &tr);
    f.PawnPairs.appendChanged(c, king, diff.before, diff.after, if (forward) &tr else &ta, if (forward) &ta else &tr);
    if (@import("backend").simd) {
        ft.applyCombined(&computed.accumulation[side], &computed.psqt[side], &target.accumulation[side], &target.psqt[side], pr.slice(), pa.slice(), tr.slice(), ta.slice());
    } else {
        target.accumulation[side] = computed.accumulation[side];
        target.psqt[side] = computed.psqt[side];
        ft.applyPsq(false, &target.accumulation[side], &target.psqt[side], pr.slice());
        ft.applyPsq(true, &target.accumulation[side], &target.psqt[side], pa.slice());
        ft.applyThreats(false, &target.accumulation[side], &target.psqt[side], tr.slice());
        ft.applyThreats(true, &target.accumulation[side], &target.psqt[side], ta.slice());
    }
    target.computed[side] = true;
}
fn changed(entry: *const CacheEntry, pieces: *const [64]t.Piece, occupied: u64, c: t.Color, king: t.Square, removed: *f.SmallList, added: *f.SmallList) void {
    var bits: u64 = 0;
    for (&entry.pieces, pieces, 0..) |old, new, i| if (old != new) {
        bits |= @as(u64, 1) << @as(u6, @intCast(i));
    };
    var r = bits & entry.piece_bb;
    while (r != 0) {
        const sq = bb.popLsb(&r);
        removed.append(f.HalfKA.makeIndex(c, sq, entry.pieces[@intFromEnum(sq)], king));
    }
    var a = bits & occupied;
    while (a != 0) {
        const sq = bb.popLsb(&a);
        added.append(f.HalfKA.makeIndex(c, sq, pieces[@intFromEnum(sq)], king));
    }
}
fn refresh(c: t.Color, pos: *const Position, ft: *const FT, target: *Accumulator, cache: *Caches) void {
    const side = @intFromEnum(c);
    const entry = &cache.entries[@intFromEnum(pos.king(c))][side];
    var removed: f.SmallList = undefined;
    removed.len = 0;
    var added: f.SmallList = undefined;
    added.len = 0;
    changed(entry, &pos.board, pos.pieces(), c, pos.king(c), &removed, &added);
    ft.applyPsq(false, &entry.accumulation, &entry.psqt, removed.slice());
    ft.applyPsq(true, &entry.accumulation, &entry.psqt, added.slice());
    entry.pieces = pos.board;
    entry.piece_bb = pos.pieces();
    var active: f.ThreatList = undefined;
    active.len = 0;
    f.FullThreats.appendActive(c, pos, &active);
    f.PawnPairs.appendActive(c, pos, &active);
    target.accumulation[side] = entry.accumulation;
    target.psqt[side] = entry.psqt;
    ft.applyThreats(true, &target.accumulation[side], &target.psqt[side], active.slice());
    target.computed[side] = true;
}
fn hybrid(c: t.Color, pos: *const Position, ft: *const FT, target: *Accumulator, computed: *const Accumulator, cache: *Caches) void {
    const dp = target.dirties.piece;
    const side = @intFromEnum(c);
    var previous_pieces = pos.board;
    var previous_bb = pos.pieces();
    if (dp.remove_sq != .none) previous_pieces[@intFromEnum(dp.to)] = dp.remove_pc else {
        previous_pieces[@intFromEnum(dp.to)] = .none;
        previous_bb &= ~bb.square(dp.to);
    }
    previous_pieces[@intFromEnum(dp.from)] = dp.pc;
    previous_bb |= bb.square(dp.from);
    const old_entry = &cache.entries[@intFromEnum(dp.from)][side];
    const new_entry = &cache.entries[@intFromEnum(dp.to)][side];
    var old_removed: f.SmallList = undefined;
    old_removed.len = 0;
    var old_added: f.SmallList = undefined;
    old_added.len = 0;
    var new_removed: f.SmallList = undefined;
    new_removed.len = 0;
    var new_added: f.SmallList = undefined;
    new_added.len = 0;
    changed(old_entry, &previous_pieces, previous_bb, c, dp.from, &old_removed, &old_added);
    changed(new_entry, &pos.board, pos.pieces(), c, dp.to, &new_removed, &new_added);
    ft.applyPsq(false, &new_entry.accumulation, &new_entry.psqt, new_removed.slice());
    ft.applyPsq(true, &new_entry.accumulation, &new_entry.psqt, new_added.slice());
    for (&target.accumulation[side], new_entry.accumulation, computed.accumulation[side], old_entry.accumulation) |*out, new, from, old| out.* = new +% from -% old;
    for (&target.psqt[side], new_entry.psqt, computed.psqt[side], old_entry.psqt) |*out, new, from, old| out.* = new +% from -% old;
    ft.applyPsq(true, &target.accumulation[side], &target.psqt[side], old_removed.slice());
    ft.applyPsq(false, &target.accumulation[side], &target.psqt[side], old_added.slice());
    var removed: f.ThreatList = undefined;
    removed.len = 0;
    var added: f.ThreatList = undefined;
    added.len = 0;
    f.FullThreats.appendChanged(c, dp.to, &target.dirties.threats, &removed, &added);
    f.PawnPairs.appendChanged(c, dp.to, target.dirties.before, target.dirties.after, &removed, &added);
    ft.applyThreats(false, &target.accumulation[side], &target.psqt[side], removed.slice());
    ft.applyThreats(true, &target.accumulation[side], &target.psqt[side], added.slice());
    new_entry.pieces = pos.board;
    new_entry.piece_bb = pos.pieces();
    target.computed[side] = true;
}
