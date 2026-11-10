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


def native_language_pass(recognized="de", effective="auto", asr="auto"):
    return {"engine": "whisper.cpp", "asr_language": asr, "detected_language": recognized,
        "language_policy": {"policy": "current_auto", "effective_argument": effective,
            "recognizer_language": recognized, "confidence": None}}


class QualityReportTests(unittest.TestCase):
    def test_unscored_pairs_report_signed_resource_deltas_without_quality_gains(self):
        pair = {"id": "source", "repeat": 1, "status": "paired_exploratory", "source_channel": 0,
                "task": "transcription", "language_mode": "auto", "path": "final",
                "comparison_id": "compression", "baseline_model": "small", "candidate_model": "small-q4",
                "measurement_scope": "resources_only", "hypothesis_exact_match": True,
                "wall_seconds_delta": -2, "peak_rss_bytes_delta": -100, "wer_delta": -.9, "cer_delta": -.9}
        result = report.summarize_comparisons([pair])[0]
        self.assertEqual(result["paired_first_repeat_utterances"], 0)
        self.assertEqual(result["paired_unscored_first_repeat_utterances"], 1)
        self.assertIsNone(result["macro_utterance_wer_delta"])
        self.assertIsNone(result["macro_utterance_cer_delta"])
        self.assertEqual(result["resource_observations"]["wall_seconds_delta"]["median"], -2)
        self.assertEqual(result["unscored_output_consistency"]["exact_matches"], 1)

    def test_resource_only_probe_retains_timing_and_never_scores_or_counts_language_accuracy(self):
        row = cell()
        row["measurement"]["measurement_scope"] = "resources_only"
        row["measurement"]["engine_passes"] = [native_language_pass("de")]
        summary = report.summarize(matrix([row]))
        cohort = summary["cohorts"][0]
        self.assertIn("Unscored resource-only", summary["limitations"][0])
        self.assertIn("No WER or CER is scored", " ".join(summary["limitations"]))
        self.assertEqual(cohort["quality"]["completed_unique_utterances"], 0)
        self.assertIsNone(cohort["quality"]["cer"]["corpus_weighted_rate"])
        self.assertIsNone(cohort["quality"]["wer"]["corpus_weighted_rate"])
        self.assertEqual(cohort["quality"]["automatic_language_labels"]["ineligibility_counts"], {"resource_only_probe": 1})
        self.assertEqual(cohort["timing"]["completed_cells"], 1)
        self.assertEqual(cohort["timing"]["complete_workload_repeats"], 1)

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

    def test_coarse_language_labels_use_repeat_one_and_preserve_lexical_denominators(self):
        correct, wrong, later = cell("correct", language="de-CH"), cell("wrong", language="de-CH"), cell("correct", repeat=2, language="de-CH")
        correct["measurement"]["engine_passes"] = [native_language_pass("de")]
        wrong["measurement"]["engine_passes"] = [native_language_pass("en")]
        later["measurement"]["engine_passes"] = [native_language_pass("fr")]
        result = report.summarize(matrix([correct, wrong, later]))
        quality = result["cohorts"][0]["quality"]
        labels = quality["automatic_language_labels"]
        self.assertEqual(labels["planned_unique_utterances"], 2)
        self.assertEqual(labels["observed_unique_utterances"], 2)
        self.assertEqual(labels["unobserved_unique_utterances"], 0)
        self.assertEqual(labels["expected_base_language_counts"], {"de": 2})
        self.assertEqual(labels["recognized_base_language_counts"], {"de": 1, "en": 1})
        self.assertEqual(labels["confusion_counts"], [
            {"expected_base_language": "de", "recognized_base_language": "de", "unique_utterances": 1},
            {"expected_base_language": "de", "recognized_base_language": "en", "unique_utterances": 1}])
        self.assertEqual(labels["observed_label_matches"], 1)
        self.assertEqual(labels["observed_label_mismatches"], 1)
        self.assertEqual(labels["observed_base_label_agreement"], 0.5)
        self.assertIsNone(labels["confidence"])
        self.assertIsNone(labels["human_language_id_accuracy"])
        self.assertIsNone(quality["language_id_accuracy"])
        self.assertEqual(labels["switch_boundary_gate"], "UNMEASURED")
        self.assertEqual(labels["out_of_set_gate"], "UNMEASURED")
        self.assertEqual(quality["wer"]["reference_units"], 20)
        self.assertEqual(quality["wer"]["errors"], 2)
        self.assertIn("published monolingual", labels["scope"])
        self.assertIn("de-CH → de", report.markdown(result))

    def test_known_language_controls_and_explicit_native_arguments_never_become_detection(self):
        known, argument, policy = cell("known", mode="known"), cell("argument"), cell("policy")
        # Even inconsistent auto-looking provenance cannot make a known row a detection.
        known["measurement"]["engine_passes"] = [native_language_pass()]
        argument["measurement"]["engine_passes"] = [native_language_pass(asr="de")]
        policy["measurement"]["engine_passes"] = [native_language_pass(effective="de")]
        result = report.summarize(matrix([known, argument, policy]))
        explicit = next(value for value in result["cohorts"] if value["language_mode"] == "known")["quality"]["automatic_language_labels"]
        automatic = next(value for value in result["cohorts"] if value["language_mode"] == "auto")["quality"]["automatic_language_labels"]
        self.assertEqual(explicit["planned_unique_utterances"], 0)
        self.assertEqual(explicit["observed_unique_utterances"], 0)
        self.assertEqual(explicit["ineligibility_counts"], {"explicit_language_control": 1})
        self.assertIsNone(explicit["observed_base_label_agreement"])
        self.assertEqual(automatic["planned_unique_utterances"], 2)
        self.assertEqual(automatic["unobserved_reason_counts"], {"not_an_automatic_native_invocation": 2})
        self.assertEqual(automatic["confusion_counts"], [])

    def test_empty_vad_raw_label_missing_policy_and_missing_pass_stay_unobserved(self):
        empty, policy_missing, pass_missing = [cell(identifier, language="en") for identifier in ["empty", "policy-missing", "pass-missing"]]
        native = native_language_pass(None)
        native["detected_language"] = "en"  # Runtime initial state after VAD found no speech.
        empty["measurement"]["engine_passes"] = [native]
        native = native_language_pass("en"); del native["language_policy"]
        policy_missing["measurement"]["engine_passes"] = [native]
        pass_missing["measurement"]["detected_language"] = "en"
        quality = report.summarize(matrix([empty, policy_missing, pass_missing]))["cohorts"][0]["quality"]
        labels = quality["automatic_language_labels"]
        self.assertEqual(labels["planned_unique_utterances"], 3)
        self.assertEqual(labels["observed_unique_utterances"], 0)
        self.assertEqual(labels["unobserved_unique_utterances"], 3)
        self.assertEqual(labels["unobserved_reason_counts"], {"no_structured_nonempty_speech_label": 1,
            "missing_structured_language_policy": 1, "missing_native_pass": 1})
        self.assertEqual(labels["recognized_base_language_counts"], {})
        self.assertIsNone(labels["observed_base_label_agreement"])
        self.assertEqual(quality["cer"]["reference_units"], 60)

    def test_multiple_channels_region_wrappers_and_non_native_passes_are_ambiguous(self):
        channels, regions, other = [cell(identifier) for identifier in ["channels", "regions", "other"]]
        channels["measurement"]["engine_passes"] = [native_language_pass(), native_language_pass()]
        wrapper = native_language_pass()
        wrapper["channel_regions"] = [{"provenance": native_language_pass()}]
        regions["measurement"]["engine_passes"] = [wrapper]
        non_native = native_language_pass(); non_native["engine"] = "synthetic"
        other["measurement"]["engine_passes"] = [non_native]
        labels = report.summarize(matrix([channels, regions, other]))["cohorts"][0]["quality"]["automatic_language_labels"]
        self.assertEqual(labels["observed_unique_utterances"], 0)
        self.assertEqual(labels["unobserved_unique_utterances"], 3)
        self.assertEqual(labels["unobserved_reason_counts"], {"ambiguous_multiple_engine_passes": 1,
            "ambiguous_region_invocations": 1, "not_a_direct_native_pass": 1})

    def test_coarse_language_labels_do_not_fall_back_after_failed_or_missing_first_repeat(self):
        failed, later, missing = cell("failed", status="failed"), cell("failed", repeat=2), cell("missing", repeat=2)
        for row in [failed, later, missing]:
            row["measurement"]["engine_passes"] = [native_language_pass()]
        labels = report.summarize(matrix([failed, later, missing]))["cohorts"][0]["quality"]["automatic_language_labels"]
        self.assertEqual(labels["planned_unique_utterances"], 2)
        self.assertEqual(labels["observed_unique_utterances"], 0)
        self.assertEqual(labels["unobserved_reason_counts"], {"repeat_one_not_completed": 2})
        self.assertIsNone(labels["observed_base_label_agreement"])

    def test_unknown_source_languages_and_declared_switches_are_not_monolingual_trials(self):
        rows = [cell("unknown", language="und"), cell("multiple", language="mul"), cell("invalid", language="de/fr"),
            cell("switched"), cell("non-speech", task="non_speech"), cell("uncertain-switches")]
        for row in rows:
            row["measurement"]["engine_passes"] = [native_language_pass()]
        corpus = {"cases": [{"id": "switched", "language": "de", "code_switches": [{"language": "fr"}]},
            {"id": "uncertain-switches", "language": "de", "code_switches": None}]}
        result = report.summarize(matrix(rows), corpus)
        labels = [value["quality"]["automatic_language_labels"] for value in result["cohorts"]]
        self.assertEqual(sum(value["planned_unique_utterances"] for value in labels), 0)
        self.assertEqual(sum(value["ineligible_unique_utterances"] for value in labels), 6)
        exclusions = {}
        for value in labels:
            for reason, count in value["ineligibility_counts"].items():
                exclusions[reason] = exclusions.get(reason, 0) + count
        self.assertEqual(exclusions, {"unknown_or_invalid_source_language": 3, "declared_code_switching": 1,
            "non_speech_source": 1, "unknown_code_switch_metadata": 1})
        self.assertTrue(all(value["observed_base_label_agreement"] is None for value in labels))

    def test_base_language_tags_are_validated_generically_without_regional_identity_claims(self):
        for tag, expected in [("de-CH", "de"), ("pt-BR", "pt"), ("zh-Hant-TW", "zh"), ("en-GB", "en"),
            ("ar", "ar"), ("gsw", "gsw"), ("abc-123", "abc"), ("und", None), ("mul", None), ("zxx", None),
            ("auto", None), ("de/fr", None), ("de--CH", None), ("e", None), ("de ", None), (None, None)]:
            with self.subTest(tag=tag):
                self.assertEqual(report.base_language(tag), expected)

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
