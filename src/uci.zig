const std = @import("std");
const e = @import("engine.zig");
const t = @import("types.zig");
const p = @import("position.zig");
const search = @import("search.zig");
const notation = @import("notation.zig");
const tm = @import("time_management.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, network_path: ?[]const u8) !void {
    const engine = try e.Engine.create(allocator, io, 16);
    defer engine.destroy();
    if (network_path) |path| try engine.loadNetwork(path);
    var output_buffer: [16384]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), io, &output_buffer);
    var session: Session = .{ .engine = engine, .writer = &output.interface };
    defer session.stopAndJoin();
    engine.worker.progress_context = &session;
    engine.worker.on_progress = Session.progress;
    engine.wait_context = &session;
    engine.on_wait = Session.waitForFinish;
    var input_buffer: [65536]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &input_buffer);
    var tokens: [16384][]const u8 = undefined;
    while (true) {
        const line = input.interface.takeDelimiter('\n') catch |err| {
            session.report(err);
            if (err == error.StreamTooLong) {
                _ = input.interface.discardDelimiterInclusive('\n') catch break;
                continue;
            }
            break;
        } orelse break;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        var count: usize = 0;
        while (words.next()) |word| {
            if (count == tokens.len) break;
            tokens[count] = word;
            count += 1;
        }
        if (count == tokens.len) {
            session.report(error.CommandTooLong);
            continue;
        }
        if (count == 0) continue;
        if (std.mem.eql(u8, tokens[0], "quit")) break;
        session.command(tokens[0..count]) catch |err| session.report(err);
    }
}

