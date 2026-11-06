"""Offline round-3 metadata contracts; no audio, models, network or recognizer."""
import copy
import hashlib
import importlib.util
import itertools
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("channel_assessment", Path(__file__).resolve().parents[1] / "quality/assess-channel-balance.py")
channel = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(channel)


def sha(value): return hashlib.sha256(value.encode()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    return hashlib.sha256(path.read_bytes()).hexdigest()


class QualityChannelAssessmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self): self.temporary.cleanup()

    def fixture(self, stage="development", reference=False):
        split, repetitions, count, mode_set = channel.STAGES[stage]
        modes = [v for v in ("known", "auto") if v in mode_set]
        execution = {k: sha(k) for k in ("profile_sha256", "runtime_settings_sha256", "runner_sha256", "whisper_binary_sha256", "corpus_sha256", "configuration_sha256")}
        execution.update(profile_id="current-defaults", vad_model_sha256=None, threads=2)
        if split == "held_out": execution["freeze_sha256"] = sha("heldout-freeze")
        runtime_path = self.root / "runtime.json"
        runtime_hash = write(runtime_path, {"runner_sha256": execution["runner_sha256"],
            "files": [{"path": "/never-open/whisper-cli", "sha256": execution["whisper_binary_sha256"]}]})
        cases = [{"id": language.replace("-", "_") + "-" + str(n), "language": language,
            "task": "standard_rendering" if language == "de-CH" else "transcription", "source_channel": 0,
            "source_sha256": sha(language + str(n)), "reference_sha256": sha("reference-" + language + str(n)),
            "source_id": "published:" + language + ":" + str(n), "code_switches": []}
            for language in channel.LANGUAGES for n in range(count)]
        arms = {role: {"id": "tiny" if role == "original" else "tiny-" + role, "sha256": sha(role),
                      "model_file_bytes": 1000 if role in ("original", "balanced_f16") else 450} for role in channel.ARM_KINDS}
        partition = {"id": "tiny", "kind": "family", "arms": arms,
                     "comparison_ids": {role: "tiny-" + role + "-vs-original" for role in channel.ARM_KINDS if role != "original"}}
        if reference:
            reference_id = reference if isinstance(reference, str) else "large-v3-turbo"
            arms = {"original": {"id": reference_id, "sha256": sha("reference-large"), "model_file_bytes": 2000}}
            partition = {"id": reference_id, "kind": "reference", "model": arms["original"]}
        plan = {"schema_version": channel.PLAN_VERSION, "stage": stage, "split": split, "repetitions": repetitions,
                "language_modes": modes, "cases": cases, "partition": partition, "execution": execution,
                "runtime_record": {"path": str(runtime_path), "sha256": runtime_hash}}
        matrix = {"split": split, "dry_run": False, "threads": 2, **{k: execution[k] for k in ("runner_sha256", "whisper_binary_sha256", "corpus_sha256", "configuration_sha256")},
                  "rows": [], "paired_comparisons": []}
        if split == "held_out": matrix["freeze_sha256"] = execution["freeze_sha256"]
        for case, role, mode, repeat in itertools.product(cases, arms, modes, range(1, repetitions + 1)):
            model = arms[role]; original = arms["original"]
            cer, wer = {"original": (100, 200), "balanced_f16": (100, 200), "plain_q5": (110, 210), "balanced_q5": (99, 199)}[role]
            native = {"engine": "whisper.cpp", "binary_sha256": execution["whisper_binary_sha256"], "model_sha256": model["sha256"],
                "vad_model_sha256": None, "decoding": {"profile_sha256": execution["runtime_settings_sha256"]},
                "asr_language": "auto" if mode == "auto" else case["language"].split("-")[0],
                "command": ["/never-open/whisper-cli", "-l", "auto" if mode == "auto" else case["language"].split("-")[0]],
                "language_policy": {"effective_argument": "auto" if mode == "auto" else case["language"].split("-")[0],
                                    "recognizer_language": case["language"].split("-")[0]}}
            artifact = {"model_file_bytes": model["model_file_bytes"]}
            measurement = {"status": "completed_with_review", "source_sha256": case["source_sha256"], "reference_sha256": case["reference_sha256"],
                "scoring_version": channel.POLICY, "reference_words": 1000, "reference_characters": 1000,
                "word_errors": wer, "wer": wer / 1000, "word_insertions": 0, "word_deletions": 0, "word_substitutions": wer,
                "character_errors": cer, "cer": cer / 1000, "character_insertions": 0, "character_deletions": 0, "character_substitutions": cer,
                "engine_passes": [native], "hypothesis_sha256": sha(case["id"] + mode + ("float-control" if role in ("original", "balanced_f16") else role)),
                "wall_seconds": 1, "source_audio_seconds": 2, "peak_rss_bytes": 10, "artifact_metrics": copy.deepcopy(artifact)}
            matrix["rows"].append({**case, "model": model["id"], "model_sha256": model["sha256"], "model_kind": channel.ARM_KINDS[role],
                "baseline_model_id": original["id"],
                "baseline_model_sha256": original["sha256"], "intervention_id": None if role == "original" else "fixture-" + role,
                "profile": execution["profile_id"], "profile_kind": "candidate", "profile_sha256": execution["profile_sha256"],
                "runtime_settings_sha256": execution["runtime_settings_sha256"], "effective_profile_sha256": execution["runtime_settings_sha256"],
                "transcription_runner_sha256": execution["runner_sha256"], "whisper_binary_sha256": execution["whisper_binary_sha256"],
                "vad_model_sha256": None, "threads": 2, "path": "final", "preparation_policy": "fixture-mono-pcm16",
                "language_mode": mode, "repeat": repeat, "scoring_policy": channel.POLICY, "status": "completed_with_review",
                "artifact_metrics": artifact, "measurement": measurement})
        return plan, matrix

    def materialize(self, plan, matrix, pair_mutation=None):
        partition, execution = plan["partition"], plan["execution"]
        rows = {(v["id"], v["model"], v["language_mode"], v["repeat"]): v for v in matrix["rows"]}
        pairs = []
        if partition["kind"] == "family":
            original = partition["arms"]["original"]
            for role, comparison in partition["comparison_ids"].items():
                candidate = partition["arms"][role]
                for case, mode, repeat in itertools.product(plan["cases"], plan["language_modes"], range(1, plan["repetitions"] + 1)):
                    before, after = [rows.get((case["id"], model["id"], mode, repeat)) for model in (original, candidate)]
                    value = {"id": case["id"], "comparison_id": comparison, "language": case["language"], "task": case["task"],
                        "source_channel": case["source_channel"], "path": "final", "language_mode": mode, "repeat": repeat,
                        "baseline_model": original["id"], "candidate_model": candidate["id"], "candidate_model_sha256": candidate["sha256"],
                        "baseline_profile": execution["profile_id"], "candidate_profile": execution["profile_id"],
                        "intervention": channel.ARM_KINDS[role], "status": "pending_pair"}
                    if before and after and channel.public.completed(before) and channel.public.completed(after):
                        value.update(status="paired_exploratory", baseline_model_sha256=original["sha256"])
                        for metric in ("cer", "wer"):
                            if case["language"] == "zh" and metric == "wer": continue
                            a, b = channel.prior.observation(before, metric), channel.prior.observation(after, metric)
                            value[metric + "_delta"] = b - a if a is not None and b is not None else None
                    pairs.append(value)
        else:
            # Canonical BenchmarkExperiment.paired() fallback: no explicit
            # specifications and no baseline profile leave one pending record
            # per candidate row, without observed deltas/baseline evidence.
            for row in matrix["rows"]:
                if row["profile_kind"] != "candidate": continue
                identity_fields = ("id", "language", "language_mode", "path", "source_sha256", "reference_sha256", "scoring_policy", "task")
                value = {key: row.get(key) for key in ("id", "task", "repeat", "language_mode", "path", "source_channel", "language", "conditions", "coverage_role")}
                value.update(identity="|".join(row[field] for field in identity_fields) + "|" + str(row["source_channel"]) + "|" + str(row["repeat"]),
                    candidate_profile=row["profile"], candidate_model=row["model"], candidate_model_sha256=row["model_sha256"],
                    baseline_model=row["baseline_model_id"], baseline_profile=None, comparison_id=None, intervention="runtime",
                    intervention_id=row["intervention_id"], pairing_contract_version="model-lineage-v2", status="pending_pair")
                pairs.append(value)
        matrix["paired_comparisons"] = pairs
        if pair_mutation is not None: pair_mutation(matrix["paired_comparisons"])
        matrix_path, plan_path, report_path = [self.root / name for name in ("matrix.json", "plan.json", "report.json")]
        matrix_hash = write(matrix_path, matrix); write(plan_path, plan)
        report = channel.public.summarize(matrix, {"cases": plan["cases"]}, allow_held_out=plan["split"] == "held_out", freeze_verified=plan["split"] == "held_out")
        snapshot_fields = [("corpus.original.json", "corpus_sha256"), ("experiment.original.json", "configuration_sha256")]
        if plan["split"] == "held_out": snapshot_fields.append(("freeze.original.json", "freeze_sha256"))
        report.update(source_matrix_sha256=matrix_hash, snapshot_evidence={name: {"status": "verified", "expected_sha256": execution[field], "observed_sha256": execution[field]} for name, field in snapshot_fields})
        write(report_path, report)
        return report, matrix_hash, (report_path, matrix_path, plan_path)

    def assess(self, plan, matrix, pair_mutation=None):
        report, digest, _ = self.materialize(plan, matrix, pair_mutation)
        return channel.assess(report, matrix, digest, plan)

    def change(self, matrix, role, *, language=None, mode=None, repeat=None, cer=None, wer=None):
        name = "tiny" if role == "original" else "tiny-" + role
        for row in matrix["rows"]:
            if row["model"] != name or language is not None and row["language"] != language or mode is not None and row["language_mode"] != mode or repeat is not None and row["repeat"] != repeat: continue
            for metric, prefix, value in (("cer", "character", cer), ("wer", "word", wer)):
                if value is not None: row["measurement"].update({metric: value / 1000, prefix + "_errors": value, prefix + "_substitutions": value})

    def test_four_arms_native_lineage_direct_contrast_and_no_promotion(self):
        plan, matrix = self.fixture(); result = self.assess(plan, matrix); value = result["model_mode_assessments"][0]
        self.assertEqual(value["decision"], "continue_no_promotion")
        self.assertAlmostEqual(value["balanced_q5_vs_plain_q5"]["macro_metrics"]["cer_relative_gain"], .10)
        self.assertEqual(value["coverage"]["planned_inference_cells"], 288)
        self.assertEqual(value["coverage"]["planned_native_parent_pair_cells"], 216)
        self.assertEqual(value["coverage"]["planned_assessor_derived_q5_pair_cells"], 72)
        self.assertEqual(value["native_parent_contrasts"]["plain_q5"]["baseline_model"]["id"], "tiny")
        self.assertEqual(value["balanced_q5_vs_plain_q5"]["baseline_model"]["id"], "tiny-plain_q5")
        self.assertEqual(value["balanced_q5_vs_plain_q5"]["baseline_model_kind"], "compression")
        self.assertAlmostEqual(value["model_file_saving_vs_original"], .55)
        chinese = next(v for v in value["balanced_q5_vs_plain_q5"]["per_language"] if v["language"] == "zh")
        self.assertIsNone(chinese["baseline"]["wer"]); self.assertIsNone(chinese["wer_delta"])
        self.assertFalse(result["default_promotion"]); self.assertEqual(result["native_review"], "PENDING")
        self.assertNotIn("legacy_reference_placeholder_evidence", result)
        self.assertNotIn("legacy_unpaired_reference_placeholders", value["coverage"])
        self.assertEqual(result["product_acceptance"], "PENDING"); self.assertEqual(result["resource_acceptance"], "UNCONTROLLED / NOT EVALUATED")

    def test_both_substantial_gain_targets_and_original_floor_are_independent(self):
        plan, matrix = self.fixture(); self.change(matrix, "balanced_q5", wer=201)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertTrue(value["gates"]["ai_macro_cer_gain_at_least_10_percent"])
        self.assertFalse(value["gates"]["ai_macro_wer_gain_at_least_5_percent"])
        self.assertTrue(value["gates"]["original_macro_wer_increase_at_most_0_005"])
        self.assertEqual(value["decision"], "reject")
        plan, matrix = self.fixture(); self.change(matrix, "plain_q5", cer=220, wer=250); self.change(matrix, "balanced_q5", cer=110, wer=205)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertTrue(value["gates"]["ai_macro_cer_gain_at_least_10_percent"])
        self.assertFalse(value["gates"]["original_macro_cer_increase_at_most_0_0025"])
        self.assertTrue(value["gates"]["original_macro_wer_increase_at_most_0_005"])

    def test_per_language_caps_apply_to_both_controls_with_no_extra_swiss_veto(self):
        plan, matrix = self.fixture(); self.change(matrix, "balanced_q5", wer=190); self.change(matrix, "balanced_q5", language="de-CH", wer=205)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertTrue(value["gates"]["original_de-CH_wer_increase_at_most_0_02"])
        self.assertNotIn("swiss_written_german_wer_no_increase", value["gates"])
        self.assertEqual(value["decision"], "continue_no_promotion")
        plan, matrix = self.fixture(); self.change(matrix, "plain_q5", language="fr", cer=90); self.change(matrix, "balanced_q5", language="fr", cer=105)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertTrue(value["gates"]["original_fr_cer_increase_at_most_0_01"])
        self.assertFalse(value["gates"]["plain_q5_fr_cer_increase_at_most_0_01"])

    def test_missing_failed_or_null_repeat_one_never_becomes_a_pass(self):
        plan, matrix = self.fixture()
        matrix["rows"].remove(next(v for v in matrix["rows"] if v["model"] == "tiny-balanced_q5" and v["language"] == "de"))
        row = next(v for v in matrix["rows"] if v["model"] == "tiny-balanced_q5" and v["language"] == "fr")
        row.update(status="failed", measurement={"status": "failed"})
        row = next(v for v in matrix["rows"] if v["model"] == "tiny-balanced_q5" and v["language"] == "it")
        row["measurement"].update(cer=None, character_errors=None, character_substitutions=None)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertEqual(value["decision"], "inconclusive_no_promotion")
        self.assertIsNone(value["balanced_q5_vs_plain_q5"]["macro_metrics"]["candidate_macro_cer"])
        for language in ("de", "fr", "it"):
            v = next(v for v in value["balanced_q5_vs_plain_q5"]["per_language"] if v["language"] == language)["candidate"]["cer"]
            self.assertEqual(v["observed_scored_utterances"], 7); self.assertIsNone(v["rate"])

    def test_failed_rows_cannot_hide_reference_units_or_runtime_corruption(self):
        for field, value in (("reference_characters", 9999), ("source_sha256", sha("other"))):
            plan, matrix = self.fixture(); row = matrix["rows"][0]
            row["status"] = "failed"; row["measurement"]["status"] = "failed"; row["measurement"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): self.assess(plan, matrix)
        plan, matrix = self.fixture(); row = matrix["rows"][0]; row["status"] = "failed"
        row["measurement"]["status"] = "failed"; row["measurement"]["engine_passes"][0]["model_sha256"] = sha("different")
        with self.assertRaisesRegex(ValueError, "Native engine/model identity"): self.assess(plan, matrix)

    def test_completed_native_language_arguments_must_match_known_case_base(self):
        for field in ("asr_language", "effective_argument", "command"):
            for incorrect in ("fr", "auto", None):
                plan, matrix = self.fixture()
                row = next(v for v in matrix["rows"] if v["language"] == "de-CH")
                native = row["measurement"]["engine_passes"][0]
                target = native["language_policy"] if field == "effective_argument" else native
                target[field] = ["/never-open/whisper-cli", "-l", incorrect] if field == "command" and incorrect is not None else incorrect
                with self.subTest(field=field, incorrect=incorrect), self.assertRaisesRegex(ValueError, "[Nn]ative.*[Aa]rgument|Native asr_language"):
                    self.assess(plan, matrix)

    def test_auto_native_invocation_cannot_contain_an_explicit_language(self):
        for field in ("asr_language", "effective_argument", "command"):
            plan, matrix = self.fixture(stage="panel")
            row = next(v for v in matrix["rows"] if v["language_mode"] == "auto" and v["language"] == "de")
            native = row["measurement"]["engine_passes"][0]
            target = native["language_policy"] if field == "effective_argument" else native
            target[field] = ["/never-open/whisper-cli", "-l", "de"] if field == "command" else "de"
            with self.subTest(field=field), self.assertRaises(ValueError): self.assess(plan, matrix)

    def test_actual_command_is_required_and_unambiguous_even_when_declared_language_matches(self):
        for command in ([], "whisper-cli -l de", ["whisper-cli"], ["whisper-cli", "-l"],
                        ["whisper-cli", "-l", "--other"], ["whisper-cli", "-l", "de", "-l", "de"],
                        ["whisper-cli", "-l", "fr"], ["whisper-cli", "--language=de"]):
            plan, matrix = self.fixture()
            row = next(v for v in matrix["rows"] if v["language"] == "de")
            row["measurement"]["engine_passes"][0]["command"] = command
            with self.subTest(command=command), self.assertRaisesRegex(ValueError, "Native command"):
                self.assess(plan, matrix)

    def test_partial_native_observations_cannot_hide_conflicting_or_malformed_language_arguments(self):
        for field, value in (("asr_language", "auto"), ("effective_argument", "fr"),
                             ("command", ["whisper-cli", "-l", "auto"]), ("command", ["whisper-cli", "-l"]),
                             ("language_policy", "de")):
            plan, matrix = self.fixture()
            row = next(v for v in matrix["rows"] if v["language"] == "de")
            row["status"] = row["measurement"]["status"] = "failed"
            native = row["measurement"]["engine_passes"][0]
            target = native["language_policy"] if field == "effective_argument" else native
            target[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError): self.assess(plan, matrix)
        plan, matrix = self.fixture()
        row = next(v for v in matrix["rows"] if v["language"] == "de")
        row["status"] = row["measurement"]["status"] = "failed"
        native = row["measurement"]["engine_passes"][0]
        for field in ("asr_language", "language_policy", "command"): native.pop(field)
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertEqual(value["decision"], "inconclusive_no_promotion")

    def test_nested_native_pass_language_conflict_is_not_hidden_by_matching_outer_pass(self):
        plan, matrix = self.fixture()
        native = matrix["rows"][0]["measurement"]["engine_passes"][0]
        child = copy.deepcopy(native); child["language_policy"]["effective_argument"] = "auto"
        native["nested"] = [{"provenance": child}]
        with self.assertRaisesRegex(ValueError, "Native effective_argument"): self.assess(plan, matrix)

    def test_quantized_kind_parent_identity_and_measured_bytes_must_match_plan(self):
        for field, value in (("model_kind", "pretrained"), ("baseline_model_id", "tiny-plain_q5"),
                             ("runtime_settings_sha256", sha("other")), ("source_channel", 1)):
            plan, matrix = self.fixture(); row = next(v for v in matrix["rows"] if v["model"] == "tiny-balanced_q5"); row[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): self.assess(plan, matrix)
        plan, matrix = self.fixture()
        for row in matrix["rows"]:
            if row["model"] == "tiny-balanced_q5":
                row["artifact_metrics"]["model_file_bytes"] = 451; row["measurement"]["artifact_metrics"]["model_file_bytes"] = 451
        with self.assertRaisesRegex(ValueError, "model-file bytes"): self.assess(plan, matrix)

    def test_original_rows_require_writer_self_baseline_and_no_intervention(self):
        for field, value in (("baseline_model_id", "tiny-plain_q5"), ("baseline_model_id", None),
                             ("baseline_model_sha256", sha("other")), ("baseline_model_sha256", None),
                             ("intervention_id", "fixture-adaptation")):
            plan, matrix = self.fixture()
            row = next(v for v in matrix["rows"] if v["model"] == "tiny")
            row[field] = value
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, "Original row"):
                self.assess(plan, matrix)

    def test_file_saving_is_actual_bytes_and_missing_observations_are_unknown(self):
        plan, matrix = self.fixture(); plan["partition"]["arms"]["balanced_q5"]["model_file_bytes"] = 501
        for row in matrix["rows"]:
            if row["model"] == "tiny-balanced_q5": row["artifact_metrics"]["model_file_bytes"] = row["measurement"]["artifact_metrics"]["model_file_bytes"] = 501
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertFalse(value["gates"]["model_file_saving_at_least_50_percent"])
        self.assertEqual(value["decision"], "reject")
        plan, matrix = self.fixture()
        for row in matrix["rows"]:
            if row["model"] == "tiny-balanced_q5": row["artifact_metrics"] = None; row["measurement"]["artifact_metrics"] = None
        value = self.assess(plan, matrix)["model_mode_assessments"][0]
        self.assertIsNone(value["model_file_saving_vs_original"]); self.assertEqual(value["decision"], "inconclusive_no_promotion")

    def test_panel_requires_exact_float_control_hashes_and_auto_labels(self):
        plan, matrix = self.fixture(stage="panel"); value = self.assess(plan, matrix)["model_mode_assessments"]
        self.assertTrue(all(v["decision"] == "continue_no_promotion" for v in value))
        row = next(v for v in matrix["rows"] if v["model"] == "tiny-balanced_f16" and v["language_mode"] == "known" and v["repeat"] == 1)
        row["measurement"]["hypothesis_sha256"] = sha("changed")
        row = next(v for v in matrix["rows"] if v["model"] == "tiny-balanced_f16" and v["language_mode"] == "auto" and v["repeat"] == 1)
        row["measurement"]["engine_passes"][0]["language_policy"]["recognizer_language"] = "fr"
        values = self.assess(plan, matrix)["model_mode_assessments"]
        self.assertTrue(all(v["decision"] == "inconclusive_no_promotion" for v in values))
        self.assertTrue(all(v["balanced_f16_control"]["status"] == "inconclusive_no_promotion" for v in values))

    def test_panel_repeat_one_failure_does_not_fall_back_to_completed_repeats(self):
        plan, matrix = self.fixture(stage="panel")
        row = next(v for v in matrix["rows"] if v["model"] == "tiny-balanced_f16" and v["language_mode"] == "known" and v["repeat"] == 1)
        row.update(status="failed", measurement={"status": "failed"})
        values = {v["language_mode"]: v for v in self.assess(plan, matrix)["model_mode_assessments"]}
        self.assertEqual(values["known"]["decision"], "inconclusive_no_promotion")
        self.assertEqual(values["known"]["balanced_f16_control"]["unknown_hypothesis_cases"], 1)
        self.assertEqual(values["auto"]["decision"], "continue_no_promotion")

    def test_panel_later_repeat_mismatch_still_invalidates_mechanism_control(self):
        plan, matrix = self.fixture(stage="panel")
        row = next(v for v in matrix["rows"] if v["model"] == "tiny-balanced_f16" and v["language_mode"] == "known" and v["repeat"] == 3)
        row["measurement"]["hypothesis_sha256"] = sha("later mismatch")
        row = next(v for v in matrix["rows"] if v["model"] == "tiny-balanced_f16" and v["language_mode"] == "auto" and v["repeat"] == 2)
        row["measurement"]["engine_passes"][0]["language_policy"]["recognizer_language"] = "fr"
        for value in self.assess(plan, matrix)["model_mode_assessments"]:
            self.assertEqual(value["decision"], "inconclusive_no_promotion")
            self.assertEqual(value["balanced_f16_control"]["required_repeats"], [1, 2, 3])
            self.assertEqual(value["balanced_f16_control"]["planned_hypothesis_pairs"], 27)
            self.assertEqual(value["balanced_f16_control"]["unique_source_utterances"], 9)

    def test_auto_transitions_are_independent_against_original_and_plain_q5(self):
        plan, matrix = self.fixture(stage="held_out")
        for row in matrix["rows"]:
            if row["repeat"] != 1 or row["language_mode"] != "auto" or not row["id"].endswith("-0"): continue
            native = row["measurement"]["engine_passes"][0]
            if row["language"] == "en" and row["model"] == "tiny": native["language_policy"]["recognizer_language"] = "fr"
            if row["language"] == "en" and row["model"] == "tiny-balanced_q5": native["language_policy"]["recognizer_language"] = "de"
            if row["language"] == "ar" and row["model"] == "tiny-balanced_q5":
                native["language_policy"]["recognizer_language"] = None; row["measurement"]["hypothesis_sha256"] = channel.prior.EMPTY
        values = {v["language_mode"]: v for v in self.assess(plan, matrix)["model_mode_assessments"]}
        self.assertEqual(values["known"]["decision"], "continue_no_promotion")
        auto = values["auto"]
        self.assertIsNone(auto["gates"]["original_no_new_wrong_auto_base_labels"])
        self.assertFalse(auto["gates"]["plain_q5_no_new_wrong_auto_base_labels"])
        self.assertEqual(auto["balanced_q5_vs_plain_q5"]["auto_labels"]["newly_wrong_cases"], 1)
        self.assertEqual(auto["balanced_q5_vs_plain_q5"]["auto_labels"]["unknown_cases"], 1)
        self.assertEqual(auto["decision"], "reject")

    def test_large_reference_partitions_have_no_native_or_derived_q5_pairs(self):
        plan, matrix = self.fixture(stage="held_out", reference=True); result = self.assess(plan, matrix)
        self.assertEqual(result["partition_assessment"]["decision"], "reference_observed_no_promotion")
        for value in result["model_mode_assessments"]:
            self.assertEqual(value["coverage"]["planned_native_parent_pair_cells"], 0)
            self.assertEqual(value["coverage"]["completed_native_parent_pair_cells"], 0)
            self.assertEqual(value["coverage"]["legacy_unpaired_reference_placeholders"], 144)
            self.assertNotIn("balanced_q5_vs_plain_q5", value)
            self.assertNotIn("canonical_row_pairs", value["reference_metrics"])
            self.assertEqual(value["reference_metrics"]["per_language"][0]["cer"]["planned_utterances"], 16)

    def test_both_large_panel_writer_placeholders_are_separate_unpaired_evidence(self):
        for model in ("large-v3-turbo", "large-v3"):
            with self.subTest(model=model):
                plan, matrix = self.fixture(stage="panel", reference=model)
                result = self.assess(plan, matrix)
                evidence = result["legacy_reference_placeholder_evidence"]
                self.assertEqual(len(matrix["rows"]), 54)
                self.assertEqual(len(matrix["paired_comparisons"]), 54)
                self.assertEqual(evidence["observed_placeholder_cells"], 54)
                self.assertEqual(evidence["native_parent_pair_cells"], 0)
                self.assertEqual(evidence["assessor_derived_q5_pair_cells"], 0)
                self.assertEqual(evidence["counts_by_language_mode"], {"known": 27, "auto": 27})
                self.assertEqual(len(evidence["cell_identities"]), 54)
                self.assertTrue(all(p["comparison_id"] is None and p["baseline_profile"] is None and p["status"] == "pending_pair" for p in matrix["paired_comparisons"]))
                self.assertEqual(result["partition_assessment"]["decision"], "reference_observed_no_promotion")
                self.assertFalse(result["default_promotion"])

    def test_pinned_reference_writer_cannot_omit_all_legacy_placeholders(self):
        plan, matrix = self.fixture(stage="panel", reference=True)
        with self.assertRaisesRegex(ValueError, "placeholder grid"):
            self.assess(plan, matrix, lambda pairs: pairs.clear())

    def test_reference_placeholders_reject_real_pairs_deltas_or_changed_identity(self):
        mutations = (("status", "paired_exploratory"), ("comparison_id", "real-comparison"), ("baseline_profile", "current-defaults"),
            ("intervention_id", "adaptation"), ("intervention", "combined"), ("pairing_contract_version", "other"),
            ("candidate_model", "tiny"), ("baseline_model", "tiny"), ("candidate_model_sha256", sha("other")), ("candidate_profile", "other"),
            ("identity", "forged"), ("source_channel", 1), ("language", "fr"), ("task", "transcription"), ("path", "live-replay"),
            ("repeat", True), ("repeat", 0), ("repeat", 4), ("id", "unknown"), ("language_mode", "unknown"),
            ("cer_delta", 0), ("baseline_model_sha256", None), ("candidate_artifact_metrics", {}), ("critical_content_review", "unmeasured"), ("reason", "other"))
        for field, value in mutations:
            plan, matrix = self.fixture(stage="panel", reference=True)
            report, _, _ = self.materialize(plan, matrix)
            matrix["paired_comparisons"][0][field] = value
            digest = write(self.root / "matrix.json", matrix)
            report["source_matrix_sha256"] = digest
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, "[Pp]laceholder"):
                channel.assess(report, matrix, digest, plan)

    def test_reference_placeholder_missing_duplicate_or_extra_cells_reject(self):
        for change in ("missing_field", "missing_cell", "duplicate", "extra_cell"):
            plan, matrix = self.fixture(stage="panel", reference=True)
            def mutate(pairs):
                if change == "missing_field": pairs[0].pop("baseline_profile")
                elif change == "missing_cell": pairs.pop()
                elif change == "duplicate": pairs.append(copy.deepcopy(pairs[0]))
                else:
                    pairs.append(copy.deepcopy(pairs[0])); pairs[-1]["id"] = "foreign"
            with self.subTest(change=change), self.assertRaises(ValueError): self.assess(plan, matrix, mutate)

    def test_reference_placeholders_never_repair_failed_quality_coverage(self):
        plan, matrix = self.fixture(stage="panel", reference=True)
        row = next(v for v in matrix["rows"] if v["language_mode"] == "known" and v["repeat"] == 1)
        row["status"] = row["measurement"]["status"] = "failed"
        result = self.assess(plan, matrix)
        values = {v["language_mode"]: v for v in result["model_mode_assessments"]}
        self.assertEqual(values["known"]["coverage"]["legacy_unpaired_reference_placeholders"], 27)
        self.assertEqual(values["known"]["decision"], "inconclusive_no_promotion")
        self.assertEqual(values["known"]["coverage"]["completed_native_parent_pair_cells"], 0)
        self.assertEqual(values["auto"]["decision"], "reference_observed_no_promotion")

    def test_family_cannot_accept_a_legacy_reference_placeholder(self):
        reference_plan, reference_matrix = self.fixture(stage="panel", reference=True)
        self.materialize(reference_plan, reference_matrix)
        placeholder = copy.deepcopy(reference_matrix["paired_comparisons"][0])
        plan, matrix = self.fixture(stage="panel")
        with self.assertRaises(ValueError): self.assess(plan, matrix, lambda pairs: pairs.append(placeholder))

    def test_expected_grids_reject_duplicates_unknown_repeats_and_derived_native_pairs(self):
        for change in ("duplicate", "repeat", "derived_pair"):
            plan, matrix = self.fixture(); report, digest, _ = self.materialize(plan, matrix)
            if change == "duplicate": matrix["rows"].append(copy.deepcopy(matrix["rows"][0]))
            elif change == "repeat": matrix["rows"][0]["repeat"] = 3
            else: matrix["paired_comparisons"][0]["baseline_model"] = "tiny-plain_q5"
            with self.subTest(change=change), self.assertRaises(ValueError): channel.assess(report, matrix, digest, plan)

    def test_complete_report_and_snapshots_reconcile_to_the_exact_matrix(self):
        for change in ("matrix_hash", "cohort", "snapshot", "runtime"):
            plan, matrix = self.fixture(stage="held_out"); report, digest, _ = self.materialize(plan, matrix)
            if change == "matrix_hash": report["source_matrix_sha256"] = sha("other")
            elif change == "cohort": report["cohorts"][0]["quality"]["cer"]["errors"] += 1
            elif change == "snapshot": report["snapshot_evidence"]["freeze.original.json"]["observed_sha256"] = sha("other")
            else: plan["runtime_record"]["sha256"] = sha("other")
            with self.subTest(change=change), self.assertRaises(ValueError): channel.assess(report, matrix, digest, plan)

    def test_plan_stage_counts_repeats_and_positive_exact_artifacts_are_fixed(self):
        for field, value in (("repetitions", 3), ("repetitions", True), ("stage", "old-round")):
            plan, _ = self.fixture(); plan[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError): channel.validate_plan(plan)
        plan, _ = self.fixture(); plan["cases"].pop()
        with self.assertRaises(ValueError): channel.validate_plan(plan)
        plan, _ = self.fixture(); plan["partition"]["arms"]["plain_q5"]["model_file_bytes"] = True
        with self.assertRaises(ValueError): channel.validate_plan(plan)

    def test_strict_metadata_reader_and_new_external_output_preserve_evidence(self):
        path = self.root / "duplicate.json"; path.write_text('{"x":1,"x":2}')
        with self.assertRaisesRegex(ValueError, "Duplicate JSON"): channel.read(path)
        alias = self.root / "alias.json"; alias.symlink_to(path)
        with self.assertRaisesRegex(ValueError, "Symlink"): channel.read(alias)
        plan, matrix = self.fixture(); _, _, paths = self.materialize(plan, matrix)
        result = channel.write_assessment(*paths, self.root / "out")
        self.assertEqual(result["schema_version"], channel.VERSION)
        self.assertFalse(result["default_promotion"])
        self.assertEqual(result["evidence"]["report_sha256"], hashlib.sha256(paths[0].read_bytes()).hexdigest())
        with self.assertRaises(FileExistsError): channel.write_assessment(*paths, self.root / "out")


if __name__ == "__main__": unittest.main()
