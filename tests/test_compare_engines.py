"""Benchmark UCI deadlines without a real engine or NNUE weights."""
import queue
import unittest
from unittest.mock import patch

from scripts.compare_engines import Engine


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


if __name__ == "__main__":
    unittest.main()
