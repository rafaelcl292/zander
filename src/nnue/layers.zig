// Derived from Stockfish nnue/layers and nnue_architecture.h; GPL-3.0-or-later.
const std = @import("std");
const Reader = @import("reader.zig").Reader;
pub const output_scale: i32 = 16;
pub const weight_scale_bits = 6;
pub const hidden_one = 128;
pub fn clipped(input: i32, comptime scale: u5) u8 {
    return @intCast(std.math.clamp(input >> scale, 0, 127));
}
pub fn squared(input: i32, comptime scale: u5) u8 {
    return @intCast(@min(127, (@as(i64, input) * input) >> (2 * scale + 7)));
}
pub fn Affine(comptime inputs: usize, comptime outputs: usize) type {
    return struct {
        biases: [outputs]i32 align(64),
        weights: [outputs][inputs]i8 align(64),
        pub fn hash(previous: u32) u32 {
            return (@as(u32, 0xcc03dae4) +% @as(u32, @intCast(outputs))) ^ (previous >> 1) ^ (previous << 31);
        }
        pub fn read(self: *@This(), reader: *Reader) !void {
            for (&self.biases) |*bias| bias.* = try reader.int(i32);
            for (&self.weights) |*row| for (row) |*weight| {
                weight.* = try reader.int(i8);
            };
        }
        pub fn propagate(self: *const @This(), input: *const [inputs]u8, output: *[outputs]i32) void {
            if (@import("backend").simd) self.propagateVector(input, output) else self.propagateScalar(input, output);
        }
        pub fn propagateVector(self: *const @This(), input: *const [inputs]u8, output: *[outputs]i32) void {
            const lanes = @min(16, std.simd.suggestVectorLength(i32) orelse 4);
            comptime std.debug.assert(inputs % lanes == 0);
            for (&self.biases, &self.weights, output) |bias, row, *value| {
                var sums: @Vector(lanes, i32) = @splat(0);
                var offset: usize = 0;
                while (offset < inputs) : (offset += lanes) {
                    const x: @Vector(lanes, u8) = input[offset..][0..lanes].*;
                    const w: @Vector(lanes, i8) = row[offset..][0..lanes].*;
                    sums +%= @as(@Vector(lanes, i32), @intCast(x)) * @as(@Vector(lanes, i32), w);
                }
                value.* = bias +% @reduce(.Add, sums);
            }
        }
        pub fn propagateScalar(self: *const @This(), input: *const [inputs]u8, output: *[outputs]i32) void {
            for (&self.biases, &self.weights, output) |bias, row, *value| {
                var sum = bias;
                for (input, row) |x, w| sum +%= @as(i32, x) * w;
                value.* = sum;
            }
        }
    };
}
pub const Architecture = struct {
    fc0: Affine(1024, 32),
    fc1: Affine(64, 32),
    fc2: Affine(128, 1),
    pub fn hash() u32 {
        var h: u32 = 0xec42e90d ^ (1024 * 2);
        h = Affine(1024, 32).hash(h);
        h +%= 0x538d24c7;
        h = Affine(64, 32).hash(h);
        h +%= 0x538d24c7;
        return Affine(128, 1).hash(h);
    }
    pub fn read(self: *Architecture, reader: *Reader) !void {
        try self.fc0.read(reader);
        try self.fc1.read(reader);
        try self.fc2.read(reader);
    }
    pub const Buffer = struct {
        fc0: [32]i32 align(64),
        concat: [128]u8 align(64),
        fc1: [32]i32 align(64),
        fc2: [1]i32 align(64),
    };
    /// Both kernels consume the same serialized weight layout.
    pub fn propagate(self: *const Architecture, input: *const [1024]u8, buffer: *Buffer) i32 {
        self.fc0.propagate(input, &buffer.fc0);
        for (buffer.fc0, 0..) |value, i| {
            buffer.concat[i] = squared(value, 7);
            buffer.concat[32 + i] = clipped(value, 7);
        }
        self.fc1.propagate(buffer.concat[0..64], &buffer.fc1);
        for (buffer.fc1, 0..) |value, i| {
            buffer.concat[64 + i] = squared(value, 6);
            buffer.concat[96 + i] = clipped(value, 6);
        }
        self.fc2.propagate(&buffer.concat, &buffer.fc2);
        const forward = buffer.fc2[0] +% (buffer.fc0[30] -% buffer.fc0[31]);
        return @intCast(@divTrunc(@as(i64, forward) * (600 * output_scale), hidden_one * (1 << weight_scale_bits) * 2));
    }
};

test "vector affine matches scalar with signed weights and wrapping bias" {
    var layer: Affine(1024, 32) = undefined;
    var rng = @import("../prng.zig").Prng.init(123);
    for (&layer.biases) |*bias| bias.* = @bitCast(@as(u32, @truncate(rng.next())));
    for (&layer.weights) |*row| for (row) |*weight| {
        weight.* = @bitCast(@as(u8, @truncate(rng.next())));
    };
    var input: [1024]u8 = undefined;
    var scalar: [32]i32 = undefined;
    var vector: [32]i32 = undefined;
    for (0..32) |_| {
        for (&input) |*x| x.* = @truncate(rng.next());
        layer.propagateScalar(&input, &scalar);
        layer.propagateVector(&input, &vector);
        try std.testing.expectEqualSlices(i32, &scalar, &vector);
    }
}
