// Derived from Stockfish nnue/network.cpp and evaluate.cpp; GPL-3.0-or-later.
const std = @import("std");
const Reader = @import("reader.zig").Reader;
const FeatureTransformer = @import("transformer.zig").FeatureTransformer;
const Architecture = @import("layers.zig").Architecture;
const accumulator = @import("accumulator.zig");
const Position = @import("../position.zig").Position;
const t = @import("../types.zig");
pub const default_name = "nn-134a887f4c8f.nnue";
pub const default_sha256 = "134a887f4c8ff7bf7284177a3b3fc6ff9cef95ba89eb8db3079a8e507f7126af";
pub const Network = struct {
    transformer: FeatureTransformer,
    layers: [8]Architecture,
    initialized: bool = false,
    pub const version: u32 = 0x6a448afa;
    pub const hash: u32 = FeatureTransformer.hash() ^ Architecture.hash();
    /// Allocate this object in final storage before loading. The description
    /// borrows from bytes; weights are copied into the network's own arrays.
    pub fn load(self: *Network, bytes: []const u8) ![]const u8 {
        self.initialized = false;
        var reader: Reader = .{ .bytes = bytes };
        if (try reader.int(u32) != version) return error.UnsupportedVersion;
        if (try reader.int(u32) != hash) return error.ArchitectureMismatch;
        const description = try reader.take(try reader.int(u32));
        if (try reader.int(u32) != FeatureTransformer.hash()) return error.ArchitectureMismatch;
        try self.transformer.read(&reader);
        for (&self.layers) |*layer| {
            if (try reader.int(u32) != Architecture.hash()) return error.ArchitectureMismatch;
            try layer.read(&reader);
        }
        if (reader.offset != reader.bytes.len) return error.TrailingData;
        self.initialized = true;
        return description;
    }
    pub const Output = struct { psqt: i32, positional: i32 };
    pub fn evaluate(self: *const Network, pos: *const Position, stack: *accumulator.Stack, cache: *accumulator.Caches) Output {
        std.debug.assert(self.initialized);
        stack.evaluate(pos, &self.transformer, cache);
        const state = stack.latest();
        const side = @intFromEnum(pos.side);
        const bucket = (@popCount(pos.pieces()) - 1) / 4;
        const psqt = @divTrunc(state.psqt[side][bucket] - state.psqt[side ^ 1][bucket], 2);
        var transformed: [1024]u8 align(64) = undefined;
        FeatureTransformer.transform(&state.accumulation, side, &transformed);
        var buffer: Architecture.Buffer = undefined;
        const positional = self.layers[bucket].propagate(&transformed, &buffer);
        return .{ .psqt = @divTrunc(psqt, 16), .positional = @divTrunc(positional, 16) };
    }
    pub fn evaluateAdjusted(self: *const Network, pos: *const Position, stack: *accumulator.Stack, cache: *accumulator.Caches, initial_optimism: i32) i32 {
        std.debug.assert(pos.st.checkers == 0);
        const out = self.evaluate(pos, stack, cache);
        var nnue: i64 = out.psqt + out.positional;
        const complexity: i64 = @intCast(@abs(out.psqt - out.positional));
        var optimism: i64 = initial_optimism;
        optimism += @divTrunc(optimism * complexity, 476);
        nnue -= @divTrunc(nnue * complexity, 18236);
        const material = 534 * @as(i64, @popCount(pos.by_type[1])) + pos.st.non_pawn_material[0] + pos.st.non_pawn_material[1];
        var value = nnue + @divTrunc(nnue * material + optimism * 7675, 91000);
        value -= @divTrunc(value * pos.st.rule50, 199);
        const max = t.value_mate - 2 * t.max_ply - 2;
        return @intCast(std.math.clamp(value, -max, max));
    }
};
