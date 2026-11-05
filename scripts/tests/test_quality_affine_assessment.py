"""Synthetic fixed-plan assessment tests; no corpus/model/recognizer access."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("affine_assessment", Path(__file__).resolve().parents[1] / "quality/assess-affine-pilot.py")
assessment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(assessment)


def sha(value): return hashlib.sha256(value.encode()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    return hashlib.sha256(path.read_bytes()).hexdigest()


class QualityAffineAssessmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self): self.temporary.cleanup()

    def fixture(self, mode="quality", modes=None, split="development"):
        modes = modes or (["known", "auto"] if mode == "control" or split == "held_out" else ["known"])
        execution = {key: sha(key) for key in ["profile_sha256", "runtime_settings_sha256", "runner_sha256", "whisper_binary_sha256", "corpus_sha256", "configuration_sha256"]}
        execution.update(profile_id="current-defaults", vad_model_sha256=None, threads=2)
        if split == "held_out": execution["freeze_sha256"] = sha("heldout-freeze")
        runtime_path = self.root / "runtime.json"
        runtime_hash = write(runtime_path, {"runner_sha256": execution["runner_sha256"], "files": [{"path": "/never-open/whisper-cli", "sha256": execution["whisper_binary_sha256"]}]})
        cases = [{"id": language.replace("-", "_") + "-" + str(index), "language": language,
                  "task": "standard_rendering" if language == "de-CH" else "transcription", "source_channel": 0,
                  "source_sha256": sha(language + str(index)), "reference_sha256": sha("reference-" + language + str(index)),
                  "source_id": "published:" + language + ":" + str(index), "code_switches": []}
                 for language in assessment.LANGUAGES for index in range(1 if mode == "control" else 8)]
        specification = {"id": "tiny", "comparison_id": "tiny-affine", "baseline": {"id": "tiny", "sha256": sha("parent")},
                         "candidate": {"id": "tiny-affine", "sha256": sha("candidate")}}
        plan = {"schema_version": "affine-assessment-plan-v1", "mode": mode, "split": split, "repetitions": 3,
                "language_modes": modes, "cases": cases, "pairs": [specification], "execution": execution,
                "runtime_record": {"path": str(runtime_path), "sha256": runtime_hash}}
        matrix = {"split": split, "dry_run": False, "threads": 2, **{key: execution[key] for key in ("runner_sha256", "whisper_binary_sha256", "corpus_sha256", "configuration_sha256")},
                  "rows": [], "paired_comparisons": []}
        if split == "held_out": matrix["freeze_sha256"] = execution["freeze_sha256"]
        for case in cases:
            for side in ("baseline", "candidate"):
                for language_mode in modes:
                    for repeat in (1, 2, 3):
                        cer_errors = 20 if side == "baseline" else 18
                        wer_errors = 30 if side == "baseline" else 29
                        native = {"engine": "whisper.cpp", "binary_sha256": execution["whisper_binary_sha256"],
                            "model_sha256": specification[side]["sha256"], "vad_model_sha256": None,
                            "decoding": {"profile_sha256": execution["runtime_settings_sha256"]},
                            "asr_language": "auto" if language_mode == "auto" else case["language"].split("-")[0],
                            "language_policy": {"effective_argument": "auto" if language_mode == "auto" else case["language"].split("-")[0],
                                                "recognizer_language": case["language"].split("-")[0]}}
                        measurement = {"status": "completed_with_review", "scoring_version": assessment.POLICY,
                            "source_sha256": case["source_sha256"], "reference_sha256": case["reference_sha256"],
                            "wer": wer_errors / 100, "word_errors": wer_errors, "reference_words": 100,
                            "word_insertions": 0, "word_deletions": 0, "word_substitutions": wer_errors,
                            "cer": cer_errors / 100, "character_errors": cer_errors, "reference_characters": 100,
                            "character_insertions": 0, "character_deletions": 0, "character_substitutions": cer_errors,
                            "engine_passes": [native], "hypothesis_sha256": sha(case["id"] + language_mode + ("same" if mode == "control" else side)),
                            "wall_seconds": 1, "source_audio_seconds": 2, "peak_rss_bytes": 10}
                        matrix["rows"].append({**case, "model": specification[side]["id"], "model_sha256": specification[side]["sha256"],
                            "profile": execution["profile_id"], "profile_sha256": execution["profile_sha256"],
                            "effective_profile_sha256": execution["runtime_settings_sha256"], "runtime_settings_sha256": execution["runtime_settings_sha256"],
                            "transcription_runner_sha256": execution["runner_sha256"], "whisper_binary_sha256": execution["whisper_binary_sha256"],
                            "vad_model_sha256": None, "threads": 2, "path": "final", "language_mode": language_mode, "repeat": repeat,
                            "scoring_policy": assessment.POLICY, "status": "completed_with_review", "measurement": measurement})
        return plan, matrix

    def materialize(self, plan, matrix):
        # Build direct pair evidence and the actual public report format from mock metrics.
        specification = plan["pairs"][0]
        rows = {(row["id"], row["model"], row["language_mode"], row["repeat"]): row for row in matrix["rows"]}
        pairs = []
        for case in plan["cases"]:
            for mode in plan["language_modes"]:
                for repeat in (1, 2, 3):
                    before, after = [rows.get((case["id"], specification[side]["id"], mode, repeat)) for side in ("baseline", "candidate")]
                    value = {"id": case["id"], "comparison_id": specification["comparison_id"], "intervention": "weight_edit", "language": case["language"],
                        "task": case["task"], "source_channel": 0, "path": "final", "language_mode": mode, "repeat": repeat,
                        "baseline_model": specification["baseline"]["id"], "candidate_model": specification["candidate"]["id"],
                        "candidate_model_sha256": specification["candidate"]["sha256"], "candidate_profile": plan["execution"]["profile_id"],
                        "baseline_profile": plan["execution"]["profile_id"], "status": "pending_pair"}
                    if before and after and assessment.public.completed(before) and assessment.public.completed(after):
                        value.update(status="paired_exploratory", baseline_model_sha256=specification["baseline"]["sha256"])
                        for name in ("wer", "cer"):
                            a, b = before["measurement"].get(name), after["measurement"].get(name)
                            if a is not None and b is not None: value[name + "_delta"] = b - a
                    pairs.append(value)
        matrix["paired_comparisons"] = pairs
        matrix_path, plan_path = self.root / "matrix.json", self.root / "plan.json"
        matrix_hash = write(matrix_path, matrix); write(plan_path, plan)
        report = assessment.public.summarize(matrix, {"cases": plan["cases"]}, allow_held_out=plan["split"] == "held_out", freeze_verified=plan["split"] == "held_out")
        snapshot_fields = [("corpus.original.json", "corpus_sha256"), ("experiment.original.json", "configuration_sha256")]
        if plan["split"] == "held_out": snapshot_fields.append(("freeze.original.json", "freeze_sha256"))
        report.update(source_matrix_sha256=matrix_hash, snapshot_evidence={name: {"status": "verified", "expected_sha256": plan["execution"][field], "observed_sha256": plan["execution"][field]} for name, field in snapshot_fields})
        report_path = self.root / "report.json"; write(report_path, report)
        return report_path, matrix_path, plan_path

    def assess(self, plan, matrix):
        paths = self.materialize(plan, matrix)
        return assessment.write_assessment(*paths, self.root / "assessment")

    def change(self, matrix, language, *, cer=None, wer=None, mode="known", repeat=None):
        for row in matrix["rows"]:
            if row["model"] == "tiny-affine" and row["language"] == language and row["language_mode"] == mode and (repeat is None or row["repeat"] == repeat):
                for name, prefix, errors in (("cer", "character", cer), ("wer", "word", wer)):
                    if errors is not None: row["measurement"].update({name: errors / 100, prefix + "_errors": errors, prefix + "_substitutions": errors})

    def test_complete_gates_use_corpus_counts_no_promotion_and_resource_observations(self):
        plan, matrix = self.fixture()
        result = self.assess(plan, matrix)
        value = result["model_mode_assessments"][0]
        self.assertEqual(value["decision"], "continue_no_promotion")
        self.assertAlmostEqual(value["macro_metrics"]["cer_relative_gain"], 0.1)
        self.assertAlmostEqual(value["macro_metrics"]["wer_relative_gain"], 1 / 30)
        self.assertEqual(value["per_language"][0]["candidate"]["cer"]["reference_units"], 800)
        self.assertEqual(value["per_language"][0]["candidate"]["cer"]["substitutions"], 144)
        chinese = next(v for v in value["per_language"] if v["language"] == "zh")
        self.assertIsNone(chinese["candidate"]["wer"])
        self.assertIsNone(chinese["wer_delta"])
        self.assertFalse(result["default_promotion"])
        self.assertEqual(result["resource_acceptance"], "UNCONTROLLED / NOT EVALUATED")
        self.assertEqual(len(result["resource_observations"]), 18)

    def test_word_gain_is_required_even_when_cer_improves(self):
        plan, matrix = self.fixture()
        for language in assessment.LANGUAGES: self.change(matrix, language, wer=30)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertEqual(value["decision"], "reject")
        self.assertTrue(value["gates"]["macro_cer_gain_at_least_5_percent"])
        self.assertFalse(value["gates"]["macro_wer_gain_at_least_2_percent"])

    def test_swiss_word_regression_cannot_be_hidden_by_other_languages(self):
        plan, matrix = self.fixture()
        for language in assessment.LANGUAGES: self.change(matrix, language, wer=27)
        self.change(matrix, "de-CH", wer=31)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertTrue(value["gates"]["macro_wer_gain_at_least_2_percent"])
        self.assertFalse(value["gates"]["swiss_written_german_wer_no_increase"])
        self.assertEqual(value["decision"], "reject")

    def test_per_language_cer_and_wer_regression_caps_are_independent(self):
        plan, matrix = self.fixture()
        self.change(matrix, "fr", cer=22)
        self.change(matrix, "ar", wer=33)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertTrue(value["gates"]["macro_cer_gain_at_least_5_percent"])
        self.assertFalse(value["gates"]["fr_cer_increase_at_most_0.01"])
        self.assertFalse(value["gates"]["ar_wer_increase_at_most_0.02"])

    def test_missing_failed_and_null_repeat_one_never_fall_back(self):
        plan, matrix = self.fixture()
        row = next(r for r in matrix["rows"] if r["model"] == "tiny-affine" and r["language"] == "de" and r["repeat"] == 1)
        matrix["rows"].remove(row)
        row = next(r for r in matrix["rows"] if r["model"] == "tiny-affine" and r["language"] == "fr" and r["repeat"] == 1)
        row.update(status="failed", measurement={"status": "failed"})
        row = next(r for r in matrix["rows"] if r["model"] == "tiny-affine" and r["language"] == "it" and r["repeat"] == 1)
        row["measurement"].update(cer=None, character_errors=None, character_substitutions=None)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertEqual(value["decision"], "inconclusive_no_promotion")
        for language in ("de", "fr", "it"):
            observed = next(v for v in value["per_language"] if v["language"] == language)["candidate"]["cer"]
            self.assertEqual(observed["observed_scored_utterances"], 7)
            self.assertIsNone(observed["rate"])
            self.assertEqual(observed["planned_utterances"], 8)
        self.assertIsNone(value["macro_metrics"]["candidate_macro_cer"])

    def test_auto_new_mismatch_and_unknown_are_separate_from_known_gates(self):
        plan, matrix = self.fixture(modes=["known", "auto"], split="held_out")
        target = next(r for r in matrix["rows"] if r["model"] == "tiny-affine" and r["language"] == "en" and r["language_mode"] == "auto" and r["repeat"] == 1)
        target["measurement"]["engine_passes"][0]["language_policy"]["recognizer_language"] = "fr"
        other = next(r for r in matrix["rows"] if r["model"] == "tiny-affine" and r["language"] == "ar" and r["language_mode"] == "auto" and r["repeat"] == 1)
        other["measurement"]["hypothesis_sha256"] = assessment.EMPTY
        other["measurement"]["engine_passes"][0]["language_policy"]["recognizer_language"] = None
        result = self.assess(plan, matrix)
        values = {v["language_mode"]: v for v in result["model_mode_assessments"]}
        self.assertEqual(values["known"]["decision"], "continue_no_promotion")
        self.assertEqual(values["auto"]["decision"], "reject")
        self.assertEqual(values["auto"]["auto_labels"]["newly_wrong_cases"], 1)
        self.assertEqual(values["auto"]["auto_labels"]["unknown_cases"], 1)
        self.assertEqual(result["model_assessments"][0]["decision"], "reject")

    def test_unknown_auto_label_is_inconclusive_without_an_observed_regression(self):
        plan, matrix = self.fixture(modes=["known", "auto"])
        target = next(r for r in matrix["rows"] if r["model"] == "tiny-affine" and r["language_mode"] == "auto" and r["repeat"] == 1)
        target["measurement"]["engine_passes"][0]["language_policy"]["recognizer_language"] = None
        value = next(v for v in self.assess(plan, matrix)["model_mode_assessments"] if v["language_mode"] == "auto")
        self.assertEqual(value["decision"], "inconclusive_no_promotion")
        self.assertIsNone(value["gates"]["no_new_wrong_auto_base_labels"])

    def test_repair_elsewhere_cannot_hide_a_new_per_case_wrong_label(self):
        plan, matrix = self.fixture(modes=["known", "auto"])
        # Aggregate mismatch counts stay equal: one case repaired, another lost.
        for row in matrix["rows"]:
            if row["language"] != "en" or row["language_mode"] != "auto" or row["repeat"] != 1: continue
            if row["id"] == "en-0" and row["model"] == "tiny":
                row["measurement"]["engine_passes"][0]["language_policy"]["recognizer_language"] = "fr"
            if row["id"] == "en-1" and row["model"] == "tiny-affine":
                row["measurement"]["engine_passes"][0]["language_policy"]["recognizer_language"] = "fr"
        values = {v["language_mode"]: v for v in self.assess(plan, matrix)["model_mode_assessments"]}
        self.assertEqual(values["auto"]["auto_labels"]["newly_wrong_cases"], 1)
        self.assertFalse(values["auto"]["gates"]["no_new_wrong_auto_base_labels"])
        self.assertEqual(values["auto"]["decision"], "reject")
        self.assertEqual(values["known"]["decision"], "continue_no_promotion")

    def test_control_hash_difference_or_unknown_label_is_inconclusive(self):
        plan, matrix = self.fixture(mode="control")
        first = next(r for r in matrix["rows"] if r["model"] == "tiny-affine" and r["repeat"] == 1)
        first["measurement"]["hypothesis_sha256"] = sha("different canonical hypothesis")
        unknown = next(r for r in matrix["rows"] if r["model"] == "tiny-affine" and r["language_mode"] == "auto" and r["repeat"] == 1)
        unknown["measurement"]["engine_passes"][0]["language_policy"]["recognizer_language"] = None
        values = self.assess(plan, matrix)["model_mode_assessments"]
        self.assertTrue(all(v["decision"] == "inconclusive_no_promotion" for v in values))

    def test_control_identical_hypotheses_and_labels_only_continue_research(self):
        plan, matrix = self.fixture(mode="control")
        result = self.assess(plan, matrix)
        self.assertTrue(all(v["decision"] == "continue_no_promotion" for v in result["model_mode_assessments"]))
        self.assertFalse(result["default_promotion"])

    def test_identity_and_denominator_corruption_are_refused(self):
        for field in ("source_sha256", "reference_sha256", "model_sha256", "transcription_runner_sha256", "runtime_settings_sha256"):
            with self.subTest(field=field):
                plan, matrix = self.fixture()
                matrix["rows"][0][field] = "0" * 64
                paths = self.materialize(plan, matrix)
                report, _ = assessment.read(paths[0]); changed, digest = assessment.read(paths[1])
                with self.assertRaises(ValueError): assessment.assess(report, changed, digest, plan)
        plan, matrix = self.fixture()
        matrix["rows"][0]["measurement"].update(reference_words=0, wer=None)
        paths = self.materialize(plan, matrix)
        report, _ = assessment.read(paths[0]); changed, digest = assessment.read(paths[1])
        # A single zero conflicts with the same reference's positive units in
        # every other planned model/mode/repeat and must reject the evidence.
        with self.assertRaisesRegex(ValueError, "Conflicting reference units"):
            assessment.assess(report, changed, digest, plan)

    def test_coherent_rate_and_denominator_mutations_across_repeats_or_models_are_rejected(self):
        for name, units, scope in (("cer", "reference_characters", "late_repeat"), ("wer", "reference_words", "candidate_model")):
            with self.subTest(metric=name, scope=scope):
                plan, matrix = self.fixture(modes=["known", "auto"])
                for row in matrix["rows"]:
                    if scope == "late_repeat" and not (row["language"] == "en" and row["model"] == "tiny-affine" and row["language_mode"] == "auto" and row["repeat"] == 3): continue
                    if scope == "candidate_model" and row["model"] != "tiny-affine": continue
                    prefix = "character" if name == "cer" else "word"
                    row["measurement"][units] = 200
                    row["measurement"][name] = row["measurement"][prefix + "_errors"] / 200
                paths = self.materialize(plan, matrix)
                report, _ = assessment.read(paths[0]); changed, digest = assessment.read(paths[1])
                with self.assertRaisesRegex(ValueError, "Conflicting reference units"):
                    assessment.assess(report, changed, digest, plan)

    def test_shared_zero_or_null_units_are_valid_unscored_not_passes(self):
        for units in (0, None):
            with self.subTest(units=units):
                plan, matrix = self.fixture(modes=["known", "auto"])
                for row in matrix["rows"]:
                    if row["id"] != "en-0": continue
                    row["measurement"].update(reference_words=units, reference_characters=units, wer=None, cer=None)
                paths = self.materialize(plan, matrix)
                report, _ = assessment.read(paths[0]); changed, digest = assessment.read(paths[1])
                result = assessment.assess(report, changed, digest, plan)
                for value in result["model_mode_assessments"]:
                    self.assertEqual(value["decision"], "inconclusive_no_promotion")
                    language = next(item for item in value["per_language"] if item["language"] == "en")
                    self.assertIsNone(language["baseline"]["cer"]["rate"])
                    self.assertEqual(language["candidate"]["cer"]["observed_scored_utterances"], 7)

    def test_single_null_units_are_unmeasured_not_a_zero_conflict(self):
        plan, matrix = self.fixture()
        row = next(row for row in matrix["rows"] if row["model"] == "tiny-affine" and row["language"] == "en" and row["repeat"] == 1)
        row["measurement"].update(reference_characters=None, cer=None)
        result = self.assess(plan, matrix)
        value = result["model_mode_assessments"][0]
        self.assertEqual(value["decision"], "inconclusive_no_promotion")
        language = next(item for item in value["per_language"] if item["language"] == "en")
        self.assertEqual(language["candidate"]["cer"]["observed_scored_utterances"], 7)
        self.assertIsNone(language["candidate"]["cer"]["rate"])

    def test_conflicting_units_on_failed_partial_measurement_cannot_be_dropped(self):
        plan, matrix = self.fixture()
        row = matrix["rows"][0]
        row.update(status="failed", measurement={"status": "failed", "reference_characters": 101})
        paths = self.materialize(plan, matrix)
        report, _ = assessment.read(paths[0]); changed, digest = assessment.read(paths[1])
        with self.assertRaisesRegex(ValueError, "Conflicting reference units"):
            assessment.assess(report, changed, digest, plan)

    def test_invalid_counts_and_nonmatching_counted_rates_are_rejected(self):
        plan, matrix = self.fixture()
        paths = self.materialize(plan, matrix)
        report, _ = assessment.read(paths[0]); original, digest = assessment.read(paths[1])
        for field, value in (("word_errors", -1), ("reference_words", True), ("word_substitutions", 0), ("wer", 0.31)):
            with self.subTest(field=field):
                changed = copy.deepcopy(original)
                changed["rows"][0]["measurement"][field] = value
                with self.assertRaises(ValueError): assessment.assess(report, changed, digest, plan)

    def test_json_duplicate_nonfinite_and_size_bounds(self):
        for text in ('{"a":1,"a":2}', '{"a":{"b":1,"b":2}}', '{"a":NaN}', '{"a":Infinity}', '{"a":1e9999}'):
            p = self.root / "invalid.json"; p.write_text(text)
            with self.assertRaises(ValueError): assessment.read(p)
        p.write_bytes(b" " * 33)
        with patch.object(assessment, "MAX_JSON_BYTES", 32):
            with self.assertRaisesRegex(ValueError, "exceeds"): assessment.read(p)

    def test_duplicate_rows_missing_pairs_and_wrong_matrix_signature(self):
        plan, matrix = self.fixture()
        paths = self.materialize(plan, matrix)
        report, _ = assessment.read(paths[0]); changed, digest = assessment.read(paths[1])
        changed["paired_comparisons"].pop()
        rebuilt = assessment.public.summarize(changed, {"cases": plan["cases"]})
        report.update({key: rebuilt[key] for key in ("requested_cells", "completed_cells", "cell_status_counts", "unique_source_utterances_planned", "comparisons", "cohorts")})
        value = assessment.assess(report, changed, digest, plan)["model_mode_assessments"][0]
        self.assertEqual(value["decision"], "inconclusive_no_promotion")
        with self.assertRaisesRegex(ValueError, "exact matrix"): assessment.assess(report, changed, "0" * 64, plan)
        changed["rows"].append(copy.deepcopy(changed["rows"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"): assessment.assess(report, changed, digest, plan)

    def test_output_is_new_and_runtime_record_paths_are_not_followed(self):
        plan, matrix = self.fixture()
        paths = self.materialize(plan, matrix)
        assessment.write_assessment(*paths, self.root / "assessment")
        before = (self.root / "assessment/assessment.json").read_bytes()
        with self.assertRaises(FileExistsError): assessment.write_assessment(*paths, self.root / "assessment")
        self.assertEqual((self.root / "assessment/assessment.json").read_bytes(), before)
        plan["runtime_record"]["sha256"] = "0" * 64
        report, _ = assessment.read(paths[0]); changed, digest = assessment.read(paths[1])
        with self.assertRaisesRegex(ValueError, "Runtime record"): assessment.assess(report, changed, digest, plan)


if __name__ == "__main__": unittest.main()
