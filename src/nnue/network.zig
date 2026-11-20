// Derived from Stockfish nnue/network.cpp and evaluate.cpp; GPL-3.0-or-later.
const std = @import("std");
const Reader = @import("reader.zig").Reader;
const FeatureTransformer = @import("transformer.zig").FeatureTransformer;
const Architecture = @import("layers.zig").Architecture;
const accumulator = @import("accumulator.zig");
const Position = @import("../position.zig").Position;
const t = @import("../types.zig");
pub const default_name = "nn-bddd9d57eb87.nnue";
pub const default_sha256 = "bddd9d57eb87bf09a6c4e1a3b3f1cc18855c83ee45fdbe18018ac3763b56b38e";
pub const Network = struct {
    transformer: FeatureTransformer,
    layers: [192]Architecture,
    layer_stack_fallback: [192]u16,
    layer_stack_index: [192]u16,
    stored_layer_stacks: u32 = 0,
    initialized: bool = false,
    pub const layer_stack_table_hash: u32 = 0x5a7ab1e5;
    pub const version: u32 = 0x6a448afa;
    pub const hash: u32 = FeatureTransformer.hash() ^ Architecture.hash() ^ layer_stack_table_hash;
    /// Allocate this object in final storage before loading. The description
    /// borrows from bytes; weights are copied into the network's own arrays.
    pub fn load(self: *Network, bytes: []const u8) ![]const u8 {
        self.initialized = false;
        var reader: Reader = .{ .bytes = bytes };
        if (try reader.int(u32) != version) return error.UnsupportedVersion;
        if (try reader.int(u32) != hash) return error.ArchitectureMismatch;
        const description = try reader.take(try reader.int(u32));
        try self.readLayerStacks(&reader);
        if (try reader.int(u32) != FeatureTransformer.hash()) return error.ArchitectureMismatch;
        try self.transformer.read(&reader);
        for (self.layers[0..self.stored_layer_stacks]) |*layer| {
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
        try out.int(writer, u32, layer_stack_table_hash);
        try out.int(writer, u32, 192);
        try out.int(writer, u32, self.stored_layer_stacks);
        for (self.layer_stack_fallback) |fallback| try out.int(writer, u16, fallback);
        try out.int(writer, u32, FeatureTransformer.hash());
        const ft = &self.transformer;
        for (ft.biases) |bias| try out.int(writer, i16, bias);
        const threats = features.FullThreats.dimensions;
        try FeatureTransformer.writeWeights(writer, ft.threat_weights[0..threats]);
        try FeatureTransformer.writeWeights(writer, ft.threat_weights[threats..]);
        try FeatureTransformer.writeWeights(writer, &ft.weights);
        for (self.layers[0..self.stored_layer_stacks]) |*layer| {
            try out.int(writer, u32, Architecture.hash());
            inline for (.{ "fc0", "fc1", "fc2" }) |name| {
                const affine = &@field(layer, name);
                for (affine.biases) |bias| try out.int(writer, i32, bias);
                try writer.writeAll(std.mem.asBytes(&affine.weights));
            }
        }
    }
    fn readLayerStacks(self: *Network, reader: *Reader) !void {
        if (try reader.int(u32) != layer_stack_table_hash or try reader.int(u32) != 192) {
            return error.ArchitectureMismatch;
        }
        self.stored_layer_stacks = try reader.int(u32);
        if (self.stored_layer_stacks == 0 or self.stored_layer_stacks > 192) return error.InvalidLayerStacks;
        for (&self.layer_stack_fallback) |*fallback| {
            fallback.* = try reader.int(u16);
            if (fallback.* >= 192) return error.InvalidLayerStacks;
        }
        var stored: u16 = 0;
        for (self.layer_stack_fallback, 0..) |fallback, index| {
            if (fallback == index) {
                self.layer_stack_index[index] = stored;
                stored += 1;
            }
        }
        if (stored != self.stored_layer_stacks) return error.InvalidLayerStacks;
        for (self.layer_stack_fallback, 0..) |fallback, index| {
            if (self.layer_stack_fallback[fallback] != fallback) return error.InvalidLayerStacks;
            self.layer_stack_index[index] = self.layer_stack_index[fallback];
        }
    }
    pub fn layerStack(self: *const Network, pos: *const Position) usize {
        const band: usize = (@popCount(pos.pieces()) - 1) / 4;
        const queens: usize = @as(usize, if (pos.piecesOf(pos.side, .queen) != 0) 2 else 0) +
            @intFromBool(pos.piecesOf(pos.side.opposite(), .queen) != 0);
        const pawns = pos.by_type[1];
        const queen_side: u64 = 0x0f0f0f0f0f0f0f0f;
        const layout: usize = if (pawns == 0) 2 else if (pawns & queen_side != 0 and pawns & ~queen_side != 0) 0 else 1;
        const officers = pos.pieces() & ~(pawns | pos.by_type[6]);
        const many: usize = @intFromBool(
            @max(@popCount(officers & pos.by_color[0]), @popCount(officers & pos.by_color[1])) >= 2,
        );
        return self.layer_stack_index[((band * 4 + queens) * 3 + layout) * 2 + many];
    }
    pub fn evaluate(
        self: *const Network,
        pos: *const Position,
        stack: *accumulator.Stack,
        cache: *accumulator.Caches,
    ) i32 {
        std.debug.assert(self.initialized);
        stack.evaluate(pos, &self.transformer, cache);
        const state = stack.latest();
        const side = @backingInt(pos.side);
        const bucket = self.layerStack(pos);
        var transformed: [1024]u8 align(64) = undefined;
        var masks: [4]u64 = undefined;
        if (@import("layers.zig").use_sparse) {
            FeatureTransformer.transformSparseMasked(&state.accumulation, side, &transformed, &masks);
        } else FeatureTransformer.transform(&state.accumulation, side, &transformed);
        var buffer: Architecture.Buffer = undefined;
        const positional = self.layers[bucket].propagatePreparedMasked(&transformed, &masks, &buffer);
        return @divTrunc(positional, 16);
    }
    pub fn trace(
        self: *const Network,
        pos: *const Position,
        stack: *accumulator.Stack,
        cache: *accumulator.Caches,
    ) [192]i32 {
        stack.evaluate(pos, &self.transformer, cache);
        const state = stack.latest();
        const side = @backingInt(pos.side);
        var transformed: [1024]u8 align(64) = undefined;
        var masks: [4]u64 = undefined;
        if (@import("layers.zig").use_sparse) {
            FeatureTransformer.transformSparseMasked(&state.accumulation, side, &transformed, &masks);
        } else FeatureTransformer.transform(&state.accumulation, side, &transformed);
        var result: [192]i32 = @splat(0);
        for (self.layers[0..self.stored_layer_stacks], result[0..self.stored_layer_stacks]) |*layer, *out| {
            var buffer: Architecture.Buffer = undefined;
            out.* = @divTrunc(layer.propagatePreparedMasked(&transformed, &masks, &buffer), 16);
        }
        return result;
    }
    pub fn evaluateAdjusted(
        self: *const Network,
        pos: *const Position,
        stack: *accumulator.Stack,
        cache: *accumulator.Caches,
        initial_optimism: i32,
    ) i32 {
        std.debug.assert(pos.st.checkers == 0);
        const nnue: i64 = self.evaluate(pos, stack, cache);
        const side = @backingInt(pos.side);
        const pawns = @as(i64, @popCount(pos.piecesOf(pos.side, .pawn))) -
            @as(i64, @popCount(pos.piecesOf(pos.side.opposite(), .pawn)));
        const simple = @import("../position.zig").piece_value[1] * pawns +
            pos.st.non_pawn_material[side] - pos.st.non_pawn_material[side ^ 1];
        const se_norm = @divTrunc(simple * 1024, @as(i64, @intCast(@abs(simple))) + 1024);
        const nnue_norm = @divTrunc(nnue * 1024, @as(i64, @intCast(@abs(nnue))) + 1024);
        const alignment = @divTrunc(se_norm * nnue_norm, 512);
        const base_eval = nnue + @divTrunc((nnue + @as(i64, initial_optimism)) * alignment, 65536);
        const material = 521 * @as(i64, @popCount(pos.by_type[1])) +
            pos.st.non_pawn_material[0] + pos.st.non_pawn_material[1];
        var value = base_eval + @divTrunc(base_eval * material, 90649);
        value -= @divTrunc(value * pos.st.rule50, 189);
        const max = t.value_mate - 2 * t.max_ply - 2;
        return @intCast(std.math.clamp(value, -max, max));
    }
};

test "layer stack table validates counts, bounds and fallback roots" {
    const network = try std.testing.allocator.create(Network);
    defer std.testing.allocator.destroy(network);
    var bytes: [12 + 192 * 2]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], Network.layer_stack_table_hash, .little);
    std.mem.writeInt(u32, bytes[4..8], 192, .little);
    std.mem.writeInt(u32, bytes[8..12], 1, .little);
    @memset(bytes[12..], 0);
    var reader: Reader = .{ .bytes = &bytes };
    try network.readLayerStacks(&reader);
    for (network.layer_stack_index) |index| try std.testing.expectEqual(@as(u16, 0), index);

    // A root later in the table must be resolved before its earlier aliases.
    for (0..192) |index| std.mem.writeInt(u16, bytes[12 + index * 2 ..][0..2], 191, .little);
    reader.offset = 0;
    try network.readLayerStacks(&reader);
    for (network.layer_stack_index) |index| try std.testing.expectEqual(@as(u16, 0), index);

    std.mem.writeInt(u16, bytes[12..14], 192, .little);
    reader.offset = 0;
    try std.testing.expectError(error.InvalidLayerStacks, network.readLayerStacks(&reader));
    // A fallback chain must not be accepted as a direct root reference.
    std.mem.writeInt(u16, bytes[12..14], 1, .little);
    reader.offset = 0;
    try std.testing.expectError(error.InvalidLayerStacks, network.readLayerStacks(&reader));
    std.mem.writeInt(u16, bytes[12..14], 191, .little);
    for ([_]u32{ 0, 2, 193 }) |count| {
        std.mem.writeInt(u32, bytes[8..12], count, .little);
        reader.offset = 0;
        try std.testing.expectError(error.InvalidLayerStacks, network.readLayerStacks(&reader));
    }
    std.mem.writeInt(u32, bytes[8..12], 1, .little);
    reader = .{ .bytes = bytes[0 .. bytes.len - 1] };
    try std.testing.expectError(error.Truncated, network.readLayerStacks(&reader));
}
