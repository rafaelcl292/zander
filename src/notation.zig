// UCI notation and score model derived from Stockfish uci.cpp; GPL-3.0-or-later.
const std = @import("std");
const t = @import("types.zig");
const p = @import("position.zig");
const s = @import("search_support.zig");
pub fn moveText(move: t.Move, chess960: bool, buffer: *[6]u8) []const u8 {
    if (move.data == 0 or move.data == t.Move.null_move.data) return "0000";
    const from = move.from();
    var to = move.to();
    if (move.kind() == .castling and !chess960) to = t.Square.make(if (@intFromEnum(to) > @intFromEnum(from)) 6 else 2, from.rank());
    buffer[0] = 'a' + @as(u8, from.file());
    buffer[1] = '1' + @as(u8, from.rank());
    buffer[2] = 'a' + @as(u8, to.file());
    buffer[3] = '1' + @as(u8, to.rank());
    if (move.kind() == .promotion) {
        buffer[4] = " pnbrqk"[@intFromEnum(move.promotionType())];
        return buffer[0..5];
    }
    return buffer[0..4];
}
pub fn parseMove(pos: *const p.Position, text: []const u8) ?t.Move {
    var list: @import("movegen.zig").MoveList = .{};
    @import("movegen.zig").generate(.legal, pos, &list);
    var buffer: [6]u8 = undefined;
    for (list.slice()) |move| if (std.ascii.eqlIgnoreCase(moveText(move, pos.chess960, &buffer), text)) {
        return move;
    };
    return null;
}
fn parameters(pos: *const p.Position) struct { a: f64, b: f64 } {
    var material: i32 = 0;
    for ([_]t.Color{ .white, .black }) |color| for ([_]t.PieceType{ .pawn, .knight, .bishop, .rook, .queen }, [_]i32{ 1, 3, 3, 5, 9 }) |piece, weight| {
        material += @as(i32, @intCast(@popCount(pos.piecesOf(color, piece)))) * weight;
    };
    const m = @as(f64, @floatFromInt(std.math.clamp(material, 17, 78))) / 58.0;
    return .{ .a = (((-142.72052667 * m + 372.35176398) * m - 340.71073572) * m) + 415.23490212, .b = (((5.93832785 * m + 15.61267078) * m - 30.57816876) * m) + 69.63866711 };
}
pub fn centipawns(value: i32, pos: *const p.Position) i32 {
    return @trunc(@as(f64, @round(100.0 * @as(f64, @floatFromInt(value)) / parameters(pos).a)));
}
pub fn writeScore(writer: *std.Io.Writer, value: i32, pos: *const p.Position) !void {
    const absolute: @TypeOf(value) = @intCast(@abs(value));
    if (absolute > s.value_tb) {
        const plies = (t.value_mate - absolute) * @as(i32, if (value > 0) 1 else -1);
        try writer.print("mate {d}", .{@divTrunc(if (plies > 0) plies + 1 else plies, 2)});
    } else if (absolute >= s.tb_win_in_max_ply) {
        const plies = (s.value_tb - absolute) * @as(i32, if (value > 0) 1 else -1);
        try writer.print("cp {d}", .{@as(i32, if (value > 0) 20000 else -20000) - plies});
    } else try writer.print("cp {d}", .{centipawns(value, pos)});
}
pub fn wdl(value: i32, pos: *const p.Position) [3]i32 {
    const params = parameters(pos);
    const v: @TypeOf(params.a) = @floatFromInt(value);
    const wins: i32 = @trunc(0.5 + 1000 / (1 + @exp((params.a - v) / params.b)));
    const losses: i32 = @trunc(0.5 + 1000 / (1 + @exp((params.a + v) / params.b)));
    return .{ wins, 1000 - wins - losses, losses };
}
