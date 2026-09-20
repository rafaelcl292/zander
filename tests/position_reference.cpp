// Generate fixtures directly from the pinned Position::init implementation.
// GPL-3.0-or-later. Test-only; never linked into the Zig engine.
#include "../vendor/stockfish/src/attacks.cpp"
#include "../vendor/stockfish/src/position.cpp"
#include "../vendor/stockfish/src/movegen.cpp"
#include "../vendor/stockfish/src/nnue/features/half_ka_v2_hm.cpp"
#include "../vendor/stockfish/src/nnue/features/full_threats.cpp"
#include "../vendor/stockfish/src/nnue/features/pp_3wide.cpp"
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
void emit_snapshot(Position& pos, bool children, uint16_t incoming = 0, const Dirties* changes = nullptr) {
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
        std::puts("}, .prefetch_keys = &.{");
        for (auto move : MoveList<LEGAL>(pos)) std::printf("%llu,", (unsigned long long)pos.prefetch_key(move));
        std::puts("}, .queries = &.{");
        for (auto move : MoveList<LEGAL>(pos)) {
            unsigned flags = unsigned(pos.capture(move)) | (unsigned(pos.capture_stage(move)) << 1)
                           | (unsigned(pos.gives_check(move)) << 2) | (unsigned(pos.pseudo_legal(move)) << 3);
            unsigned bit = 4;
            for (int threshold : {-3000, -1276, -825, -208, -1, 0, 1, 208, 781, 825, 1276, 2538, 3000})
                flags |= unsigned(pos.see_ge(move, threshold)) << bit++;
            std::printf("%u,", flags);
        }
        std::puts("}, .draw_flags = &.{");
        for (int ply : {0, 1, 2, 3, 4, 5, 8, 32}) {
            unsigned flags = unsigned(pos.is_draw(ply)) | (unsigned(pos.is_repetition(ply)) << 1)
                           | (unsigned(pos.has_repeated()) << 2) | (unsigned(pos.upcoming_repetition(ply)) << 3);
            std::printf("%u,", flags);
        }
        std::puts("}, .normal_pseudo = &.{");
        if (children) {
            for (unsigned raw = 1; raw < 4096; ++raw) {
                Move move{uint16_t(raw)};
                if (move.is_ok() && pos.pseudo_legal(move)) std::printf("%u,", raw);
            }
        }
        std::puts("}, .children = &.{");
        if (children) {
            for (auto move : MoveList<LEGAL>(pos)) {
                StateInfo next;
                Dirties dirties;
                pos.do_move(move, next, pos.gives_check(move), dirties, nullptr, nullptr);
                emit_snapshot(pos, false, move.raw(), &dirties);
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
                Dirties dirties;
                pos.do_move(move, states[count++], pos.gives_check(move), dirties, nullptr, nullptr);
                emit_snapshot(pos, false, move.raw(), &dirties);
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
        std::puts("}, .dirty_piece = &.{");
        if (changes) {
            const auto& d = changes->dirtyPiece;
            std::printf("%u,%u,%u,%u,%u,%u,%u", unsigned(d.pc), unsigned(d.from), unsigned(d.to),
                unsigned(d.remove_sq), unsigned(d.add_sq), unsigned(d.remove_sq == SQ_NONE ? NO_PIECE : d.remove_pc),
                unsigned(d.add_sq == SQ_NONE ? NO_PIECE : d.add_pc));
        }
        std::puts("}, .dirty_threats = &.{");
        if (changes) for (auto d : changes->dirtyThreats.list) std::printf("%u,", d.raw());
        std::puts("}, .dirty_pawns = &.{");
        if (changes) {
            for (auto b : changes->dirtyPawnPairs.before) emit(b);
            for (auto b : changes->dirtyPawnPairs.after) emit(b);
        }
        std::puts("}, .features = &.{");
        using namespace Eval::NNUE::Features;
        const auto list = [](const auto& indices) { for (auto index : indices) std::printf("%u,", unsigned(index)); };
        for (Color c : {WHITE, BLACK}) {
            const Square king = pos.square<KING>(c);
            std::puts(".{ .half = &.{");
            for (Bitboard b = pos.pieces(); b;) {
                const Square s = pop_lsb(b);
                std::printf("%u,", unsigned(HalfKAv2_hm::make_index(c, s, pos.piece_on(s), king)));
            }
            std::puts("}, .threats = &.{");
            FullThreats::IndexList threats;
            FullThreats::append_active_indices(c, pos, threats); list(threats);
            std::puts("}, .pawns = &.{");
            PP_3Wide::IndexList pawns;
            PP_3Wide::append_active_indices(c, pos, pawns); list(pawns);
            HalfKAv2_hm::IndexList hr, ha;
            FullThreats::IndexList tr, ta;
            PP_3Wide::IndexList pr, pa;
            if (changes) {
                HalfKAv2_hm::append_changed_indices(c, king, changes->dirtyPiece, hr, ha);
                FullThreats::append_changed_indices(c, king, changes->dirtyThreats, tr, ta);
                PP_3Wide::append_changed_indices(c, king, changes->dirtyPawnPairs, pr, pa);
            }
            std::puts("}, .half_removed = &.{"); list(hr);
            std::puts("}, .half_added = &.{"); list(ha);
            std::puts("}, .threats_removed = &.{"); list(tr);
            std::puts("}, .threats_added = &.{"); list(ta);
            std::puts("}, .pawns_removed = &.{"); list(pr);
            std::puts("}, .pawns_added = &.{"); list(pa);
            std::printf("}, .refresh = %s },\n", changes && HalfKAv2_hm::requires_refresh(changes->dirtyPiece, c) ? "true" : "false");
        }
        std::printf("}, .move = %u, .nodes = %llu },\n", unsigned(incoming), (unsigned long long)(children ? perft(pos, 3) : 0));
}

int main(int argc, char** argv) {
    using namespace Stockfish;
    Attacks::init();
    Position::init();
    using namespace Eval::NNUE::Features;
    uint64_t hashes[3] = {14695981039346656037ULL, 14695981039346656037ULL, 14695981039346656037ULL};
    const auto mix = [&](int i, uint32_t value) { hashes[i] = (hashes[i] ^ value) * 1099511628211ULL; };
    for (Color c : {WHITE, BLACK}) {
        for (int k = 0; k < 64; ++k) for (int s = 0; s < 64; ++s) for (auto pc : Pieces)
            mix(0, HalfKAv2_hm::make_index(c, Square(s), pc, Square(k)));
        for (Square k : {SQ_A1, SQ_H1}) {
            for (auto pc : Pieces) for (int from = 0; from < 64; ++from) {
                Bitboard targets = type_of(pc) == PAWN ? Attacks::PseudoAttacks[color_of(pc)][from] : Attacks::PseudoAttacks[type_of(pc)][from];
                while (targets) {
                    const Square to = pop_lsb(targets);
                    for (auto target : Pieces) mix(1, FullThreats::make_index(c, pc, Square(from), to, target, k));
                }
            }
            for (int first = 0; first < 96; ++first) for (int second = first + 1; second < 96; ++second)
                mix(2, PP_3Wide::make_index(c, Color(first / 48), Square(first % 48 + 8), Square(second % 48 + 8), Color(second / 48), k));
        }
    }
    std::printf("pub const index_checksums = [_]u64{%llu,%llu,%llu};\n", (unsigned long long)hashes[0], (unsigned long long)hashes[1], (unsigned long long)hashes[2]);
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
    std::puts("pub const FeatureSet = struct { half: []const u16, threats: []const u16, pawns: []const u16, half_removed: []const u16, half_added: []const u16, threats_removed: []const u16, threats_added: []const u16, pawns_removed: []const u16, pawns_added: []const u16, refresh: bool }; ");
    std::puts("pub const Snapshot = struct { valid: bool, fen: []const u8, data: []const u64, legal: []const u16 = &.{}, pseudo: []const u16 = &.{}, captures: []const u16 = &.{}, quiets: []const u16 = &.{}, queries: []const u32 = &.{}, prefetch_keys: []const u64 = &.{}, draw_flags: []const u8 = &.{}, normal_pseudo: []const u16 = &.{}, children: []const Snapshot = &.{}, walk: []const Snapshot = &.{}, null_state: []const Snapshot = &.{}, features: []const FeatureSet = &.{}, dirty_piece: []const u8 = &.{}, dirty_threats: []const u32 = &.{}, dirty_pawns: []const u64 = &.{}, move: u16 = 0, nodes: u64 = 0 };\npub const positions = [_]Snapshot{");
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
        Dirties dirties;
        pos.do_move(move, states[i + 1], pos.gives_check(move), dirties, nullptr, nullptr);
        emit_snapshot(pos, false, move.raw(), &dirties);
    }
    std::puts("};");
}
