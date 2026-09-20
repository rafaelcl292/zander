#!/usr/bin/env python3
"""Generate deterministic endgames; the C++ oracle rejects illegal positions."""
import json
import pathlib
import random
rng = random.Random(0x53595A595759)
manifest = json.loads((pathlib.Path(__file__).with_name("syzygy_manifest.json")).read_text())
for entry in manifest["files"]:
    if not entry["name"].endswith(".rtbw"):
        continue
    white, black = entry["name"][:-5].split("v")
    for sample in range(120):
        board = [""] * 64
        for piece in white + black.lower():
            while True:
                square = rng.randrange(8, 56) if piece.lower() == "p" else rng.randrange(64)
                if not board[square]:
                    board[square] = piece
                    break
        rows = []
        for rank in range(7, -1, -1):
            row, empty = "", 0
            for piece in board[rank * 8:rank * 8 + 8]:
                if piece:
                    if empty:
                        row += str(empty)
                    row += piece
                    empty = 0
                else:
                    empty += 1
            rows.append(row + (str(empty) if empty else ""))
        print("/".join(rows), rng.choice(("w", "b")), "- -", (0, 80, 99)[sample % 3], 1)
# En passant and zeroing captures, including color reversal.
print("8/8/8/3pP3/8/4k3/8/4K3 w - d6 0 1")
print("4k3/8/4K3/8/3Pp3/8/8/8 b - d3 0 1")
