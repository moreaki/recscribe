"""Count-only non-inferiority contracts; no corpus words, audio or inference."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("preservation", Path(__file__).resolve().parents[1] / "quality/quality-preservation.py")
quality = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quality)


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def fixture():
    policy = dict(schema_version="1.0", languages=["en", "zh", "de-CH"], primary_languages=["en", "zh"],
                  word_metric_excluded_languages=["zh"], macro_cer_margin=.005, macro_wer_margin=.01,
                  language_cer_margin=.01, language_wer_margin=.02, paired_sources_per_language=2,
                  bootstrap_draws=100, bootstrap_seed=10410520261110, confidence=.95)
    models = [dict(id="small", kind="pretrained", sha256=sha("parent")),
              dict(id="q4", kind="compression", sha256=sha("q4"), baseline_model_id="small", baseline_model_sha256=sha("parent"))]
    spec = dict(id="q4-vs-f16", intervention="compression", baseline_model_id="small", candidate_model_id="q4",
                baseline_profile_id="matched", candidate_profile_id="matched")
    experiment = dict(models=models, comparisons=[spec], language_modes=["known"], quality_preservation_policy=policy)
    cases, rows = [], []
    for language in policy["languages"]:
        for i in range(2):
            identifier = f"source-{language}-{i}"
            case = dict(id=identifier, language=language, source_channel=0, source_id="original:" + identifier,
                        sha256=sha("audio:" + identifier), reference_sha256=sha("reference:" + identifier), split="held_out",
                        task="standard_rendering" if language == "de-CH" else "transcription")
            cases.append(case)
            for model in models:
                errors = int(model["id"] == "q4")
                measurement = dict(status="completed_with_review", scoring_version="swift-nfc-casefold-alphanumeric-v1")
                for prefix, units, count in (("character", "reference_characters", 200), ("word", "reference_words", 100)):
                    measurement.update({prefix + "_errors": errors, units: count, prefix + "_insertions": 0,
                                        prefix + "_deletions": 0, prefix + "_substitutions": errors})
                row = dict(model=model["id"], model_sha256=model["sha256"], profile="matched", language_mode="known", language=language,
                           id=identifier, source_channel=0, task=case["task"], path="final", repeat=1,
                           status="completed_with_review", source_sha256=case["sha256"], reference_sha256=case["reference_sha256"],
                           scoring_policy="swift-nfc-casefold-alphanumeric-v1", runtime_settings_sha256=sha("runtime"),
                           transcription_runner_sha256=sha("runner"), whisper_binary_sha256=sha("whisper"),
                           profile_sha256=sha("profile"), vad_model_sha256=None, measurement=measurement)
                rows.append(row)
    return dict(split="held_out", rows=rows), dict(cases=cases), experiment


class QualityPreservationTests(unittest.TestCase):
    def test_exact_margin_passes_and_chinese_words_are_excluded(self):
        matrix, corpus, experiment = fixture()
        result = quality.evaluate(matrix, corpus, experiment)
        value = result["comparisons"][0]
        self.assertEqual(value["status"], "pass_exploratory")
        self.assertEqual(value["primary_macro"]["cer"]["point_delta"], .005)
        self.assertEqual(value["primary_macro"]["cer"]["one_sided_upper_delta"], .005)
        self.assertEqual(value["primary_macro"]["wer"]["languages"], ["en"])
        chinese = next(row for row in value["languages"] if row["language"] == "zh")
        self.assertIsNone(chinese["wer"])
        self.assertEqual(chinese["cer"]["candidate"]["substitutions"], 2)
        self.assertIn("NOT_AUTHORIZED", result["product_acceptance"])

    def test_swiss_floor_can_fail_while_primary_macro_passes(self):
        matrix, corpus, experiment = fixture()
        for row in matrix["rows"]:
            if row["model"] == "q4" and row["language"] == "de-CH":
                row["measurement"].update(character_errors=3, character_substitutions=3)
        value = quality.evaluate(matrix, corpus, experiment)["comparisons"][0]
        self.assertEqual(value["primary_macro"]["cer"]["gate"], "pass_exploratory")
        swiss = next(row for row in value["languages"] if row["language"] == "de-CH")
        self.assertEqual(swiss["cer"]["gate"], "fail_exploratory")
        self.assertEqual(value["status"], "fail_exploratory")

    def test_failed_first_result_stays_missing_without_macro_or_later_repeat_replacement(self):
        matrix, corpus, experiment = fixture()
        row = next(row for row in matrix["rows"] if row["model"] == "q4" and row["language"] == "en")
        later = copy.deepcopy(row); later["repeat"] = 2
        row["status"] = "failed"
        matrix["rows"].append(later)
        value = quality.evaluate(matrix, corpus, experiment)["comparisons"][0]
        self.assertEqual(value["status"], "pending")
        self.assertIsNone(value["primary_macro"]["cer"])
        self.assertEqual(value["languages"][0]["paired_source_units"], 1)
        self.assertIsNone(value["languages"][0]["cer"])

    def test_identity_denominator_and_count_mismatches_never_become_a_pair(self):
        for field in ("source_sha256", "reference_sha256", "transcription_runner_sha256", "scoring_policy", "model_sha256"):
            matrix, corpus, experiment = fixture()
            next(row for row in matrix["rows"] if row["model"] == "q4")[field] = sha("different")
            with self.subTest(field=field), self.assertRaises(ValueError):
                quality.evaluate(matrix, corpus, experiment)
        for change in (dict(reference_characters=201), dict(character_errors=9), dict(character_errors=True)):
            matrix, corpus, experiment = fixture()
            next(row for row in matrix["rows"] if row["model"] == "q4")["measurement"].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                quality.evaluate(matrix, corpus, experiment)

    def test_deterministic_order_independent_and_no_mutation_or_resource_quality_upgrade(self):
        matrix, corpus, experiment = fixture()
        before = copy.deepcopy((matrix, corpus, experiment))
        result = quality.evaluate(matrix, corpus, experiment)
        self.assertEqual((matrix, corpus, experiment), before)
        matrix["rows"].reverse(); corpus["cases"].reverse()
        self.assertEqual(quality.evaluate(matrix, corpus, experiment), result)
        matrix["measurement_scope"] = "resources_only"
        resource = quality.evaluate(matrix, corpus, experiment)
        self.assertIn("UNMEASURED", resource["status"])
        self.assertEqual(resource["comparisons"], [])
        matrix.pop("measurement_scope")
        matrix["rows"].append(copy.deepcopy(matrix["rows"][0]))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            quality.evaluate(matrix, corpus, experiment)

    def test_invalid_policy_and_parent_alias_are_rejected(self):
        for field, value in (("bootstrap_draws", 0), ("bootstrap_seed", True), ("confidence", float("nan")),
                             ("macro_cer_margin", -1), ("paired_sources_per_language", 0)):
            matrix, corpus, experiment = fixture()
            experiment["quality_preservation_policy"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                quality.evaluate(matrix, corpus, experiment)
        matrix, corpus, experiment = fixture()
        experiment["models"][1]["sha256"] = experiment["models"][0]["sha256"]
        with self.assertRaises(ValueError):
            quality.evaluate(matrix, corpus, experiment)

    def test_existing_reporter_integrates_count_only_gates_and_keeps_heldout_opt_in(self):
        spec = importlib.util.spec_from_file_location("quality_report_preservation_test", Path(__file__).resolve().parents[1] / "quality/report-pilot.py")
        report = importlib.util.module_from_spec(spec); spec.loader.exec_module(report)
        matrix, corpus, experiment = fixture()
        matrix["freeze_sha256"] = sha("synthetic fixture freeze")
        with self.assertRaisesRegex(ValueError, "Held-out"):
            report.summarize(matrix, corpus, experiment)
        result = report.summarize(matrix, corpus, experiment, allow_held_out=True, freeze_verified=True)
        self.assertEqual(result["quality_preservation"]["comparisons"][0]["status"], "pass_exploratory")
        self.assertIn("Fixed quality preservation gates", report.markdown(result))


if __name__ == "__main__":
    unittest.main()
