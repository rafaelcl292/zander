// Derived from Stockfish nnue_feature_transformer.h; GPL-3.0-or-later.
const std = @import("std");
const features = @import("features.zig");
const Reader = @import("reader.zig").Reader;
pub const dimensions = 1024;
pub const buckets = 8;
pub const combined_features = features.FullThreats.dimensions + features.PawnPairs.dimensions;
pub const FeatureTransformer = struct {
    biases: [dimensions]i16 align(64),
    weights: [features.HalfKA.dimensions][dimensions]i16 align(64),
    threat_weights: [combined_features][dimensions]i8 align(64),
    psqt_weights: [features.HalfKA.dimensions][buckets]i32 align(64),
    threat_psqt: [combined_features][buckets]i32 align(64),
    pub fn hash() u32 {
        var result: u32 = 0;
        for ([_]u32{ features.FullThreats.hash_value, features.PawnPairs.hash_value, features.HalfKA.hash_value }) |h| result = ((result << 1) | (result >> 31)) ^ h;
        return result ^ (dimensions * 2);
    }
    pub fn read(self: *FeatureTransformer, reader: *Reader) !void {
        try reader.leb128(i16, &self.biases);
        const threats = features.FullThreats.dimensions;
        const pairs = features.PawnPairs.dimensions;
        const threat_bytes = std.mem.sliceAsBytes(self.threat_weights[0..threats]);
        @memcpy(threat_bytes, try reader.take(threat_bytes.len));
        try reader.leb128(i32, @as([*]i32, @ptrCast(&self.threat_psqt))[0 .. threats * buckets]);
        const pair_bytes = std.mem.sliceAsBytes(self.threat_weights[threats..]);
        @memcpy(pair_bytes, try reader.take(pair_bytes.len));
        try reader.leb128(i32, @as([*]i32, @ptrCast(&self.threat_psqt[threats]))[0 .. pairs * buckets]);
        try reader.leb128(i16, @as([*]i16, @ptrCast(&self.weights))[0 .. features.HalfKA.dimensions * dimensions]);
        try reader.leb128(i32, @as([*]i32, @ptrCast(&self.psqt_weights))[0 .. features.HalfKA.dimensions * buckets]);
    }
    pub fn applyPsq(self: *const FeatureTransformer, comptime add: bool, acc: *[dimensions]i16, psqt: *[buckets]i32, indices: []const u16) void {
        if (@import("backend").simd) return self.applyVector(add, false, acc, psqt, indices);
        for (acc, 0..) |*value, j| {
            for (indices) |index| {
                if (add) value.* +%= self.weights[index][j] else value.* -%= self.weights[index][j];
            }
        }
        for (psqt, 0..) |*value, j| {
            for (indices) |index| {
                if (add) value.* +%= self.psqt_weights[index][j] else value.* -%= self.psqt_weights[index][j];
            }
        }
    }
    pub fn applyThreats(self: *const FeatureTransformer, comptime add: bool, acc: *[dimensions]i16, psqt: *[buckets]i32, indices: []const u16) void {
        if (@import("backend").simd) return self.applyVector(add, true, acc, psqt, indices);
        for (acc, 0..) |*value, j| {
            for (indices) |index| {
                if (add) value.* +%= self.threat_weights[index][j] else value.* -%= self.threat_weights[index][j];
            }
        }
        for (psqt, 0..) |*value, j| {
            for (indices) |index| {
                if (add) value.* +%= self.threat_psqt[index][j] else value.* -%= self.threat_psqt[index][j];
            }
        }
    }
    fn applyVector(self: *const FeatureTransformer, comptime add: bool, comptime threats: bool, acc: *[dimensions]i16, psqt: *[buckets]i32, indices: []const u16) void {
        const lanes = @min(32, std.simd.suggestVectorLength(i16) orelse 8);
        var offset: usize = 0;
        while (offset < dimensions) : (offset += lanes) {
            var value: @Vector(lanes, i16) = acc[offset..][0..lanes].*;
            for (indices) |index| {
                const weight: @Vector(lanes, i16) = if (threats)
                    @as(@Vector(lanes, i8), self.threat_weights[index][offset..][0..lanes].*)
                else
                    self.weights[index][offset..][0..lanes].*;
                if (add) value +%= weight else value -%= weight;
            }
            acc[offset..][0..lanes].* = value;
        }
        for (psqt, 0..) |*value, j| for (indices) |index| {
            const weight = if (threats) self.threat_psqt[index][j] else self.psqt_weights[index][j];
            if (add) value.* +%= weight else value.* -%= weight;
        };
    }
    /// Reference apply_combined: retain one tile in registers through all
    /// feature removals/additions, then write the destination once.
    pub fn applyCombined(self: *const FeatureTransformer, from: *const [dimensions]i16, from_psqt: *const [buckets]i32, to: *[dimensions]i16, to_psqt: *[buckets]i32, removed: []const u16, added: []const u16, threats_removed: []const u16, threats_added: []const u16) void {
        const lanes = @min(32, std.simd.suggestVectorLength(i16) orelse 8);
        const registers = 8;
        var offset: usize = 0;
        while (offset < dimensions) : (offset += lanes * registers) {
            var tile: [registers]@Vector(lanes, i16) = undefined;
            inline for (0..registers) |i| tile[i] = from[offset + i * lanes ..][0..lanes].*;
            self.applyTile(false, false, lanes, &tile, offset, removed);
            self.applyTile(true, false, lanes, &tile, offset, added);
            self.applyTile(false, true, lanes, &tile, offset, threats_removed);
            self.applyTile(true, true, lanes, &tile, offset, threats_added);
            inline for (0..registers) |i| to[offset + i * lanes ..][0..lanes].* = tile[i];
        }
        var psqt: @Vector(buckets, i32) = from_psqt.*;
        for (removed) |index| psqt -%= @as(@Vector(buckets, i32), self.psqt_weights[index]);
        for (added) |index| psqt +%= @as(@Vector(buckets, i32), self.psqt_weights[index]);
        for (threats_removed) |index| psqt -%= @as(@Vector(buckets, i32), self.threat_psqt[index]);
        for (threats_added) |index| psqt +%= @as(@Vector(buckets, i32), self.threat_psqt[index]);
        to_psqt.* = psqt;
    }
    /// Reference cache refresh: store updated PSQ values to the cache before
    /// adding active threats to the same register tile for the live position.
    pub fn applyRefresh(self: *const FeatureTransformer, cache: *[dimensions]i16, cache_psqt: *[buckets]i32, to: *[dimensions]i16, to_psqt: *[buckets]i32, removed: []const u16, added: []const u16, active: []const u16) void {
        const lanes = @min(32, std.simd.suggestVectorLength(i16) orelse 8);
        var offset: usize = 0;
        while (offset < dimensions) : (offset += lanes * 8) {
            var tile: [8]@Vector(lanes, i16) = undefined;
            inline for (0..8) |i| tile[i] = cache[offset + i * lanes ..][0..lanes].*;
            self.applyTile(false, false, lanes, &tile, offset, removed);
            self.applyTile(true, false, lanes, &tile, offset, added);
            inline for (0..8) |i| cache[offset + i * lanes ..][0..lanes].* = tile[i];
            self.applyTile(true, true, lanes, &tile, offset, active);
            inline for (0..8) |i| to[offset + i * lanes ..][0..lanes].* = tile[i];
        }
        var psqt: @Vector(buckets, i32) = cache_psqt.*;
        for (removed) |index| psqt -%= @as(@Vector(buckets, i32), self.psqt_weights[index]);
        for (added) |index| psqt +%= @as(@Vector(buckets, i32), self.psqt_weights[index]);
        cache_psqt.* = psqt;
        for (active) |index| psqt +%= @as(@Vector(buckets, i32), self.threat_psqt[index]);
        to_psqt.* = psqt;
    }
    inline fn applyTile(self: *const FeatureTransformer, comptime add: bool, comptime threats: bool, comptime lanes: usize, tile: *[8]@Vector(lanes, i16), offset: usize, indices: []const u16) void {
        for (indices) |index| {
            inline for (0..8) |i| {
                const start = offset + i * lanes;
                const weight: @Vector(lanes, i16) = if (threats)
                    @as(@Vector(lanes, i8), self.threat_weights[index][start..][0..lanes].*)
                else
                    self.weights[index][start..][0..lanes].*;
                if (add) tile[i] +%= weight else tile[i] -%= weight;
            }
        }
    }
    pub fn transform(acc: *const [2][dimensions]i16, side: usize, output: *[dimensions]u8) void {
        if (@import("backend").simd) return transformVector(acc, side, output);
        transformScalar(acc, side, output);
    }
    pub fn transformVector(acc: *const [2][dimensions]i16, side: usize, output: *[dimensions]u8) void {
        transformVectorMasked(acc, side, output, null);
    }
    pub fn transformMasked(acc: *const [2][dimensions]i16, side: usize, output: *[dimensions]u8, masks: *[4]u64) void {
        if (@import("backend").simd) return transformVectorMasked(acc, side, output, masks);
        transformScalar(acc, side, output);
        masks.* = @import("layers.zig").Architecture.nonzeroMasks(output);
    }
    fn transformVectorMasked(acc: *const [2][dimensions]i16, side: usize, output: *[dimensions]u8, masks: ?*[4]u64) void {
        if (masks) |bits| bits.* = @splat(0);
        const lanes = @min(32, std.simd.suggestVectorLength(i16) orelse 8);
        const Signed = @Vector(lanes, i16);
        const Unsigned = @Vector(lanes, u16);
        for (0..2) |p| {
            var j: usize = 0;
            while (j < dimensions / 2) : (j += lanes) {
                const a: Signed = acc[side ^ p][j..][0..lanes].*;
                const b: Signed = acc[side ^ p][j + dimensions / 2 ..][0..lanes].*;
                const first: Unsigned = @intCast(@min(@max(a, @as(Signed, @splat(0))), @as(Signed, @splat(255))));
                const second: Unsigned = @intCast(@min(@max(b, @as(Signed, @splat(0))), @as(Signed, @splat(255))));
                // 255 * 255 fits u16; the clipped product fits seven bits.
                const values: @Vector(lanes, u8) = @intCast((first * second) >> @splat(9));
                const start = p * (dimensions / 2) + j;
                output[start..][0..lanes].* = values;
                if (masks) |bits| {
                    const words: @Vector(lanes / 4, u32) = @bitCast(values);
                    const mask: std.meta.Int(.unsigned, lanes / 4) = @bitCast(words != @as(@Vector(lanes / 4, u32), @splat(0)));
                    bits[start / 256] |= @as(u64, mask) << @as(u6, @intCast((start % 256) / 4));
                }
            }
        }
    }
    pub fn transformScalar(acc: *const [2][dimensions]i16, side: usize, output: *[dimensions]u8) void {
        for (0..2) |p| {
            for (0..dimensions / 2) |j| {
                const first: u32 = @intCast(std.math.clamp(acc[side ^ p][j], 0, 255));
                const second: u32 = @intCast(std.math.clamp(acc[side ^ p][j + dimensions / 2], 0, 255));
                output[p * (dimensions / 2) + j] = @intCast(first * second / 512);
            }
        }
    }
};

test "vector feature transformation matches scalar clipping and lane order" {
    var rng = @import("../prng.zig").Prng.init(789);
    var acc: [2][dimensions]i16 = undefined;
    var scalar: [dimensions]u8 = undefined;
    var vector: [dimensions]u8 = undefined;
    const edges = [_]i16{ -32768, -1, 0, 1, 254, 255, 256, 32767 };
    for (0..16) |pattern| {
        for (&acc) |*row| for (row, 0..) |*value, i| {
            value.* = if (pattern < edges.len) edges[(i + pattern) % edges.len] else @bitCast(@as(u16, @truncate(rng.next())));
        };
        for (0..2) |side| {
            FeatureTransformer.transformScalar(&acc, side, &scalar);
            FeatureTransformer.transformVector(&acc, side, &vector);
            try std.testing.expectEqualSlices(u8, &scalar, &vector);
            var masks: [4]u64 = undefined;
            FeatureTransformer.transformMasked(&acc, side, &vector, &masks);
            try std.testing.expectEqualSlices(u8, &scalar, &vector);
            try std.testing.expectEqual(@import("layers.zig").Architecture.nonzeroMasks(&scalar), masks);
        }
    }
}
