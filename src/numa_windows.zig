// Win64 NUMA and processor-group support. API layouts follow Microsoft's
// GROUP_AFFINITY, PROCESSOR_NUMBER, and CACHE_RELATIONSHIP definitions.
const std = @import("std");
const n = @import("numa.zig");
const Handle = *anyopaque;
const GroupAffinity = extern struct { mask: usize = 0, group: u16 = 0, reserved: [3]u16 = @splat(0) };
const Processor = extern struct { group: u16, number: u8, reserved: u8 = 0 };
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) Handle;
extern "kernel32" fn GetCurrentThread() callconv(.winapi) Handle;
extern "kernel32" fn GetActiveProcessorCount(u16) callconv(.winapi) u32;
extern "kernel32" fn SwitchToThread() callconv(.winapi) i32;
extern "kernel32" fn GetActiveProcessorGroupCount() callconv(.winapi) u16;
extern "kernel32" fn GetNumaProcessorNodeEx(*const Processor, *u16) callconv(.winapi) i32;
extern "kernel32" fn GetProcessAffinityMask(Handle, *usize, *usize) callconv(.winapi) i32;
extern "kernel32" fn GetProcessGroupAffinity(Handle, *u16, [*]u16) callconv(.winapi) i32;
extern "kernel32" fn SetThreadGroupAffinity(Handle, *const GroupAffinity, ?*GroupAffinity) callconv(.winapi) i32;
extern "kernel32" fn GetLogicalProcessorInformationEx(u32, ?[*]u8, *u32) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleW([*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn GetProcAddress(Handle, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
const GetSelected = *const fn (Handle, ?[*]GroupAffinity, u16, *u16) callconv(.winapi) i32;
const SetSelected = *const fn (Handle, ?[*]const GroupAffinity, u16) callconv(.winapi) i32;
fn procedure(comptime T: type, name: [*:0]const u8) ?T {
    const module = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse return null;
    return @ptrCast(GetProcAddress(module, name));
}
fn oldRestriction() ?n.Mask {
    var proc: usize = 0;
    var system: usize = 0;
    if (GetProcessAffinityMask(GetCurrentProcess(), &proc, &system) == 0 or proc == 0) return null;
    var groups: [16]u16 align(4) = undefined;
    var count: u16 = groups.len;
    if (GetProcessGroupAffinity(GetCurrentProcess(), &count, &groups) == 0) return null;
    if (count == 0 or count > groups.len) return null;
    if (count > 1) {
        if (procedure(GetSelected, "GetThreadSelectedCpuSetMasks") == null) return null;
        // A disposable thread avoids modifying the caller's legacy group affinity.
        var scan: AffinityScan = .{ .groups = groups, .count = count };
        const thread = std.Thread.spawn(.{}, AffinityScan.run, .{&scan}) catch return null;
        thread.join();
        return if (scan.valid and !scan.full) scan.mask else null;
    }
    if (GetActiveProcessorGroupCount() == 1 and proc == system) return null;
    if (groups[0] >= @as(n.Mask, undefined).len) return null;
    var result: n.Mask = @splat(0);
    result[groups[0]] = proc;
    return result;
}
const AffinityScan = struct {
    groups: [16]u16,
    count: u16,
    mask: n.Mask = @splat(0),
    valid: bool = false,
    full: bool = true,
    fn run(self: *AffinityScan) void {
        for (self.groups[0..self.count]) |group| {
            if (group >= self.mask.len) return;
            const active = GetActiveProcessorCount(group);
            if (active == 0 or active > 64) return;
            var proc_combined: usize = std.math.maxInt(usize);
            var sys_combined: usize = std.math.maxInt(usize);
            for (0..@min(active, 2)) |cpu| {
                const affinity: GroupAffinity = .{ .group = group, .mask = @as(usize, 1) << @intCast(cpu) };
                if (SetThreadGroupAffinity(GetCurrentThread(), &affinity, null) == 0) return;
                _ = SwitchToThread();
                var proc: usize = 0;
                var system: usize = 0;
                if (GetProcessAffinityMask(GetCurrentProcess(), &proc, &system) == 0) return;
                proc_combined &= proc;
                sys_combined &= system;
            }
            self.mask[group] = proc_combined;
            if (proc_combined != sys_combined) self.full = false;
        }
        self.valid = true;
    }
};
fn allowed() n.Mask {
    var result: n.Mask = oldRestriction() orelse @splat(std.math.maxInt(usize));
    if (procedure(GetSelected, "GetThreadSelectedCpuSetMasks")) |get| {
        var masks: [16]GroupAffinity = undefined;
        var count: u16 = 0;
        if (get(GetCurrentThread(), &masks, masks.len, &count) != 0 and count > 0 and count <= masks.len) {
            var selected: n.Mask = @splat(0);
            for (masks[0..count]) |mask| if (mask.group < selected.len) {
                selected[mask.group] |= mask.mask;
            };
            for (&result, selected) |*word, other| word.* &= other;
        }
    }
    return result;
}
/// Split domains at processor-group boundaries, as the pinned reference does.
pub fn splitGroups(topology: n.Topology) !n.Topology {
    var result: n.Topology = .{ .count = 0, .available = topology.available };
    for (topology.nodes[0..topology.count]) |node| for (node.cpus, 0..) |word, group| {
        if (word == 0) continue;
        if (result.count == result.nodes.len) return error.TooManyNumaNodes;
        result.nodes[result.count] = .{ .id = node.id };
        result.nodes[result.count].cpus[group] = word;
        result.count += 1;
    };
    if (result.count == 0) return error.EmptyTopology;
    return result;
}
pub fn discover(respect_affinity: bool) n.Topology {
    const groups = GetActiveProcessorGroupCount();
    if (groups == 0 or groups > @as(n.Mask, undefined).len) return .{};
    const restriction: n.Mask = if (respect_affinity) allowed() else @splat(std.math.maxInt(usize));
    var system: n.Topology = .{ .count = 0, .available = true };
    for (0..groups) |group| for (0..64) |cpu| {
        if (restriction[group] & (@as(usize, 1) << @intCast(cpu)) == 0) continue;
        const processor: Processor = .{ .group = @intCast(group), .number = @intCast(cpu) };
        var id: u16 = 0;
        if (GetNumaProcessorNodeEx(&processor, &id) == 0 or id == 65535) continue;
        var index: usize = 0;
        while (index < system.count and system.nodes[index].id != id) : (index += 1) {}
        if (index == system.count) {
            if (index == system.nodes.len) return .{};
            system.nodes[index] = .{ .id = id };
            system.count += 1;
        }
        system.nodes[index].cpus[group] |= @as(usize, 1) << @intCast(cpu);
    };
    if (system.count == 0) return .{};
    std.mem.sort(n.Node, system.nodes[0..system.count], {}, struct {
        fn less(_: void, a: n.Node, b: n.Node) bool {
            return a.id < b.id;
        }
    }.less);
    var size: u32 = 0;
    _ = GetLogicalProcessorInformationEx(2, null, &size);
    if (size == 0) return splitGroups(system) catch .{};
    const buffer = std.heap.page_allocator.alloc(u8, size) catch return splitGroups(system) catch .{};
    defer std.heap.page_allocator.free(buffer);
    if (GetLogicalProcessorInformationEx(2, buffer.ptr, &size) == 0 or size > buffer.len) return splitGroups(system) catch .{};
    const topology = cacheTopology(system, buffer[0..size]) catch system;
    return splitGroups(topology) catch .{};
}
/// Parse variable-sized cache records without relying on host structure packing.
pub fn cacheTopology(system: n.Topology, bytes: []const u8) !n.Topology {
    var domains: [64]n.Node = undefined;
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < 8) return error.InvalidTopology;
        const size = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        if (size < 8 or size > bytes.len - offset) return error.InvalidTopology;
        const record = bytes[offset..][0..size];
        offset += size;
        if (std.mem.readInt(u32, record[0..4], .little) != 2) continue;
        if (size < 56) return error.InvalidTopology;
        if (record[8] != 3) continue;
        const groups = @max(1, std.mem.readInt(u16, record[38..40], .little));
        if (40 + @as(usize, groups) * 16 > size) return error.InvalidTopology;
        var cache: n.Mask = @splat(0);
        for (0..groups) |i| {
            const mask = record[40 + i * 16 ..][0..16];
            const group = std.mem.readInt(u16, mask[8..10], .little);
            if (group >= cache.len) return error.InvalidTopology;
            cache[group] |= @intCast(std.mem.readInt(u64, mask[0..8], .little));
        }
        for (system.nodes[0..system.count]) |node| {
            var subset = node.cpus;
            for (&subset, cache) |*word, other| word.* &= other;
            if (n.cpuCount(subset) == 0) continue;
            if (count == domains.len) return error.TooManyNumaNodes;
            domains[count] = .{ .id = node.id, .cpus = subset };
            count += 1;
        }
    }
    if (count == 0) return system;
    // Stable grouping retains the API's L3 order inside each physical node.
    std.mem.sort(n.Node, domains[0..count], {}, struct {
        fn less(_: void, a: n.Node, b: n.Node) bool {
            return a.id < b.id;
        }
    }.less);
    return n.Topology.bundleL3(domains[0..count], 32);
}
pub const Guard = struct {
    previous: ?GroupAffinity = null,
    selected: [16]GroupAffinity = undefined,
    selected_count: u16 = 0,
    set_selected: ?SetSelected = null,
    pub fn bind(mask: n.Mask) !Guard {
        var groups: [16]GroupAffinity = undefined;
        var count: u16 = 0;
        for (mask, 0..) |word, group| if (word != 0) {
            groups[count] = .{ .mask = word, .group = @intCast(group) };
            count += 1;
        };
        if (count == 0) return error.EmptyAffinity;
        var result: Guard = .{};
        const set = procedure(SetSelected, "SetThreadSelectedCpuSetMasks");
        if (set) |setter| {
            const get = procedure(GetSelected, "GetThreadSelectedCpuSetMasks") orelse return error.AffinityUnavailable;
            if (get(GetCurrentThread(), &result.selected, result.selected.len, &result.selected_count) == 0 or result.selected_count > result.selected.len) return error.AffinityUnavailable;
            if (setter(GetCurrentThread(), &groups, count) == 0) return error.AffinityUnavailable;
            result.set_selected = setter;
        }
        errdefer result.restore();
        if (set == null or oldRestriction() != null) {
            var previous: GroupAffinity = undefined;
            if (SetThreadGroupAffinity(GetCurrentThread(), &groups[0], &previous) == 0) return error.AffinityUnavailable;
            result.previous = previous;
        }
        _ = SwitchToThread();
        return result;
    }
    pub fn restore(self: Guard) void {
        if (self.previous) |previous| _ = SetThreadGroupAffinity(GetCurrentThread(), &previous, null);
        if (self.set_selected) |set| _ = set(GetCurrentThread(), if (self.selected_count == 0) null else &self.selected, self.selected_count);
    }
};

test "Windows cache record parsing handles old and multi-group layouts" {
    var system = try n.Topology.fromString("0-7:64-71");
    system.available = true;
    var bytes: [72]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 2, .little);
    std.mem.writeInt(u32, bytes[4..8], bytes.len, .little);
    bytes[8] = 3;
    std.mem.writeInt(u16, bytes[38..40], 2, .little);
    std.mem.writeInt(u64, bytes[40..48], 255, .little);
    std.mem.writeInt(u64, bytes[56..64], 255, .little);
    std.mem.writeInt(u16, bytes[64..66], 1, .little);
    const result = try cacheTopology(system, &bytes);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(usize, 8), n.cpuCount(result.nodes[1].cpus));
    std.mem.writeInt(u32, bytes[4..8], 56, .little);
    std.mem.writeInt(u16, bytes[38..40], 0, .little);
    const old = try cacheTopology(system, bytes[0..56]);
    try std.testing.expectEqual(@as(usize, 1), old.count);
    try std.testing.expectError(error.InvalidTopology, cacheTopology(system, bytes[0..55]));
    const combined = try n.Topology.fromString("0-7,64-71");
    try std.testing.expectEqual(@as(usize, 2), (try splitGroups(combined)).count);
}
