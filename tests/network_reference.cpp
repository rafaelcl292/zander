// Test-only real-network oracle from the pinned Stockfish sources.
// GPL-3.0-or-later.
#include <bits/stdc++.h>
#define private public
#include "../vendor/stockfish/src/nnue/network.h"
#undef private
#include "../vendor/stockfish/src/attacks.cpp"
#include "../vendor/stockfish/src/position.cpp"
#include "../vendor/stockfish/src/movegen.cpp"
#include "../vendor/stockfish/src/nnue/features/half_ka_v2_hm.cpp"
#include "../vendor/stockfish/src/nnue/features/full_threats.cpp"
#include "../vendor/stockfish/src/nnue/features/pp_3wide.cpp"
#include "../vendor/stockfish/src/nnue/nnue_accumulator.cpp"
#include "../vendor/stockfish/src/nnue/network.cpp"
#include "../vendor/stockfish/src/evaluate.cpp"
using namespace Stockfish;
using namespace Stockfish::Eval::NNUE;
int main(int argc, char** argv) {
    if (argc != 3) return 1;
    auto net = std::make_unique<Network>();
    std::ifstream weights(argv[1], std::ios::binary);
    std::string description;
    if (!net->read_parameters(weights, description)) return 2;
    net->initialized = true;
    auto stack = std::make_unique<AccumulatorStack>();
    auto cache = std::make_unique<AccumulatorCaches>(*net);
    Attacks::init(); Position::init();
    std::puts("pub const Event = struct { root: usize, move: u16 = 0, pop: bool = false, evaluate: bool = false, checksum: u64 = 0, psqt: i32 = 0, positional: i32 = 0, adjusted: [3]i32 = .{0,0,0} };\npub const events = [_]Event{");
    std::ifstream inputs(argv[2]); std::string line; size_t root = 0;
    while (std::getline(inputs, line)) {
        const size_t index = root++;
        Position pos; StateInfo states[50];
        if (pos.set(line.substr(2), line[0] == '1', &states[0])) continue;
        stack->reset();
        auto emit = [&](Move move, bool pop, bool evaluate) {
            std::printf(".{ .root=%zu, .move=%u, .pop=%s, .evaluate=%s", index, unsigned(move.raw()), pop?"true":"false", evaluate?"true":"false");
            if (evaluate) {
                auto [psqt, positional] = net->evaluate(pos, *stack, *cache);
                uint64_t h = 14695981039346656037ULL;
                for (auto& perspective : stack->latest().accumulation) for (auto v : perspective) h = (h ^ uint16_t(v)) * 1099511628211ULL;
                for (auto& perspective : stack->latest().psqtAccumulation) for (auto v : perspective) h = (h ^ uint32_t(v)) * 1099511628211ULL;
                std::printf(", .checksum=%llu, .psqt=%d, .positional=%d", (unsigned long long)h, psqt, positional);
                if (!pos.checkers()) {
                    std::printf(", .adjusted=.{");
                    for (int optimism : {0, 17, -13}) std::printf("%d,", Eval::evaluate(*net,pos,*stack,*cache,optimism));
                    std::printf("}");
                }
            }
            std::puts(" },");
        };
        emit(Move::none(), false, true);
        if (!pos.checkers()) {
            pos.do_null_move(states[1]); emit(Move::null(),false,true);
            pos.undo_null_move(); emit(Move::null(),true,true);
        }
        // Exercise every legal first move, including promotions and Chess960 castling.
        for (auto m : MoveList<LEGAL>(pos)) {
            pos.do_move(m, states[1], pos.gives_check(m), stack->push(), nullptr, nullptr);
            emit(m,false,true);
            pos.undo_move(m); stack->pop(); emit(m,true,false);
        }
        PRNG rng(20260919); std::vector<Move> moves;
        for (size_t i=0; i<48; ++i) {
            MoveList<LEGAL> legal(pos); if (!legal.size()) break;
            Move m = *(legal.begin() + rng.rand<uint64_t>() % legal.size());
            pos.do_move(m, states[i+1], pos.gives_check(m), stack->push(), nullptr, nullptr);
            moves.push_back(m); emit(m,false,i%3==2 || i==47);
        }
        while (!moves.empty()) {
            Move m=moves.back(); moves.pop_back(); pos.undo_move(m); stack->pop();
            emit(m,true,moves.size()%4==0);
        }
    }
    std::puts("};");
}
