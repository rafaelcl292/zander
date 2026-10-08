#!/usr/bin/env python3
"""Reproducible UCI benchmarks and paired games with a Stockfish legality referee."""
import argparse
import hashlib
import json
import pathlib
import platform
import queue
import re
import statistics
import subprocess
import threading
import time


class Engine:
    def __init__(self, executable, network, threads, hash_mb):
        self.executable = str(pathlib.Path(executable).resolve())
        self.process = subprocess.Popen([self.executable], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, bufsize=1)
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self.stdin = self.process.stdin
        self.stdout = self.process.stdout
        self.stderr = self.process.stderr
        self.lines: queue.Queue[str | None] = queue.Queue()
        self.errors: list[str] = []
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.error_reader = threading.Thread(target=lambda: self.errors.extend(self.stderr.readlines()), daemon=True)
        self.error_reader.start()
        try:
            self.send("uci")
            self.until("uciok")
            self.send(f"setoption name EvalFile value {pathlib.Path(network).resolve()}")
            self.send(f"setoption name Threads value {threads}")
            self.send(f"setoption name Hash value {hash_mb}")
            self.send("setoption name NumaPolicy value none")
            self.ready()
        except BaseException:
            self.close()
            raise

    def _read(self):
        for line in self.stdout:
            self.lines.put(line.strip())
        self.lines.put(None)

    def send(self, command):
        self.stdin.write(command + "\n")
        self.stdin.flush()

    def until(self, prefix, timeout=120):
        deadline = time.monotonic() + timeout
        result = []
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError(f"Timeout awaiting {prefix}: {result[-8:]}; {self.errors}")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty as error:
                raise RuntimeError(f"Timeout awaiting {prefix}: {result[-8:]}; {self.errors}") from error
            if line is None:
                raise RuntimeError(f"Engine exited: {self.executable}: {self.errors}")
            if line.startswith("info string error"):
                raise RuntimeError(line)
            result.append(line)
            if line.startswith(prefix):
                return result

    def ready(self):
        self.send("isready")
        self.until("readyok")

    def new_game(self):
        self.send("ucinewgame")
        self.ready()

    def position(self, fen, moves=()):
        self.send("position fen " + fen + (" moves " + " ".join(moves) if moves else ""))

    def search(self, limit):
        start = time.perf_counter_ns()
        self.send("go " + limit)
        lines = self.until("bestmove")
        elapsed = time.perf_counter_ns() - start
        infos = [line for line in lines if line.startswith("info depth ")]
        info = infos[-1] if infos else ""
        def field(pattern):
            match = re.search(pattern, info)
            return match.group(1) if match else None
        bestmove = re.fullmatch(r"bestmove ([a-h][1-8][a-h][1-8][nbrq]?|0000|\(none\))(?: ponder [a-h][1-8][a-h][1-8][nbrq]?)?", lines[-1])
        if bestmove is None:
            raise RuntimeError(f"Malformed bestmove response: {lines[-1]}")
        raw_move = bestmove.group(1)
        # Stockfish omits nodes and PV when there are no legal root moves.
        terminal = raw_move in ("0000", "(none)")
        nodes = field(r"\bnodes (\d+)\b")
        depth = field(r"\bdepth (\d+)\b")
        score = field(r"\bscore ((?:cp|mate) -?\d+)\b")
        pv = field(r"\bpv (.*)")
        if depth is None or score is None or (not terminal and (nodes is None or not pv)):
            raise RuntimeError(f"Incomplete search evidence: {lines[-8:]}")
        if terminal:
            if int(depth) != 0 or score not in ("cp 0", "mate 0") or pv:
                raise RuntimeError(f"Inconsistent terminal search evidence: {lines[-8:]}")
        else:
            assert pv is not None
            if pv.split()[0] != raw_move:
                raise RuntimeError(f"Bestmove differs from principal variation: {lines[-8:]}")
            requested_depth = re.fullmatch(r"depth (\d+)", limit)
            if requested_depth and int(depth) < int(requested_depth.group(1)):
                raise RuntimeError(f"Search stopped before requested {limit}: {info}")
        return {"move": "0000" if terminal else raw_move, "raw_move": raw_move,
                "nodes": int(nodes) if nodes is not None else 0, "depth": int(depth), "score": score,
                "pv": pv or "", "elapsed_ns": elapsed}

    def referee(self, fen, moves):
        self.position(fen, moves)
        self.send("go perft 1")
        lines = self.until("Nodes searched:")
        legal = {match.group(1) for line in lines
                 if (match := re.fullmatch(r"([a-h][1-8][a-h][1-8][nbrq]?): 1", line))}
        self.send("d")
        self.send("isready")
        board = self.until("readyok")
        current = next(line[5:] for line in board if line.startswith("Fen: "))
        checkers = next(line[len("Checkers:"):].strip() for line in board if line.startswith("Checkers:"))
        return current, legal, bool(checkers)

    def close(self):
        if self.process.poll() is None:
            try:
                self.send("quit")
                self.process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=1)
        self.error_reader.join(timeout=1)
        for stream in (self.stdin, self.stdout, self.stderr):
            try:
                stream.close()
            except OSError:
                # The process may have exited with buffered input still pending.
                pass


