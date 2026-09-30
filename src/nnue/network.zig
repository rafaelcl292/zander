// Derived from Stockfish nnue/network.cpp and evaluate.cpp; GPL-3.0-or-later.
const std = @import("std");
const Reader = @import("reader.zig").Reader;
const FeatureTransformer = @import("transformer.zig").FeatureTransformer;
const Architecture = @import("layers.zig").Architecture;
const accumulator = @import("accumulator.zig");
const Position = @import("../position.zig").Position;
const t = @import("../types.zig");
pub const default_name = "nn-252f33942263.nnue";
pub const default_sha256 = "252f33942263bc8b8f740ba8aec3fed5a159ff148113c47a55c18c33d6627ab3";
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
    /// Serialize the live weights, independently of the source file lifetime.
    pub fn save(self: *const Network, writer: *std.Io.Writer, description: []const u8) !void {
        if (!self.initialized) return error.UninitializedNetwork;
        const out = @import("writer.zig");
        const features = @import("features.zig");
        try out.int(writer, u32, version);
        try out.int(writer, u32, hash);
        try out.int(writer, u32, @intCast(description.len));
        try writer.writeAll(description);
        try out.int(writer, u32, FeatureTransformer.hash());
        const ft = &self.transformer;
        try out.leb128(writer, i16, &ft.biases);
        const threats = features.FullThreats.dimensions;
        try writer.writeAll(std.mem.sliceAsBytes(ft.threat_weights[0..threats]));
        try writer.writeAll(std.mem.sliceAsBytes(ft.threat_weights[threats..]));
        try out.leb128(writer, i16, @as([*]const i16, @ptrCast(&ft.weights))[0 .. features.HalfKA.dimensions * 1024]);
        for (&self.layers) |*layer| {
            try out.int(writer, u32, Architecture.hash());
            inline for (.{ "fc0", "fc1", "fc2" }) |name| {
                const affine = &@field(layer, name);
                for (affine.biases) |bias| try out.int(writer, i32, bias);
                try writer.writeAll(std.mem.asBytes(&affine.weights));
            }
        }
    }
    pub fn evaluate(self: *const Network, pos: *const Position, stack: *accumulator.Stack, cache: *accumulator.Caches) i32 {
        std.debug.assert(self.initialized);
        stack.evaluate(pos, &self.transformer, cache);
        const state = stack.latest();
        const side = @intFromEnum(pos.side);
        const bucket = (@popCount(pos.pieces()) - 1) / 4;
        var transformed: [1024]u8 align(64) = undefined;
        var masks: [4]u64 = undefined;
        if (@import("layers.zig").use_sparse) FeatureTransformer.transformSparseMasked(&state.accumulation, side, &transformed, &masks) else FeatureTransformer.transform(&state.accumulation, side, &transformed);
        var buffer: Architecture.Buffer = undefined;
        const positional = self.layers[bucket].propagatePreparedMasked(&transformed, &masks, &buffer);
        return @divTrunc(positional, 16);
    }
    pub fn trace(self: *const Network, pos: *const Position, stack: *accumulator.Stack, cache: *accumulator.Caches) [8]i32 {
        stack.evaluate(pos, &self.transformer, cache);
        const state = stack.latest();
        const side = @intFromEnum(pos.side);
        var transformed: [1024]u8 align(64) = undefined;
        var masks: [4]u64 = undefined;
        if (@import("layers.zig").use_sparse) FeatureTransformer.transformSparseMasked(&state.accumulation, side, &transformed, &masks) else FeatureTransformer.transform(&state.accumulation, side, &transformed);
        var result: [8]i32 = undefined;
        for (&self.layers, &result) |*layer, *out| {
            var buffer: Architecture.Buffer = undefined;
            out.* = @divTrunc(layer.propagatePreparedMasked(&transformed, &masks, &buffer), 16);
        }
        return result;
    }
    pub fn evaluateAdjusted(self: *const Network, pos: *const Position, stack: *accumulator.Stack, cache: *accumulator.Caches, initial_optimism: i32) i32 {
        std.debug.assert(pos.st.checkers == 0);
        const nnue: i64 = self.evaluate(pos, stack, cache);
        const side = @intFromEnum(pos.side);
        const pawns = @as(i64, @popCount(pos.piecesOf(pos.side, .pawn))) - @as(i64, @popCount(pos.piecesOf(pos.side.opposite(), .pawn)));
        const simple = @import("../position.zig").piece_value[1] * pawns + pos.st.non_pawn_material[side] - pos.st.non_pawn_material[side ^ 1];
        const se_norm = @divTrunc(simple * 1024, @as(i64, @intCast(@abs(simple))) + 1024);
        const nnue_norm = @divTrunc(nnue * 1024, @as(i64, @intCast(@abs(nnue))) + 1024);
        const alignment = @divTrunc(se_norm * nnue_norm, 512);
        const base_eval = nnue + @divTrunc(nnue * alignment, 65536) + @divTrunc(@as(i64, initial_optimism) * alignment, 16384);
        const material = 521 * @as(i64, @popCount(pos.by_type[1])) + pos.st.non_pawn_material[0] + pos.st.non_pawn_material[1];
        var value = @divTrunc(base_eval * (90649 + material), 90649);
        value -= @divTrunc(value * pos.st.rule50, 189);
        const max = t.value_mate - 2 * t.max_ply - 2;
        return @intCast(std.math.clamp(value, -max, max));
    }
};
