const std = @import("std");
pub const ReadError = error{ Truncated, InvalidLeb128, IntegerOverflow };
/// Bounded, allocation-free reader for the upstream little-endian NNUE format.
pub const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,
    pub fn take(self: *Reader, count: usize) ReadError![]const u8 {
        if (count > self.bytes.len - self.offset) return error.Truncated;
        const result = self.bytes[self.offset..][0..count];
        self.offset += count;
        return result;
    }
    pub fn int(self: *Reader, comptime T: type) ReadError!T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }
    pub fn leb128(self: *Reader, comptime T: type, out: []T) ReadError!void {
        const magic = "COMPRESSED_LEB128";
        if (!std.mem.eql(u8, try self.take(magic.len), magic)) return error.InvalidLeb128;
        const byte_count = try self.int(u32);
        var block: Reader = .{ .bytes = try self.take(byte_count) };
        for (out) |*value| {
            var result: i64 = 0;
            var shift: u6 = 0;
            var done = false;
            for (0..(@bitSizeOf(T) + 6) / 7) |_| {
                const byte = try block.int(u8);
                result |= @as(i64, byte & 127) << shift;
                shift += 7;
                if (byte & 128 == 0) {
                    if (byte & 64 != 0) result |= -(@as(i64, 1) << shift);
                    done = true;
                    break;
                }
            }
            if (!done) return error.InvalidLeb128;
            if (result < std.math.minInt(T) or result > std.math.maxInt(T)) return error.IntegerOverflow;
            value.* = @intCast(result);
        }
        if (block.offset != block.bytes.len) return error.InvalidLeb128;
    }
};
test "signed LEB128 boundaries and malformed blocks" {
    var reader: Reader = .{ .bytes = "COMPRESSED_LEB128\x09\x00\x00\x00\x00\x7f\x3f\xc0\x00\x80\x80\x7e\x01" };
    var values: [6]i16 = undefined;
    try reader.leb128(i16, &values);
    try std.testing.expectEqualSlices(i16, &.{ 0, -1, 63, 64, -32768, 1 }, &values);
    reader = .{ .bytes = "COMPRESSED_LEB128\x01\x00\x00\x00\x80" };
    try std.testing.expectError(error.Truncated, reader.leb128(i16, values[0..1]));
    reader = .{ .bytes = "COMPRESSED_LEB128\x03\x00\x00\x00\xff\xff\x03" };
    try std.testing.expectError(error.IntegerOverflow, reader.leb128(i16, values[0..1]));
    reader = .{ .bytes = "COMPRESSED_LEB128\x02\x00\x00\x00\x00\x00" };
    try std.testing.expectError(error.InvalidLeb128, reader.leb128(i16, values[0..1]));
}
