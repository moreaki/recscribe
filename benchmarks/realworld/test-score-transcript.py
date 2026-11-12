#!/usr/bin/env python3
"""Run actual compiled standalone scorer contracts; no model/audio/GPU required.

Usage through work-artifacts.py: python3 this-file.py /absolute/score-transcript
Compilation is separate and must occur after competing acquisition guards finish.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCORER = None


class CompiledScorerTests(unittest.TestCase):
    def setUp(self):
        if SCORER is None or not SCORER.is_file():
            raise RuntimeError("Supply the actual compiled scorer; unexecuted checks are not passes")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def run_case(self, reference=b"ONE two", hypothesis=b"one TWO", language="en", extra=None):
        ref, hyp = self.root / "reference.txt", self.root / "hypothesis.txt"
        ref.write_bytes(reference); hyp.write_bytes(hypothesis)
        self.original = reference, hypothesis
        command = [str(SCORER), "--reference", str(ref), "--reference-sha256", hashlib.sha256(reference).hexdigest(),
                   "--hypothesis", str(hyp), "--hypothesis-sha256", hashlib.sha256(hypothesis).hexdigest(),
                   "--language", language, "--output", str(self.root / "result")]
        if extra:
            for key, value in extra.items():
                if key in command:
                    command[command.index(key) + 1] = str(value)
                else:
                    command += [key, str(value)]
        return subprocess.run(command, capture_output=True, text=True, timeout=10)

    def test_unchanged_native_v1_normalization_counts_and_input_snapshots(self):
        result = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        score = json.loads(result.stdout)
        self.assertEqual(score["scoring_version"], "swift-nfc-casefold-alphanumeric-v1")
        self.assertEqual(score["word_errors"], 0); self.assertEqual(score["reference_words"], 2)
        self.assertEqual(score["character_errors"], 0); self.assertEqual(score["reference_characters"], 6)
        self.assertFalse(score["quality_approval"])
        self.assertEqual((self.root / "result/reference.original.txt").read_bytes(), self.original[0])
        self.assertEqual((self.root / "result/hypothesis.original.txt").read_bytes(), self.original[1])

    def test_chinese_keeps_v1_cer_and_suppresses_unsegmented_word_metrics(self):
        result = self.run_case("你好世界".encode(), "你好世".encode(), "zh")
        self.assertEqual(result.returncode, 0, result.stderr)
        score = json.loads(result.stdout)
        self.assertEqual(score["scoring_version"], "swift-nfc-casefold-alphanumeric-v1")
        self.assertEqual(score["character_errors"], 1); self.assertEqual(score["reference_characters"], 4)
        self.assertEqual(score["cer"], .25)
        for key in ("wer", "reference_words", "word_errors", "word_insertions", "word_deletions", "word_substitutions"):
            self.assertIsNone(score[key])

    def test_changed_hash_invalid_utf8_and_alignment_budget_remain_failed(self):
        cases = [(b"a", b"a", {"--reference-sha256": "0" * 64}), (b"\xff", b"a", {}),
                 (b"a" * 10001, b"b" * 10001, {})]
        for index, (reference, hypothesis, extra) in enumerate(cases):
            extra = dict(extra, **{"--output": str(self.root / ("failed-" + str(index)))})
            result = self.run_case(reference, hypothesis, extra=extra)
            with self.subTest(index=index):
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / ("failed-" + str(index)) / "score.json").exists())
                self.assertTrue((self.root / ("failed-" + str(index)) / "failure.json").is_file())

    def test_text_bound_cancellation_and_existing_output_never_get_scores(self):
        result = self.run_case(b"a" * (1048576 + 1), b"a")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "result/score.json").exists())
        marker = self.root / "cancel.request"; marker.touch()
        result = self.run_case(extra={"--cancel-marker": marker, "--output": self.root / "cancelled"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "cancelled/score.json").exists())
        preserved = self.root / "existing";preserved.mkdir();(preserved / "sentinel").write_bytes(b"retain")
        result = self.run_case(extra={"--output": preserved})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((preserved / "sentinel").read_bytes(), b"retain")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scorer", type=Path)
    args = parser.parse_args()
    SCORER = args.scorer.resolve(strict=True)
    unittest.main(argv=[__file__])
