// Test bridge to the unmodified pinned Stockfish sources. GPL-3.0-or-later.
#include "../vendor/stockfish/src/bitboard.h"
using namespace Stockfish;
extern "C" uint64_t sf_shift(uint64_t b, int8_t d) { return shift(b, Direction(d)); }
extern "C" uint64_t sf_key(uint64_t seed) { return make_key(seed); }
extern "C" uint64_t sf_pawns(uint64_t b, uint8_t c) { return c ? pawn_attacks_bb<BLACK>(b) : pawn_attacks_bb<WHITE>(b); }
extern "C" uint32_t sf_decode(uint16_t raw) {
    Move m(raw);
    return uint32_t(m.is_ok()) | (uint32_t(m.type_of()) << 1)
         | (uint32_t(m.promotion_type()) << 17)
         | (m.is_ok() ? (uint32_t(m.from_sq()) << 20) | (uint32_t(m.to_sq()) << 26) : 0);
}
extern "C" uint16_t sf_move(uint8_t from, uint8_t to, uint8_t pt) {
    return Move::make<PROMOTION>(Square(from), Square(to), PieceType(pt)).raw();
}

#include "../vendor/stockfish/src/attacks.cpp"
extern "C" void sf_attacks_init() { Attacks::init(); }
extern "C" uint64_t sf_attacks(uint8_t pt, uint8_t s, uint64_t occupied) {
    return Attacks::attacks_bb(PieceType(pt), Square(s), occupied);
}
extern "C" uint64_t sf_geometry(uint8_t kind, uint8_t a, uint8_t b) {
    return kind == 0 ? Attacks::line_bb(Square(a), Square(b))
         : kind == 1 ? Attacks::between_bb(Square(a), Square(b))
                     : Attacks::ray_pass_bb(Square(a), Square(b));
}
extern "C" uint64_t sf_magic(uint8_t pt, uint8_t s) { return Attacks::magic(Square(s), PieceType(pt)).magic; }
