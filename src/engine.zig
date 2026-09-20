const std = @import("std");
const t = @import("types.zig");
const p = @import("position.zig");
const h = @import("history.zig");
const tt = @import("tt.zig");
const search = @import("search.zig");
const nn = @import("nnue/network.zig");
const acc = @import("nnue/accumulator.zig");
const tm = @import("time_management.zig");
const notation = @import("notation.zig");
pub const default_network = "networks/nn-134a887f4c8f.nnue";
/// Stable owner of one worker. Reconfiguration requires the search thread to
/// be joined. Only Control's atomic methods may run concurrently with search.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    tables: *@import("attacks.zig").Tables,
    keys: *@import("position_keys.zig").PositionKeys,
    network: ?*nn.Network = null,
    network_path: ?[]u8 = null,
    accumulators: *acc.Stack,
    caches: *acc.Caches,
    shared: h.SharedHistories,
    base: *@import("quiescence.zig").Worker,
    worker: search.Worker,
    clusters: []align(64) tt.Cluster,
    table: tt.Table,
    roots: []search.RootMove,
    states: []p.StateInfo,
    position: p.Position,
    control: @import("search_control.zig").Control,
    search_limits: search.Worker.Limits = .{ .depth = t.max_ply - 1 },
    requested: [t.max_moves]t.Move = undefined,
    original_time_adjust: f64 = -1,
    hash_mb: usize,
    node_time: tm.NodeTime = .{},
    node_rate: i64 = 0,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, hash_mb: usize) !*Engine {
        if (hash_mb < 1 or hash_mb > 4096) return error.InvalidHashSize;
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.io = io;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.tables = try a.create(@import("attacks.zig").Tables);
        self.tables.init();
        self.keys = try a.create(@import("position_keys.zig").PositionKeys);
        self.keys.init();
        self.accumulators = try a.create(acc.Stack);
        self.accumulators.reset();
        self.caches = try a.create(acc.Caches);
        const main = try a.create(h.ButterflyHistory);
        const low = try a.create(h.LowPlyHistory);
        const capture = try a.create(h.CapturePieceToHistory);
        const correction = try a.alloc(h.CorrectionEntry, h.correction_history_base_size);
        const pawn = try a.alloc(h.PawnEntry, h.pawn_history_base_size);
        const continuation = try a.create(h.ContinuationHistoryBlock);
        const continuation_correction = try a.create(h.ContinuationCorrectionHistory);
        self.shared = try h.SharedHistories.init(1, correction, continuation, pawn);
        self.roots = try a.alloc(search.RootMove, t.max_moves);
        self.base = try a.create(@import("quiescence.zig").Worker);
        self.clusters = try allocator.alignedAlloc(tt.Cluster, .@"64", hash_mb * 1024 * 1024 / @sizeOf(tt.Cluster));
        errdefer allocator.free(self.clusters);
        self.table = tt.Table.init(self.clusters);
        self.hash_mb = hash_mb;
        self.states = try allocator.alloc(p.StateInfo, 1);
        errdefer allocator.free(self.states);
        try self.position.set(p.start_fen, false, &self.states[0], self.tables, self.keys);
        self.network = null;
        self.network_path = null;
        self.control = .{ .context = self, .clock = clock };
        self.search_limits = .{ .depth = t.max_ply - 1 };
        self.original_time_adjust = -1;
        self.node_time = .{};
        self.node_rate = 0;
        self.base.* = .{ .network = undefined, .accumulators = self.accumulators, .caches = self.caches, .table = &self.table, .main_history = main, .low_ply_history = low, .capture_history = capture, .shared = &self.shared, .continuation_correction = continuation_correction, .control = &self.control };
        self.worker = search.Worker.init(self.base);
        self.worker.skill_rng = .init(@as(u64, @bitCast(clock(self))) | 1);
        self.newGame();
        return self;
    }
    pub fn destroy(self: *Engine) void {
        const allocator = self.allocator;
        if (self.network) |network| allocator.destroy(network);
        if (self.network_path) |path| allocator.free(path);
        allocator.free(self.states);
        allocator.free(self.clusters);
        self.arena.deinit();
        allocator.destroy(self);
    }
    fn clock(context: ?*anyopaque) i64 {
        const self: *Engine = @ptrCast(@alignCast(context.?));
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }
    pub fn newGame(self: *Engine) void {
        h.fill(self.base.main_history, -5);
        h.fill(self.base.low_ply_history, 102);
        h.fill(self.base.capture_history, -742);
        h.fill(self.base.continuation_correction, 5);
        self.shared.clearRange(0, 1);
        self.worker.tt_move_history.set(0);
        self.worker.previous_score = t.value_infinite;
        self.worker.previous_average = t.value_infinite;
        self.worker.previous_time_reduction = 0.85;
        self.original_time_adjust = -1;
        self.node_time = .{};
        self.table.clear();
        self.accumulators.reset();
        if (self.network) |network| self.caches.clear(&network.transformer);
    }
    pub fn resizeHash(self: *Engine, mb: usize) !void {
        if (mb < 1 or mb > 4096) return error.InvalidHashSize;
        const replacement = try self.allocator.alignedAlloc(tt.Cluster, .@"64", mb * 1024 * 1024 / @sizeOf(tt.Cluster));
        const table = tt.Table.init(replacement);
        self.allocator.free(self.clusters);
        self.clusters = replacement;
        self.table = table;
        self.hash_mb = mb;
    }
    pub fn loadNetwork(self: *Engine, path: []const u8) !void {
        const replacement = try self.allocator.create(nn.Network);
        errdefer self.allocator.destroy(replacement);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(200 * 1024 * 1024));
        defer self.allocator.free(bytes);
        _ = try replacement.load(bytes);
        const owned_path = try self.allocator.dupe(u8, path);
        if (self.network) |network| self.allocator.destroy(network);
        if (self.network_path) |old_path| self.allocator.free(old_path);
        self.network = replacement;
        self.network_path = owned_path;
        self.base.network = replacement;
        self.newGame();
    }
    pub fn ensureNetwork(self: *Engine) !void {
        if (self.network == null) try self.loadNetwork(default_network);
    }
    /// Build a replacement position and complete history before publishing it.
    /// StateInfo.previous pointers never survive a relocation of their storage.
    pub fn setPosition(self: *Engine, fen: []const u8, chess960: bool, moves: []const []const u8) !void {
        const states = try self.allocator.alloc(p.StateInfo, moves.len + 1);
        errdefer self.allocator.free(states);
        var position: p.Position = undefined;
        try position.set(fen, chess960, &states[0], self.tables, self.keys);
        for (moves, 1..) |text, i| {
            const move = notation.parseMove(&position, text) orelse return error.IllegalMove;
            position.doMove(move, &states[i]);
        }
        self.allocator.free(self.states);
        self.states = states;
        self.position = position;
    }
    pub fn prepareSearch(self: *Engine, limits: search.Worker.Limits, time_limits: tm.Limits, overhead: i64, ponder_option: bool) !void {
        if (limits.depth < 1 or limits.depth >= t.max_ply) return error.InvalidDepth;
        if (limits.multi_pv < 1 or limits.multi_pv > t.max_moves) return error.InvalidMultiPV;
        if (limits.search_moves.len > self.requested.len) return error.TooManyRootMoves;
        try self.ensureNetwork();
        @memcpy(self.requested[0..limits.search_moves.len], limits.search_moves);
        self.search_limits = limits;
        self.search_limits.search_moves = self.requested[0..limits.search_moves.len];
        var adjusted_overhead = overhead;
        const adjusted_limits = self.node_time.prepare(time_limits, @intFromEnum(self.position.side), self.node_rate, &adjusted_overhead);
        const budget = tm.Budget.init(adjusted_limits, @intFromEnum(self.position.side), self.position.game_ply, adjusted_overhead, ponder_option, &self.original_time_adjust);
        self.control.reset(adjusted_limits, budget);
    }
    pub fn runSearch(self: *Engine) !search.Worker.Result {
        const result = try self.worker.iterativeDeepening(&self.position, self.roots, self.search_limits);
        if (self.control.limits.npmsec != 0 and self.control.limits.managed()) self.node_time.advance(@intCast(result.nodes), self.control.limits.increment[@intFromEnum(self.position.side)]);
        return result;
    }
    pub fn extendPonder(self: *Engine) void {
        if (self.worker.root_moves.len == 0) return;
        const pv = &self.worker.root_moves[0].pv;
        if (pv.len != 1) return;
        var state: p.StateInfo = undefined;
        const first = pv.moves[0];
        self.position.doMove(first, &state);
        defer self.position.undoMove(first);
        if (self.position.isDraw(1)) return;
        const probe = self.table.probe(self.position.key());
        if (probe.found and self.position.pseudoLegal(probe.data.move) and self.position.legal(probe.data.move)) pv.append(probe.data.move);
    }
};
