/// Read-only, highest-locality hints corresponding to Stockfish's default
/// prefetch policy. Disable with -Dprefetch=false for controlled measurements.
pub inline fn read(pointer: anytype) void {
    if (@import("backend").prefetch) @prefetch(pointer, .{ .rw = .read, .locality = 3, .cache = .data });
}
