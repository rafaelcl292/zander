//! Physical layout snapshot for reproducible memory experiments.
const std = @import("std");
const z = @import("root.zig");

pub fn write(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\n");
    inline for (.{ z.search_support.Stack, z.position.StateInfo, z.nnue_accumulator.Accumulator, z.nnue_accumulator.Stack, z.nnue_accumulator.CacheEntry, z.nnue_accumulator.Caches, z.position.Position, z.tt.Entry, z.tt.Cluster, z.worker_memory.Storage }, 0..) |T, index| {
        if (index != 0) try writer.writeAll(",\n");
        try writer.print("\"{s}\":{{\"size\":{d},\"alignment\":{d},\"fields\":[", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, 0..) |name, Field, i| {
            if (i != 0) try writer.writeAll(",");
            try writer.print("{{\"name\":\"{s}\",\"offset\":{d},\"size\":{d}}}", .{ name, @offsetOf(T, name), @sizeOf(Field) });
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("\n}\n");
}
