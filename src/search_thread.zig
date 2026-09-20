const std = @import("std");
const t = @import("types.zig");
const p = @import("position.zig");
const h = @import("history.zig");
const acc = @import("nnue/accumulator.zig");
const search = @import("search.zig");
const QWorker = @import("quiescence.zig").Worker;

/// Persistent helper with exclusively owned mutable search storage. The owner
/// publishes jobs under the mutex and joins a job before inspecting its result.
pub const Helper = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    affinity: ?@import("numa.zig").Mask,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    busy: bool = false,
    exiting: bool = false,
    base: *QWorker,
    worker: search.Worker,
    roots: []search.RootMove,
    position: p.Position = undefined,
    root_state: p.StateInfo = undefined,
    limits: search.Worker.Limits = .{ .depth = t.max_ply - 1 },
    failure: ?anyerror = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, index: usize, shared: *h.SharedHistories, table: *@import("tt.zig").Table, control: *@import("search_control.zig").Control, affinity: ?@import("numa.zig").Mask) !*Helper {
        const self = try allocator.create(Helper);
        errdefer allocator.destroy(self);
        self.* = .{ .arena = .init(std.heap.page_allocator), .io = io, .affinity = affinity, .base = undefined, .worker = undefined, .roots = undefined };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const base = try a.create(QWorker);
        base.* = .{
            .network = undefined,
            .accumulators = try a.create(acc.Stack),
            .caches = try a.create(acc.Caches),
            .main_history = try a.create(h.ButterflyHistory),
            .low_ply_history = try a.create(h.LowPlyHistory),
            .capture_history = try a.create(h.CapturePieceToHistory),
            .continuation_correction = try a.create(h.ContinuationCorrectionHistory),
            .shared = shared,
            .table = table,
            .control = control,
            .publish_nodes = index != 0,
            .helper = index != 0,
        };
        self.base = base;
        self.worker = search.Worker.init(base);
        self.worker.thread_index = index;
        self.worker.advance_generation = index == 0;
        self.roots = try a.alloc(search.RootMove, t.max_moves);
        self.clear(null);
        if (index != 0) self.thread = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, loop, .{self});
        return self;
    }
    pub fn clear(self: *Helper, network: ?*const @import("nnue/network.zig").Network) void {
        h.fill(self.base.main_history, -5);
        h.fill(self.base.low_ply_history, 102);
        h.fill(self.base.capture_history, -742);
        h.fill(self.base.continuation_correction, 5);
        self.worker.tt_move_history.set(0);
        self.worker.previous_score = t.value_infinite;
        self.worker.previous_average = t.value_infinite;
        self.worker.previous_time_reduction = 0.85;
        self.base.accumulators.reset();
        if (network) |net| {
            self.base.network = net;
            self.base.caches.clear(&net.transformer);
        }
    }
    pub fn start(self: *Helper, position: *const p.Position, limits: search.Worker.Limits, main: *search.Worker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(!self.busy);
        self.position = position.*;
        self.root_state = position.st.*;
        self.position.st = &self.root_state;
        self.limits = limits;
        // Only the main worker is bounded by UCI depth; helpers deepen until stop.
        self.limits.depth = t.max_ply - 1;
        self.worker.tablebases = main.tablebases;
        self.worker.tb_options = main.tb_options;
        self.worker.skill_level = main.skill_level;
        self.worker.skill_elo = main.skill_elo;
        self.failure = null;
        self.busy = true;
        self.condition.broadcast(self.io);
    }
    pub fn wait(self: *Helper) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.busy) self.condition.waitUncancelable(self.io, &self.mutex);
    }
    pub fn destroy(self: *Helper, allocator: std.mem.Allocator) void {
        self.wait();
        self.mutex.lockUncancelable(self.io);
        self.exiting = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.arena.deinit();
        allocator.destroy(self);
    }
    fn runJob(self: *Helper) !void {
        const guard = try @import("numa.zig").Guard.bind(if (self.affinity) |*mask| mask else null);
        defer guard.restore();
        _ = try self.worker.iterativeDeepening(&self.position, self.roots, self.limits);
    }
    fn loop(self: *Helper) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            while (!self.busy and !self.exiting) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.exiting) return;
            self.mutex.unlock(self.io);
            self.runJob() catch |err| {
                self.failure = err;
                self.base.control.?.requestStop();
            };
            self.mutex.lockUncancelable(self.io);
            self.busy = false;
            self.condition.broadcast(self.io);
        }
    }
};
