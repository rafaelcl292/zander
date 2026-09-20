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
    pub fn transform(acc: *const [2][dimensions]i16, side: usize, output: *[dimensions]u8) void {
        for (0..2) |p| {
            for (0..dimensions / 2) |j| {
                const first: u32 = @intCast(std.math.clamp(acc[side ^ p][j], 0, 255));
                const second: u32 = @intCast(std.math.clamp(acc[side ^ p][j + dimensions / 2], 0, 255));
                output[p * (dimensions / 2) + j] = @intCast(first * second / 512);
            }
        }
    }
};
