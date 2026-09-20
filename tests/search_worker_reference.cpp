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
    std::puts("pub const HistoryCase = struct { root: usize, variant: usize, best: u16, quiet: u16, quiets: []const u16, captures: []const u16, before: i32, after: i32, hashes: [7]u64 };\npub const histories = [_]HistoryCase{");
    inputs.clear(); inputs.seekg(0); root=0;
    auto hashBytes=[](const void* pointer,size_t size) {
        uint64_t hash=14695981039346656037ULL;
        auto bytes=static_cast<const unsigned char*>(pointer);
        for(size_t i=0;i<size;++i) hash=(hash^bytes[i])*1099511628211ULL;
        return hash;
    };
    while(std::getline(inputs,line)) {
        size_t index=root++; Position pos; StateInfo st;
        if(pos.set(line.substr(2),line[0]=='1',&st)) continue;
        MoveList<LEGAL> legal(pos); if(!legal.size()) continue;
        for(int variant=0;variant<4;++variant) {
            Search::Stack frames[8]{}; auto ss=frames+7;
            ss->ply=std::array{0,4,5,18}[variant]; ss->inCheck=variant==1;
            for(int i=0;i<7;++i) {
                frames[6-i].continuationHistory=&worker->continuationHistory[0][0][0][i];
                frames[6-i].continuationCorrectionHistory=&worker->continuationCorrectionHistory[0][i];
                frames[6-i].currentMove=(i+variant)%3==0?Move::null():Move(SQ_A2,SQ_A3);
            }
            frames[6].statScore=std::array{0,280,-280,-2800}[variant];
            frames[6].ttHit=variant%2; frames[6].moveCount=variant<3?1+frames[6].ttHit:3;
            Move best=variant%2?*(legal.end()-1):*legal.begin(), quiet=Move::none();
            for(Move m:legal) {
                if(!pos.capture_stage(m)) quiet=m;
                if(variant==2 && pos.capture_stage(m)) best=m;
            }
            SearchedList quiets,captures;
            for(Move m:legal) if(m!=best) {
                auto& list=pos.capture_stage(m)?captures:quiets;
                if(list.size()<8) list.push_back(m);
            }
            int before=correction_value(*worker,pos,ss);
            const int bonus=std::array{-1000,-4,-3,1000}[variant];
            update_correction_history(pos,ss,*worker,bonus);
            if(quiet) update_quiet_histories(pos,ss,*worker,quiet,bonus);
            update_all_stats(pos,ss,*worker,best,variant%2?SQ_NONE:pos.square<KING>(pos.side_to_move()),quiets,captures,std::array{1,4,12,1}[variant],variant==2?best:Move::none(),variant%2==0);
            std::printf(".{ .root=%zu,.variant=%d,.best=%u,.quiet=%u,.before=%d,.after=%d,.quiets=&.{",index,variant,unsigned(best.raw()),unsigned(quiet.raw()),before,correction_value(*worker,pos,ss));
            for(Move m:quiets) std::printf("%u,",unsigned(m.raw()));
            std::printf("},.captures=&.{");
            for(Move m:captures) std::printf("%u,",unsigned(m.raw()));
            std::printf("},.hashes=.{");
            const auto emitHash=[&](const auto& obj) { std::printf("%llu,",(unsigned long long)hashBytes(&obj,sizeof(obj))); };
            emitHash(worker->mainHistory); emitHash(worker->lowPlyHistory); emitHash(worker->captureHistory);
            emitHash(worker->continuationHistory); emitHash(worker->continuationCorrectionHistory);
            std::printf("%llu,",(unsigned long long)hashBytes(&worker->sharedHistory.correctionHistory[0],worker->sharedHistory.correctionHistory.get_size()*sizeof(worker->sharedHistory.correctionHistory[0])));
            emitHash(worker->sharedHistory.pawn_entry(pos));
            std::puts("} },");
        }
    }
    std::puts("};");

    std::puts("pub const reductions = [_]i32{");
    for(size_t i=1;i<worker->reductions.size();++i) std::printf("%d,",worker->reductions[i]);
    std::puts("};\npub const ReductionCase = struct { improving: bool, root_delta: i32, delta: i32, checksum: u64 };\npub const reduction_cases = [_]ReductionCase{");
    for (bool improving : {false,true}) for(int rootDelta : {1,21,320,64002}) for(int delta : {0,1,20,rootDelta}) {
        worker->rootDelta=rootDelta;
        uint64_t hash=14695981039346656037ULL;
        for(int d=1;d<MAX_PLY;++d) for(int mn=1;mn<MAX_MOVES;++mn) hash=(hash^uint32_t(worker->reduction(improving,d,mn,delta)))*1099511628211ULL;
        std::printf(".{ .improving=%s,.root_delta=%d,.delta=%d,.checksum=%llu },\n",improving?"true":"false",rootDelta,delta,(unsigned long long)hash);
    }
    std::puts("};");

    std::puts("pub const MoveCase = struct { root: usize, move: u16, frame: bool, key: u64, nodes: u64, size: usize, current: u16, continuation: i32, correction: i32 };\npub const worker_moves = [_]MoveCase{");
    inputs.clear(); inputs.seekg(0); root=0;
    while(std::getline(inputs,line)) {
        size_t index=root++; Position pos; StateInfo st,next;
        if(pos.set(line.substr(2),line[0]=='1',&st)) continue;
        auto emit=[&](Move move, bool withFrame) {
            Search::Stack frames[8]{}; auto ss=frames+7; ss->inCheck=bool(pos.checkers());
            for(int i=0;i<7;++i) {
                frames[i].continuationHistory=&worker->continuationHistory[0][0][NO_PIECE][0];
                frames[i].continuationCorrectionHistory=&worker->continuationCorrectionHistory[NO_PIECE][0];
            }
            worker->nodes=0; worker->accumulatorStack.reset();
            bool null=move==Move::null();
            if(null) worker->do_null_move(pos,next,ss);
            else worker->do_move(pos,move,next,pos.gives_check(move),withFrame?ss:nullptr);
            int continuation=ss->continuationHistory?int((reinterpret_cast<char*>(ss->continuationHistory)-reinterpret_cast<char*>(&worker->continuationHistory))/sizeof(PieceToHistory)):-1;
            int correction=ss->continuationCorrectionHistory?int((reinterpret_cast<char*>(ss->continuationCorrectionHistory)-reinterpret_cast<char*>(&worker->continuationCorrectionHistory))/sizeof(CorrectionHistory<PieceTo>)):-1;
            std::printf(".{ .root=%zu,.move=%u,.frame=%s,.key=%llu,.nodes=%llu,.size=%zu,.current=%u,.continuation=%d,.correction=%d },\n",index,unsigned(move.raw()),withFrame?"true":"false",(unsigned long long)pos.key(),(unsigned long long)uint64_t(worker->nodes),worker->accumulatorStack.size,unsigned(ss->currentMove.raw()),continuation,correction);
            if(null) worker->undo_null_move(pos); else worker->undo_move(pos,move);
        };
        for(Move move:MoveList<LEGAL>(pos)) { emit(move,true); emit(move,false); }
        if(!pos.checkers()) emit(Move::null(),true);
    }
    std::puts("};");

    std::puts("pub const MainCase = struct { root: usize, depth: i32, mode: usize, warm: bool, score: i32, nodes: u64, sel_depth: i32, tt_checksum: u64, tt_history: i16, history_hashes: [7]u64 = .{0,0,0,0,0,0,0}, pv: []const u16 };\npub const main_cases = [_]MainCase{");
    inputs.clear(); inputs.seekg(0); root=0;
    worker->threadIdx=1; threads.stop=false;
    while(std::getline(inputs,line)) {
        size_t index=root++; Position pos; StateInfo st;
        if(pos.set(line.substr(2),line[0]=='1',&st)) continue;
        for(int depth : {1,2,4,6,8,10}) for(int mode=0;mode<3;++mode) {
            worker->clear(); worker->lowPlyHistory.fill(102);
            std::memset(tt.table,0,tt.clusterCount*sizeof(Cluster)); tt.generation8=0; tt.new_search();
            for(bool warm : {false,true}) {
                worker->nodes=0; worker->selDepth=0; worker->nmpMinPly=0; worker->rootDepth=depth;
                worker->rootDelta=mode==0?64002:1; worker->lastIterationIdxPV.clear();
                worker->accumulatorStack.reset();
                Search::Stack frames[MAX_PLY+10]{}; auto ss=frames+7;
                for(int i=1;i<=7;++i) {
                    (ss-i)->continuationHistory=&worker->continuationHistory[0][0][NO_PIECE][0];
                    (ss-i)->continuationCorrectionHistory=&worker->continuationCorrectionHistory[NO_PIECE][0];
                    (ss-i)->staticEval=VALUE_NONE;
                }
                for(int i=0;i<=MAX_PLY+2;++i) (ss+i)->ply=i;
                Search::PVMoves pv; ss->pv=&pv;
                const int score=mode==0?worker->search<PV>(pos,ss,-32001,32001,depth,false):worker->search<NonPV>(pos,ss,99,100,depth,mode==1);
                std::printf(".{ .root=%zu,.depth=%d,.mode=%d,.warm=%s,.score=%d,.nodes=%llu,.sel_depth=%d,.tt_checksum=%llu,.tt_history=%d,.pv=&.{",index,depth,mode,warm?"true":"false",score,(unsigned long long)uint64_t(worker->nodes),worker->selDepth,(unsigned long long)hashBytes(tt.table,tt.clusterCount*sizeof(Cluster)),int(worker->ttMoveHistory));
                for(Move move:pv) std::printf("%u,",unsigned(move.raw()));
                std::printf("}");
                if(depth==10 && mode==0 && (index==0 || index==2 || index==6)) {
                    std::printf(",.history_hashes=.{");
                    const auto emit=[&](const auto& obj) { std::printf("%llu,",(unsigned long long)hashBytes(&obj,sizeof(obj))); };
                    emit(worker->mainHistory); emit(worker->lowPlyHistory); emit(worker->captureHistory);
                    emit(worker->continuationHistory); emit(worker->continuationCorrectionHistory);
                    std::printf("%llu,",(unsigned long long)hashBytes(&worker->sharedHistory.correctionHistory[0],worker->sharedHistory.correctionHistory.get_size()*sizeof(worker->sharedHistory.correctionHistory[0])));
                    emit(worker->sharedHistory.pawn_entry(pos));
                    std::printf("}");
                }
                std::puts(" },");
            }
        }
    }
    std::puts("};");
    std::puts("pub const RootRecord = struct { effort: u64, score: i32, average: i32, squared: i32, uci: i32, lower: bool, upper: bool, sel_depth: i32, pv: []const u16 };\npub const RootCase = struct { root: usize, depth: i32, mode: usize, warm: bool, score: i32, nodes: u64, sel_depth: i32, changes: usize, tt_checksum: u64, records: []const RootRecord };\npub const root_cases = [_]RootCase{");
    inputs.clear(); inputs.seekg(0); root=0;
    while(std::getline(inputs,line)) {
        size_t index=root++; Position pos; StateInfo st;
        if(pos.set(line.substr(2),line[0]=='1',&st)) continue;
        if(MoveList<LEGAL>(pos).size()==0) continue;
        for(int depth : {1,4,8}) for(int mode=0;mode<3;++mode) {
            worker->clear(); worker->lowPlyHistory.fill(102);
            worker->rootMoves.clear();
            for(Move m:MoveList<LEGAL>(pos)) worker->rootMoves.emplace_back(m);
            worker->pvIdx=mode==2 && worker->rootMoves.size()>1?1:0;
            worker->pvLast=worker->rootMoves.size();
            if(mode==2) worker->pvLast=std::min(worker->pvLast,worker->pvIdx+3);
            std::memset(tt.table,0,tt.clusterCount*sizeof(Cluster)); tt.generation8=0; tt.new_search();
            for(bool warm : {false,true}) {
                worker->nodes=0; worker->selDepth=0; worker->nmpMinPly=0; worker->rootDepth=depth;
                worker->bestMoveChanges=0; worker->lastIterationIdxPV.clear();
                int alpha=mode==0?-32001:mode==1?99:-101, beta=mode==0?32001:mode==1?100:-100;
                worker->rootDelta=beta-alpha; worker->accumulatorStack.reset();
                Search::Stack frames[MAX_PLY+10]{}; auto ss=frames+7;
                for(int i=1;i<=7;++i) {
                    (ss-i)->continuationHistory=&worker->continuationHistory[0][0][NO_PIECE][0];
                    (ss-i)->continuationCorrectionHistory=&worker->continuationCorrectionHistory[NO_PIECE][0];
                    (ss-i)->staticEval=VALUE_NONE;
                }
                for(int i=0;i<=MAX_PLY+2;++i) (ss+i)->ply=i;
                Search::PVMoves pv; ss->pv=&pv;
                int score=worker->search<Root>(pos,ss,alpha,beta,depth,false);
                std::printf(".{ .root=%zu,.depth=%d,.mode=%d,.warm=%s,.score=%d,.nodes=%llu,.sel_depth=%d,.changes=%zu,.tt_checksum=%llu,.records=&.{",index,depth,mode,warm?"true":"false",score,(unsigned long long)uint64_t(worker->nodes),worker->selDepth,size_t(worker->bestMoveChanges),(unsigned long long)hashBytes(tt.table,tt.clusterCount*sizeof(Cluster)));
                for(const auto& rm:worker->rootMoves) {
                    std::printf(".{ .effort=%llu,.score=%d,.average=%d,.squared=%d,.uci=%d,.lower=%s,.upper=%s,.sel_depth=%d,.pv=&.{",(unsigned long long)rm.effort,rm.score,rm.averageScore,rm.meanSquaredScore,rm.uciScore,rm.inexactLower?"true":"false",rm.inexactUpper?"true":"false",rm.selDepth);
                    for(Move move:rm.pv) std::printf("%u,",unsigned(move.raw()));
                    std::printf("} },");
                }
                std::puts("} },");
            }
        }
    }
    std::puts("};");

}
