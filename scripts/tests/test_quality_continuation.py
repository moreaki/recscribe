"""No-retry continuation baseline prerequisites, without audio or inference."""
import copy
import importlib.util
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "benchmarks/quantized-quality/continue-after-build-v1.py"
SPEC = importlib.util.spec_from_file_location("quality_continuation", SOURCE)
continuation = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(continuation)


def fixture():
    cases = [dict(id="a", sha256="audio-a", reference_sha256="reference-a"), dict(id="b", sha256="audio-b", reference_sha256="reference-b")]
    models = ["tiny", "base", "small", "large-v3-turbo", "large-v3"]
    rows = [dict(model=model, id=c["id"], language_mode=mode, repeat=1, path="final", status="completed_with_review",
                 source_sha256=c["sha256"], reference_sha256=c["reference_sha256"], measurement=dict(reference_characters=1,
                    scoring_version="swift-nfc-casefold-alphanumeric-v1")) for model in models for c in cases for mode in ("known", "auto")]
    return cases, rows, models


class QualityContinuationTests(unittest.TestCase):
    def test_every_original_baseline_is_required_while_candidate_partial_results_stay_missing(self):
        cases, rows, models = fixture(); snapshot = copy.deepcopy(rows)
        rows.append(dict(model="large-v3-turbo-q5_1", status="cancelled"))
        self.assertEqual(continuation.validate_baselines(cases, rows, models), 20)
        self.assertEqual(rows[:-1], snapshot)
        rows[0]["status"] = "cancelled"
        with self.assertRaises(ValueError): continuation.validate_baselines(cases, rows, models)

    def test_missing_duplicate_changed_reference_or_scorer_cannot_release_heldout(self):
        for change in ("missing", "duplicate", "reference", "scorer"):
            cases, rows, models = fixture()
            if change == "missing": rows.pop()
            elif change == "duplicate": rows.append(copy.deepcopy(rows[0]))
            elif change == "reference": rows[0]["reference_sha256"] = "changed"
            else: rows[0]["measurement"]["scoring_version"] = "different"
            with self.subTest(change=change), self.assertRaises(ValueError):
                continuation.validate_baselines(cases, rows, models)
