"""Preparation gates use synthetic metadata; no media, inference or approvals."""
import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("evidence", Path(__file__).resolve().parents[1] / "quality/evaluation-evidence.py")
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


class PreparationEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.models = [{"id": "small", "sha256": "a" * 64},
            {"id": "small-q4", "sha256": "b" * 64, "kind": "compression",
             "baseline_model_id": "small", "baseline_model_sha256": "a" * 64}]
        self.policy = {"schema_version": "1.0", "minimum_reduction_percent": 30,
            "comparisons": [{"id": "small-size", "baseline_model_id": "small", "candidate_model_id": "small-q4", "purpose": "same_model_compression"}]}

    def decide(self, candidate, baseline=100):
        rows = [{"model": m["id"], "model_sha256": m["sha256"], "artifact_metrics": {"model_file_bytes": value}}
                for m, value in zip(self.models, [baseline, candidate])]
        return evidence.model_size_decisions(self.policy, self.models, rows)["comparisons"][0]

    def test_exact_thirty_percent_boundary_and_one_byte_above(self):
        self.assertEqual(self.decide(70)["size_gate"], "pass")
        self.assertEqual(self.decide(71)["size_gate"], "fail")
        result = self.decide(30)
        self.assertEqual(result["reduction_percent"], 70)
        self.assertEqual(result["quality_gate"], "NOT_EVALUATED")
        self.assertEqual(result["latency_memory_gate"], "NOT_EVALUATED")
        self.assertEqual(result["promotion"], "NOT_AUTHORIZED_BY_SIZE_GATE")

    def test_missing_size_is_pending_and_zero_or_invalid_size_is_an_error(self):
        self.assertEqual(self.decide(None)["size_gate"], "pending")
        self.assertIsNone(self.decide(None)["reduction_percent"])
        for value in [0, -1, True, 70.0]:
            with self.assertRaises(ValueError):
                self.decide(value)

    def test_invalid_thresholds_fail_and_comparison_identity_is_explicit(self):
        for value in [0, 100, True, float("nan"), float("inf"), "30"]:
            self.policy["minimum_reduction_percent"] = value
            with self.assertRaises(ValueError):
                self.decide(50)
        self.policy["minimum_reduction_percent"] = 30
        self.models[1]["baseline_model_sha256"] = "c" * 64
        with self.assertRaisesRegex(ValueError, "unchanged parent"):
            self.decide(50)
        self.policy["comparisons"][0]["purpose"] = "cross_model_replacement"
        self.assertEqual(self.decide(98)["size_gate"], "fail")

    def test_unknown_model_hash_and_conflicting_observations_fail(self):
        rows = [{"model": "small", "model_sha256": "a" * 64, "artifact_metrics": {"model_file_bytes": 100}},
                {"model": "small", "model_sha256": "a" * 64, "artifact_metrics": {"model_file_bytes": 99}}]
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            evidence.model_size_decisions(self.policy, self.models, rows)
        self.models[0]["sha256"] = "not-a-hash"
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.decide(50)

    def test_compression_cannot_relabel_unchanged_or_recursively_derived_weights(self):
        self.models[0]["kind"] = "compression"
        with self.assertRaisesRegex(ValueError, "unchanged parent"):
            self.decide(50)
        self.models[0]["kind"] = "pretrained"
        self.models[1]["sha256"] = self.models[0]["sha256"]
        with self.assertRaisesRegex(ValueError, "unchanged parent"):
            self.decide(50)

    def test_unreviewed_unknown_groups_are_reported_without_reading_reference_text(self):
        corpus = {"schema_version": "2.0", "cases": [{"id": "swiss", "language": "de-CH",
            "task": "standard_rendering", "split": "development", "speaker_ids": [],
            "reviewed": False, "reference": "/not/read/reference.txt", "conditions": ["street_noise"],
            "variety": "ZH", "script": "Latn", "source_channel": 0}]}
        original = copy.deepcopy(corpus)
        report = evidence.corpus_preparation(corpus)
        self.assertEqual(corpus, original)
        cohort = report["cohorts"][0]
        self.assertEqual(cohort["missing_evidence_counts"]["human_review"], 1)
        self.assertEqual(cohort["missing_evidence_counts"]["speaker_ids"], 1)
        self.assertEqual(cohort["missing_evidence_counts"]["session_id"], 1)
        self.assertNotIn("source_channel", cohort["missing_evidence_counts"])
        self.assertEqual(cohort["declared_scripts"], ["Latn"])
        self.assertIn("NOT_ASSESSED", report["approval"])
        self.assertEqual(len(report["missing_priority_language_splits"]), 17)

    def test_optional_dialect_cases_do_not_fill_primary_swiss_rendering_coverage(self):
        corpus = {"cases": [{"language": "de-CH", "split": "development", "task": "dialect_transcription", "coverage_role": "optional"}]}
        result = evidence.corpus_preparation(corpus)
        self.assertIn({"language": "de-CH", "split": "development"}, result["missing_priority_language_splits"])

    def test_derived_views_do_not_fill_missing_primary_source_coverage(self):
        corpus = {"cases": [{"language": "fr", "split": "development", "task": "transcription", "parent_case_id": "original"}]}
        self.assertIn({"language": "fr", "split": "development"}, evidence.corpus_preparation(corpus)["missing_priority_language_splits"])


if __name__ == "__main__":
    unittest.main()
