// Test-only history update oracle. GPL-3.0-or-later.
#include "../vendor/stockfish/src/history.h"
#include <cstdio>
using namespace Stockfish;
template<int D, bool Shared> void emit() {
    StatsEntry<i16,D,Shared> value;
    for (int initial : {-D,-D/2,-1,0,1,D/2,D}) {
        value = initial;
        for (int bonus : {INT32_MIN,-60000,-D-1,-D,-D/2,-1,0,1,D/2,D,D+1,60000,INT32_MAX}) {
            value << bonus;
            std::printf(".{ .limit=%d, .shared=%s, .initial=%d, .bonus=%d, .result=%d },\n", D,Shared?"true":"false",initial,bonus,int(value));
            // Deliberately chain updates; 'initial' marks the start of each chain.
        }
    }
}
int main() {
    std::printf("pub const Case = struct { limit: i32, shared: bool, initial: i16, bonus: i32, result: i16 };\npub const cases = [_]Case{\n");
    emit<7183,false>(); emit<10692,false>(); emit<30000,true>();
    emit<8192,true>(); emit<8192,false>(); emit<1024,true>(); emit<1024,false>();
    std::puts("};");
    std::printf("pub const sizes = [_]usize{ %zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu };\n",sizeof(ButterflyHistory),sizeof(LowPlyHistory),sizeof(CapturePieceToHistory),sizeof(PieceToHistory),sizeof(ContinuationHistoryBlock),sizeof(CorrectionBundle<i16,1024>),sizeof(CorrectionHistory<PieceTo>),sizeof(CorrectionHistory<Continuation>));
}
