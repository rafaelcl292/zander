const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    try output.interface.writeAll("Zander — incremental Stockfish port in Zig 0.16.0\nFoundation: types, moves, attack tables, Zobrist keys, and repetition index. Search/UCI/NNUE are not implemented yet.\n");
    try output.interface.flush();
}
