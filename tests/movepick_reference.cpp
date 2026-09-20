// Test-only scalar move ordering oracle. GPL-3.0-or-later.
#include "../vendor/stockfish/src/attacks.cpp"
#include "../vendor/stockfish/src/position.cpp"
#include "../vendor/stockfish/src/movegen.cpp"
#include "../vendor/stockfish/src/movepick.cpp"
#include <cstdio>
#include <fstream>
using namespace Stockfish;
bool flat = false;
int sample(uint64_t seed, uint64_t index, int limit) {
    if (flat) return 0;
    return int((make_key(seed ^ index) >> 32) % (2 * limit + 1)) - limit;
}
int main(int argc, char** argv) {
    if (argc != 2) return 1;
    Attacks::init(); Position::init();
    auto main = std::make_unique<ButterflyHistory>();
    auto low = std::make_unique<LowPlyHistory>();
    auto capture = std::make_unique<CapturePieceToHistory>();
    auto continuation = std::make_unique<PieceToHistory[]>(6);
    const PieceToHistory* ch[6];
    SharedHistories shared(1);
    std::puts("pub const Case = struct { flat: bool, fen: []const u8, chess960: bool, tt: u16, depth: i32, ply: usize, probcut: bool, threshold: i32, skip_after: usize, moves: []const u16 };\npub const cases = [_]Case{");
    for (int pattern=0; pattern<2; ++pattern) {
    flat = pattern == 1;
    for (int c=0;c<2;++c) for (int m=0;m<65536;++m) (*main)[c][m]=sample(11,c*65536+m,7183);
    for (int p=0;p<5;++p) for (int m=0;m<65536;++m) (*low)[p][m]=sample(22,p*65536+m,7183);
    for (int pc=0;pc<16;++pc) for (int to=0;to<64;++to) for (int cap=0;cap<8;++cap) (*capture)[pc][to][cap]=sample(33,(pc*64+to)*8+cap,10692);
    for (int j=0;j<6;++j) {
        ch[j]=&continuation[j];
        for (int pc=0;pc<16;++pc) for (int to=0;to<64;++to) continuation[j][pc][to]=sample(44,(j*16+pc)*64+to,30000);
    }
    auto emit = [&](Position& pos, Move tt, int depth, int ply, bool probcut, int threshold, int skipAfter) {
        auto picker = probcut ? std::make_unique<MovePicker>(pos,tt,threshold,capture.get()) : std::make_unique<MovePicker>(pos,tt,depth,main.get(),low.get(),capture.get(),ch,&shared,ply);
        // Walks can exceed the parser's clock limits. Move ordering uses
        // neither clock; normalize both to keep serialized fixtures parseable.
        std::string fen = pos.fen();
        fen.erase(fen.rfind(' '));
        fen.replace(fen.rfind(' ') + 1, std::string::npos, "0 1");
        std::printf(".{ .flat=%s, .fen=\"%s\", .chess960=%s, .tt=%u, .depth=%d, .ply=%d, .probcut=%s, .threshold=%d, .skip_after=%d, .moves=&.{",flat?"true":"false",fen.c_str(),pos.is_chess960()?"true":"false",unsigned(tt.raw()),depth,ply,probcut?"true":"false",threshold,skipAfter);
        for (int n=0;;++n) {
            if (n==skipAfter) picker->skip_quiet_moves();
            Move m=picker->next_move(); if (!m) break;
            std::printf("%u,",unsigned(m.raw()));
            if (n>=MAX_MOVES) std::abort();
        }
        std::puts("} },");
    };
    std::ifstream inputs(argv[1]); std::string line;
    while (std::getline(inputs,line)) {
        Position pos; StateInfo states[9];
        if (pos.set(line.substr(2),line[0]=='1',&states[0])) continue;
        PRNG rng(20260919);
        for (int step=0;step<9;++step) {
            auto& pawn=shared.pawn_entry(pos);
            for (int pc=0;pc<16;++pc) for (int to=0;to<64;++to) pawn[pc][to]=sample(55,pc*64+to,8192);
            MoveList<LEGAL> legal(pos);
            for (int depth : {-1,0,1,2,4,8}) {
                int ply=(depth+1)%6;
                emit(pos,Move::none(),depth,ply,false,0,999);
                emit(pos,legal.size()?*legal.begin():Move::none(),depth,ply,false,0,0);
                emit(pos,legal.size()?*(legal.end()-1):Move::none(),depth,ply,false,0,3);
                emit(pos,Move::make<NORMAL>(SQ_A1,SQ_A1),depth,ply,false,0,12);
            }
            // Every legal TT move must come first, even a quiet in quiescence.
            for (Move m : legal) emit(pos,m,0,0,false,0,999);
            if (!pos.checkers()) for (int threshold : {-800,0,300,1000}) {
                emit(pos,Move::none(),0,0,true,threshold,999);
                emit(pos,legal.size()?*legal.begin():Move::none(),0,0,true,threshold,999);
            }
            if (!legal.size() || step==8) break;
            Move move=*(legal.begin()+rng.rand<uint64_t>()%legal.size());
            pos.do_move(move,states[step+1]);
        }
    }
    }
    std::puts("};");
}
