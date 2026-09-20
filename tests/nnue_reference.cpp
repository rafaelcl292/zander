// Scalar NNUE arithmetic and serialization oracle; GPL-3.0-or-later.
#include "../vendor/stockfish/src/nnue/nnue_architecture.h"
#include <cstdio>
#include <sstream>
using namespace Stockfish;
using namespace Stockfish::Eval::NNUE;
template<typename Range> void emit(const Range& values) {
    for (auto v : values) std::printf("%lld,", (long long)v);
}
int main() {
    std::ostringstream bytes(std::ios::binary);
    const int ins[] = {1024, 64, 128}, outs[] = {32, 32, 1};
    for (int layer = 0; layer < 3; ++layer) {
        for (int out = 0; out < outs[layer]; ++out) write_little_endian<i32>(bytes, ((out * 97 + layer * 13) % 257 - 128) * 64);
        for (int out = 0; out < outs[layer]; ++out)
            for (int in = 0; in < ins[layer]; ++in)
                write_little_endian<i8>(bytes, i8((in * 7 + layer * 3 + out * 5) % 17 - 8));
    }
    std::puts("pub const parameters = [_]u8{");
    for (unsigned char b : bytes.str()) std::printf("%u,", unsigned(b));
    std::puts("};");
    NetworkArchitecture network;
    std::istringstream stream(bytes.str(), std::ios::binary);
    if (!network.read_parameters(stream)) return 1;
    std::printf("pub const architecture_hash: u32 = %u;\n", NetworkArchitecture::get_hash_value());
    std::puts("pub const Case = struct { input: [1024]u8, fc0: [32]i32, concat: [128]u8, fc1: [32]i32, fc2: i32, result: i32 };\npub const cases = [_]Case{");
    for (int n = 0; n < 64; ++n) {
        alignas(64) u8 input[1024], concat[128];
        alignas(64) i32 fc0[32], fc1[32], fc2[32];
        for (int i = 0; i < 1024; ++i) input[i] = n == 0 ? 0 : n == 1 ? 127 : (i + n) % 5 ? 0 : (i * 17 + n * 29) % 128;
        NNZInfo<1024> nnz{};
        network.fc_0.propagate(input, fc0, nnz);
        network.ac_sqr_0.propagate(fc0, concat);
        network.ac_0.propagate(fc0, concat + 32);
        network.fc_1.propagate(concat, fc1);
        network.ac_sqr_1.propagate(fc1, concat + 64);
        network.ac_1.propagate(fc1, concat + 96);
        network.fc_2.propagate(concat, fc2);
        std::puts(".{.input=.{"); emit(input);
        std::puts("},.fc0=.{"); emit(fc0);
        std::puts("},.concat=.{"); emit(concat);
        std::puts("},.fc1=.{"); emit(fc1);
        std::printf("},.fc2=%d,.result=%d},\n", fc2[0], network.propagate(input, nnz));
    }
    std::puts("};");
    std::ostringstream compressed(std::ios::binary);
    std::array<i16, 8> short_values{-32768, -8192, -65, -1, 0, 64, 8192, 32767};
    std::array<i32, 8> long_values{INT32_MIN, -2097152, -8193, -1, 0, 8192, 2097152, INT32_MAX};
    write_leb_128<i16>(compressed, short_values);
    write_leb_128<i32>(compressed, long_values);
    std::puts("pub const compressed = [_]u8{");
    for (unsigned char b : compressed.str()) std::printf("%u,", unsigned(b));
    std::puts("};");
}
