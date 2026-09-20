const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
pub const Policy = enum { auto, none, system };
pub const Mask = linux.cpu_set_t;
pub const Node = struct { id: usize = 0, cpus: Mask = @splat(0) };
pub const Topology = struct {
    nodes: [64]Node = @splat(.{}),
    count: usize = 1,
    available: bool = false,
    pub fn discover(io: std.Io) Topology {
        var result: Topology = .{};
        if (builtin.os.tag != .linux) return result;
        var allowed: Mask = @splat(0);
        if (linux.errno(linux.sched_getaffinity(0, @sizeOf(Mask), &allowed)) != .SUCCESS) return result;
        result.nodes[0].cpus = allowed;
        result.available = true;
        var found: usize = 0;
        for (0..result.nodes.len) |id| {
            var path: [96]u8 = undefined;
            const name = std.fmt.bufPrint(&path, "/sys/devices/system/node/node{d}/cpulist", .{id}) catch unreachable;
            var buffer: [8192]u8 = undefined;
            const text = std.Io.Dir.cwd().readFile(io, name, &buffer) catch continue;
            var mask = parseCpuList(text) catch continue;
            for (&mask, allowed) |*word, allowed_word| word.* &= allowed_word;
            if (cpuCount(mask) == 0) continue;
            result.nodes[found] = .{ .id = id, .cpus = mask };
            found += 1;
        }
        if (found != 0) result.count = found;
        return result;
    }
    pub fn binding(self: *const Topology, policy: Policy, threads: usize) bool {
        return self.available and policy != .none and (policy == .system or (self.count > 1 and threads > 1));
    }
    /// Place successive workers on the least occupied node relative to its
    /// available CPU count. Affinity restrictions are applied during discovery.
    pub fn distribute(self: *const Topology, assignment: []usize) void {
        var assigned: [64]usize = @splat(0);
        for (assignment) |*node| {
            var best: usize = 0;
            for (1..self.count) |candidate| {
                if (assigned[candidate] * cpuCount(self.nodes[best].cpus) < assigned[best] * cpuCount(self.nodes[candidate].cpus)) best = candidate;
            }
            node.* = best;
            assigned[best] += 1;
        }
    }
};
pub const Guard = struct {
    previous: ?Mask = null,
    pub fn bind(mask: ?*const Mask) !Guard {
        if (builtin.os.tag != .linux or mask == null) return .{};
        var previous: Mask = @splat(0);
        if (linux.errno(linux.sched_getaffinity(0, @sizeOf(Mask), &previous)) != .SUCCESS) return error.AffinityUnavailable;
        try linux.sched_setaffinity(0, mask.?);
        return .{ .previous = previous };
    }
    pub fn restore(self: Guard) void {
        if (builtin.os.tag == .linux) if (self.previous) |mask| {
            linux.sched_setaffinity(0, &mask) catch {};
        };
    }
};
pub fn cpuCount(mask: Mask) usize {
    var count: usize = 0;
    for (mask) |word| count += @popCount(word);
    return count;
}
pub fn parseCpuList(text: []const u8) !Mask {
    var mask: Mask = @splat(0);
    var ranges = std.mem.tokenizeAny(u8, text, ",\n\r ");
    while (ranges.next()) |range| {
        var ends = std.mem.splitScalar(u8, range, '-');
        const first = try std.fmt.parseInt(usize, ends.next().?, 10);
        const last = if (ends.next()) |end| try std.fmt.parseInt(usize, end, 10) else first;
        if (ends.next() != null or first > last or last >= @bitSizeOf(Mask)) return error.InvalidCpuRange;
        for (first..last + 1) |cpu| mask[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    }
    return mask;
}

test "CPU lists and node distribution honor unequal capacities" {
    const mask = try parseCpuList("0-3,8,10-11\n");
    try std.testing.expectEqual(@as(usize, 7), cpuCount(mask));
    try std.testing.expectError(error.InvalidCpuRange, parseCpuList("5-2"));
    var topology: Topology = .{};
    topology.count = 2;
    topology.nodes[0].cpus = try parseCpuList("0-3");
    topology.nodes[1].cpus = try parseCpuList("4-5");
    var assignment: [6]usize = undefined;
    topology.distribute(&assignment);
    var counts: [2]usize = @splat(0);
    for (assignment) |node| counts[node] += 1;
    try std.testing.expectEqualSlices(usize, &.{ 4, 2 }, &counts);
}

test "affinity guard restores the calling thread mask" {
    if (builtin.os.tag != .linux) return;
    var original: Mask = @splat(0);
    if (linux.errno(linux.sched_getaffinity(0, @sizeOf(Mask), &original)) != .SUCCESS) return;
    var single: Mask = @splat(0);
    for (original, 0..) |word, i| if (word != 0) {
        single[i] = @as(usize, 1) << @intCast(@ctz(word));
        break;
    };
    {
        const guard = try Guard.bind(&single);
        defer guard.restore();
        var current: Mask = @splat(0);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sched_getaffinity(0, @sizeOf(Mask), &current)));
        try std.testing.expectEqualSlices(usize, &single, &current);
    }
    var restored: Mask = @splat(0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sched_getaffinity(0, @sizeOf(Mask), &restored)));
    try std.testing.expectEqualSlices(usize, &original, &restored);
}
