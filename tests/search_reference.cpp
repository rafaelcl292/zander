// Test-only access to the pinned scalar search helpers. GPL-3.0-or-later.
#include "../vendor/stockfish/src/search.cpp"
#include <cstdio>
using namespace Stockfish;
int main() {
    std::puts("pub const ScoreCase = struct { score: i32, ply: i32, rule50: i32, stored: i32, restored: i32 };\npub const scores = [_]ScoreCase{");
    for (int score : {-32001,-32000,-31755,-31754,-31753,-31508,-31507,-31506,-100,0,100,31506,31507,31508,31753,31754,31755,32000,32001,32002})
        for (int ply : {0,1,7,100,246}) for (int rule50 : {0,1,50,99,100,101,32767})
            std::printf(".{ .score=%d,.ply=%d,.rule50=%d,.stored=%d,.restored=%d },\n",score,ply,rule50,score==VALUE_NONE?VALUE_NONE:value_to_tt(score,ply),value_from_tt(score,ply,rule50));
    std::puts("};\npub const Correction = struct { value: i32, correction: i32, result: i32 };\npub const corrections = [_]Correction{");
    for (int v : {-32000,-31506,-1,0,1,31506,32000}) for (int cv : {INT32_MIN,-131073,-131072,-131071,-1,0,1,131071,131072,131073,INT32_MAX})
        std::printf(".{ .value=%d,.correction=%d,.result=%d },\n",v,cv,to_corrected_static_eval(v,cv));
    std::puts("};\npub const Continuation = struct { in_check: bool, valid: u8, bonus: i32, initial: [6]i16, result: [6]i16 };\npub const continuations = [_]Continuation{");
    auto tables = std::make_unique<PieceToHistory[]>(6);
    Stack frames[7]{};
    for (bool check : {false,true}) for (int mask=0;mask<64;++mask) for (int bonus : {-4000,-500,-1,0,1,500,4000}) {
        std::printf(".{ .in_check=%s,.valid=%d,.bonus=%d,.initial=.{",check?"true":"false",mask,bonus);
        frames[6].inCheck=check;
        for (int i=0;i<6;++i) {
            frames[5-i].continuationHistory=&tables[i];
            frames[5-i].currentMove=(mask&(1<<i))?Move(SQ_A2,SQ_A3):Move::null();
            int v=int((make_key(mask*17+i+123) >> 32)%60001)-30000;
            tables[i][W_KNIGHT][SQ_C3]=v;
            std::printf("%d,",v);
        }
        update_continuation_histories(&frames[6],W_KNIGHT,SQ_C3,bonus);
        std::printf("},.result=.{");
        for (int i=0;i<6;++i) std::printf("%d,",int(tables[i][W_KNIGHT][SQ_C3]));
        std::puts("} },");
    }
    std::puts("};\npub const divisors = [_]i32{");
    for (int d=0;d<=MAX_PLY;++d) std::printf("%d,",lmr_divisor(d));
    std::puts("};\npub const pv = [_]u16{");
    Search::PVMoves pv, child;
    for(int i=0;i<MAX_PLY;++i) child.push_back(Move(uint16_t(i+100)));
    pv.update(Move(uint16_t(400)),&child);
    for(auto m : pv) std::printf("%u,",unsigned(m.raw()));
    std::puts("};");
}