def digest(path):
    with open(path, "rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def peak_rss_bytes(engine):
    """Linux process high-water RSS through the benchmarks; unavailable elsewhere."""
    try:
        status = pathlib.Path(f"/proc/{engine.process.pid}/status").read_text()
    except OSError:
        return None
    match = re.search(r"^VmHWM:\s+(\d+) kB$", status, re.MULTILINE)
    return int(match.group(1)) * 1024 if match else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate")
    parser.add_argument("reference", help="Pinned Stockfish executable, also used as legality referee")
    parser.add_argument("--network", required=True)
    parser.add_argument("--tablebases", help="Optional Syzygy path for both engines")
    parser.add_argument("--positions", default="tests/benchmark_positions.txt")
    parser.add_argument("--depth", type=int, default=6)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--hash", type=int, default=16)
    parser.add_argument("--games", type=int, default=0, help="Even number of paired games")
    parser.add_argument("--game-nodes", type=int, default=10000)
    parser.add_argument("--max-plies", type=int, default=400)
    parser.add_argument("--require-identical", action="store_true")
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("artifacts/comparison.json"))
    args = parser.parse_args()
    if args.games < 0 or args.games % 2 or min(args.depth, args.repeats, args.threads, args.hash, args.game_nodes, args.max_plies) < 1:
        parser.error("Use positive limits and a nonnegative even game count")
    if args.require_identical and args.threads != 1:
        parser.error("Exact tree comparison requires one worker")
    positions = [line.split(";", 1)[0].strip() for line in pathlib.Path(args.positions).read_text().splitlines()]
    positions = [line for line in positions if line and not line.startswith("#")]
    if not positions:
        parser.error("Positions file must contain at least one position")
    # Corpus entries contain a Chess960 flag; ordinary FEN-only files also work.
    positions = [(line.startswith("1|"), line.split("|", 1)[-1].strip()) for line in positions]
    report = {"platform": platform.platform(), "network_sha256": digest(args.network),
              "positions_sha256": digest(args.positions),
              "executables": {"candidate": digest(args.candidate), "reference": digest(args.reference)},
              "configuration": {key: str(value) if isinstance(value, pathlib.Path) else value
                                for key, value in vars(args).items()}, "benchmarks": [], "games": []}
    clients = []
    try:
        for path in (args.candidate, args.reference):
            clients.append(Engine(path, args.network, args.threads, args.hash))
            if args.tablebases:
                clients[-1].send(f"setoption name SyzygyPath value {pathlib.Path(args.tablebases).resolve()}")
                clients[-1].ready()
        for chess960, fen in positions:
            samples = [[], []]
            # Alternate execution order to reduce systematic thermal/order bias.
            for repeat in range(args.repeats):
                for index in ((0, 1) if repeat % 2 == 0 else (1, 0)):
                    engine = clients[index]
                    engine.send(f"setoption name UCI_Chess960 value {str(chess960).lower()}")
                    engine.new_game()
                    engine.position(fen)
                    samples[index].append(engine.search(f"depth {args.depth}"))
            equivalent = all(all(sample[key] == samples[1][0][key] for key in ("move", "score", "pv", "nodes", "depth"))
                             for group in samples for sample in group)
            timing = [statistics.median(sample["elapsed_ns"] for sample in group) for group in samples]
            report["benchmarks"].append({"fen": fen, "chess960": chess960, "samples": samples, "identical": equivalent,
                                          "median_elapsed_ns": timing, "reference_over_candidate": timing[1] / timing[0]})
            print(f"Benchmark {len(report['benchmarks'])}/{len(positions)} identical={equivalent}", flush=True)
        report["benchmark_peak_rss_bytes"] = dict(zip(
            ("candidate", "reference"), (peak_rss_bytes(engine) for engine in clients), strict=True))
        if args.games:
            referee = Engine(args.reference, args.network, 1, 1)
            clients.append(referee)
            start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
            openings = [[], ["e2e4", "e7e5"], ["d2d4", "d7d5"], ["c2c4", "e7e5"],
                        ["g1f3", "d7d5"], ["e2e4", "c7c5"], ["d2d4", "g8f6"], ["e2e4", "e7e6"]]
            for game in range(args.games):
                for engine in clients[:2]:
                    engine.send("setoption name UCI_Chess960 value false")
                    engine.new_game()
                moves = list(openings[(game // 2) % len(openings)])
                opening_length = len(moves)
                candidate_white = game % 2 == 0
                repetitions = {}
                result, reason = "*", "ply limit"
                for _ in range(args.max_plies + 1):
                    fen, legal, check = referee.referee(start, moves)
                    identity = " ".join(fen.split()[:4])
                    repetitions[identity] = repetitions.get(identity, 0) + 1
                    white = fen.split()[1] == "w"
                    if not legal:
                        result, reason = (("0-1" if white else "1-0"), "checkmate") if check else ("1/2-1/2", "stalemate")
                        break
                    if repetitions[identity] >= 3 or int(fen.split()[4]) >= 100:
                        result, reason = "1/2-1/2", "repetition" if repetitions[identity] >= 3 else "fifty-move rule"
                        break
                    if len(moves) - opening_length >= args.max_plies:
                        break
                    index = 0 if white == candidate_white else 1
                    clients[index].position(start, moves)
                    move = clients[index].search(f"nodes {args.game_nodes}")["move"]
                    if move not in legal:
                        raise RuntimeError(f"Illegal move by engine {index}: {move}; {fen}")
                    moves.append(move)
                report["games"].append({"candidate_white": candidate_white, "opening_plies": opening_length,
                                          "moves": moves, "result": result, "reason": reason})
                print(f"Game {game + 1}/{args.games}: {result} ({reason})", flush=True)
        report["identical"] = all(case["identical"] for case in report["benchmarks"])
        # Ply-capped games remain unfinished, never counted as draws or Elo evidence.
        report["finished_games"] = sum(game["result"] != "*" for game in report["games"])
    finally:
        for engine in clients:
            engine.close()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    if args.require_identical and not report["identical"]:
        raise SystemExit("Search comparison differs; inspect the report")
    print(args.output)


if __name__ == "__main__":
    main()
