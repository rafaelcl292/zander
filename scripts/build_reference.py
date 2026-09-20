#!/usr/bin/env python3
"""Build the pinned scalar Stockfish outside the submodule working tree."""
import argparse
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "artifacts/stockfish-reference")
    parser.add_argument("--cxx", default="c++")
    args = parser.parse_args()
    source = ROOT / "vendor/stockfish/src"
    makefile = (source / "Makefile").read_text().replace("\\\n", " ")
    match = re.search(r"^SRCS\s*=\s*(.*)$", makefile, re.MULTILINE)
    if match is None:
        raise ValueError("Could not find SRCS in the pinned Stockfish Makefile")
    sources = match.group(1).split()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [args.cxx, "-std=c++17", "-O3", "-DNDEBUG", "-DIS_64BIT",
               "-DNNUE_EMBEDDING_OFF", "-pthread", *map(str, (source / name for name in sources)),
               "-o", str(output)]
    subprocess.run(command, cwd=output.parent, check=True)
    print(output)


if __name__ == "__main__":
    main()
