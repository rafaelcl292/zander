// Test-only Syzygy oracle from the pinned Stockfish revision; GPL-3.0-or-later.
#include "../vendor/stockfish/src/attacks.cpp"
#include "../vendor/stockfish/src/position.cpp"
#include "../vendor/stockfish/src/movegen.cpp"
#include "../vendor/stockfish/src/nnue/features/half_ka_v2_hm.cpp"
#include "../vendor/stockfish/src/nnue/features/full_threats.cpp"
#include "../vendor/stockfish/src/nnue/features/pp_3wide.cpp"
#include "../vendor/stockfish/src/syzygy/tbprobe.h"
#include "../vendor/stockfish/src/search.h"
#include <cstdio>
#include <fstream>
#include <sstream>
using namespace Stockfish;
int main(int argc, char** argv) {
    if(argc != 3) return 1;
    Attacks::init(); Position::init();
    std::ostringstream discarded;
    auto previous = std::cout.rdbuf(discarded.rdbuf());
    Tablebases::init(argv[1]);
    std::cout.rdbuf(previous);
    std::puts("pub const Root = struct { move: u16, dtz_rank: i32, dtz_score: i32, wdl_rank: i32, wdl_score: i32 };\npub const Case = struct { fen: []const u8, wdl: i32, dtz: i32, wdl_state: i32, dtz_state: i32, roots: []const Root, rule50: bool, rank_distance: bool, dtz_ok: bool, wdl_ok: bool };\npub const cases = [_]Case{");
    unsigned index=0;
    std::ifstream input(argv[2]); std::string fen;
    while(std::getline(input,fen)) {
        Position pos; StateInfo st;
        if(pos.set(fen,false,&st)) continue;
        Tablebases::ProbeState wdlState, dtzState;
        auto wdl=Tablebases::probe_wdl(pos,&wdlState);
        auto dtz=Tablebases::probe_dtz(pos,&dtzState);
        const bool rule50=index%3!=0, rankDistance=index%2==0;
        Search::RootMoves roots;
        if(index++%29==0) for(Move move:MoveList<LEGAL>(pos)) roots.emplace_back(move);
        bool dtzOk=Tablebases::root_probe(pos,roots,rule50,rankDistance,[](){return false;});
        auto distance=roots;
        bool wdlOk=Tablebases::root_probe_wdl(pos,roots,rule50);
        std::printf(".{.fen=\"%s\",.wdl=%d,.dtz=%d,.wdl_state=%d,.dtz_state=%d,.rule50=%s,.rank_distance=%s,.dtz_ok=%s,.wdl_ok=%s,.roots=&.{",fen.c_str(),int(wdl),dtz,int(wdlState),int(dtzState),rule50?"true":"false",rankDistance?"true":"false",dtzOk?"true":"false",wdlOk?"true":"false");
        for(size_t i=0;i<roots.size();++i) std::printf(".{.move=%u,.dtz_rank=%d,.dtz_score=%d,.wdl_rank=%d,.wdl_score=%d},",roots[i].pv[0].raw(),distance[i].tbRank,distance[i].tbScore,roots[i].tbRank,roots[i].tbScore);
        std::puts("}},");
    }
    std::puts("};");
}