const Session = struct {
    engine: *e.Engine,
    writer: *std.Io.Writer,
    thread: ?std.Thread = null,
    output_mutex: std.Io.Mutex = .init,
    wake_mutex: std.Io.Mutex = .init,
    wake_condition: std.Io.Condition = .init,
    multi_pv: usize = 1,
    skill_level: i32 = 20,
    limit_strength: bool = false,
    elo: i32 = 1320,
    chess960: bool = false,
    show_wdl: bool = false,
    ponder_option: bool = false,
    move_overhead: i64 = 10,

    fn report(self: *Session, err: anyerror) void {
        self.output_mutex.lockUncancelable(self.engine.io);
        defer self.output_mutex.unlock(self.engine.io);
        self.writer.print("info string error {s}\n", .{@errorName(err)}) catch {};
        self.writer.flush() catch {};
    }
    fn text(self: *Session, message: []const u8) !void {
        self.output_mutex.lockUncancelable(self.engine.io);
        defer self.output_mutex.unlock(self.engine.io);
        try self.writer.writeAll(message);
        try self.writer.flush();
    }
    fn wake(self: *Session) void {
        self.wake_mutex.lockUncancelable(self.engine.io);
        defer self.wake_mutex.unlock(self.engine.io);
        self.wake_condition.broadcast(self.engine.io);
    }
    fn stopAndJoin(self: *Session) void {
        if (self.thread) |thread| {
            self.engine.control.requestStop();
            self.wake();
            thread.join();
            self.thread = null;
        }
    }
    fn command(self: *Session, args: []const []const u8) !void {
        const cmd = args[0];
        if (std.mem.eql(u8, cmd, "uci")) {
            try self.text("id name Zander\nid author Zander contributors\n" ++
                "option name Hash type spin default 16 min 1 max 4096\n" ++
                "option name SyzygyPath type string default <empty>\n" ++
                "option name SyzygyProbeDepth type spin default 1 min 1 max 100\n" ++
                "option name Syzygy50MoveRule type check default true\n" ++
                "option name SyzygyProbeLimit type spin default 7 min 0 max 7\n" ++
                "option name NumaPolicy type string default auto\n" ++
                "option name PagePolicy type combo default auto var auto var small var transparent var huge2m var huge1g\n" ++
                "option name Threads type spin default 1 min 1 max 256\n" ++
                "option name Skill Level type spin default 20 min 0 max 20\n" ++
                "option name UCI_LimitStrength type check default false\n" ++
                "option name UCI_Elo type spin default 1320 min 1320 max 3190\n" ++
                "option name nodestime type spin default 0 min 0 max 10000\n" ++
                "option name MultiPV type spin default 1 min 1 max 256\n" ++
                "option name Ponder type check default false\n" ++
                "option name UCI_Chess960 type check default false\n" ++
                "option name UCI_ShowWDL type check default false\n" ++
                "option name Move Overhead type spin default 10 min 0 max 5000\n" ++
                "option name EvalFile type string default " ++ e.default_network ++ "\n" ++
                "option name Clear Hash type button\nuciok\n");
        } else if (std.mem.eql(u8, cmd, "isready")) {
            if (self.thread == null) self.engine.ensureNetwork() catch |err| self.report(err);
            try self.text("readyok\n");
        } else if (std.mem.eql(u8, cmd, "stop")) {
            self.stopAndJoin();
        } else if (std.mem.eql(u8, cmd, "ponderhit")) {
            self.engine.control.ponderHit();
            self.wake();
        } else if (std.mem.eql(u8, cmd, "ucinewgame")) {
            self.stopAndJoin();
            self.engine.newGame();
        } else if (std.mem.eql(u8, cmd, "setoption")) {
            self.stopAndJoin();
            try self.setOption(args[1..]);
        } else if (std.mem.eql(u8, cmd, "position")) {
            self.stopAndJoin();
            try self.setPosition(args[1..]);
        } else if (std.mem.eql(u8, cmd, "go")) {
            self.stopAndJoin();
            self.go(args[1..]) catch |err| {
                self.report(err);
                try self.text("bestmove 0000\n");
            };
        } else if (std.mem.eql(u8, cmd, "bench")) {
            self.stopAndJoin();
            try self.bench(args[1..]);
        } else if (std.mem.eql(u8, cmd, "d") or std.mem.eql(u8, cmd, "flip") or std.mem.eql(u8, cmd, "eval") or std.mem.eql(u8, cmd, "compiler") or std.mem.eql(u8, cmd, "export_net")) {
            self.stopAndJoin();
            try self.diagnostic(args);
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "license") or std.mem.eql(u8, cmd, "--license")) {
            try self.text("Zander is a Stockfish port in Zig, licensed under GPL-3.0-or-later. See README.md and LICENSE.\nCommands: uci, position, go, stop, ponderhit, setoption, isready, ucinewgame, d, flip, eval, compiler, export_net, quit.\n");
        } else if (std.mem.startsWith(u8, cmd, "#")) {
            return;
        } else if (std.mem.eql(u8, cmd, "debug")) {
            if (args.len != 2 or (!std.mem.eql(u8, args[1], "on") and !std.mem.eql(u8, args[1], "off"))) return error.InvalidDebugCommand;
        } else if (std.mem.eql(u8, cmd, "register")) {
            try self.text("registration ok\n");
        } else return error.UnknownCommand;
    }
    // Defaults are copied from the pinned GPL-3.0-or-later benchmark.cpp.
    fn bench(self: *Session, args: []const []const u8) !void {
        if (args.len > 5) return error.UnexpectedArgument;
        const hash = if (args.len > 0) args[0] else "16";
        const threads = if (args.len > 1) args[1] else "1";
        const limit = if (args.len > 2) args[2] else "13";
        const source = if (args.len > 3) args[3] else "default";
        const kind = if (args.len > 4) args[4] else "depth";
        var current_buffer: [256]u8 = undefined;
        var current = std.Io.Writer.fixed(&current_buffer);
        try self.engine.position.writeFen(&current);
        const file = if (!std.mem.eql(u8, source, "default") and !std.mem.eql(u8, source, "current")) try std.Io.Dir.cwd().readFileAlloc(self.engine.io, source, self.engine.allocator, .limited(16 * 1024 * 1024)) else null;
        defer if (file) |bytes| self.engine.allocator.free(bytes);
        const positions = file orelse if (std.mem.eql(u8, source, "current")) current.buffered() else @embedFile("benchmark_positions.txt");
        try self.setOption(&.{ "name", "Threads", "value", threads });
        try self.setOption(&.{ "name", "Hash", "value", hash });
        self.engine.newGame();
        const start = std.Io.Clock.awake.now(self.engine.io).toMilliseconds();
        var total: u64 = 0;
        var lines = std.mem.tokenizeAny(u8, positions, "\r\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "setoption ")) {
                var parts = std.mem.tokenizeScalar(u8, line[10..], ' ');
                var tokens: [64][]const u8 = undefined;
                var n: usize = 0;
                while (parts.next()) |part| {
                    if (n == tokens.len) return error.TooManyTokens;
                    tokens[n] = part;
                    n += 1;
                }
                try self.setOption(tokens[0..n]);
                continue;
            }
            const split = std.mem.indexOf(u8, line, " moves ") orelse line.len;
            var moves: [16384][]const u8 = undefined;
            var count: usize = 0;
            if (split < line.len) {
                var tokens = std.mem.tokenizeScalar(u8, line[split + 7 ..], ' ');
                while (tokens.next()) |move| {
                    if (count == moves.len) return error.TooManyTokens;
                    moves[count] = move;
                    count += 1;
                }
            }
            try self.engine.setPosition(line[0..split], self.chess960, moves[0..count]);
            if (std.mem.eql(u8, kind, "eval")) {
                try self.diagnostic(&.{"eval"});
            } else if (std.mem.eql(u8, kind, "perft")) {
                total += try self.writePerft(try integer(u8, limit, 1, t.max_ply - 1));
            } else {
                try self.go(&.{ kind, limit });
                if (self.thread) |thread| thread.join();
                self.thread = null;
                total += self.engine.totalNodes();
            }
        }
        const elapsed: u64 = @intCast(@max(1, std.Io.Clock.awake.now(self.engine.io).toMilliseconds() - start + 1));
        self.output_mutex.lockUncancelable(self.engine.io);
        defer self.output_mutex.unlock(self.engine.io);
        try self.writer.print("Total time (ms) : {d}\nNodes searched  : {d}\nNodes/second    : {d}\n", .{ elapsed, total, 1000 * total / elapsed });
        try self.writer.flush();
    }
    fn diagnostic(self: *Session, args: []const []const u8) !void {
        const cmd = args[0];
        if (!std.mem.eql(u8, cmd, "export_net") and args.len != 1) return error.UnexpectedArgument;
        const pos = &self.engine.position;
        if (std.mem.eql(u8, cmd, "flip")) {
            var original: [256]u8 = undefined;
            var fen = std.Io.Writer.fixed(&original);
            try pos.writeFen(&fen);
            var fields = std.mem.tokenizeScalar(u8, fen.buffered(), ' ');
            var ranks = std.mem.splitScalar(u8, fields.next().?, '/');
            var rows: [8][]const u8 = undefined;
            for (&rows) |*row| row.* = ranks.next().?;
            var buffer: [256]u8 = undefined;
            var flipped = std.Io.Writer.fixed(&buffer);
            for (0..8) |i| {
                for (rows[7 - i]) |c| try flipped.writeByte(if (std.ascii.isLower(c)) std.ascii.toUpper(c) else std.ascii.toLower(c));
                if (i != 7) try flipped.writeByte('/');
            }
            try flipped.writeAll(if (std.mem.eql(u8, fields.next().?, "w")) " b " else " w ");
            for (fields.next().?) |c| try flipped.writeByte(if (std.ascii.isLower(c)) std.ascii.toUpper(c) else std.ascii.toLower(c));
            try flipped.writeByte(' ');
            const ep = fields.next().?;
            if (ep[0] == '-') try flipped.writeByte('-') else try flipped.print("{c}{c}", .{ ep[0], @as(u8, if (ep[1] == '3') '6' else '3') });
            try flipped.print(" {s} {s}", .{ fields.next().?, fields.next().? });
            try self.engine.setPosition(flipped.buffered(), pos.chess960, &.{});
            return;
        }
        self.output_mutex.lockUncancelable(self.engine.io);
        defer self.output_mutex.unlock(self.engine.io);
        if (std.mem.eql(u8, cmd, "d")) {
            const border = " +---+---+---+---+---+---+---+---+\n";
            try self.writer.writeAll("\n");
            try self.writer.writeAll(border);
            for (0..8) |r| {
                for (0..8) |f| try self.writer.print(" | {c}", .{" PNBRQK  pnbrqk"[@intFromEnum(pos.pieceOn(t.Square.make(@intCast(f), @intCast(7 - r))))]});
                try self.writer.print(" | {d}\n{s}", .{ 8 - r, border });
            }
            try self.writer.writeAll("   a   b   c   d   e   f   g   h\n\nFen: ");
            try pos.writeFen(self.writer);
            try self.writer.print("\nKey: {X:0>16}\nCheckers: ", .{pos.key()});
            var checkers = pos.st.checkers;
            while (checkers != 0) {
                const square: t.Square = @enumFromInt(@ctz(checkers));
                checkers &= checkers - 1;
                try self.writer.print("{c}{c} ", .{ @as(u8, 'a') + square.file(), @as(u8, '1') + square.rank() });
            }
            try self.writer.writeByte('\n');
        } else if (std.mem.eql(u8, cmd, "compiler")) {
            const builtin = @import("builtin");
            try self.writer.print("Zig {s}\nTarget: {s}-{s}\nOptimization: {s}\nNNUE backend: {s}\n", .{ builtin.zig_version_string, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.mode), @tagName(@import("backend").nnue_backend) });
        } else if (std.mem.eql(u8, cmd, "eval")) {
            try self.engine.ensureNetwork();
            if (pos.st.checkers != 0) {
                try self.writer.writeAll("Final evaluation: none (in check)\n");
            } else {
                self.engine.accumulators.reset();
                const network = self.engine.network.?;
                const trace = network.trace(pos, self.engine.accumulators, self.engine.caches);
                const bucket = (@popCount(pos.pieces()) - 1) / 4;
                const border = "+------------+------------+------------+------------+\n";
                try self.writer.print("NNUE network contributions (Normalized, {s} to move)\n{s}", .{ if (pos.side == .white) "White" else "Black", border });
                try self.writer.writeAll("|   Bucket   |  Material  | Positional |   Total    |\n|            |   (PSQT)   |  (Layers)  |            |\n");
                try self.writer.writeAll(border);
                for (trace, 0..) |out, index| {
                    try self.writer.print("|  {d}         |  ", .{index});
                    for ([_]i32{ out.psqt, out.positional, out.psqt + out.positional }) |value| {
                        try self.writer.print("{c}{d:6.2}   |  ", .{ @as(u8, if (value < 0) '-' else if (value > 0) '+' else ' '), @as(f64, @floatFromInt(@abs(notation.centipawns(value, pos)))) / 100.0 });
                    }
                    if (index == bucket) try self.writer.writeAll("<-- this bucket is used");
                    try self.writer.writeByte('\n');
                }
                try self.writer.writeAll(border);
                const raw = trace[bucket].psqt + trace[bucket].positional;
                try self.writer.print("NNUE evaluation          {s}{d} (side to move, internal units)\n", .{ if (raw >= 0) "+" else "", raw });
                const sign: i32 = if (pos.side == .white) 1 else -1;
                const values = [_]i32{ notation.centipawns(raw * sign, pos), notation.centipawns(network.evaluateAdjusted(pos, self.engine.accumulators, self.engine.caches, 0) * sign, pos) };
                for (values, [_][]const u8{ "NNUE evaluation", "Final evaluation" }) |value, label| {
                    try self.writer.print("{s}      {s}{d:.2} (white side)\n", .{ label, if (value >= 0) "+" else "", @as(f64, @floatFromInt(value)) / 100.0 });
                }
            }
        } else if (std.mem.eql(u8, cmd, "export_net")) {
            if (args.len > 2) return error.UnexpectedArgument;
            try self.engine.ensureNetwork();
            const name = if (args.len == 2) args[1] else "nn-export.nnue";
            const file = try std.Io.Dir.cwd().createFile(self.engine.io, name, .{});
            defer file.close(self.engine.io);
            var buffer: [65536]u8 = undefined;
            var output = file.writer(self.engine.io, &buffer);
            try self.engine.network.?.save(&output.interface, "Zander exported network");
            try output.interface.flush();
            try self.writer.print("info string Network saved to {s}\n", .{name});
        }
        try self.writer.flush();
    }
    fn integer(comptime T: type, text_value: []const u8, min: T, max: T) !T {
        const value = std.fmt.parseInt(T, text_value, 10) catch return error.InvalidNumber;
        if (value < min or value > max) return error.OutOfRange;
        return value;
    }
    fn boolean(value: []const u8) !bool {
        if (std.ascii.eqlIgnoreCase(value, "true")) return true;
        if (std.ascii.eqlIgnoreCase(value, "false")) return false;
        return error.InvalidBoolean;
    }
    fn setOption(self: *Session, args: []const []const u8) !void {
        if (args.len < 2 or !std.mem.eql(u8, args[0], "name")) return error.InvalidOption;
        var split: usize = 1;
        while (split < args.len and !std.mem.eql(u8, args[split], "value")) split += 1;
        const name = try std.mem.join(self.engine.allocator, " ", args[1..split]);
        defer self.engine.allocator.free(name);
        const value = try std.mem.join(self.engine.allocator, " ", args[if (split < args.len) split + 1 else split..]);
        defer self.engine.allocator.free(value);
        if (std.ascii.eqlIgnoreCase(name, "SyzygyPath")) {
            try self.engine.loadTablebases(value);
        } else if (std.ascii.eqlIgnoreCase(name, "SyzygyProbeDepth")) {
            self.engine.worker.tb_options.depth = try integer(i32, value, 1, 100);
        } else if (std.ascii.eqlIgnoreCase(name, "Syzygy50MoveRule")) {
            self.engine.worker.tb_options.rule50 = try boolean(value);
            self.engine.newGame();
        } else if (std.ascii.eqlIgnoreCase(name, "SyzygyProbeLimit")) {
            self.engine.worker.tb_options.limit = try integer(usize, value, 0, 7);
        } else if (std.ascii.eqlIgnoreCase(name, "NumaPolicy")) {
            const numa = @import("numa.zig");
            const policy = std.meta.stringToEnum(numa.Policy, value) orelse numa.Policy.custom;
            const topology = switch (policy) {
                .custom => try numa.Topology.fromString(value),
                .hardware => numa.Topology.discoverWithAffinity(self.engine.io, false),
                else => self.engine.startup_topology,
            };
            const previous = self.engine.numa_policy;
            const previous_topology = self.engine.topology;
            self.engine.numa_policy = policy;
            self.engine.topology = topology;
            self.engine.resizeThreads(self.engine.helpers.len + 1) catch |err| {
                self.engine.numa_policy = previous;
                self.engine.topology = previous_topology;
                return err;
            };
        } else if (std.ascii.eqlIgnoreCase(name, "PagePolicy")) {
            const policy = std.meta.stringToEnum(@import("memory.zig").PagePolicy, value) orelse return error.InvalidPagePolicy;
            const previous = self.engine.page_policy;
            self.engine.page_policy = policy;
            self.engine.resizeHash(self.engine.hash_mb) catch |err| {
                self.engine.page_policy = previous;
                return err;
            };
        } else if (std.ascii.eqlIgnoreCase(name, "Hash")) try self.engine.resizeHash(try integer(usize, value, 1, 4096)) else if (std.ascii.eqlIgnoreCase(name, "Threads")) {
            try self.engine.resizeThreads(try integer(usize, value, 1, 256));
        } else if (std.ascii.eqlIgnoreCase(name, "Skill Level")) self.skill_level = try integer(i32, value, 0, 20) else if (std.ascii.eqlIgnoreCase(name, "UCI_LimitStrength")) self.limit_strength = try boolean(value) else if (std.ascii.eqlIgnoreCase(name, "UCI_Elo")) self.elo = try integer(i32, value, 1320, 3190) else if (std.ascii.eqlIgnoreCase(name, "nodestime")) {
            self.engine.node_rate = try integer(i64, value, 0, 10000);
            self.engine.node_time = .{};
        } else if (std.ascii.eqlIgnoreCase(name, "MultiPV")) self.multi_pv = try integer(usize, value, 1, t.max_moves) else if (std.ascii.eqlIgnoreCase(name, "Ponder")) self.ponder_option = try boolean(value) else if (std.ascii.eqlIgnoreCase(name, "UCI_Chess960")) self.chess960 = try boolean(value) else if (std.ascii.eqlIgnoreCase(name, "UCI_ShowWDL")) self.show_wdl = try boolean(value) else if (std.ascii.eqlIgnoreCase(name, "Move Overhead")) self.move_overhead = try integer(i64, value, 0, 5000) else if (std.ascii.eqlIgnoreCase(name, "EvalFile")) {
            if (value.len == 0) return error.EmptyNetworkPath;
            try self.engine.loadNetwork(value);
        } else if (std.ascii.eqlIgnoreCase(name, "Clear Hash")) self.engine.newGame() else return error.UnknownOption;
    }
    fn setPosition(self: *Session, args: []const []const u8) !void {
        if (args.len == 0) return error.MissingPosition;
        var fen_buffer: [256]u8 = undefined;
        var fen: []const u8 = undefined;
        var next: usize = undefined;
        if (std.mem.eql(u8, args[0], "startpos")) {
            fen = p.start_fen;
            next = 1;
        } else if (std.mem.eql(u8, args[0], "fen") and args.len >= 5) {
            var output = std.Io.Writer.fixed(&fen_buffer);
            next = 1;
            while (next < args.len and !std.mem.eql(u8, args[next], "moves")) : (next += 1) {
                if (next > 6) return error.InvalidPosition;
                if (next > 1) try output.writeByte(' ');
                try output.writeAll(args[next]);
            }
            if (next < 5) return error.InvalidPosition;
            fen = output.buffered();
        } else return error.InvalidPosition;
        if (next < args.len) {
            if (!std.mem.eql(u8, args[next], "moves")) return error.ExpectedMoves;
            next += 1;
        }
        try self.engine.setPosition(fen, self.chess960, args[next..]);
    }
    fn writePerft(self: *Session, depth: u8) !u64 {
        self.output_mutex.lockUncancelable(self.engine.io);
        defer self.output_mutex.unlock(self.engine.io);
        var moves: @import("movegen.zig").MoveList = .{};
        const pos = &self.engine.position;
        @import("movegen.zig").generate(.legal, pos, &moves);
        var total: u64 = 0;
        for (moves.slice()) |move| {
            const nodes = block: {
                if (depth == 1) break :block 1;
                var state: @import("position.zig").StateInfo = undefined;
                pos.doMove(move, &state);
                defer pos.undoMove(move);
                break :block @import("perft.zig").count(pos, depth - 1);
            };
            total += nodes;
            var buffer: [6]u8 = undefined;
            try self.writer.print("{s}: {d}\n", .{ notation.moveText(move, pos.chess960, &buffer), nodes });
        }
        try self.writer.print("\nNodes searched: {d}\n\n", .{total});
        try self.writer.flush();
        return total;
    }
    fn go(self: *Session, args: []const []const u8) !void {
        if (args.len != 0 and std.mem.eql(u8, args[0], "perft")) {
            if (args.len != 2) return error.InvalidPerftCommand;
            _ = try self.writePerft(try integer(u8, args[1], 1, t.max_ply - 1));
            return;
        }
        var limits: search.Worker.Limits = .{ .depth = t.max_ply - 1, .multi_pv = self.multi_pv };
        var time_limits: tm.Limits = .{};
        var requested: [t.max_moves]t.Move = undefined;
        var count: usize = 0;
        var i: usize = 0;
        while (i < args.len) {
            const key = args[i];
            i += 1;
            if (std.mem.eql(u8, key, "infinite")) {
                time_limits.infinite = true;
                continue;
            }
            if (std.mem.eql(u8, key, "ponder")) {
                time_limits.ponder = true;
                continue;
            }
            if (std.mem.eql(u8, key, "searchmoves")) {
                while (i < args.len and !isGoKeyword(args[i])) : (i += 1) {
                    if (notation.parseMove(&self.engine.position, args[i])) |move| {
                        if (count == requested.len) return error.TooManyRootMoves;
                        requested[count] = move;
                        count += 1;
                    }
                }
                continue;
            }
            if (i == args.len) return error.MissingGoValue;
            const value = args[i];
            i += 1;
            if (std.mem.eql(u8, key, "depth")) limits.depth = try integer(i32, value, 1, t.max_ply - 1) else if (std.mem.eql(u8, key, "nodes")) time_limits.nodes = try integer(u64, value, 0, std.math.maxInt(i64)) else if (std.mem.eql(u8, key, "movetime")) time_limits.move_time = try integer(i64, value, 0, 1_000_000_000_000) else if (std.mem.eql(u8, key, "wtime")) time_limits.time[0] = try integer(i64, value, 0, 1_000_000_000_000) else if (std.mem.eql(u8, key, "btime")) time_limits.time[1] = try integer(i64, value, 0, 1_000_000_000_000) else if (std.mem.eql(u8, key, "winc")) time_limits.increment[0] = try integer(i64, value, 0, 1_000_000_000_000) else if (std.mem.eql(u8, key, "binc")) time_limits.increment[1] = try integer(i64, value, 0, 1_000_000_000_000) else if (std.mem.eql(u8, key, "movestogo")) time_limits.moves_to_go = try integer(i32, value, 0, 100000) else if (std.mem.eql(u8, key, "mate")) time_limits.mate = try integer(i32, value, 0, t.max_ply / 2) else return error.UnknownGoOption;
        }
        limits.search_moves = requested[0..count];
        self.engine.worker.skill_level = self.skill_level;
        self.engine.worker.skill_elo = if (self.limit_strength) self.elo else 0;
        try self.engine.prepareSearch(limits, time_limits, self.move_overhead, self.ponder_option);
        self.thread = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, searchThread, .{self});
    }
    fn isGoKeyword(word: []const u8) bool {
        for ([_][]const u8{ "infinite", "ponder", "searchmoves", "depth", "nodes", "movetime", "wtime", "btime", "winc", "binc", "movestogo", "mate" }) |key| if (std.mem.eql(u8, word, key)) {
            return true;
        };
        return false;
    }
    fn searchThread(self: *Session) void {
        const result = self.engine.runSearch() catch |err| {
            self.report(err);
            self.text("bestmove 0000\n") catch {};
            return;
        };
        self.engine.extendPonder();
        self.output_mutex.lockUncancelable(self.engine.io);
        defer self.output_mutex.unlock(self.engine.io);
        self.writeInfo() catch {};
        var buffer: [6]u8 = undefined;
        self.writer.print("bestmove {s}", .{notation.moveText(result.best_move, self.engine.position.chess960, &buffer)}) catch {};
        if (self.engine.worker.root_moves.len != 0 and self.engine.worker.root_moves[0].pv.len > 1) self.writer.print(" ponder {s}", .{notation.moveText(self.engine.worker.root_moves[0].pv.moves[1], self.engine.position.chess960, &buffer)}) catch {};
        self.writer.writeByte('\n') catch {};
        self.writer.flush() catch {};
    }
    fn waitForFinish(context: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context.?));
        self.wake_mutex.lockUncancelable(self.engine.io);
        defer self.wake_mutex.unlock(self.engine.io);
        while (!self.engine.control.stopped() and (self.engine.control.ponder.load(.acquire) or self.engine.control.limits.infinite)) self.wake_condition.waitUncancelable(self.engine.io, &self.wake_mutex);
    }
    fn progress(context: ?*anyopaque, _: *search.Worker) void {
        const self: *Session = @ptrCast(@alignCast(context.?));
        self.output_mutex.lockUncancelable(self.engine.io);
        defer self.output_mutex.unlock(self.engine.io);
        self.writeInfo() catch {
            self.engine.control.requestStop();
        };
        self.writer.flush() catch {
            self.engine.control.requestStop();
        };
    }
    fn writeInfo(self: *Session) !void {
        const worker = &self.engine.worker;
        if (worker.root_moves.len == 0) {
            try self.writer.writeAll("info depth 0 score ");
            try notation.writeScore(self.writer, if (self.engine.position.st.checkers != 0) -t.value_mate else 0, &self.engine.position);
            try self.writer.writeAll(" nodes 0\n");
            return;
        }
        const elapsed = @as(u64, @intCast(@max(1, self.engine.control.elapsed())));
        for (worker.root_moves[0..@min(self.multi_pv, worker.root_moves.len)], 1..) |*root, index| {
            const previous = root.score == -t.value_infinite;
            if (worker.root_depth <= 1 and previous and index > 1) continue;
            var value = if (previous) root.previous_score else root.uci_score;
            if (value == -t.value_infinite) value = 0;
            const tb_score = worker.tb_config.root_in_tb and @abs(value) < @import("search_support.zig").mate_in_max_ply;
            if (tb_score) value = root.tb_score;
            var extended: std.ArrayList(t.Move) = .empty;
            defer extended.deinit(self.engine.allocator);
            const support = @import("search_support.zig");
            if (@abs(value) >= support.tb_win_in_max_ply and @abs(value) < support.mate_in_max_ply and !previous and (!root.isInexact() or tb_score)) {
                if (worker.tablebases) |database| {
                    try extended.appendSlice(self.engine.allocator, root.pv.slice());
                    if (try @import("syzygy/pv.zig").extend(self.engine.allocator, &extended, database, worker.tb_options, &self.engine.control, &self.engine.position, &value, @min(self.multi_pv, worker.root_moves.len), self.move_overhead)) try self.writer.writeAll("info string Syzygy PV extension reached its time limit\n");
                    // Retain the corrected search prefix, including the ponder move.
                    root.pv.resize(@min(extended.items.len, root.pv.moves.len));
                    @memcpy(root.pv.moves[0..root.pv.len], extended.items[0..root.pv.len]);
                }
            }
            const depth = if (previous) @max(1, worker.root_depth - 1) else worker.root_depth;
            try self.writer.print("info depth {d} seldepth {d} multipv {d} score ", .{ depth, root.sel_depth, index });
            try notation.writeScore(self.writer, value, &self.engine.position);
            if (!previous and !tb_score) {
                if (root.inexact_lower) try self.writer.writeAll(" lowerbound") else if (root.inexact_upper) try self.writer.writeAll(" upperbound");
            }
            if (self.show_wdl) {
                const wdl = notation.wdl(value, &self.engine.position);
                try self.writer.print(" wdl {d} {d} {d}", .{ wdl[0], wdl[1], wdl[2] });
            }
            try self.writer.print(" nodes {d} nps {d} hashfull {d} tbhits {d} time {d} pv", .{ self.engine.totalNodes(), self.engine.totalNodes() * 1000 / elapsed, self.engine.table.hashfull(0), self.engine.tablebaseHits(), elapsed });
            const pv = if (previous) &root.previous_pv else &root.pv;
            for (if (extended.items.len != 0) extended.items else pv.slice()) |move| {
                var buffer: [6]u8 = undefined;
                try self.writer.print(" {s}", .{notation.moveText(move, self.engine.position.chess960, &buffer)});
            }
            try self.writer.writeByte('\n');
        }
    }
};
