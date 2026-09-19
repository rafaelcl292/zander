// Generate fixtures directly from the pinned Position::init implementation.
// GPL-3.0-or-later. Test-only; never linked into the Zig engine.
#include "../vendor/stockfish/src/attacks.cpp"
#include "../vendor/stockfish/src/position.cpp"
#include <cstdio>
#include <fstream>
int main(int argc, char** argv) {
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
    std::puts("pub const Snapshot = struct { valid: bool, fen: []const u8, data: []const u64 };\npub const positions = [_]Snapshot{");
    if (argc != 2) return 1;
    std::ifstream input(argv[1]);
    if (!input) return 1;
    std::string line;
    while (std::getline(input, line)) {
        if (line.empty()) continue;
        Position pos;
        StateInfo st;
        auto error = pos.set(line.substr(2), line[0] == '1', &st);
        if (error) { std::puts(".{ .valid = false, .fen = \"\", .data = &.{} },"); continue; }
        std::printf(".{ .valid = true, .fen = \"%s\", .data = &.{\n", pos.fen().c_str());
        const auto emit = [](uint64_t n) { std::printf("%llu,", (unsigned long long)n); };
        for (int i = 0; i < 64; ++i) emit(pos.piece_on(Square(i)));
        emit(pos.pieces());
        for (int i = 1; i < 8; ++i) emit(pos.pieces(PieceType(i)));
        for (Color c : {WHITE, BLACK}) emit(pos.pieces(c));
        emit(pos.key()); emit(st.key); emit(st.materialKey); emit(st.pawnKey); emit(st.minorPieceKey);
        for (auto k : st.nonPawnKey) emit(k);
        for (auto v : st.nonPawnMaterial) emit(v);
        emit(st.castlingRights); emit(st.rule50); emit(st.pliesFromNull); emit(st.epSquare);
        emit(st.checkersBB);
        for (auto v : st.blockersForKing) emit(v);
        for (auto v : st.pinners) emit(v);
        for (auto v : st.checkSquares) emit(v);
        emit(st.capturedPiece); emit(st.repetition); emit(pos.game_ply()); emit(pos.side_to_move());
        for (CastlingRights cr : {WHITE_OO, WHITE_OOO, BLACK_OO, BLACK_OOO}) {
            emit(pos.can_castle(cr));
            emit(pos.can_castle(cr) ? pos.castling_rook_square(cr) : SQ_NONE);
            emit(pos.can_castle(cr) && pos.castling_impeded(cr));
        }
        for (int i = 0; i < 64; ++i) emit(pos.attackers_to(Square(i)));
        std::puts("} },");
    }
    std::puts("};");
}
