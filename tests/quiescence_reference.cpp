// Test-only real-network oracle from the pinned Stockfish sources.
// GPL-3.0-or-later.
#include <bits/stdc++.h>
#define private public
#include "../vendor/stockfish/src/nnue/network.h"
#include "../vendor/stockfish/src/search.h"
#include "../vendor/stockfish/src/thread.h"
#include "../vendor/stockfish/src/tt.h"
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
#include "../vendor/stockfish/src/search.cpp"
#include "../vendor/stockfish/src/tt.cpp"
int main(int argc, char** argv) {
    if (argc!=3) return 1;
    auto source=std::make_unique<Network>();
    std::ifstream weights(argv[1],std::ios::binary); std::string description;
    if (!source->read_parameters(weights,description)) return 2;
    source->initialized=true;
    Attacks::init(); Position::init();
    NumaReplicationContext numa{NumaConfig{}};
    LazyNumaReplicatedSystemWide<Network> network(numa,std::move(source));
    OptionsMap options; ThreadPool threads; TranspositionTable tt;
    tt.clusterCount=32768;
    tt.table=static_cast<Cluster*>(aligned_large_pages_alloc(tt.clusterCount*sizeof(Cluster)));
    std::map<NumaIndex,SharedHistories> shared;
    shared.try_emplace(0,1);
    Search::SharedState state(options,threads,tt,shared,network);
    auto worker=std::make_unique<Search::Worker>(state,nullptr,0,0,1,NumaReplicatedAccessToken(0));
    worker->lowPlyHistory.fill(102);
    worker->optimism[WHITE]=worker->optimism[BLACK]=0;
    std::puts("pub const Case = struct { root: usize, path: []const u16, pv_node: bool, warm: bool, alpha: i32, beta: i32, score: i32, nodes: u64, sel_depth: i32, tt_checksum: u64, pv: []const u16 };\npub const cases = [_]Case{");
    std::ifstream inputs(argv[2]); std::string line; size_t root=0;
    while (std::getline(inputs,line)) {
        size_t index=root++; Position pos; StateInfo states[9];
        if (pos.set(line.substr(2),line[0]=='1',&states[0])) continue;
        PRNG rng(20260919); std::vector<Move> path;
        for (int step=0; step <= (index==0?8:3); ++step) {
        for (auto window : {std::pair{-32001,32001},std::pair{-100,100},std::pair{-1,0},std::pair{99,100},std::pair{-100,-99}}) {
            bool pvNode=window.first!=window.second-1;
            std::memset(tt.table,0,tt.clusterCount*sizeof(Cluster));
            tt.generation8=0; tt.new_search();
            for (bool warm : {false,true}) {
                Search::Stack stack[MAX_PLY+10]{}; auto ss=stack+7;
                for (int i=1;i<=7;++i) {
                    (ss-i)->continuationHistory=&worker->continuationHistory[0][0][NO_PIECE][0];
                    (ss-i)->continuationCorrectionHistory=&worker->continuationCorrectionHistory[NO_PIECE][0];
                    (ss-i)->staticEval=VALUE_NONE;
                }
                for (int i=0;i<=MAX_PLY+2;++i) (ss+i)->ply=i;
                Search::PVMoves pv; ss->pv=&pv;
                worker->nodes=0; worker->selDepth=0; worker->accumulatorStack.reset();
                int score=pvNode?worker->qsearch<PV>(pos,ss,window.first,window.second):worker->qsearch<NonPV>(pos,ss,window.first,window.second);
                uint64_t hash=14695981039346656037ULL;
                auto bytes=reinterpret_cast<const unsigned char*>(tt.table);
                for(size_t i=0;i<tt.clusterCount*sizeof(Cluster);++i) hash=(hash^bytes[i])*1099511628211ULL;
                std::printf(".{ .root=%zu,.path=&.{",index);
                for (Move m:path) std::printf("%u,",unsigned(m.raw()));
                std::printf("},.pv_node=%s,.warm=%s,.alpha=%d,.beta=%d,.score=%d,.nodes=%llu,.sel_depth=%d,.tt_checksum=%llu,.pv=&.{",pvNode?"true":"false",warm?"true":"false",window.first,window.second,score,(unsigned long long)uint64_t(worker->nodes),worker->selDepth,(unsigned long long)hash);
                for(auto m:pv) std::printf("%u,",unsigned(m.raw()));
                std::puts("} },");
            }
        }
        if (step == (index==0?8:3)) break;
        MoveList<LEGAL> legal(pos);
        if (!legal.size()) break;
        const Move cycle[] = {Move(SQ_B1,SQ_A3),Move(SQ_B8,SQ_A6),Move(SQ_A3,SQ_B1),Move(SQ_A6,SQ_B8)};
        Move move=index==0?cycle[step%4]:*(legal.begin()+rng.rand<uint64_t>()%legal.size());
        path.push_back(move); pos.do_move(move,states[step+1]);
        }
    }
    std::puts("};");
}
