"""Offline report contracts; never load a recognizer/model or real corpus text."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "quality" / "report-pilot.py"
SPEC = importlib.util.spec_from_file_location("quality_report", MODULE)
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)


def cell(identifier="a", repeat=1, status="completed", language="de", model="tiny", mode="auto", **overrides):
    value = {"id": identifier, "repeat": repeat, "status": status, "language": language, "model": model,
        "model_sha256": model + "-hash", "profile": "control", "language_mode": mode, "path": "final",
        "task": "transcription", "scoring_policy": "legacy-v1", "runtime_settings_sha256": "runtime",
        "source_sha256": identifier + "-audio", "reference_sha256": identifier + "-reference", "source_channel": 0,
        "evidence_directory": "cell-" + identifier + "-" + str(repeat),
        "artifact_metrics": {"model_file_bytes": 100, "download_artifact_bytes": 80, "filesystem_allocated_bytes": 128},
        "measurement": {"status": "completed", "wer": 0.1, "cer": 0.1,
            "word_errors": 1, "reference_words": 10, "character_errors": 2, "reference_characters": 20,
            "word_insertions": 0, "word_deletions": 0, "word_substitutions": 1,
            "character_insertions": 0, "character_deletions": 0, "character_substitutions": 2,
            "wall_seconds": 2, "source_audio_seconds": 4, "peak_rss_bytes": 200,
            "hypothesis_sha256": "same", "scoring_version": "legacy-v1"}}
    value.update(overrides)
    return value


def matrix(rows):
    return {"schema_version": "1.0", "split": "development", "rows": rows, "host": {"os": "Test OS", "cpu_count": 4}}


class QualityReportTests(unittest.TestCase):
    def test_quality_uses_repeat_one_without_pseudoreplication(self):
        rows = [cell(identifier, repeat) for identifier in ["a", "b", "c"] for repeat in [1, 2, 3]]
        for row in rows:
            if row["repeat"] > 1:
                row["measurement"].update(wer=0, word_errors=0, word_substitutions=0, cer=0, character_errors=0, character_substitutions=0)
        result = report.summarize(matrix(rows))
        cohort = result["cohorts"][0]
        self.assertEqual(result["unique_source_utterances_planned"], 3)
        self.assertEqual(cohort["quality"]["completed_unique_utterances"], 3)
        self.assertEqual(cohort["quality"]["wer"]["reference_units"], 30)
        self.assertEqual(cohort["quality"]["wer"]["errors"], 3)
        self.assertAlmostEqual(cohort["quality"]["wer"]["corpus_weighted_rate"], 0.1)
        self.assertEqual(cohort["timing"]["completed_cells"], 9)
        self.assertEqual(cohort["timing"]["complete_workload_repeats"], 3)

    def test_failed_first_repeat_never_falls_back_to_later_success(self):
        failed = cell(status="failed")
        result = report.summarize(matrix([failed, cell(repeat=2)]))["cohorts"][0]
        self.assertEqual(result["quality"]["completed_unique_utterances"], 0)
        self.assertIsNone(result["quality"]["cer"]["corpus_weighted_rate"])
        self.assertIsNone(result["quality"]["cer"]["errors"])
        self.assertEqual(result["cell_status_counts"], {"completed": 1, "failed": 1})
        self.assertEqual(result["timing"]["completed_cells"], 1)
        self.assertEqual(result["timing"]["complete_workload_repeats"], 1)

    def test_pending_progress_snapshot_has_no_fake_zero_scores_or_timing(self):
        pending = [cell(repeat=value, status="queued", measurement=None) for value in [1, 2, 3]]
        result = report.summarize(matrix(pending))["cohorts"][0]
        self.assertEqual(result["quality"]["planned_unique_utterances"], 1)
        self.assertEqual(result["quality"]["completed_unique_utterances"], 0)
        self.assertIsNone(result["quality"]["wer"]["corpus_weighted_rate"])
        self.assertIsNone(result["quality"]["false_speech_characters"])
        self.assertIsNone(result["timing"]["complete_workload_wall_seconds"]["median"])
        self.assertIsNone(result["peak_process_rss_bytes"]["median"])

    def test_pending_rows_without_artifact_or_measurement_objects_stay_unmeasured(self):
        pending = cell(status="pending", measurement=None, artifact_metrics=None)
        result = report.summarize(matrix([pending]))["cohorts"][0]
        self.assertIsNone(result["artifact_metrics"]["model_file_bytes"])
        self.assertIsNone(result["quality"]["cer"]["corpus_weighted_rate"])

    def test_empty_reference_reports_false_speech_without_inventing_lexical_accuracy(self):
        empty = cell()
        empty["measurement"].update(wer=None, cer=None, reference_words=0, reference_characters=0,
            word_errors=3, character_errors=12, false_speech_characters=12)
        quality = report.summarize(matrix([empty]))["cohorts"][0]["quality"]
        self.assertIsNone(quality["wer"]["corpus_weighted_rate"])
        self.assertIsNone(quality["cer"]["corpus_weighted_rate"])
        self.assertEqual(quality["empty_reference_cases_measured"], 1)
        self.assertEqual(quality["false_speech_characters"], 12)

    def test_chinese_word_rate_is_unreported_while_character_counts_remain(self):
        result = report.summarize(matrix([cell(language="zh")]))["cohorts"][0]
        self.assertIsNone(result["quality"]["wer"])
        self.assertIn("misleading", result["quality"]["wer_status"])
        self.assertEqual(result["quality"]["cer"]["reference_units"], 20)
        self.assertEqual(result["quality"]["cer"]["corpus_weighted_rate"], 0.1)

    def test_workload_timing_requires_every_case_and_weights_by_actual_audio(self):
        a, b = cell("a"), cell("b")
        a["measurement"].update(wall_seconds=2, source_audio_seconds=1)
        b["measurement"].update(wall_seconds=8, source_audio_seconds=8)
        pending = cell("b", repeat=2, status="pending", measurement=None)
        a2 = cell("a", repeat=2)
        cohort = report.summarize(matrix([a, b, a2, pending]))["cohorts"][0]
        self.assertEqual(cohort["timing"]["complete_workload_repeats"], 1)
        self.assertAlmostEqual(cohort["timing"]["complete_workload_real_time_factor"]["median"], 10 / 9)
        incomplete = next(value for value in cohort["timing"]["workloads"] if value["repeat"] == 2)
        self.assertEqual(incomplete["status"], "incomplete")
        self.assertIsNone(incomplete["wall_seconds"])

    def test_upstream_load_is_separate_and_missing_timers_remain_null(self):
        no_timer = report.summarize(matrix([cell()]))["cohorts"][0]
        self.assertIsNone(no_timer["timing"]["model_load_seconds_per_native_invocation"]["median"])
        measured = cell()
        measured["measurement"]["engine_runtime_measurements"] = [{"runtime_timings": {
            "parser_version": "upstream-v1", "observations": {"load": [{"seconds": 0.25}], "total": [{"seconds": 10}]}}}]
        timing = report.summarize(matrix([measured]))["cohorts"][0]["timing"]
        self.assertEqual(timing["model_load_seconds_per_native_invocation"]["median"], 0.25)
        self.assertIn("not total process", timing["model_load_seconds_per_native_invocation"]["scope"])
        self.assertIsNone(timing["first_result_latency_seconds"])

    def test_inconsistent_counts_duplicate_cells_and_changed_artifact_sizes_fail(self):
        inconsistent = cell(); inconsistent["measurement"]["character_errors"] = 7
        with self.assertRaisesRegex(ValueError, "denominator"):
            report.summarize(matrix([inconsistent]))
        with self.assertRaisesRegex(ValueError, "Duplicate benchmark cell"):
            report.summarize(matrix([cell(), cell()]))
        changed = cell(repeat=2); changed["artifact_metrics"]["model_file_bytes"] = 101
        with self.assertRaisesRegex(ValueError, "conflicting"):
            report.summarize(matrix([cell(), changed]))

    def test_models_modes_tasks_and_runtime_identity_are_not_pooled(self):
        rows = [cell(), cell(mode="known"), cell(model="base"), cell(task="standard_rendering"), cell(runtime_settings_sha256="different")]
        result = report.summarize(matrix(rows))
        self.assertEqual(len(result["cohorts"]), 5)
        self.assertEqual(result["unique_source_utterances_planned"], 1)
        self.assertTrue(all(value["quality"]["completed_unique_utterances"] == 1 for value in result["cohorts"]))

    def test_observed_scoring_versions_remain_separate_when_declared_policy_is_missing(self):
        before, after = cell(scoring_policy=None), cell(scoring_policy=None)
        after["measurement"]["scoring_version"] = "new-v2"
        result = report.summarize(matrix([before, after]))
        self.assertEqual(len(result["cohorts"]), 2)
        self.assertEqual({cohort["scoring_policy"] for cohort in result["cohorts"]}, {"legacy-v1", "new-v2"})

    def test_variation_hashes_do_not_require_loading_hypothesis_text(self):
        first, second = cell(), cell(repeat=2)
        second["measurement"]["hypothesis_sha256"] = "different"
        result = report.summarize(matrix([first, second]))["cohorts"][0]
        self.assertEqual(result["utterance_repeats"][0]["distinct_hypothesis_hashes"], 2)
        self.assertTrue(result["utterance_repeats"][0]["transcript_variation"])
        self.assertEqual(result["quality"]["completed_unique_utterances"], 1)

    def test_report_never_reads_or_exports_raw_reference_or_hypothesis_text(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            row = cell(); row["measurement"]["source_text"] = "DO_NOT_EXPORT_PRIVATE_TEXT"
            row["measurement"]["command"] = ["private hint DO_NOT_EXPORT_PRIVATE_TEXT"]
            source = matrix([row])
            (root / "matrix.json").write_text(json.dumps(source))
            (root / "corpus.original.json").write_text(json.dumps({"cases": [{"id": "a", "reference": str(root / "missing-private-reference.txt"), "audio": str(root / "missing-original.wav"),
                "source_text": "DO_NOT_EXPORT_PRIVATE_TEXT", "license": "Public test license", "source_url": "https://public.example/source", "reviewed": False}]}))
            result = report.write_report(root / "matrix.json", root / "output")
            self.assertNotIn("DO_NOT_EXPORT_PRIVATE_TEXT", json.dumps(result))
            self.assertNotIn("DO_NOT_EXPORT_PRIVATE_TEXT", (root / "output" / "report.md").read_text())
            self.assertEqual(result["source_credits"], [{"license": "Public test license", "source_url": "https://public.example/source"}])
            self.assertEqual(result["cohorts"][0]["sample_grouping"]["source_manifest_reviewed_cases"], 0)
            with self.assertRaises(FileExistsError):
                report.write_report(root / "matrix.json", root / "output")

    def test_held_out_outcomes_require_explicit_opt_in_and_frozen_identity(self):
        held = matrix([cell()]); held["split"] = "held_out"
        with self.assertRaisesRegex(ValueError, "Held-out"):
            report.summarize(held)
        with self.assertRaisesRegex(ValueError, "Held-out"):
            report.summarize(held, allow_held_out=True)
        held["freeze_sha256"] = "frozen-hash"
        with self.assertRaisesRegex(ValueError, "Held-out"):
            report.summarize(held, allow_held_out=True)
        self.assertEqual(report.summarize(held, allow_held_out=True, freeze_verified=True)["completed_cells"], 1)

    def test_snapshot_hashes_are_verified_before_metadata_is_used(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            corpus = json.dumps({"cases": [{"id": "a", "duration_seconds": 4}]}).encode()
            experiment = json.dumps({"models": [{"id": "tiny", "sha256": "tiny-hash"}]}).encode()
            source = matrix([cell()])
            source.update(corpus_sha256=hashlib.sha256(corpus).hexdigest(), configuration_sha256=hashlib.sha256(experiment).hexdigest())
            (root / "corpus.original.json").write_bytes(corpus)
            (root / "experiment.original.json").write_bytes(experiment)
            (root / "matrix.json").write_text(json.dumps(source))
            result = report.write_report(root / "matrix.json", root / "verified")
            self.assertEqual(result["snapshot_evidence"]["corpus.original.json"]["status"], "verified")
            self.assertEqual(result["snapshot_evidence"]["experiment.original.json"]["status"], "verified")
            (root / "corpus.original.json").write_text('{"cases":[]}')
            with self.assertRaisesRegex(ValueError, "corpus.original.json hash differs"):
                report.write_report(root / "matrix.json", root / "changed")
            self.assertFalse((root / "changed").exists())

    def test_missing_snapshots_are_explicitly_unavailable_not_inferred(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = matrix([cell()]); source.update(corpus_sha256="a" * 64, configuration_sha256="b" * 64)
            (root / "matrix.json").write_text(json.dumps(source))
            result = report.write_report(root / "matrix.json", root / "report")
            self.assertEqual(result["snapshot_evidence"]["corpus.original.json"]["status"], "unavailable; metadata not inferred")
            self.assertIsNone(result["snapshot_evidence"]["corpus.original.json"]["observed_sha256"])
            self.assertEqual(result["source_credits"], [])
            self.assertEqual(result["model_sources"], {})

    def test_held_out_writer_requires_matching_retained_freeze_and_bound_snapshots(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            corpus, experiment = json.dumps({"cases": [], "frozen": True}).encode(), json.dumps({"models": []}).encode()
            corpus_hash, experiment_hash = hashlib.sha256(corpus).hexdigest(), hashlib.sha256(experiment).hexdigest()
            (root / "corpus.original.json").write_bytes(corpus)
            (root / "experiment.original.json").write_bytes(experiment)
            source = matrix([cell()]); source.update(split="held_out", corpus_sha256=corpus_hash, configuration_sha256=experiment_hash, freeze_sha256="f" * 64)
            (root / "matrix.json").write_text(json.dumps(source))
            with self.assertRaisesRegex(ValueError, "requires the retained freeze"):
                report.write_report(root / "matrix.json", root / "missing", allow_held_out=True)
            freeze = {"corpus_sha256": "wrong", "experiment_sha256": experiment_hash, "frozen_before_held_out": True, "budgets": {"test": "predeclared"}}
            frozen_bytes = json.dumps(freeze).encode(); (root / "freeze.original.json").write_bytes(frozen_bytes)
            with self.assertRaisesRegex(ValueError, "freeze.original.json hash differs"):
                report.write_report(root / "matrix.json", root / "wrong-hash", allow_held_out=True)
            source["freeze_sha256"] = hashlib.sha256(frozen_bytes).hexdigest(); (root / "matrix.json").write_text(json.dumps(source))
            with self.assertRaisesRegex(ValueError, "same corpus/experiment"):
                report.write_report(root / "matrix.json", root / "wrong-binding", allow_held_out=True)
            freeze["corpus_sha256"] = corpus_hash
            frozen_bytes = json.dumps(freeze).encode(); (root / "freeze.original.json").write_bytes(frozen_bytes)
            source["freeze_sha256"] = hashlib.sha256(frozen_bytes).hexdigest(); (root / "matrix.json").write_text(json.dumps(source))
            result = report.write_report(root / "matrix.json", root / "allowed", allow_held_out=True)
            self.assertEqual(result["snapshot_evidence"]["freeze.original.json"]["status"], "verified")
            (root / "freeze.original.json").write_bytes(frozen_bytes + b"\n")
            with self.assertRaisesRegex(ValueError, "freeze.original.json hash differs"):
                report.write_report(root / "matrix.json", root / "changed-freeze", allow_held_out=True)

    def test_comparison_quality_uses_only_paired_repeat_one_and_hides_chinese_wer(self):
        paired = {"id": "a", "source_channel": 0, "comparison_id": "weights", "intervention": "weight_edit", "baseline_model": "tiny", "candidate_model": "tiny-edited", "candidate_profile": "control", "language": "de", "task": "transcription", "language_mode": "auto", "path": "final", "status": "paired_exploratory", "wer_delta": -0.2, "cer_delta": -0.1}
        values = []
        for repeat in [1, 2, 3]:
            value = copy.deepcopy(paired); value["repeat"] = repeat
            if repeat > 1:
                value["wer_delta"] = 0.5
            values.append(value)
        summary = report.summarize_comparisons(values)[0]
        self.assertEqual(summary["paired_first_repeat_utterances"], 1)
        self.assertEqual(summary["macro_utterance_wer_delta"], -0.2)
        paired.update(language="zh", repeat=1)
        chinese = report.summarize_comparisons([paired])[0]
        self.assertIsNone(chinese["macro_utterance_wer_delta"])
        self.assertEqual(chinese["macro_utterance_cer_delta"], -0.1)

    def test_legacy_comparison_strings_never_pool_unknown_modes_or_tasks(self):
        legacy = {"comparison_id": "weights", "intervention": "weight_edit", "baseline_model": "tiny", "candidate_model": "edited",
            "candidate_profile": "control", "language": "de", "status": "paired_exploratory", "pairing_contract_version": "model-lineage-v2", "wer_delta": -0.2}
        known, automatic = copy.deepcopy(legacy), copy.deepcopy(legacy)
        known["identity"] = "a|de|known|final|audio|reference|scorer|transcription|0|1"
        automatic["identity"] = "a|de|auto|final|audio|reference|scorer|transcription|0|1"
        result = report.summarize_comparisons([known, automatic])[0]
        self.assertIn("unavailable", result["aggregation_status"])
        self.assertIsNone(result["paired_first_repeat_utterances"])
        self.assertIsNone(result["macro_utterance_wer_delta"])

    def test_duplicate_comparison_cells_and_changed_model_hashes_fail(self):
        value = {"id": "a", "repeat": 1, "source_channel": 0, "comparison_id": "weights", "intervention": "weight_edit", "baseline_model": "tiny",
            "candidate_model": "edited", "candidate_profile": "control", "language": "de", "task": "transcription", "language_mode": "auto", "path": "final", "status": "paired_exploratory", "candidate_model_sha256": "edited-hash"}
        with self.assertRaisesRegex(ValueError, "Duplicate paired"):
            report.summarize_comparisons([value, copy.deepcopy(value)])
        changed = copy.deepcopy(value); changed.update(repeat=2, candidate_model_sha256="other-hash")
        with self.assertRaisesRegex(ValueError, "artifact hash"):
            report.summarize_comparisons([value, changed])


if __name__ == "__main__":
    unittest.main()
