// Generate fixtures directly from the pinned Position::init implementation.
// GPL-3.0-or-later. Test-only; never linked into the Zig engine.
#include "../vendor/stockfish/src/attacks.cpp"
#include "../vendor/stockfish/src/position.cpp"
#include <cstdio>
int main() {
    using namespace Stockfish;
    Attacks::init();
    Position::init();
    std::puts("pub const keys = [_]u64{");
    for (const auto& row : Zobrist::psq)
        for (auto key : row) std::printf("%llu,\n", (unsigned long long)key);
    for (auto key : Zobrist::enpassant) std::printf("%llu,\n", (unsigned long long)key);
    for (auto key : Zobrist::castling) std::printf("%llu,\n", (unsigned long long)key);
    std::printf("%llu,\n%llu,\n};\n", (unsigned long long)Zobrist::side, (unsigned long long)Zobrist::noPawns);
    std::puts("pub const cuckoo_keys = [_]u64{");
    for (auto key : cuckoo) std::printf("%llu,\n", (unsigned long long)key);
    std::puts("};\npub const cuckoo_moves = [_]u16{");
    for (auto move : cuckooMove) std::printf("%u,\n", unsigned(move.raw()));
    std::puts("};");
}
