const Position = @import("position.zig").Position;
const StateInfo = @import("position.zig").StateInfo;
const movegen = @import("movegen.zig");
/// Diagnostic node count; storage is bounded by depth and uses no allocator.
/// Callers must bound depth before accepting untrusted input.
pub fn count(pos: *Position, depth: u8) u64 {
    if (depth == 0) return 1;
    // generate initializes the length and every move in the returned slice.
    var moves: movegen.MoveList = undefined;
    movegen.generate(.legal, pos, &moves);
    if (depth == 1) return moves.len;
    var nodes: u64 = 0;
    for (moves.slice()) |m| {
        var state: StateInfo = undefined;
        pos.doMove(m, &state);
        nodes += count(pos, depth - 1);
        pos.undoMove(m);
    }
    return nodes;
}
