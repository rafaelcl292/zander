// Derived from Stockfish misc.h; GPL-3.0-or-later.
const std = @import("std");
/// Deterministic upstream xorshift64* generator. Not cryptographic.
pub const Prng = struct {
    state: u64,
    pub fn init(seed: u64) Prng {
        std.debug.assert(seed != 0);
        return .{ .state = seed };
    }
    pub fn next(self: *Prng) u64 {
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        return self.state *% 2685821657736338717;
    }
    pub fn sparse(self: *Prng) u64 {
        const a = self.next();
        const b = self.next();
        return a & b & self.next();
    }
};
