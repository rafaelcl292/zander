const std = @import("std");

pub fn int(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn encoded(comptime T: type, value: T, buffer: *[(@bitSizeOf(T) + 6) / 7]u8) []const u8 {
    var remaining = value;
    var count: usize = 0;
    while (true) {
        var byte: u8 = @as(u8, @truncate(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(remaining)))) & 127;
        remaining >>= 7;
        const done = (remaining == 0 and byte & 64 == 0) or (remaining == -1 and byte & 64 != 0);
        if (!done) byte |= 128;
        buffer[count] = byte;
        count += 1;
        if (done) return buffer[0..count];
    }
}

/// Two passes avoid retaining an extra compressed copy of large weight arrays.
pub fn leb128(writer: *std.Io.Writer, comptime T: type, values: []const T) !void {
    var buffer: [(@bitSizeOf(T) + 6) / 7]u8 = undefined;
    var count: u32 = 0;
    for (values) |value| count = try std.math.add(u32, count, @intCast(encoded(T, value, &buffer).len));
    try writer.writeAll("COMPRESSED_LEB128");
    try int(writer, u32, count);
    for (values) |value| try writer.writeAll(encoded(T, value, &buffer));
}

test "signed compressed writer round-trips integer boundaries" {
    const values = [_]i32{ 0, -1, 63, 64, -64, -65, 127, 128, -32768, 32767, std.math.minInt(i32), std.math.maxInt(i32) };
    var buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    try leb128(&output, i32, &values);
    var reader: @import("reader.zig").Reader = .{ .bytes = output.buffered() };
    var decoded: [values.len]i32 = undefined;
    try reader.leb128(i32, &decoded);
    try std.testing.expectEqualSlices(i32, &values, &decoded);
    try std.testing.expectEqual(reader.bytes.len, reader.offset);
}
