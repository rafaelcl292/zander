#!/usr/bin/env python3
"""Exercise UCI through real pipes, including concurrent control commands."""
import argparse
import os
import queue
import re
import subprocess
import threading
import tempfile
import pathlib
import struct
import time


class Client:
    def __init__(self, executable):
        self.process = subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, bufsize=1)
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self.stdin = self.process.stdin
        self.stdout = self.process.stdout
        self.stderr = self.process.stderr
        self.lines: queue.Queue[str | None] = queue.Queue()
        self.errors: list[str] = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=lambda: self.errors.extend(self.stderr.readlines()), daemon=True).start()

    def _read(self):
        for line in self.stdout:
            self.lines.put(line.rstrip())
        self.lines.put(None)

    def send(self, command):
        self.stdin.write(command + "\n")
        self.stdin.flush()

    def until(self, prefix, timeout=60):
        result = []
        deadline = time.monotonic() + timeout
        while True:
            try:
                line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                raise AssertionError(f"Timeout awaiting {prefix}: {result}; stderr={self.errors}")
            assert line is not None, (prefix, result, self.errors, self.process.poll())
            result.append(line)
            if line.startswith(prefix):
                return result
            assert time.monotonic() < deadline, (prefix, result)

    def quiet_bestmove(self, seconds=0.1):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                line = self.lines.get(timeout=max(0.001, deadline - time.monotonic()))
            except queue.Empty:
                return
            assert line is not None and not line.startswith("bestmove"), line

    def search(self, command):
        self.send(command)
        lines = self.until("bestmove")
        assert not any("info string error" in line for line in lines), lines
        assert re.fullmatch(r"bestmove (?:[a-h][1-8][a-h][1-8][nbrq]?|0000)(?: ponder [a-h][1-8][a-h][1-8][nbrq]?)?", lines[-1]), lines
        return lines

    def close(self):
        if self.process.poll() is None:
            self.send("quit")
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                raise
        assert self.process.returncode == 0, self.errors
        assert not self.errors, self.errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("network")
    parser.add_argument("--tablebases")
    args = parser.parse_args()
    client = Client(args.executable)
    try:
        client.send("uci")
        handshake = client.until("uciok")
        for option in ("Hash", "MultiPV", "Ponder", "UCI_Chess960", "UCI_ShowWDL", "EvalFile", "Skill Level", "UCI_LimitStrength", "UCI_Elo", "nodestime"):
            assert any(line.startswith(f"option name {option} ") for line in handshake), handshake
        client.send("position fen 7k/7P/6K1/8/3B4/8/8/8 b - -")
        client.send("go perft 1")
        assert client.until("Nodes searched:")[-1] == "Nodes searched: 0"
        client.send("position startpos")
        client.send("go perft 3")
        divided = client.until("Nodes searched:")
        assert divided[-1] == "Nodes searched: 8902", divided
        counts = {line.split(": ")[0]: int(line.split(": ")[1]) for line in divided if re.match(r"^[a-h][1-8][a-h][1-8]: ", line)}
        assert len(counts) == 20 and sum(counts.values()) == 8902, counts
        assert counts["e2e4"] == 600 and counts["g1f3"] == 440, counts
        client.send("go perft 1")
        assert client.until("Nodes searched:")[-1] == "Nodes searched: 20"
        client.send("setoption name UCI_Chess960 value true")
        client.send("position fen r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        client.send("go perft 1")
        castle_moves = client.until("Nodes searched:")
        assert "e1h1: 1" in castle_moves and "e1a1: 1" in castle_moves, castle_moves
        client.send("setoption name UCI_Chess960 value false")
        client.send("position startpos")
        client.send("isready")
        assert all(line in ("", "readyok") for line in client.until("readyok"))
        client.send(f"setoption name EvalFile value {args.network}")
        client.send("compiler")
        assert any("Zig " in line for line in client.until("NNUE backend:"))
        client.send("d")
        assert "Fen: rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" in client.until("Checkers:")
        client.send("flip")
        client.send("d")
        assert "Fen: rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1" in client.until("Checkers:")
        client.send("flip")
        client.send("eval")
        trace = client.until("Final evaluation")
        assert sum(bool(re.match(r"^\|  [0-7] ", line)) for line in trace) == 8, trace
        assert sum("this bucket is used" in line for line in trace) == 1, trace
        with tempfile.TemporaryDirectory(prefix="zander-export-") as directory:
            exported = pathlib.Path(directory) / "export.nnue"
            client.send(f"export_net {exported}")
            client.until("info string Network saved", timeout=120)
            original = pathlib.Path(args.network).read_bytes()
            saved = exported.read_bytes()
            original_offset = 12 + struct.unpack_from("<I", original, 8)[0]
            saved_offset = 12 + struct.unpack_from("<I", saved, 8)[0]
            assert original[:8] == saved[:8]
            assert original[original_offset:] == saved[saved_offset:], "Export changed network weights"
            client.send(f"setoption name EvalFile value {exported}")
            client.send("isready")
            assert client.until("readyok") == ["readyok"]
        # The source is gone: the engine must continue using its owned weights.

        client.send("bench 1 1 3 current perft")
        assert "Nodes searched  : 8902" in client.until("Nodes/second")
        client.send("bench 1 1 2 current depth")
        assert any(line.startswith("bestmove ") for line in client.until("Nodes/second"))
        client.send("ucinewgame")
        client.send("setoption name Hash value 1")
        if hasattr(os, "sched_getaffinity"):
            cpus = sorted(os.sched_getaffinity(0))
            domains = str(cpus[0]) + (":" + ",".join(str(cpu) for cpu in cpus[1:3]) if len(cpus) > 1 else "")
            client.send(f"setoption name NumaPolicy value {domains}")
            client.send("position startpos")
            assert client.search("go depth 2")[-1].startswith("bestmove ")
            client.send(f"setoption name NumaPolicy value {cpus[0]}:{cpus[0]}")
            client.send("isready")
            assert any("DuplicateCpu" in line for line in client.until("readyok"))
            assert client.search("go depth 2")[-1].startswith("bestmove ")
        for policy in ("system", "none", "auto"):
            client.send(f"setoption name NumaPolicy value {policy}")
        for policy in ("small", "transparent", "huge2m", "auto"):
            client.send(f"setoption name PagePolicy value {policy}")
        client.send("setoption name MultiPV value 3")
        client.send("setoption name UCI_ShowWDL value true")
        client.send("isready")
        assert client.until("readyok") == ["readyok"]
        client.send("position startpos")
        lines = client.search("go depth 4")
        assert lines[-1].startswith("bestmove d2d4"), lines
        assert any("nodes 1475 " in line for line in lines), lines
        assert any("multipv 3 " in line and " wdl " in line for line in lines), lines
        for line in lines:
            if " wdl " in line:
                assert sum(map(int, line.split(" wdl ")[1].split()[:3])) == 1000, line
        for reset in ("setoption name Clear Hash", "setoption name Threads value 1"):
            client.send(reset)
            lines = client.search("go depth 4")
            assert any("nodes 1475 " in line for line in lines), lines
        client.send("position startpos moves e2e5")
        assert "IllegalMove" in client.until("info string error")[-1]
        lines = client.search("go depth 3 searchmoves e2e4")
        assert lines[-1].startswith("bestmove e2e4"), lines
        client.send("setoption name MultiPV value 1")
        for option in ("Skill Level value 0", "Skill Level value 19",
                       "UCI_LimitStrength value true", "UCI_Elo value 3190"):
            client.send("setoption name " + option)
            client.search("go depth 2")
        client.send("setoption name Skill Level value 20")
        client.send("setoption name UCI_LimitStrength value false")
        client.send("setoption name nodestime value 10")
        client.send("ucinewgame")
        lines = client.search("go movetime 100")
        nodes = int(re.findall(r" nodes (\d+)", "\n".join(lines))[-1])
        assert 1000 <= nodes < 3000, lines
        client.search("go wtime 1000 btime 1000 winc 10 binc 10")
        client.send("setoption name nodestime value 0")
        client.send("position startpos moves e2e4 e7e5 g1f3 b8c6")
        client.search("go nodes 64")
        for command in ("go movetime 40", "go wtime 100 btime 100 winc 0 binc 0", "go wtime 100 btime 200 movestogo 1"):
            start = time.monotonic()
            client.search(command)
            assert time.monotonic() - start < 5, command
        client.send("go infinite depth 1")
        client.until("info depth 1")
        client.quiet_bestmove()
        client.send("isready")
        assert not any(line.startswith("bestmove") for line in client.until("readyok"))
        client.send("stop")
        client.until("bestmove", 5)
        client.send("stop")
        client.quiet_bestmove()
        client.send("go ponder depth 2")
        client.until("info depth 2")
        client.quiet_bestmove()
        client.send("ponderhit")
        client.until("bestmove", 5)
        client.send("go ponder movetime 30")
        client.quiet_bestmove(0.15)
        client.send("ponderhit")
        client.until("bestmove", 5)
        for _ in range(3):
            client.send("go infinite")
            client.send("stop")
            client.until("bestmove", 5)
            client.quiet_bestmove(0.03)
        client.send("setoption name EvalFile value tests/positions.txt")
        client.until("info string error")
        client.search("go depth 2")
        client.send("ucinewgame")
        client.send("setoption name Hash value 2")
        client.send("setoption name Clear Hash")
        client.send("setoption name UCI_Chess960 value true")
        client.send("position fen 4k3/8/8/8/8/8/8/RK5R w AH - 0 1")
        lines = client.search("go depth 2 searchmoves b1h1")
        assert lines[-1].startswith("bestmove b1h1"), lines
        client.send("setoption name UCI_Chess960 value false")
        client.send("position fen 4k3/P7/8/8/8/8/8/4K3 w - - 0 1")
        assert client.search("go depth 2 searchmoves a7a8q")[-1].startswith("bestmove a7a8q")
        client.send("position fen 7k/8/5KQ1/8/8/8/8/8 w - - 0 1")
        lines = client.search("go mate 1")
        assert any("score mate 1 " in line for line in lines), lines
        for fen, score in (("7k/6Q1/5K2/8/8/8/8/8 b - - 100 70", "mate 0"),
                           ("7k/5Q2/5K2/8/8/8/8/8 b - - 100 70", "cp 0")):
            client.send("position fen " + fen)
            lines = client.search("go depth 3")
            assert lines[-1] == "bestmove 0000", lines
            assert any(f"score {score}" in line for line in lines), lines
            assert client.search("go infinite")[-1] == "bestmove 0000"
            assert client.search("go ponder depth 1")[-1] == "bestmove 0000"
        for command in ("setoption name Hash value 0", "setoption name MultiPV value 257", "setoption name Ponder value maybe"):
            client.send(command)
            client.until("info string error")
        client.send("go depth nope")
        lines = client.until("bestmove")
        assert any("info string error" in line for line in lines), lines
        client.send("position startpos")
        client.send("go infinite")
        client.send("setoption name Hash value 1")
        client.until("bestmove", 5)
        client.send("isready")
        client.until("readyok")
        client.search("go depth 2")
        client.send("setoption name UCI_Chess960 value false")
        client.send("position startpos")
        for threads in (2, 3, 1, 2):
            client.send(f"setoption name Threads value {threads}")
            client.send("isready")
            client.until("readyok")
            client.search("go depth 4")
            client.search("go nodes 4096")
            client.send("go infinite")
            client.until("info depth 1")
            client.send("isready")
            client.until("readyok")
            client.send("stop")
            client.until("bestmove", 5)
            client.send("go ponder depth 2")
            client.until("info depth 2")
            client.quiet_bestmove()
            client.send("ponderhit")
            client.until("bestmove", 5)
        client.send("setoption name Threads value 1")
        client.send("setoption name MultiPV value 3")
        lines = client.search("go depth 4")
        assert any("nodes 1475 " in line for line in lines), lines
        if args.tablebases:
            client.send(f"setoption name SyzygyPath value {args.tablebases}")
            client.send("setoption name MultiPV value 1")
            fen = "8/8/8/7Q/8/4K3/8/4k3 w - - 0 1"
            client.send("position fen " + fen)
            lines = client.search("go depth 4")
            assert any(re.search(r"tbhits [1-9]", line) for line in lines), lines
            pv = [line.split(" pv ")[1] for line in lines if " pv " in line][-1]
            client.send("position fen " + fen + " moves " + pv)
            assert client.search("go depth 1")[-1] == "bestmove 0000"
            client.send("position fen " + fen)
            client.send("setoption name Threads value 2")
            client.search("go depth 4")
            client.send("setoption name Syzygy50MoveRule value false")
            client.search("go depth 4")
            client.send("setoption name SyzygyProbeLimit value 0")
            client.send("ucinewgame")
            lines = client.search("go depth 2")
            assert not any(re.search(r"tbhits [1-9]", line) for line in lines), lines
            client.send("setoption name SyzygyProbeLimit value 7")
            client.send("setoption name SyzygyProbeDepth value 100")
            client.send("setoption name SyzygyPath value tests/positions.txt")
            client.until("info string error")
            lines = client.search("go depth 2")
            assert any(re.search(r"tbhits [1-9]", line) for line in lines), lines
            client.send("setoption name SyzygyPath value <empty>")
            client.search("go depth 2")
            client.send("position startpos")
        client.send("x" * 70000)
        client.until("info string error")
        client.send("isready")
        client.until("readyok")
        client.send("go infinite")  # Quit also interrupts and joins a live worker.
    finally:
        client.close()
    eof_client = Client(args.executable)
    try:
        eof_client.send(f"setoption name EvalFile value {args.network}")
        eof_client.send("isready")
        eof_client.until("readyok")
        eof_client.send("go infinite")
        eof_client.stdin.close()
        eof_client.process.wait(timeout=10)
    finally:
        eof_client.close()
    print("UCI integration passed: clocks, nodes, stop, ponder, state, options, Chess960, and terminal positions.")


if __name__ == "__main__":
    main()
