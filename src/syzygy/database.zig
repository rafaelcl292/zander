const std = @import("std");
const idx = @import("index.zig");
const Table = @import("table.zig").Table;
const p = @import("../position.zig");
const mg = @import("../movegen.zig");
pub const Entry = struct { wdl: *Table, dtz: ?*Table = null };
pub const Probe = struct { value: i32, zeroing: bool = false };
pub const Database = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    maps: idx.Maps,
    entries: std.ArrayList(*Entry) = .empty,
    lookup: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
    cardinality: usize = 0,
    pub fn create(allocator: std.mem.Allocator, io: std.Io, paths: []const u8, keys: *const @import("../position_keys.zig").PositionKeys) !*Database {
        const self = try allocator.create(Database);
        self.* = .{ .allocator = allocator, .io = io, .maps = idx.Maps.init() };
        errdefer self.destroy();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var files: std.StringHashMapUnmanaged([]const u8) = .empty;
        var dirs = std.mem.tokenizeScalar(u8, paths, if (@import("builtin").os.tag == .windows) ';' else ':');
        while (dirs.next()) |path| {
            if (std.mem.eql(u8, path, "<empty>")) continue;
            var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
            defer dir.close(io);
            var iterator = dir.iterate();
            while (try iterator.next(io)) |file| {
                if (!std.mem.endsWith(u8, file.name, ".rtbw") and !std.mem.endsWith(u8, file.name, ".rtbz")) continue;
                if (files.contains(file.name)) continue;
                try files.put(a, try a.dupe(u8, file.name), try std.fs.path.join(a, &.{ path, file.name }));
            }
        }
        var iterator = files.iterator();
        while (iterator.next()) |file| {
            const name = file.key_ptr.*;
            if (!std.mem.endsWith(u8, name, ".rtbw")) continue;
            const stem = name[0 .. name.len - 5];
            const material = idx.Material.init(stem, keys) catch continue;
            const wdl_table = try Table.load(allocator, io, file.value_ptr.*, material, &self.maps, false);
            errdefer wdl_table.destroy(allocator, io);
            const entry = try allocator.create(Entry);
            errdefer allocator.destroy(entry);
            entry.* = .{ .wdl = wdl_table };
            const dtz_name = try std.fmt.allocPrint(a, "{s}.rtbz", .{stem});
            if (files.get(dtz_name)) |dtz_path| entry.dtz = try Table.load(allocator, io, dtz_path, material, &self.maps, true);
            errdefer if (entry.dtz) |dtz_table| dtz_table.destroy(allocator, io);
            try self.lookup.ensureUnusedCapacity(allocator, 2);
            try self.entries.append(allocator, entry);
            self.lookup.putAssumeCapacity(material.key, entry);
            self.lookup.putAssumeCapacity(material.reversed_key, entry);
            self.cardinality = @max(self.cardinality, material.piece_count);
        }
        return self;
    }
    pub fn destroy(self: *Database) void {
        const allocator = self.allocator;
        for (self.entries.items) |entry| {
            entry.wdl.destroy(allocator, self.io);
            if (entry.dtz) |dtz_table| dtz_table.destroy(allocator, self.io);
            allocator.destroy(entry);
        }
        self.entries.deinit(allocator);
        self.lookup.deinit(allocator);
        allocator.destroy(self);
    }
    fn raw(self: *const Database, pos: *const p.Position, distance: bool, outcome: i32) !?i32 {
        if (@popCount(pos.pieces()) == 2) return 0;
        const entry = self.lookup.get(pos.st.material_key) orelse return error.MissingTablebase;
        const table = if (distance) entry.dtz orelse return error.MissingTablebase else entry.wdl;
        return table.probe(pos, &self.maps, outcome);
    }
    pub fn wdl(self: *const Database, pos: *p.Position) anyerror!Probe {
        return self.search(pos, false);
    }
    fn search(self: *const Database, pos: *p.Position, zeroing_moves: bool) anyerror!Probe {
        var moves: mg.MoveList = .{};
        mg.generate(.legal, pos, &moves);
        var searched: usize = 0;
        var best: i32 = -2;
        for (moves.slice()) |move| {
            if (!pos.capture(move) and (!zeroing_moves or pos.board[@intFromEnum(move.from())].pieceType() != .pawn)) continue;
            searched += 1;
            var state: p.StateInfo = undefined;
            pos.doMove(move, &state);
            const result = self.search(pos, false) catch |err| {
                pos.undoMove(move);
                return err;
            };
            pos.undoMove(move);
            if (-result.value > best) {
                best = -result.value;
                if (best >= 2) return .{ .value = best, .zeroing = true };
            }
        }
        const exhausted = searched != 0 and searched == moves.len;
        const value = if (exhausted) best else (try self.raw(pos, false, 0)).?;
        if (best >= value) return .{ .value = best, .zeroing = best > 0 or exhausted };
        return .{ .value = value };
    }
    pub fn beforeZeroing(value: i32) i32 {
        return switch (value) {
            2 => 1,
            1 => 101,
            -1 => -101,
            -2 => -1,
            else => 0,
        };
    }
    pub fn dtz(self: *const Database, pos: *p.Position) anyerror!i32 {
        const result = try self.search(pos, true);
        if (result.value == 0) return 0;
        if (result.zeroing) return beforeZeroing(result.value);
        if (try self.raw(pos, true, result.value)) |value| return (value + @as(i32, if (@abs(result.value) == 1) 100 else 0)) * std.math.sign(result.value);
        var moves: mg.MoveList = .{};
        mg.generate(.legal, pos, &moves);
        var minimum: i32 = 0xffff;
        for (moves.slice()) |move| {
            const zeroing = pos.capture(move) or pos.board[@intFromEnum(move.from())].pieceType() == .pawn;
            var state: p.StateInfo = undefined;
            pos.doMove(move, &state);
            const probe = block: {
                if (zeroing) {
                    const child = self.search(pos, false) catch |err| {
                        pos.undoMove(move);
                        return err;
                    };
                    break :block -beforeZeroing(child.value);
                }
                const child = self.dtz(pos) catch |err| {
                    pos.undoMove(move);
                    return err;
                };
                break :block -child;
            };
            if (probe == 1 and pos.st.checkers != 0) {
                var replies: mg.MoveList = .{};
                mg.generate(.legal, pos, &replies);
                if (replies.len == 0) minimum = 1;
            }
            const value = probe + if (zeroing) @as(i32, 0) else std.math.sign(probe);
            if (value < minimum and std.math.sign(value) == std.math.sign(result.value)) minimum = value;
            pos.undoMove(move);
        }
        return if (minimum == 0xffff) -1 else minimum;
    }
};
