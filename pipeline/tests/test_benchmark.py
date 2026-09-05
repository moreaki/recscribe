import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import wave

from recscribe.benchmark import accuracy, distance
from recscribe.storage import sha256


class BenchmarkTests(unittest.TestCase):
    def test_known_edit_counts(self):
        self.assertEqual(distance("kitten", "sitting"), 3)
        score = accuracy("Das ist ein Test", "Das war ein Test extra")
        self.assertEqual(score["word_errors"], 2)
        self.assertEqual(score["wer"], 0.5)

    def test_empty_reference_measures_false_speech(self):
        score = accuracy("", "Invented speech")
        self.assertIsNone(score["wer"])
        self.assertEqual(score["false_speech_words"], 2)

    def test_unicode_and_punctuation(self):
        self.assertEqual(accuracy("Grüezi!", "GRU\u0308EZI")["wer"], 0)

    def test_corpus_readiness_has_no_fake_scores(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "results"
            manifest = Path(__file__).resolve().parents[2] / "benchmarks/manifests/corpus.template.json"
            result = subprocess.run([sys.executable, "-m", "recscribe.benchmark", str(manifest),
                                     "--output", str(output), "--dry-run"], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads((output / "results.json").read_text())
            self.assertEqual(len(data["results"]), 5)
            self.assertTrue(all(r["status"] == "pending_corpus" and "wer" not in r for r in data["results"]))

    @unittest.skipUnless(sys.platform == "darwin", "macOS resource accounting")
    def test_measured_synthetic_silence_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root / "silence.wav"
            with wave.open(str(audio), "wb") as wav:
                wav.setparams((1, 2, 16000, 0, "NONE", ""))
                wav.writeframes(b"\x00\x00" * 1600)
            (root / "reference.txt").write_text("")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"cases": [{"id": "silence", "category": "noise",
                "audio": "silence.wav", "reference": "reference.txt", "language": "en",
                "license": "synthetic test", "sha256": sha256(audio)}]}))
            result = subprocess.run([sys.executable, "-m", "recscribe.benchmark", str(manifest),
                "--output", str(root / "results"), "--whisper-cli", sys.executable,
                "--model", str(root / "unused-model")], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads((root / "results/results.json").read_text())["results"][0]
            self.assertGreater(data["wall_seconds"], 0)
            self.assertGreater(data["peak_rss_bytes"], 0)
            self.assertEqual(data["false_speech_words"], 0)
            self.assertEqual(data["engine_passes"], [])


if __name__ == "__main__":
    unittest.main()
