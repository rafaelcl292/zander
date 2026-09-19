// Generate fixtures directly from the pinned Position::init implementation.
// GPL-3.0-or-later. Test-only; never linked into the Zig engine.
#include "../vendor/stockfish/src/attacks.cpp"
#include "../vendor/stockfish/src/position.cpp"
#include "../vendor/stockfish/src/movegen.cpp"
#include <cstdio>
#include <fstream>
using namespace Stockfish;
uint64_t perft(Position& pos, unsigned depth) {
    if (depth == 0) return 1;
    uint64_t total = 0;
    for (auto move : MoveList<LEGAL>(pos)) {
        StateInfo next;
        pos.do_move(move, next);
        total += perft(pos, depth - 1);
        pos.undo_move(move);
    }
    return total;
}
void emit_snapshot(Position& pos, bool children, uint16_t incoming = 0) {
        std::printf(".{ .valid = true, .fen = \"%s\", .data = &.{\n", pos.fen().c_str());
        const auto emit = [](uint64_t n) { std::printf("%llu,", (unsigned long long)n); };
        for (int i = 0; i < 64; ++i) emit(pos.piece_on(Square(i)));
        emit(pos.pieces());
        for (int i = 1; i < 8; ++i) emit(pos.pieces(PieceType(i)));
        for (Color c : {WHITE, BLACK}) emit(pos.pieces(c));
        emit(pos.key()); emit(pos.state()->key); emit(pos.state()->materialKey); emit(pos.state()->pawnKey); emit(pos.state()->minorPieceKey);
        for (auto k : pos.state()->nonPawnKey) emit(k);
        for (auto v : pos.state()->nonPawnMaterial) emit(v);
        emit(pos.state()->castlingRights); emit(pos.state()->rule50); emit(pos.state()->pliesFromNull); emit(pos.state()->epSquare);
        emit(pos.state()->checkersBB);
        for (auto v : pos.state()->blockersForKing) emit(v);
        for (auto v : pos.state()->pinners) emit(v);
        for (int pt = PAWN; pt <= KING; ++pt) emit(pos.state()->checkSquares[pt]);
        emit(pos.state()->capturedPiece); emit(pos.state()->repetition); emit(pos.game_ply()); emit(pos.side_to_move());
        for (CastlingRights cr : {WHITE_OO, WHITE_OOO, BLACK_OO, BLACK_OOO}) {
            emit(pos.can_castle(cr));
            emit(pos.can_castle(cr) ? pos.castling_rook_square(cr) : SQ_NONE);
            emit(pos.can_castle(cr) && pos.castling_impeded(cr));
        }
        for (int i = 0; i < 64; ++i) emit(pos.attackers_to(Square(i)));
        std::puts("}, .legal = &.{");
        for (auto m : MoveList<LEGAL>(pos)) std::printf("%u,", unsigned(m.raw()));
        std::puts("}, .pseudo = &.{");
        if (pos.checkers()) {
            for (auto m : MoveList<EVASIONS>(pos)) std::printf("%u,", unsigned(m.raw()));
        } else {
            for (auto m : MoveList<NON_EVASIONS>(pos)) std::printf("%u,", unsigned(m.raw()));
        }
        std::puts("}, .captures = &.{");
        if (!pos.checkers()) for (auto m : MoveList<CAPTURES>(pos)) std::printf("%u,", unsigned(m.raw()));
        std::puts("}, .quiets = &.{");
        if (!pos.checkers()) for (auto m : MoveList<QUIETS>(pos)) std::printf("%u,", unsigned(m.raw()));
        std::puts("}, .children = &.{");
        if (children) {
            for (auto move : MoveList<LEGAL>(pos)) {
                StateInfo next;
                pos.do_move(move, next);
                emit_snapshot(pos, false, move.raw());
                pos.undo_move(move);
            }
        }
        std::puts("}, .walk = &.{");
        if (children) {
            StateInfo states[48];
            Move moves[48];
            int count = 0;
            PRNG rng(20260919);
            while (count < 48) {
                MoveList<LEGAL> legal(pos);
                if (legal.size() == 0) break;
                Move move = legal.begin()[rng.rand<uint64_t>() % legal.size()];
                moves[count] = move;
                pos.do_move(move, states[count++]);
                emit_snapshot(pos, false, move.raw());
            }
            while (count) pos.undo_move(moves[--count]);
        }
        std::puts("}, .null_state = &.{");
        if (children && !pos.checkers()) {
            StateInfo next;
            pos.do_null_move(next);
            emit_snapshot(pos, false, Move::null().raw());
            pos.undo_null_move();
        }
        std::printf("}, .move = %u, .nodes = %llu },\n", unsigned(incoming), (unsigned long long)(children ? perft(pos, 3) : 0));
}

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
    std::puts("pub const Snapshot = struct { valid: bool, fen: []const u8, data: []const u64, legal: []const u16 = &.{}, pseudo: []const u16 = &.{}, captures: []const u16 = &.{}, quiets: []const u16 = &.{}, children: []const Snapshot = &.{}, walk: []const Snapshot = &.{}, null_state: []const Snapshot = &.{}, move: u16 = 0, nodes: u64 = 0 };\npub const positions = [_]Snapshot{");
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
        emit_snapshot(pos, true);
    }
    std::puts("};");
    std::puts("pub const repetition = [_]Snapshot{");
    Position pos;
    StateInfo states[13];
    pos.set("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", false, &states[0]);
    const Move cycle[] = {Move(SQ_G1, SQ_F3), Move(SQ_G8, SQ_F6), Move(SQ_F3, SQ_G1), Move(SQ_F6, SQ_G8)};
    for (int i = 0; i < 12; ++i) {
        const Move move = cycle[i % 4];
        pos.do_move(move, states[i + 1]);
        emit_snapshot(pos, false, move.raw());
    }
    std::puts("};");
}
