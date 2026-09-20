const std = @import("std");
const t = @import("types.zig");
const p = @import("position.zig");
const h = @import("history.zig");
const tt = @import("tt.zig");
const search = @import("search.zig");
const nn = @import("nnue/network.zig");
const acc = @import("nnue/accumulator.zig");
const tm = @import("time_management.zig");
const numa = @import("numa.zig");
const Group = @import("numa_group.zig").Group;
const memory = @import("memory.zig");
const Helper = @import("search_thread.zig").Helper;
const notation = @import("notation.zig");
pub const default_network = "networks/nn-134a887f4c8f.nnue";
/// Stable owner of the main worker and persistent helper threads. Reconfiguration requires the search thread to
/// be joined. Only Control's atomic methods may run concurrently with search.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    shared_arena: std.heap.ArenaAllocator,
    helpers: []*Helper,
    main_storage: *Helper,
    topology: numa.Topology,
    numa_policy: numa.Policy,
    groups: []*Group,
    worker_nodes: [256]usize,
    io: std.Io,
    tables: *@import("attacks.zig").Tables,
    keys: *@import("position_keys.zig").PositionKeys,
    network: ?*nn.Network = null,
    tablebases: ?*@import("syzygy/database.zig").Database,
    network_path: ?[]u8 = null,
    accumulators: *acc.Stack,
    caches: *acc.Caches,
    shared: h.SharedHistories,
    base: *@import("quiescence.zig").Worker,
    worker: search.Worker,
    clusters: []align(64) tt.Cluster,
    hash_region: memory.Region,
    page_policy: memory.PagePolicy = .auto,
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
    wait_context: ?*anyopaque = null,
    on_wait: ?*const fn (?*anyopaque) void = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, hash_mb: usize) !*Engine {
        if (hash_mb < 1 or hash_mb > 4096) return error.InvalidHashSize;
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.io = io;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        self.shared_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.shared_arena.deinit();
        self.topology = numa.Topology.discover(io);
        self.numa_policy = .auto;
        self.worker_nodes = @splat(0);
        self.groups = try allocator.alloc(*Group, 0);
        errdefer allocator.free(self.groups);
        self.helpers = try allocator.alloc(*Helper, 0);
        errdefer allocator.free(self.helpers);
        const a = self.arena.allocator();
        const shared_allocator = self.shared_arena.allocator();
        self.tables = try a.create(@import("attacks.zig").Tables);
        self.tables.init();
        self.keys = try a.create(@import("position_keys.zig").PositionKeys);
        self.keys.init();
        const correction = try shared_allocator.alloc(h.CorrectionEntry, h.correction_history_base_size);
        const pawn = try shared_allocator.alloc(h.PawnEntry, h.pawn_history_base_size);
        const continuation = try shared_allocator.create(h.ContinuationHistoryBlock);
        self.shared = try h.SharedHistories.init(1, correction, continuation, pawn);
        self.page_policy = .auto;
        self.hash_region = try memory.Region.allocate(allocator, hash_mb * 1024 * 1024, self.page_policy);
        errdefer self.hash_region.deinit();
        self.clusters = std.mem.bytesAsSlice(tt.Cluster, self.hash_region.bytes);
        self.table = tt.Table.init(self.clusters);
        self.hash_mb = hash_mb;
        self.states = try allocator.alloc(p.StateInfo, 1);
        errdefer allocator.free(self.states);
        try self.position.set(p.start_fen, false, &self.states[0], self.tables, self.keys);
        self.network = null;
        self.tablebases = null;
        self.network_path = null;
        self.control = .{ .context = self, .clock = clock };
        self.search_limits = .{ .depth = t.max_ply - 1 };
        self.original_time_adjust = -1;
        self.node_time = .{};
        self.node_rate = 0;
        self.wait_context = null;
        self.on_wait = null;
        self.main_storage = try Helper.create(allocator, io, 0, &self.shared, &self.table, &self.control);
        self.base = self.main_storage.base;
        self.accumulators = self.base.accumulators;
        self.caches = self.base.caches;
        self.roots = self.main_storage.roots;
        self.worker = self.main_storage.worker;
        self.worker.skill_rng = .init(@as(u64, @bitCast(clock(self))) | 1);
        self.newGame();
        return self;
    }
    pub fn destroy(self: *Engine) void {
        const allocator = self.allocator;
        for (self.helpers) |helper| helper.destroy(allocator);
        allocator.free(self.helpers);
        self.main_storage.destroy(allocator);
        for (self.groups) |group| group.destroy(allocator);
        allocator.free(self.groups);
        self.shared_arena.deinit();
        if (self.tablebases) |database| database.destroy();
        if (self.network) |network| allocator.destroy(network);
        if (self.network_path) |path| allocator.free(path);
        allocator.free(self.states);
        self.hash_region.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }
    fn clock(context: ?*anyopaque) i64 {
        const self: *Engine = @ptrCast(@alignCast(context.?));
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }
    pub fn newGame(self: *Engine) void {
        const main_guard = numa.Guard.bind(if (self.groups.len != 0 and self.groups[self.worker_nodes[0]].mask != null) &self.groups[self.worker_nodes[0]].mask.? else null) catch numa.Guard{};
        defer main_guard.restore();
        h.fill(self.base.main_history, -5);
        h.fill(self.base.low_ply_history, 102);
        h.fill(self.base.capture_history, -742);
        h.fill(self.base.continuation_correction, 5);
        if (self.groups.len == 0) self.shared.clearRange(0, 1) else {
            for (self.groups) |group| {
                const guard = numa.Guard.bind(if (group.mask) |*mask| mask else null) catch numa.Guard{};
                defer guard.restore();
                group.shared.clearRange(0, 1);
            }
        }
        self.worker.tt_move_history.set(0);
        self.worker.previous_score = t.value_infinite;
        self.worker.previous_average = t.value_infinite;
        self.worker.previous_time_reduction = 0.85;
        self.original_time_adjust = -1;
        self.node_time = .{};
        self.clearHash();
        for (self.helpers, 1..) |helper, index| {
            const group = self.groups[self.worker_nodes[index]];
            const guard = numa.Guard.bind(if (group.mask) |*mask| mask else null) catch numa.Guard{};
            defer guard.restore();
            helper.clear(group.network);
        }
        self.accumulators.reset();
        if (self.network) |network| self.caches.clear(&network.transformer);
    }
    pub fn resizeThreads(self: *Engine, count: usize) !void {
        if (count < 1 or count > 256) return error.InvalidThreadCount;
        const bind = self.topology.binding(self.numa_policy, count);
        var assignment: [256]usize = @splat(0);
        if (bind) self.topology.distribute(assignment[0..count]);
        var node_count: usize = 1;
        var counts: [64]usize = @splat(0);
        for (assignment[0..count]) |node| {
            counts[node] += 1;
            node_count = @max(node_count, node + 1);
        }
        const groups = try self.allocator.alloc(*Group, node_count);
        errdefer self.allocator.free(groups);
        var group_count: usize = 0;
        errdefer for (groups[0..group_count]) |group| group.destroy(self.allocator);
        for (groups, 0..) |*group, node| {
            group.* = try Group.create(self.allocator, if (bind) self.topology.nodes[node].cpus else null, @max(1, counts[node]), self.network);
            group_count += 1;
        }
        const main_storage = block: {
            const guard = try numa.Guard.bind(if (groups[assignment[0]].mask) |*mask| mask else null);
            defer guard.restore();
            break :block try Helper.create(self.allocator, self.io, 0, &self.shared, &self.table, &self.control);
        };
        errdefer main_storage.destroy(self.allocator);
        var region = try memory.Region.allocate(self.allocator, self.hash_mb * 1024 * 1024, self.page_policy);
        errdefer region.deinit();
        const helpers = try self.allocator.alloc(*Helper, count - 1);
        errdefer self.allocator.free(helpers);
        var initialized: usize = 0;
        errdefer for (helpers[0..initialized]) |helper| helper.destroy(self.allocator);
        for (helpers, 1..) |*helper, index| {
            const group = groups[assignment[index]];
            const guard = try numa.Guard.bind(if (group.mask) |*mask| mask else null);
            defer guard.restore();
            helper.* = try Helper.create(self.allocator, self.io, index, &group.shared, &self.table, &self.control);
            initialized += 1;
        }
        for (self.helpers) |helper| helper.destroy(self.allocator);
        self.allocator.free(self.helpers);
        for (self.groups) |group| group.destroy(self.allocator);
        self.allocator.free(self.groups);
        self.shared_arena.deinit();
        self.shared_arena = .init(self.allocator);
        self.groups = groups;
        self.worker_nodes = assignment;
        const previous_worker = self.worker;
        self.main_storage.destroy(self.allocator);
        self.main_storage = main_storage;
        self.base = main_storage.base;
        self.accumulators = self.base.accumulators;
        self.caches = self.base.caches;
        self.roots = main_storage.roots;
        self.worker = main_storage.worker;
        self.worker.on_progress = previous_worker.on_progress;
        self.worker.progress_context = previous_worker.progress_context;
        self.worker.skill_rng = previous_worker.skill_rng;
        self.worker.skill_level = previous_worker.skill_level;
        self.worker.skill_elo = previous_worker.skill_elo;
        self.worker.tablebases = self.tablebases;
        self.worker.tb_options = previous_worker.tb_options;
        self.shared = groups[assignment[0]].shared;
        self.base.shared = &self.shared;
        if (groups[assignment[0]].network) |network| self.base.network = network;
        self.helpers = helpers;
        self.hash_region.deinit();
        self.hash_region = region;
        self.clusters = std.mem.bytesAsSlice(tt.Cluster, region.bytes);
        self.table = .{ .clusters = self.clusters };
        self.base.publish_nodes = count > 1;
        self.worker.advance_generation = count == 1;
        self.control.worker_count = count;
        self.control.node_context = self;
        self.control.read_nodes = if (count > 1) readNodes else null;
        self.control.read_changes = if (count > 1) readChanges else null;
        self.newGame();
    }
    fn clearHash(self: *Engine) void {
        self.table.generation = 0;
        if (self.groups.len == 0) return self.table.clear();
        const bytes = std.mem.sliceAsBytes(self.clusters);
        const page: usize = switch (self.hash_region.backing) {
            .huge1g => 1024 * 1024 * 1024,
            .huge2m, .transparent_hint => 2 * 1024 * 1024,
            else => std.heap.pageSize(),
        };
        const pages = std.mem.alignForward(usize, bytes.len, page) / page;
        for (self.groups, 0..) |group, index| {
            const guard = numa.Guard.bind(if (group.mask) |*mask| mask else null) catch numa.Guard{};
            defer guard.restore();
            const begin = @min(bytes.len, pages * index / self.groups.len * page);
            const end = @min(bytes.len, pages * (index + 1) / self.groups.len * page);
            @memset(bytes[begin..end], 0);
        }
    }
    fn readNodes(context: ?*anyopaque) u64 {
        const self: *Engine = @ptrCast(@alignCast(context.?));
        var nodes = self.base.published_nodes.load(.monotonic);
        for (self.helpers) |helper| nodes += helper.base.published_nodes.load(.monotonic);
        return nodes;
    }
    pub fn totalNodes(self: *Engine) u64 {
        return if (self.helpers.len == 0) self.base.nodes else readNodes(self);
    }
    fn readChanges(context: ?*anyopaque) usize {
        const self: *Engine = @ptrCast(@alignCast(context.?));
        var changes = self.worker.published_changes.swap(0, .monotonic);
        for (self.helpers) |helper| changes += helper.worker.published_changes.swap(0, .monotonic);
        return changes;
    }
    fn selectBest(self: *Engine) *search.Worker {
        const support = @import("search_support.zig");
        var candidates: [256]*search.Worker = undefined;
        candidates[0] = &self.worker;
        for (self.helpers, 1..) |helper, i| candidates[i] = &helper.worker;
        const workers = candidates[0 .. self.helpers.len + 1];
        var minimum: i32 = t.value_infinite;
        for (workers) |worker| minimum = @min(minimum, worker.root_moves[0].score);
        var votes: [t.max_moves]i64 = @splat(0);
        for (workers) |worker| for (self.worker.root_moves, 0..) |root, i| {
            if (root.pv.moves[0].data == worker.root_moves[0].pv.moves[0].data) {
                votes[i] += worker.root_moves[0].score - minimum + 14;
                break;
            }
        };
        var best = &self.worker;
        for (workers) |worker| {
            const current = worker.root_moves[0];
            const chosen = best.root_moves[0];
            const current_decisive = current.score != -t.value_infinite and @abs(current.score) >= support.tb_win_in_max_ply and !current.isInexact();
            const chosen_decisive = chosen.score != -t.value_infinite and @abs(chosen.score) >= support.tb_win_in_max_ply and !chosen.isInexact();
            var current_vote: i64 = 0;
            var chosen_vote: i64 = 0;
            for (self.worker.root_moves, 0..) |root, i| {
                if (root.pv.moves[0].data == current.pv.moves[0].data) current_vote = votes[i];
                if (root.pv.moves[0].data == chosen.pv.moves[0].data) chosen_vote = votes[i];
            }
            if (chosen_decisive) {
                if (current_decisive and @abs(current.score) > @abs(chosen.score)) best = worker;
            } else if (current_decisive or (current.score > -support.tb_win_in_max_ply and
                (current_vote > chosen_vote or (current_vote == chosen_vote and current.pv.len > chosen.pv.len)))) best = worker;
        }
        return best;
    }
    pub fn resizeHash(self: *Engine, mb: usize) !void {
        if (mb < 1 or mb > 4096) return error.InvalidHashSize;
        var replacement = try memory.Region.allocate(self.allocator, mb * 1024 * 1024, self.page_policy);
        errdefer replacement.deinit();
        const clusters = std.mem.bytesAsSlice(tt.Cluster, replacement.bytes);
        const table: tt.Table = .{ .clusters = clusters };
        self.hash_region.deinit();
        self.hash_region = replacement;
        self.clusters = clusters;
        self.table = table;
        self.hash_mb = mb;
        self.clearHash();
    }
    pub fn loadTablebases(self: *Engine, path: []const u8) !void {
        const replacement = try @import("syzygy/database.zig").Database.create(self.allocator, self.io, path, self.keys);
        if (self.tablebases) |previous| previous.destroy();
        self.tablebases = replacement;
        self.worker.tablebases = replacement;
        self.newGame();
    }
    pub fn tablebaseHits(self: *Engine) u64 {
        var hits = self.worker.tb_hits.load(.monotonic);
        for (self.helpers) |helper| hits += helper.worker.tb_hits.load(.monotonic);
        if (self.worker.tb_config.root_in_tb) hits += self.worker.root_moves.len;
        return hits;
    }
    pub fn loadNetwork(self: *Engine, path: []const u8) !void {
        const replacement = try self.allocator.create(nn.Network);
        errdefer self.allocator.destroy(replacement);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(200 * 1024 * 1024));
        defer self.allocator.free(bytes);
        _ = try replacement.load(bytes);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        var replicas: [64]?memory.Region = @splat(null);
        errdefer for (&replicas) |*replica| if (replica.*) |*region| region.deinit();
        for (self.groups, 0..) |group, i| replicas[i] = try group.copyNetwork(self.allocator, replacement);
        for (self.groups, 0..) |group, i| group.replaceNetwork(replacement, replicas[i]);
        if (self.network) |network| self.allocator.destroy(network);
        if (self.network_path) |old_path| self.allocator.free(old_path);
        self.network = replacement;
        self.network_path = owned_path;
        self.base.network = if (self.groups.len != 0) self.groups[self.worker_nodes[0]].network.? else replacement;
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
        self.control.use_nodes_time = self.node_rate != 0;
        self.base.published_nodes.store(0, .monotonic);
        self.worker.published_changes.store(0, .monotonic);
        self.worker.tb_hits.store(0, .monotonic);
        for (self.helpers) |helper| {
            helper.base.published_nodes.store(0, .monotonic);
            helper.worker.published_changes.store(0, .monotonic);
            helper.worker.tb_hits.store(0, .monotonic);
        }
    }
    pub fn runSearch(self: *Engine) !search.Worker.Result {
        const guard = try numa.Guard.bind(if (self.groups.len != 0 and self.groups[self.worker_nodes[0]].mask != null) &self.groups[self.worker_nodes[0]].mask.? else null);
        defer guard.restore();
        if (self.helpers.len != 0) self.table.newSearch();
        for (self.helpers) |helper| helper.start(&self.position, self.search_limits, &self.worker);
        var joined = false;
        defer if (!joined) {
            self.control.helpers_stop.store(true, .release);
            for (self.helpers) |helper| helper.wait();
        };
        var result = try self.worker.iterativeDeepening(&self.position, self.roots, self.search_limits);
        if (result.best_move.data != 0) {
            if (self.on_wait) |wait| wait(self.wait_context);
        }
        self.control.helpers_stop.store(true, .release);
        for (self.helpers) |helper| helper.wait();
        joined = true;
        for (self.helpers) |helper| if (helper.failure) |err| return err;
        if (self.helpers.len != 0 and self.worker.root_moves.len != 0 and self.search_limits.depth == t.max_ply - 1 and !@import("skill.zig").Skill.init(self.worker.skill_level, self.worker.skill_elo).enabled()) {
            const best = self.selectBest();
            if (best != &self.worker) {
                @memcpy(self.roots[0..best.root_moves.len], best.root_moves);
                self.worker.completed_depth = best.completed_depth;
                self.worker.tb_config = best.tb_config;
                self.worker.previous_score = best.root_moves[0].score;
                self.worker.previous_average = best.root_moves[0].average_score;
                result.best_move = best.root_moves[0].pv.moves[0];
                result.score = best.root_moves[0].score;
                result.depth = best.completed_depth;
            }
        }
        result.nodes = self.totalNodes();
        if (self.control.limits.npmsec != 0) self.node_time.advance(@intCast(result.nodes), self.control.limits.increment[@intFromEnum(self.position.side)]);
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
