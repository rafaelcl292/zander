"""Benchmark UCI deadlines and evidence without engine binaries or NNUE weights."""
import queue
import contextlib
import io
import pathlib
import tempfile
import unittest
from unittest.mock import patch

from scripts.compare_engines import Engine
from scripts import compare_engines


class EngineDeadlineTests(unittest.TestCase):
    def fake_engine(self, lines: list[str]) -> Engine:
        engine = Engine.__new__(Engine)
        engine.lines = queue.Queue()
        engine.errors = ["fake engine diagnostic"]
        for line in lines:
            engine.lines.put(line)
        return engine

    def test_busy_engine_times_out_with_output_still_queued(self):
        engine = self.fake_engine(["info depth 1", "info depth 2", "bestmove e2e4"])
        # Advance beyond the deadline while output remains available. The late
        # bestmove bounds this test even if deadline enforcement regresses.
        with patch("scripts.compare_engines.time.monotonic", side_effect=[0, 0.25, 1, 2]):
            with self.assertRaisesRegex(RuntimeError, "Timeout awaiting bestmove") as raised:
                engine.until("bestmove", timeout=1)
        self.assertIn("info depth 1", str(raised.exception))
        self.assertIn("fake engine diagnostic", str(raised.exception))
        self.assertEqual(engine.lines.get_nowait(), "info depth 2")

    def test_silent_engine_times_out(self):
        engine = self.fake_engine([])
        with self.assertRaisesRegex(RuntimeError, "Timeout awaiting bestmove"):
            engine.until("bestmove", timeout=0.01)

    def test_response_before_deadline_preserves_output(self):
        lines = ["info depth 1", "bestmove e2e4"]
        engine = self.fake_engine(lines)
        with patch("scripts.compare_engines.time.monotonic", side_effect=[0, 0.25, 0.5]):
            self.assertEqual(engine.until("bestmove", timeout=1), lines)


class SearchEvidenceTests(unittest.TestCase):
    def search(self, lines: list[str], limit: str = "depth 6"):
        engine = Engine.__new__(Engine)
        with patch.object(engine, "send"), patch.object(engine, "until", return_value=lines):
            return engine.search(limit)

    def test_incomplete_evidence_is_rejected(self):
        for info in (None, "info depth 6 nodes 10 pv e2e4",
                     "info depth 6 score cp 20 pv e2e4",
                     "info depth 6 score cp 20 nodes 10"):
            with self.subTest(info=info), self.assertRaisesRegex(RuntimeError, "Incomplete search evidence"):
                self.search(([info] if info else []) + ["bestmove e2e4"])

    def test_early_search_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "before requested depth 6"):
            self.search(["info depth 5 score cp 20 nodes 10 pv e2e4", "bestmove e2e4"])

    def test_complete_search_is_preserved(self):
        result = self.search(["info depth 6 score cp 20 nodes 10 pv e2e4 e7e5", "bestmove e2e4 ponder e7e5"])
        self.assertEqual({key: result[key] for key in ("move", "depth", "score", "nodes", "pv")},
                         {"move": "e2e4", "depth": 6, "score": "cp 20", "nodes": 10, "pv": "e2e4 e7e5"})

    def test_nodes_limited_game_search_is_accepted(self):
        result = self.search(["info depth 2 score cp 20 nodes 100 pv e2e4", "bestmove e2e4"], "nodes 100")
        self.assertEqual(result["depth"], 2)

    def test_bestmove_must_match_pv(self):
        with self.assertRaisesRegex(RuntimeError, "differs from principal variation"):
            self.search(["info depth 6 score cp 20 nodes 10 pv d2d4", "bestmove e2e4"])

    def test_terminal_positions_need_no_pv_or_requested_depth(self):
        for move in ("0000", "(none)"):
            for score in ("cp 0", "mate 0"):
                for nodes in ("", " nodes 0"):
                    with self.subTest(move=move, score=score, nodes=nodes):
                        result = self.search([f"info depth 0 score {score}{nodes}", f"bestmove {move}"])
                        self.assertEqual(result["move"], "0000")
                        self.assertEqual(result["pv"], "")
                        self.assertEqual(result["nodes"], 0)

    def test_inconsistent_terminal_response_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Inconsistent terminal"):
            self.search(["info depth 6 score cp 20 nodes 10 pv e2e4", "bestmove 0000"])

    def test_malformed_bestmove_is_rejected(self):
        for line in ("bestmove", "bestmove nonsense", "bestmove e2e4 garbage"):
            with self.subTest(line=line), self.assertRaisesRegex(RuntimeError, "Malformed bestmove"):
                self.search([line])

    def test_empty_corpus_is_rejected_before_starting_engines(self):
        with tempfile.TemporaryDirectory() as directory:
            positions = pathlib.Path(directory) / "positions.txt"
            for contents in ("", "\n # comment\n; comment\n"):
                positions.write_text(contents)
                args = ["compare_engines.py", "candidate", "reference", "--network", "network",
                        "--positions", str(positions), "--require-identical"]
                with self.subTest(contents=contents), patch("sys.argv", args), \
                     patch.object(compare_engines, "Engine") as engine, \
                     contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                    compare_engines.main()
                self.assertEqual(raised.exception.code, 2)
                engine.assert_not_called()


if __name__ == "__main__":
    unittest.main()
