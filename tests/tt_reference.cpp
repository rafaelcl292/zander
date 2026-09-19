// Test-only access to pinned TT internals, avoiding thread-pool allocation.
// Preinclude standard headers so the access shim cannot change library classes.
// GPL-3.0-or-later. This helper is restricted to the GNU/Linux reference harness.
#include <bits/stdc++.h>
#define private public
#include "../vendor/stockfish/src/tt.cpp"
#undef private
using namespace Stockfish;
static void emit_data(const TTData& d) {
    std::printf(".{%u,%d,%d,%d,%u,%u}", unsigned(d.move.raw()), d.value, d.eval, d.depth, unsigned(d.bound), unsigned(d.is_pv));
}
int main() {
    alignas(64) Cluster clusters[1024]{};
    alignas(TranspositionTable) unsigned char memory[sizeof(TranspositionTable)];
    auto* table = new(memory) TranspositionTable;
    // No destructor: backing memory belongs to this stack, not the TT allocator.
    table->clusterCount = 1024;
    table->table = clusters;
    PRNG rng(1070372);
    std::puts("pub const Event = struct { key: u64, found: bool, slot: usize, before: [6]i32, after: [6]i32, generation: u8, hashfull: [3]u32 };\npub const events = [_]Event{");
    for (int i = 0; i < 10000; ++i) {
        if (i % 37 == 0) table->new_search();
        const uint64_t key = i < 3000 ? (uint64_t(i % 16) << 54) | uint64_t(i % 7) : rng.rand<uint64_t>();
        auto [found, data, writer] = table->probe(key);
        std::printf(".{.key=%llu,.found=%s,.slot=%td,.before=", (unsigned long long)key, found ? "true" : "false", writer.entry - table->first_entry(key));
        emit_data(data);
        const int value = i % 11 == 0 ? 31900 : i % 4000 - 2000;
        writer.write(key, value, i % 3 == 0, Bound(i % 4), i % 32 - 2, Move(uint16_t(i % 5 == 0 ? 0 : 1 + i % 4094)), i % 2000 - 1000, table->generation());
        if (i % 7 == 0) writer.penalize(i % 17);
        std::printf(",.after="); emit_data(writer.entry->read());
        std::printf(",.generation=%u,.hashfull=.{%d,%d,%d}},\n", unsigned(table->generation()), table->hashfull(0), table->hashfull(3), table->hashfull(31));
    }
    std::puts("};\npub const edge_cases = [_][6]i32{");
    TTEntry entry{};
    const auto record = [&]() { emit_data(entry.read()); std::puts(","); };
    entry.save(1, 31900, false, BOUND_LOWER, 12, Move(123), 7, 0); record();
    entry.save(1, 20, false, BOUND_LOWER, 1, Move::none(), 8, 0); record();
    entry.save(1, 20, false, BOUND_EXACT, -2, Move::none(), 8, 0); record();
    entry.save(2, -31900, false, BOUND_UPPER, 5, Move::none(), 9, 31); record();
    entry.save(2, 100, false, BOUND_UPPER, 0, Move(42), 10, 0); record();
    TTWriter writer(&entry); writer.penalize(300); record();
    std::puts("};");
}
