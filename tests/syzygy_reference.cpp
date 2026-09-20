// Test-only Syzygy oracle from the pinned Stockfish revision; GPL-3.0-or-later.
#include "../vendor/stockfish/src/attacks.cpp"
#include "../vendor/stockfish/src/position.cpp"
#include "../vendor/stockfish/src/movegen.cpp"
#include "../vendor/stockfish/src/nnue/features/half_ka_v2_hm.cpp"
#include "../vendor/stockfish/src/nnue/features/full_threats.cpp"
#include "../vendor/stockfish/src/nnue/features/pp_3wide.cpp"
#include "../vendor/stockfish/src/syzygy/tbprobe.h"
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
    std::puts("pub const Case = struct { fen: []const u8, wdl: i32, dtz: i32, wdl_state: i32, dtz_state: i32 };\npub const cases = [_]Case{");
    std::ifstream input(argv[2]); std::string fen;
    while(std::getline(input,fen)) {
        Position pos; StateInfo st;
        if(pos.set(fen,false,&st)) continue;
        Tablebases::ProbeState wdlState, dtzState;
        auto wdl=Tablebases::probe_wdl(pos,&wdlState);
        auto dtz=Tablebases::probe_dtz(pos,&dtzState);
        std::printf(".{.fen=\"%s\",.wdl=%d,.dtz=%d,.wdl_state=%d,.dtz_state=%d},\n",fen.c_str(),int(wdl),dtz,int(wdlState),int(dtzState));
    }
    std::puts("};");
}
