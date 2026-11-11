"""Offline synthetic-derivative contracts: scoped fixtures, no corpus/network/ASR."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import wave

MODULE = Path(__file__).resolve().parents[1] / "quality" / "derive-sensitivity.py"
SPEC = importlib.util.spec_from_file_location("quality_sensitivity", MODULE)
sensitivity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sensitivity)

SAMPLES = [-32768, -32767, -9, -8, -7, -1, 0, 1, 7, 8, 9, 32767]
PCM = struct.pack("<12h", *SAMPLES)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixture(root, *, channels=1, rate=16000, width=2):
    source = root / "sources"
    source.mkdir()
    audio = source / "original.wav"
    with wave.open(str(audio), "wb") as stream:
        stream.setnchannels(channels)
        stream.setsampwidth(width)
        stream.setframerate(rate)
        stream.writeframes(PCM)
    reference = source / "reference.txt"
    reference.write_bytes(b"Published human reference; untouched.\n")
    provenance = source / "provenance.json"
    provenance.write_text(json.dumps({"dataset_split": "train", "evaluation_split": "development", "license": "test-only"}))
    with wave.open(str(audio), "rb") as stream:
        duration = stream.getnframes() / stream.getframerate()
    case = {"id": "published-case", "category": "read-speech-pilot", "audio": str(audio), "reference": str(reference), "provenance": str(provenance),
            "sha256": digest(audio), "reference_sha256": digest(reference), "duration_seconds": duration,
            "split": "development", "source_id": "published:original-source", "source_channel": 0,
            "speaker_ids": [], "session_id": None, "source_url": "https://public.example/exact-release",
            "original_audio_sha256": "a" * 64, "language": "de-CH", "task": "standard_rendering",
            "variety": "published variety; not adjudicated", "script": "Latn", "license": "test-only",
            "conditions": ["read_speech"], "code_switches": [], "scoring_policy": "unicode-nfc-apostrophe-v2",
            "reviewed": False, "reference_conventions": "Original published text"}
    corpus = {"schema_version": "1.0", "corpus_version": "selected-test-v1", "frozen": False, "cases": [case], "errors": []}
    manifest = root / "selected.development.json"
    manifest.write_text(json.dumps(corpus))
    return manifest, corpus


def pcm(path):
    with wave.open(str(path), "rb") as stream:
        return stream.getnframes(), stream.readframes(stream.getnframes())


class QualitySensitivityTests(unittest.TestCase):
    def test_fixed_noise_is_reproducible_time_aligned_and_records_achieved_snr(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source.wav"
            data = struct.pack("<16000h", *([1000, -1000] * 8000))
            with wave.open(str(source), "wb") as stream:
                stream.setparams((1, 2, 16000, 16000, "NONE", "not compressed")); stream.writeframes(data)
            original = source.read_bytes()
            reports = [sensitivity.add_white_noise(source, root / (str(i) + ".wav"), snr_db=10, seed=42,
                budget=sensitivity.Budget()) for i in range(2)]
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(reports[0], reports[1])
            self.assertEqual((root / "0.wav").read_bytes(), (root / "1.wav").read_bytes())
            self.assertEqual(pcm(root / "0.wav")[0], 16000)
            self.assertNotEqual(pcm(root / "0.wav")[1], data)
            self.assertAlmostEqual(reports[0]["achieved_post_clipping_snr_db"], 10, delta=.2)
            self.assertEqual(reports[0]["clipped_samples"], 0)
            self.assertEqual(reports[0]["source_to_derived_offset_seconds"], 0)

    def test_noise_refuses_undefined_snr_invalid_parameters_and_budget_exhaustion(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source.wav"
            with wave.open(str(source), "wb") as stream:
                stream.setparams((1, 2, 16000, 16000, "NONE", "not compressed")); stream.writeframes(bytes(32000))
            for snr, seed in [(10, 42), (float("nan"), 42), (41, 42), (10, -1), (10, True)]:
                with self.assertRaises(ValueError):
                    sensitivity.add_white_noise(source, root / "never.wav", snr_db=snr, seed=seed, budget=sensitivity.Budget())
            self.assertFalse((root / "never.wav").exists())
            with wave.open(str(source), "wb") as stream:
                stream.setparams((1, 2, 16000, 16000, "NONE", "not compressed")); stream.writeframes(struct.pack("<16000h", *([32767] * 16000)))
            with self.assertRaises(ValueError):
                sensitivity.add_white_noise(source, root / "budget.wav", snr_db=10, seed=42, budget=sensitivity.Budget(maximum_bytes=1024))
            result = sensitivity.add_white_noise(source, root / "clipped.wav", snr_db=0, seed=42, budget=sensitivity.Budget())
            self.assertGreater(result["clipped_samples"], 0)
            self.assertEqual(pcm(root / "clipped.wav")[0], 16000)

    def test_exact_prefix_and_signed_gain_preserve_originals_and_grouping(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest, corpus = fixture(root)
            original = corpus["cases"][0]
            originals = {p: p.read_bytes() for p in [manifest, *list((root / "sources").iterdir())]}
            output = root / "protected-derived"
            result = sensitivity.prepare(manifest, output)
            self.assertEqual(result["unique_parent_cases"], 1)
            self.assertEqual(result["condition_instances"], 2)
            quiet, gain = result["cases"]
            frames, data = pcm(Path(quiet["audio"]))
            self.assertEqual(frames, 480000 + len(SAMPLES))
            self.assertEqual(data[:960000], bytes(960000))
            self.assertEqual(data[960000:], PCM)
            frames, data = pcm(Path(gain["audio"]))
            self.assertEqual(frames, len(SAMPLES))
            self.assertEqual(struct.unpack("<12h", data), (-4096, -4095, -1, -1, 0, 0, 0, 0, 0, 1, 1, 4095))
            self.assertEqual(quiet["source_timing"]["source_to_derived_offset_seconds"], 30)
            self.assertEqual(gain["source_timing"]["source_to_derived_offset_seconds"], 0)
            source_pcm_hash = hashlib.sha256(PCM).hexdigest()
            self.assertEqual(quiet["source_timing"]["source_pcm_sha256"], source_pcm_hash)
            self.assertEqual(quiet["source_timing"]["retained_source_suffix_pcm_sha256"], source_pcm_hash)
            for row in result["cases"]:
                self.assertEqual(row["parent_case_id"], original["id"])
                for field in ("source_id", "speaker_ids", "session_id", "source_channel", "task", "language", "license",
                              "source_url", "reference_sha256", "original_audio_sha256", "reference_conventions"):
                    self.assertEqual(row[field], original[field])
                self.assertNotIn("source_group_id", row)
                self.assertFalse(row["reviewed"])
                self.assertEqual(row["source_declared_scoring_policy"], original["scoring_policy"])
                self.assertEqual(row["scoring_policy"], "swift-nfc-casefold-alphanumeric-v1")
                self.assertEqual(row["evaluation_scoring_version"], "legacy-v1")
                self.assertEqual(Path(row["reference"]).read_bytes(), originals[Path(original["reference"])])
                self.assertEqual(digest(Path(row["audio"])), row["sha256"])
            for path, data in originals.items():
                self.assertEqual(path.read_bytes(), data)
            self.assertEqual((output / "source.manifest.original.json").read_bytes(), originals[manifest])
            pending = json.loads((output / "manifest.v2.pending.json").read_text())
            self.assertEqual(pending["schema_version"], "2.0")
            self.assertFalse(pending["frozen"])
            self.assertTrue(all(not row["reviewed"] for row in pending["cases"]))
            self.assertTrue(all(row["domain"] is None for row in pending["cases"]))
            self.assertFalse(json.loads((output / "COMPLETED.json").read_text())["asr_executed"])

    def test_existing_output_and_files_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest, _ = fixture(root)
            output = root / "existing"
            output.mkdir()
            retained = output / "retained.txt"
            retained.write_bytes(b"keep exact bytes")
            with self.assertRaises(FileExistsError):
                sensitivity.prepare(manifest, output)
            self.assertEqual(retained.read_bytes(), b"keep exact bytes")
            with self.assertRaises(FileExistsError):
                sensitivity.save(retained, b"replace", sensitivity.Budget())
            self.assertEqual(retained.read_bytes(), b"keep exact bytes")

    def test_heldout_case_is_rejected_before_audio_or_reference_reads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest, corpus = fixture(root)
            other = copy.deepcopy(corpus["cases"][0])
            other.update(id="other-case", split="held_out")
            corpus["cases"].append(other)
            manifest.write_text(json.dumps(corpus))
            real_open = sensitivity.open_regular
            def only_manifest(path):
                self.assertEqual(path, manifest)
                return real_open(path)
            with patch.object(sensitivity, "open_regular", side_effect=only_manifest):
                with self.assertRaisesRegex(ValueError, "Held-out"):
                    sensitivity.prepare(manifest, root / "output")
            self.assertFalse((root / "output").exists())

    def test_heldout_paths_and_provenance_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest, corpus = fixture(root)
            with self.assertRaisesRegex(ValueError, "Held-out"):
                sensitivity.prepare(manifest, root / "held_out" / "output")
            Path(corpus["cases"][0]["provenance"]).write_text('{"dataset_split":"private"}')
            with self.assertRaisesRegex(ValueError, "Held-out"):
                sensitivity.prepare(manifest, root / "output")
            self.assertFalse((root / "output").exists())

    def test_symlinks_and_traversal_cannot_escape_or_alias_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest, corpus = fixture(root)
            alias = root / "alias"
            alias.symlink_to(root / "sources", target_is_directory=True)
            corpus["cases"][0]["audio"] = str(alias / "original.wav")
            manifest.write_text(json.dumps(corpus))
            with self.assertRaisesRegex(ValueError, "Symlink"):
                sensitivity.prepare(manifest, root / "output")
            with self.assertRaisesRegex(ValueError, "traversal"):
                sensitivity.safe_path(root / "sources" / ".." / "escape")
            corpus["cases"][0]["id"] = "../escape"
            manifest.write_text(json.dumps(corpus))
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                sensitivity.prepare(manifest, root / "output")

    def test_wrong_audio_format_is_rejected_before_output_creation(self):
        for settings in ({"channels": 2}, {"rate": 8000}, {"width": 1}):
            with self.subTest(settings=settings), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                manifest, _ = fixture(root, **settings)
                with self.assertRaisesRegex(ValueError, "mono 16 kHz"):
                    sensitivity.prepare(manifest, root / "output")
                self.assertFalse((root / "output").exists())

    def test_hash_and_duration_mismatches_are_not_repaired(self):
        for field, value, message in (("sha256", "0" * 64, "hash mismatch"),
                                      ("reference_sha256", "0" * 64, "hash mismatch"),
                                      ("duration_seconds", 1, "duration does not match")):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                manifest, corpus = fixture(root)
                corpus["cases"][0][field] = value
                manifest.write_text(json.dumps(corpus))
                before = manifest.read_bytes()
                with self.assertRaisesRegex(ValueError, message):
                    sensitivity.prepare(manifest, root / "output")
                self.assertEqual(manifest.read_bytes(), before)
                self.assertFalse((root / "output").exists())

    def test_case_duration_output_and_time_budgets_are_enforced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest, corpus = fixture(root)
            with self.assertRaisesRegex(ValueError, "duration"):
                sensitivity.prepare(manifest, root / "duration", maximum_seconds=0.0001)
            duplicate = copy.deepcopy(corpus["cases"][0])
            duplicate["id"] = "another-case"
            corpus["cases"].append(duplicate)
            manifest.write_text(json.dumps(corpus))
            with self.assertRaisesRegex(ValueError, "case bound"):
                sensitivity.prepare(manifest, root / "cases", maximum_cases=1)
            with self.assertRaisesRegex(ValueError, "byte budget"):
                sensitivity.prepare(manifest, root / "bytes", maximum_bytes=1024)
            self.assertLessEqual(sum(p.stat().st_size for p in (root / "bytes").rglob("*") if p.is_file()), 1024)
            self.assertFalse((root / "bytes" / "COMPLETED.json").exists())
            with patch.object(sensitivity.time, "monotonic", side_effect=[0, 2]):
                with self.assertRaises(TimeoutError):
                    sensitivity.prepare(manifest, root / "time", seconds=1)
            self.assertFalse((root / "time").exists())

    def test_cancellation_keeps_partial_evidence_and_sources_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest, corpus = fixture(root)
            original = Path(corpus["cases"][0]["audio"])
            before = original.read_bytes()
            output = root / "canceled"
            target = output / "published-case" / (sensitivity.CONDITIONS[0] + ".wav")
            def cancel_during_transform():
                if target.exists():
                    raise InterruptedError("fixture cancellation")
            with self.assertRaises(InterruptedError):
                sensitivity.prepare(manifest, output, check=cancel_during_transform)
            self.assertEqual(original.read_bytes(), before)
            self.assertTrue((output / "source.manifest.original.json").exists())
            self.assertTrue((output / "FAILED.json").exists())
            self.assertFalse((output / "COMPLETED.json").exists())
            self.assertFalse((output / "manifest.exploratory.legacy.json").exists())
            flag = root / "cancel.request"
            flag.touch()
            with self.assertRaises(InterruptedError):
                sensitivity.prepare(manifest, root / "pre-canceled", cancel=flag)
            self.assertFalse((root / "pre-canceled").exists())

    def test_source_changes_during_derivation_fail_final_hash_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest, corpus = fixture(root)
            reference = Path(corpus["cases"][0]["reference"])
            real_transform = sensitivity.transform
            def changed_source(*args, **kwargs):
                result = real_transform(*args, **kwargs)
                reference.write_bytes(b"x" * reference.stat().st_size)
                return result
            with patch.object(sensitivity, "transform", side_effect=changed_source):
                with self.assertRaisesRegex(ValueError, "Source changed"):
                    sensitivity.prepare(manifest, root / "output")
            self.assertFalse((root / "output" / "COMPLETED.json").exists())
            self.assertTrue((root / "output" / "FAILED.json").exists())

    def test_truncated_declared_pcm_frames_do_not_produce_complete_manifests(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest, corpus = fixture(root)
            audio = Path(corpus["cases"][0]["audio"])
            audio.write_bytes(audio.read_bytes()[:-2])
            corpus["cases"][0]["sha256"] = digest(audio)
            manifest.write_text(json.dumps(corpus))
            with self.assertRaisesRegex(ValueError, "Truncated"):
                sensitivity.prepare(manifest, root / "output")
            self.assertFalse((root / "output" / "manifest.exploratory.legacy.json").exists())
            self.assertTrue((root / "output" / "FAILED.json").exists())


if __name__ == "__main__":
    unittest.main()
