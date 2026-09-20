const std = @import("std");
const tm = @import("time_management.zig");
/// The command thread only touches the atomics. All other fields belong to
/// the search worker until it is joined. A supplied clock permits deterministic tests.
pub const Control = struct {
    stop: std.atomic.Value(bool) = .init(false),
    ponder: std.atomic.Value(bool) = .init(false),
    context: ?*anyopaque = null,
    clock: *const fn (?*anyopaque) i64,
    start: i64 = 0,
    limits: tm.Limits = .{},
    budget: tm.Budget = .{},
    calls: i32 = 0,
    stop_on_ponderhit: bool = false,
    increase_depth: bool = true,
    pub fn reset(self: *Control, limits: tm.Limits, budget: tm.Budget) void {
        self.limits = limits;
        self.budget = budget;
        self.start = self.clock(self.context);
        self.calls = 0;
        self.stop_on_ponderhit = false;
        self.increase_depth = true;
        self.stop.store(false, .release);
        self.ponder.store(limits.ponder, .release);
    }
    pub fn stopped(self: *const Control) bool {
        return self.stop.load(.acquire);
    }
    pub fn requestStop(self: *Control) void {
        self.stop.store(true, .release);
    }
    pub fn ponderHit(self: *Control) void {
        self.ponder.store(false, .release);
    }
    pub fn elapsed(self: *const Control) i64 {
        return @max(0, self.clock(self.context) - self.start);
    }
    pub fn poll(self: *Control, nodes: u64) void {
        self.calls -= 1;
        if (self.calls > 0) return;
        self.calls = if (self.limits.nodes != 0) @intCast(@min(512, self.limits.nodes / 1024)) else 512;
        if (self.ponder.load(.acquire)) return;
        const elapsed_ms = self.elapsed();
        if ((self.limits.managed() and (elapsed_ms > self.budget.maximum or self.stop_on_ponderhit)) or (self.limits.move_time != 0 and elapsed_ms >= self.limits.move_time) or (self.limits.nodes != 0 and nodes >= self.limits.nodes)) self.requestStop();
    }
};

test "clock and node limits honor ponder and stop" {
    const Clock = struct {
        fn now(context: ?*anyopaque) i64 {
            return @as(*i64, @ptrCast(@alignCast(context.?))).*;
        }
    };
    var now: i64 = 100;
    var control: Control = .{ .clock = Clock.now, .context = &now };
    control.reset(.{ .move_time = 10 }, .{});
    now = 109;
    control.poll(0);
    try std.testing.expect(!control.stopped());
    now = 110;
    control.calls = 0;
    control.poll(0);
    try std.testing.expect(control.stopped());
    control.reset(.{ .nodes = 1, .ponder = true }, .{});
    control.poll(5);
    try std.testing.expect(!control.stopped());
    control.ponderHit();
    control.poll(5);
    try std.testing.expect(control.stopped());
    control.reset(.{ .time = .{ 1000, 1000 }, .ponder = true }, .{ .maximum = 5 });
    control.stop_on_ponderhit = true;
    control.ponderHit();
    control.poll(0);
    try std.testing.expect(control.stopped());
    control.reset(.{}, .{});
    control.requestStop();
    try std.testing.expect(control.stopped());
}
