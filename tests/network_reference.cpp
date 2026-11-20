// Test-only real-network oracle from the pinned Stockfish sources.
// GPL-3.0-or-later.
#include <bits/stdc++.h>
#define private public
#include "../vendor/stockfish/src/nnue/network.h"
#undef private
#include "../vendor/stockfish/src/attacks.cpp"
#include "../vendor/stockfish/src/position.cpp"
#include "../vendor/stockfish/src/movegen.cpp"
#include "../vendor/stockfish/src/nnue/features/k32h3.cpp"
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
    Attacks::init();
    std::puts("pub const Event = struct { root: usize, move: u16 = 0, pop: bool = false, evaluate: bool = false, checksum: u64 = 0, positional: i32 = 0, trace: [192]i32 = @splat(0), adjusted: [3]i32 = .{0,0,0} };\npub const events = [_]Event{");
    std::ifstream inputs(argv[2]); std::string line; size_t root = 0;
    while (std::getline(inputs, line)) {
        const size_t index = root++;
        Position pos; StateInfo states[50];
        if (pos.set(line.substr(2), line[0] == '1', &states[0])) continue;
        stack->reset();
        auto emit = [&](Move move, bool pop, bool evaluate) {
            std::printf(".{ .root=%zu, .move=%u, .pop=%s, .evaluate=%s", index, unsigned(move.raw()), pop?"true":"false", evaluate?"true":"false");
            if (evaluate) {
                auto positional = net->evaluate(pos, *stack, *cache);
                uint64_t h = 14695981039346656037ULL;
                for (auto& perspective : stack->latest().accumulation) for (auto v : perspective) h = (h ^ uint16_t(v)) * 1099511628211ULL;
                std::printf(", .checksum=%llu, .positional=%d", (unsigned long long)h, positional);
                if (move == Move::none()) {
                    const auto trace = net->trace_evaluate(pos, *stack, *cache);
                    std::printf(", .trace=.{");
                    for (auto value : trace.positional) std::printf("%d,", value);
                    std::printf("}");
                }
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
        for (auto m : MoveList<ALL>(pos)) {
            const auto before = Features::K32H3::block_state(pos);
            pos.do_move(m, states[1], pos.gives_check(m), stack->push(pos), nullptr);
            emit(m,false,true);
            Move delayedReply = Move::none();
            if (before != Features::K32H3::block_state(pos)) {
                MoveList<ALL> replies(pos);
                if (replies.size()) delayedReply = *replies.begin();
            }
            pos.undo_move(m); stack->pop(); emit(m,true,false);
            if (delayedReply != Move::none()) {
                // Reuse the child slot, defer the block-changing move, then
                // evaluate its descendant and unwind through both positions.
                pos.do_move(m, states[1], pos.gives_check(m), stack->push(pos), nullptr);
                emit(m,false,false);
                pos.do_move(delayedReply, states[2], pos.gives_check(delayedReply), stack->push(pos), nullptr);
                emit(delayedReply,false,true);
                pos.undo_move(delayedReply); stack->pop(); emit(delayedReply,true,true);
                pos.undo_move(m); stack->pop(); emit(m,true,true);
            }
        }
        PRNG rng(20260919); std::vector<Move> moves;
        for (size_t i=0; i<48; ++i) {
            MoveList<ALL> legal(pos); if (!legal.size()) break;
            Move m = *(legal.begin() + rng.rand<uint64_t>() % legal.size());
            pos.do_move(m, states[i+1], pos.gives_check(m), stack->push(pos), nullptr);
            moves.push_back(m); emit(m,false,i%3==2 || i==47);
        }
        while (!moves.empty()) {
            Move m=moves.back(); moves.pop_back(); pos.undo_move(m); stack->pop();
            emit(m,true,moves.size()%4==0);
        }
    }
    std::puts("};");
}
