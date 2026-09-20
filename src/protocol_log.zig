const std = @import("std");
/// Caller serializes input, output, and configuration with the UCI output mutex.
pub const Log = struct {
    destination: *std.Io.Writer,
    io: std.Io,
    file: ?std.Io.File.Writer = null,
    buffer: [4096]u8 = undefined,
    line_start: bool = true,
    interface: std.Io.Writer = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = &.{} },
    pub fn close(self: *Log) void {
        if (self.file) |*file| {
            file.interface.flush() catch {};
            file.file.close(self.io);
        }
        self.file = null;
        self.line_start = true;
    }
    pub fn configure(self: *Log, path: []const u8) !void {
        if (path.len == 0) return self.close();
        if (self.file) |*file| try file.interface.flush();
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        self.close();
        self.file = file.writer(self.io, &self.buffer);
    }
    fn record(self: *Log, prefix: []const u8, text: []const u8) !void {
        const file = if (self.file) |*file| file else return;
        var offset: usize = 0;
        while (offset < text.len) {
            if (self.line_start) try file.interface.writeAll(prefix);
            const end = if (std.mem.indexOfScalar(u8, text[offset..], '\n')) |index| offset + index + 1 else text.len;
            try file.interface.writeAll(text[offset..end]);
            self.line_start = text[end - 1] == '\n';
            offset = end;
        }
    }
    pub fn input(self: *Log, line: []const u8) !void {
        try self.record(">> ", line);
        try self.record(">> ", "\n");
        if (self.file) |*file| try file.interface.flush();
    }
    fn emit(self: *Log, bytes: []const u8) std.Io.Writer.Error!void {
        try self.destination.writeAll(bytes);
        try self.record("<< ", bytes);
    }
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Log = @fieldParentPtr("interface", writer);
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.emit(bytes);
            count += bytes.len;
        }
        for (0..splat) |_| try self.emit(data[data.len - 1]);
        return count + data[data.len - 1].len * splat;
    }
    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Log = @fieldParentPtr("interface", writer);
        try self.destination.flush();
        if (self.file) |*file| try file.interface.flush();
    }
};
