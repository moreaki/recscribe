#!/usr/bin/env python3
"""Assess frozen round-3 metadata without ASR, rescoring or raw-evidence reads.

CLI: assess-channel-balance.py REPORT --matrix MATRIX --plan PLAN --output NEW
Reads only those three absolute JSON files and the plan's hashed runtime_record.
Audio/reference/hypothesis/model/library/log paths inside them are never followed.

Plan schema: channel-balance-assessment-plan-v1. stage is panel/development/held_out;
split is development/development/held_out; repeats are 3/1/1; language modes are
known+auto/known/known+auto. Cases use the existing explicit source identity fields,
with 1/8/16 cases per language. execution and runtime_record match the round-2 API.

One partition per plan:
  {id: tiny|base|small, kind: family,
   arms: {original, balanced_f16, plain_q5, balanced_q5},
   comparison_ids: {balanced_f16, plain_q5, balanced_q5}}
or {id: large-v3-turbo|large-v3, kind: reference, model: MODEL}.
Every MODEL has unique id, exact sha256 and positive model_file_bytes. The native
runner kinds are pretrained/conversion_control/compression/combined respectively.
Native pairs are exclusively each derived arm against original. The assessor
derives the independent balanced_q5/plain_q5 contrast from the same canonical rows.
Neither quantized arm is relabelled as an untouched pretrained control.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import importlib.util
import itertools
import json
from pathlib import Path
import re

SPEC = importlib.util.spec_from_file_location("prior_affine_assessment", Path(__file__).with_name("assess-affine-pilot.py"))
prior = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prior)
public = prior.public
read, require, valid_hash, equivalent = prior.read, prior.require, prior.valid_hash, prior.equivalent
native_identities, reference_units, counted, automatic = prior.native_identities, prior.reference_units, prior.counted, prior.automatic
LANGUAGES, POLICY = prior.LANGUAGES, prior.POLICY
VERSION = "channel-balance-assessment-v1"
PLAN_VERSION = "channel-balance-assessment-plan-v1"
ARM_KINDS = {"original": "pretrained", "balanced_f16": "conversion_control", "plain_q5": "compression", "balanced_q5": "combined"}
STAGES = {"panel": ("development", 3, 1, {"known", "auto"}),
          "development": ("development", 1, 8, {"known"}),
          "held_out": ("held_out", 1, 16, {"known", "auto"})}


def safe_id(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,200}", value) is not None


def validate_plan(plan):
    require(isinstance(plan, dict) and plan.get("schema_version") == PLAN_VERSION and isinstance(plan.get("stage"), str)
            and plan["stage"] in STAGES, "Unsupported channel assessment plan/stage")
    split, repeats, per_language, modes = STAGES[plan["stage"]]
    require(plan.get("split") == split and type(plan.get("repetitions")) is int and plan["repetitions"] == repeats,
            "Stage requires its frozen split and repeat count (panel 3, quality 1)")
    requested_modes = plan.get("language_modes")
    require(isinstance(requested_modes, list) and all(isinstance(v, str) for v in requested_modes)
            and len(requested_modes) == len(set(requested_modes)) and set(requested_modes) == modes,
            "Stage requires its exact frozen language modes")
    cases = plan.get("cases")
    require(isinstance(cases, list) and len(cases) == 9 * per_language and all(isinstance(v, dict) for v in cases), "Incorrect fixed stage case count")
    require(all(isinstance(v.get("language"), str) for v in cases)
            and Counter(v.get("language") for v in cases) == Counter({language: per_language for language in LANGUAGES}), "Incomplete nine-language case coverage")
    ids, sources = set(), set()
    source_hashes, reference_hashes = set(), set()
    for case in cases:
        require(safe_id(case.get("id")) and case["id"] not in ids, "Unsafe/duplicate planned case ID")
        ids.add(case["id"])
        require(case.get("task") == ("standard_rendering" if case["language"] == "de-CH" else "transcription"), "Unexpected planned task")
        require(type(case.get("source_channel")) is int and case["source_channel"] >= 0, "Explicit source channel required")
        require(valid_hash(case.get("source_sha256")) and valid_hash(case.get("reference_sha256")), "Source/reference hashes required")
        require(case["source_sha256"] not in source_hashes and case["reference_sha256"] not in reference_hashes, "Repeated planned source/reference hashes cannot inflate source coverage")
        source_hashes.add(case["source_sha256"]); reference_hashes.add(case["reference_sha256"])
        require(isinstance(case.get("source_id"), str) and case["source_id"].strip() and case["source_id"] not in sources, "Unique original source IDs required")
        sources.add(case["source_id"])
    partition = plan.get("partition", {})
    require(isinstance(partition, dict) and isinstance(partition.get("kind"), str)
            and partition["kind"] in {"family", "reference"}, "One explicit family/reference partition required")
    if partition["kind"] == "family":
        require(partition.get("id") in {"tiny", "base", "small"}, "Unsupported small-model family")
        arms = partition.get("arms", {})
        comparisons = partition.get("comparison_ids", {})
        require(isinstance(arms, dict) and set(arms) == set(ARM_KINDS), "Family requires all four fixed arms")
        require(isinstance(comparisons, dict) and set(comparisons) == set(ARM_KINDS) - {"original"}
                and all(safe_id(v) for v in comparisons.values()) and len(set(comparisons.values())) == 3, "Three unique native parent comparisons required")
    else:
        require(partition.get("id") in {"large-v3-turbo", "large-v3"}, "Unsupported large reference")
        require(not partition.get("arms") and not partition.get("comparison_ids"), "Reference partitions have no derived arms or native pairs")
        arms, comparisons = {"original": partition.get("model", {})}, {}
    models = {}
    for role, model in arms.items():
        require(isinstance(model, dict) and safe_id(model.get("id")) and model["id"] not in models
                and valid_hash(model.get("sha256")) and type(model.get("model_file_bytes")) is int
                and model["model_file_bytes"] > 0, "Every arm needs a unique ID, exact hash and positive file bytes")
        models[model["id"]] = {**model, "role": role, "kind": ARM_KINDS[role]}
    if partition["kind"] == "family":
        require(arms["original"]["model_file_bytes"] == arms["balanced_f16"]["model_file_bytes"], "Balanced F16 must retain original file size")
    execution = plan.get("execution", {})
    require(isinstance(execution, dict), "Execution identity object required")
    for field in ("profile_sha256", "runtime_settings_sha256", "runner_sha256", "whisper_binary_sha256", "corpus_sha256", "configuration_sha256"):
        require(valid_hash(execution.get(field)), "Missing execution checksum: " + field)
    require(safe_id(execution.get("profile_id")) and execution.get("vad_model_sha256") is None
            and type(execution.get("threads")) is int and execution["threads"] == 2, "Require one explicit no-VAD two-thread profile")
    if split == "held_out": require(valid_hash(execution.get("freeze_sha256")), "Held-out family freeze hash required")
    require(isinstance(plan.get("runtime_record"), dict) and isinstance(plan["runtime_record"].get("path"), str)
            and valid_hash(plan["runtime_record"].get("sha256")), "Hashed runtime record required")
    return {case["id"]: case for case in cases}, models, comparisons


def measured_bytes(row, expected):
    """Compare every observed size, including partial failed-row observations."""
    measurement = row.get("measurement") or {}
    observations = []
    for metrics in (row.get("artifact_metrics"), measurement.get("artifact_metrics")):
        if metrics is None: continue
        require(isinstance(metrics, dict), "Invalid artifact metrics")
        value = metrics.get("model_file_bytes")
        if value is None: continue
        require(type(value) is int and value > 0 and value == expected, "Observed model-file bytes disagree with frozen arm")
        observations.append(value)
    return expected if observations else None


def native_language_arguments(value, row):
    """Validate invocation evidence, independently of recognizer output labels.

    Failed rows may have no native invocation yet. Any invocation fields they do
    retain must agree; a failure cannot hide a conflicting configured language.
    Completed native passes require all three actual invocation observations.
    """
    expected = "auto" if row["language_mode"] == "auto" else row["language"].split("-", 1)[0]
    completed = public.completed(row)
    if isinstance(value, dict):
        if value.get("engine") == "whisper.cpp":
            language = value.get("asr_language")
            require(language is None and not completed or language == expected,
                    "Native asr_language disagrees with planned language argument")
            policy = value.get("language_policy")
            require(policy is None and not completed or isinstance(policy, dict),
                    "Native language_policy invocation evidence missing/malformed")
            effective = policy.get("effective_argument") if isinstance(policy, dict) else None
            require(effective is None and not completed or effective == expected,
                    "Native effective_argument disagrees with planned language argument")
            command = value.get("command")
            if command is None:
                require(not completed, "Completed native pass lacks actual command language argument")
            else:
                require(isinstance(command, list) and command and all(isinstance(v, str) for v in command)
                        and command[0], "Native command invocation evidence malformed")
                arguments = []
                for index, argument in enumerate(command[1:], 1):
                    if argument in ("-l", "--language"):
                        require(index + 1 < len(command) and command[index + 1]
                                and not command[index + 1].startswith("-"), "Native command language argument malformed")
                        arguments.append(command[index + 1])
                    elif argument.startswith("--language=") or argument.startswith("-l="):
                        # The recorded native adapter uses separate flag/value
                        # elements. Do not infer support for another CLI syntax.
                        require(False, "Native command language argument malformed")
                require(len(arguments) == 1 and arguments[0] == expected,
                        "Native command language argument missing/ambiguous or disagrees with planned language argument")
        for child in value.values(): native_language_arguments(child, row)
    elif isinstance(value, list):
        for child in value: native_language_arguments(child, row)


def validate_measurement(row, execution, model_hash):
    measurement = row.get("measurement")
    require(measurement is None or isinstance(measurement, dict), "Invalid measurement object")
    if measurement is None: return
    for observed, declared in (("source_sha256", "source_sha256"), ("reference_sha256", "reference_sha256"), ("scoring_version", "scoring_policy")):
        require(measurement.get(observed) is None or measurement[observed] == row[declared], "Measured source/scorer identity mismatch")
    observations = native_identities(measurement.get("engine_passes"), execution, model_hash)
    native_language_arguments(measurement.get("engine_passes"), row)
    if public.completed(row):
        require(observations > 0, "Completed row lacks native identity evidence")
        require(all(measurement.get(a) == row[b] for a, b in (("source_sha256", "source_sha256"), ("reference_sha256", "reference_sha256"), ("scoring_version", "scoring_policy"))), "Completed row lacks measured source/scorer identity")
    for metric, prefix in (("wer", "word"), ("cer", "character")):
        denominator = "reference_words" if metric == "wer" else "reference_characters"
        fields = [prefix + "_errors", denominator] + [prefix + "_" + op for op in ("insertions", "deletions", "substitutions")]
        for field in fields:
            require(measurement.get(field) is None or type(measurement[field]) is int and measurement[field] >= 0, "Invalid scoring count/denominator")
        rate = measurement.get(metric)
        require(rate is None or public.finite_number(rate) and rate >= 0, "Invalid lexical rate")
        errors, units = measurement.get(prefix + "_errors"), measurement.get(denominator)
        if rate is not None and errors is not None and units is not None and units > 0:
            require(equivalent(rate, errors / units), "Retained lexical rate disagrees with counted units")
        operations = [measurement.get(prefix + "_" + op) for op in ("insertions", "deletions", "substitutions")]
        if errors is not None and all(v is not None for v in operations): require(sum(operations) == errors, "Edit operations disagree with total errors")


def reference_placeholder(pair, rows, original, execution):
    """Validate only the runner's unpaired runtime fallback for a reference row.

    With no explicit comparisons or baseline profile, paired() emits one of
    these records per candidate row. It is not an observed parent comparison.
    """
    fields = {"identity", "candidate_profile", "id", "task", "repeat", "language_mode", "path", "source_channel",
              "candidate_model", "candidate_model_sha256", "baseline_model", "baseline_profile", "comparison_id",
              "intervention", "intervention_id", "language", "conditions", "coverage_role", "pairing_contract_version", "status"}
    require(isinstance(pair, dict) and set(pair) == fields, "Malformed legacy reference placeholder fields")
    require(pair["status"] == "pending_pair" and pair["comparison_id"] is None and pair["baseline_profile"] is None
            and pair["intervention_id"] is None and pair["intervention"] == "runtime"
            and pair["pairing_contract_version"] == "model-lineage-v2", "Malformed legacy reference placeholder status/lineage")
    require(all(isinstance(pair[k], str) for k in ("id", "candidate_model", "language_mode")) and type(pair["repeat"]) is int,
            "Malformed legacy reference placeholder cell")
    key = (pair["id"], pair["candidate_model"], pair["language_mode"], pair["repeat"])
    row = rows.get(key)
    require(row is not None and row.get("profile_kind") == "candidate", "Legacy reference placeholder lacks its canonical candidate row")
    require(pair["baseline_model"] == pair["candidate_model"] == original["id"]
            and pair["candidate_model_sha256"] == original["sha256"] and pair["candidate_profile"] == execution["profile_id"],
            "Legacy reference placeholder changes original model/profile identity")
    for field in ("id", "task", "repeat", "language_mode", "path", "source_channel", "language", "conditions", "coverage_role"):
        require(type(pair[field]) is type(row.get(field)) and pair[field] == row.get(field), "Legacy reference placeholder source/cell identity differs")
    identity_fields = ("id", "language", "language_mode", "path", "source_sha256", "reference_sha256", "scoring_policy", "task")
    identity = "|".join(row[field] for field in identity_fields) + "|" + str(row["source_channel"]) + "|" + str(row["repeat"])
    require(pair["identity"] == identity, "Legacy reference placeholder identity string differs")
    return key


def validate_inputs(report, matrix, matrix_hash, plan):
    cases, models, comparisons = validate_plan(plan)
    require(isinstance(report, dict) and isinstance(matrix, dict), "Report and matrix must be JSON objects")
    execution, partition = plan["execution"], plan["partition"]
    require(report.get("schema_version") == public.VERSION == "quality-pilot-report-1.1", "Public report 1.1 required")
    require(report.get("source_matrix_sha256") == matrix_hash, "Report does not bind exact matrix bytes")
    require(matrix.get("split") == plan["split"] and matrix.get("dry_run") is False and type(matrix.get("threads")) is int and matrix["threads"] == 2, "Matrix execution scope mismatch")
    for field in ("corpus_sha256", "configuration_sha256", "runner_sha256", "whisper_binary_sha256"):
        require(matrix.get(field) == execution[field] and report.get("provenance", {}).get(field) == execution[field], "Frozen matrix/report identity mismatch: " + field)
    snapshots = [("corpus.original.json", "corpus_sha256"), ("experiment.original.json", "configuration_sha256")]
    if plan["split"] == "held_out":
        require(matrix.get("freeze_sha256") == execution["freeze_sha256"] and report.get("provenance", {}).get("freeze_sha256") == execution["freeze_sha256"], "Held-out freeze identity mismatch")
        snapshots.append(("freeze.original.json", "freeze_sha256"))
    for filename, field in snapshots:
        observed = report.get("snapshot_evidence", {}).get(filename, {})
        require(observed.get("status") == "verified" and observed.get("expected_sha256") == observed.get("observed_sha256") == execution[field], "Verified snapshot attestation missing/mismatched")
    runtime, runtime_hash = read(plan["runtime_record"]["path"])
    require(runtime_hash == plan["runtime_record"]["sha256"] and runtime.get("runner_sha256") == execution["runner_sha256"], "Runtime record identity mismatch")
    require(any(v.get("sha256") == execution["whisper_binary_sha256"] and v.get("path", "").endswith("/whisper-cli") for v in runtime.get("files", [])), "Runtime record lacks planned whisper-cli")
    expected = set(itertools.product(cases, models, plan["language_modes"], range(1, plan["repetitions"] + 1)))
    rows, units, byte_evidence, preparations = {}, {}, {}, set()
    require(isinstance(matrix.get("rows"), list), "Matrix rows required")
    original = partition["arms"]["original"] if partition["kind"] == "family" else partition["model"]
    for row in matrix["rows"]:
        require(isinstance(row, dict) and all(isinstance(row.get(v), str) for v in ("id", "model", "language_mode")) and type(row.get("repeat")) is int, "Invalid inference cell identity")
        key = (row["id"], row["model"], row["language_mode"], row["repeat"])
        require(key in expected and key not in rows, "Unexpected/duplicate matrix inference cell")
        case, model = cases[key[0]], models[key[1]]
        for field in ("language", "task", "source_channel", "source_sha256", "reference_sha256"):
            require(type(row.get(field)) is type(case[field]) and row[field] == case[field], "Planned source identity mismatch: " + field)
        require(row.get("model_sha256") == model["sha256"] and row.get("model_kind") == model["kind"], "Arm artifact hash/kind mismatch; quantized is not untouched")
        if model["role"] == "original":
            # The runner records a canonical row's own untouched artifact as its
            # comparison baseline; this is not configuration adaptation lineage.
            require(row.get("baseline_model_id") == model["id"] and row.get("baseline_model_sha256") == model["sha256"]
                    and row.get("intervention_id") is None, "Original row must retain its own baseline identity without intervention")
        else:
            require(row.get("baseline_model_id") == original["id"] and row.get("baseline_model_sha256") == original["sha256"] and safe_id(row.get("intervention_id")), "Each derived arm must retain its original F16 parent")
        require(row.get("path") == "final" and row.get("profile") == execution["profile_id"] and row.get("scoring_policy") == POLICY, "Row path/profile/scoring mismatch")
        for field, value in (("profile_sha256", execution["profile_sha256"]), ("runtime_settings_sha256", execution["runtime_settings_sha256"]),
                            ("effective_profile_sha256", execution["runtime_settings_sha256"]), ("whisper_binary_sha256", execution["whisper_binary_sha256"]),
                            ("transcription_runner_sha256", execution["runner_sha256"]), ("vad_model_sha256", None), ("threads", 2)):
            require(type(row.get(field)) is type(value) and row[field] == value, "Row runtime identity mismatch: " + field)
        preparation = row.get("preparation_policy")
        require(isinstance(preparation, str) and preparation, "Explicit shared preparation policy required")
        preparations.add(preparation); require(len(preparations) == 1, "Shared audio preparation differs across arms/repeats")
        reference_units(row, units, len(cases) * 2)
        validate_measurement(row, execution, model["sha256"])
        byte_evidence[key] = measured_bytes(row, model["model_file_bytes"])
        rows[key] = row
    expected_pairs = set(itertools.product(comparisons.values(), cases, plan["language_modes"], range(1, plan["repetitions"] + 1)))
    pair_roles = {value: role for role, value in comparisons.items()}
    pairs, placeholders = {}, {}
    require(isinstance(matrix.get("paired_comparisons"), list), "Explicit native parent-pair array required")
    for pair in matrix["paired_comparisons"]:
        if partition["kind"] == "reference":
            key = reference_placeholder(pair, rows, original, execution)
            require(key not in placeholders, "Duplicate legacy reference placeholder")
            placeholders[key] = pair
            continue
        require(isinstance(pair, dict) and all(isinstance(pair.get(v), str) for v in ("comparison_id", "id", "language_mode")) and type(pair.get("repeat")) is int, "Invalid parent pair identity")
        key = (pair["comparison_id"], pair["id"], pair["language_mode"], pair["repeat"])
        require(key in expected_pairs and key not in pairs, "Unexpected/duplicate native pair; derived-to-derived native pairs are prohibited")
        role, case = pair_roles[key[0]], cases[key[1]]
        candidate = partition["arms"][role]
        require(pair.get("baseline_model") == original["id"] and pair.get("candidate_model") == candidate["id"] and pair.get("intervention") == ARM_KINDS[role], "Native comparison must retain actual original-parent lineage/kind")
        for side, model in (("baseline", original), ("candidate", candidate)):
            observed = pair.get(side + "_model_sha256")
            require(observed is None and pair.get("status") != "paired_exploratory" or observed == model["sha256"], "Pair artifact checksum mismatch")
            require(pair.get(side + "_profile") in (execution["profile_id"], None) and (pair.get("status") != "paired_exploratory" or pair.get(side + "_profile") == execution["profile_id"]), "Pair runtime profile mismatch")
        for field in ("language", "task", "source_channel"):
            require(type(pair.get(field)) is type(case[field]) and pair[field] == case[field], "Pair source identity mismatch")
        require(pair.get("path") == "final", "Pair input path mismatch")
        if pair.get("status") == "paired_exploratory":
            before, after = [rows.get((key[1], model["id"], key[2], key[3])) for model in (original, candidate)]
            require(before is not None and after is not None and public.completed(before) and public.completed(after), "Paired status lacks completed canonical inputs")
            for metric in ("wer", "cer"):
                if metric == "wer" and case["language"] == "zh": continue
                a, b = prior.observation(before, metric), prior.observation(after, metric)
                require(equivalent(pair.get(metric + "_delta"), b - a if a is not None and b is not None else None), "Native pair metric delta mismatch")
        pairs[key] = pair
    require(partition["kind"] != "reference" or set(placeholders) == set(rows), "Legacy reference placeholder grid must match all retained canonical rows")
    rebuilt = public.summarize(matrix, {"cases": list(cases.values())}, allow_held_out=plan["split"] == "held_out", freeze_verified=plan["split"] == "held_out")
    for field in ("requested_cells", "completed_cells", "cell_status_counts", "unique_source_utterances_planned", "comparisons"):
        require(equivalent(report.get(field), rebuilt[field]), "Public report disagrees with matrix: " + field)
    def index(cohorts): return {tuple(v.get(k) for k in public.GROUP_FIELDS): v for v in cohorts}
    actual, expected_cohorts = index(report.get("cohorts", [])), index(rebuilt["cohorts"])
    require(len(actual) == len(report.get("cohorts", [])) and actual.keys() == expected_cohorts.keys(), "Missing/duplicate report cohort")
    for key, cohort in actual.items():
        for field in ("model_kind", "baseline_model_id", "baseline_model_sha256", "coverage_role", "requested_cells", "cell_status_counts", "quality", "timing", "peak_process_rss_bytes", "artifact_metrics", "utterance_repeats"):
            require(equivalent(cohort.get(field), expected_cohorts[key][field]), "Public cohort disagrees with matrix: " + field)
    return cases, models, rows, pairs, expected, expected_pairs, byte_evidence, placeholders


def row_contrast(plan, cases, rows, mode, baseline, candidate):
    """A matched contrast never changes either arm's retained native lineage."""
    per_language, labels, hypotheses = [], [], []
    for language in LANGUAGES:
        selected = [case for case in cases.values() if case["language"] == language]
        value = {"language": language}
        for side, model in (("baseline", baseline), ("candidate", candidate)):
            observations = [rows[(case["id"], model["id"], mode, 1)] for case in selected if (case["id"], model["id"], mode, 1) in rows]
            value[side] = {"cer": counted(observations, len(selected), "cer"),
                           "wer": None if language == "zh" else counted(observations, len(selected), "wer")}
        for metric in ("cer", "wer"):
            a, b = [value[side][metric]["rate"] if value[side][metric] else None for side in ("baseline", "candidate")]
            value[metric + "_delta"] = b - a if a is not None and b is not None else None
        per_language.append(value)
        for case in selected:
            before, after = [rows.get((case["id"], model["id"], mode, 1)) for model in (baseline, candidate)]
            hashes = [row["measurement"].get("hypothesis_sha256") if row and public.completed(row) else None for row in (before, after)]
            hypotheses.append({"id": case["id"], "language": language,
                "identical_hypothesis_hash": hashes[0] == hashes[1] if all(valid_hash(v) for v in hashes) else None})
            if mode == "auto":
                a, ar = automatic(before); b, br = automatic(after); expected = public.base_language(language)
                labels.append({"id": case["id"], "language": language, "expected_base": expected,
                    "baseline": a, "candidate": b, "baseline_unknown_reason": ar, "candidate_unknown_reason": br,
                    "newly_wrong": a == expected and b is not None and b != expected,
                    "changed_already_wrong": a is not None and b is not None and a != expected and b != expected and a != b})
    macros = {}
    for metric, count in (("cer", 9), ("wer", 8)):
        for side in ("baseline", "candidate"):
            rates = [v[side][metric]["rate"] for v in per_language if v[side][metric] is not None]
            macros[side + "_macro_" + metric] = sum(rates) / count if len(rates) == count and all(v is not None for v in rates) else None
        a, b = macros["baseline_macro_" + metric], macros["candidate_macro_" + metric]
        macros[metric + "_relative_gain"] = (a - b) / a if a is not None and b is not None and a > 0 else None
        macros["macro_" + metric + "_delta"] = b - a if a is not None and b is not None else None
    completed = sum(all(key in rows and public.completed(rows[key]) for key in ((case, baseline["id"], mode, repeat), (case, candidate["id"], mode, repeat)))
                    for case, repeat in itertools.product(cases, range(1, plan["repetitions"] + 1)))
    unknown = sum(v["baseline"] is None or v["candidate"] is None for v in labels)
    newly_wrong = sum(v["newly_wrong"] for v in labels)
    return {"baseline_model": baseline, "candidate_model": candidate, "macro_metrics": macros, "per_language": per_language,
        "canonical_row_pairs": {"planned_pair_cells": len(cases) * plan["repetitions"], "completed_pair_cells": completed,
                                "quality_unique_pairs_planned": len(cases), "quality_repeat": 1},
        "auto_labels": {"scope": "coarse published-source base labels; explicit mode is not language-ID evidence",
            "planned_cases": len(cases) if mode == "auto" else 0, "unknown_cases": unknown, "newly_wrong_cases": newly_wrong,
            "changed_already_wrong_cases": sum(v["changed_already_wrong"] for v in labels), "cases": labels},
        "no_new_wrong_auto_labels": (False if newly_wrong else None if unknown else True) if mode == "auto" else True,
        "hypothesis_identity": hypotheses}


def float_control(plan, cases, rows, mode, original, balanced):
    repeats = list(range(1, plan["repetitions"] + 1)) if plan["stage"] == "panel" else [1]
    hypotheses, labels = [], []
    for case, repeat in itertools.product(cases.values(), repeats):
        before, after = [rows.get((case["id"], model["id"], mode, repeat)) for model in (original, balanced)]
        hashes = [row["measurement"].get("hypothesis_sha256") if row and public.completed(row) else None for row in (before, after)]
        hypotheses.append({"id": case["id"], "language": case["language"], "repeat": repeat,
            "identical_hypothesis_hash": hashes[0] == hashes[1] if all(valid_hash(v) for v in hashes) else None})
        if mode == "auto":
            a, ar = automatic(before); b, br = automatic(after)
            labels.append({"id": case["id"], "language": case["language"], "repeat": repeat,
                "baseline": a, "candidate": b, "baseline_unknown_reason": ar, "candidate_unknown_reason": br,
                "identical_observed_labels": a == b if a is not None and b is not None else None})
    same_hashes = all(v["identical_hypothesis_hash"] is True for v in hypotheses)
    same_labels = all(v["identical_observed_labels"] is True for v in labels) if mode == "auto" else True
    return {"scope": "required all-repeat numerical panel" if plan["stage"] == "panel" else "descriptive repeat 1 only; separate frozen panel receipt required by final family review",
        "required_repeats": repeats, "unique_source_utterances": len(cases), "planned_hypothesis_pairs": len(hypotheses),
        "identical_required_hypothesis_hashes": True if same_hashes else None,
        "observed_different_hypothesis_pairs": sum(v["identical_hypothesis_hash"] is False for v in hypotheses),
        "unknown_hypothesis_pairs": sum(v["identical_hypothesis_hash"] is None for v in hypotheses),
        "unknown_hypothesis_cases": len({v["id"] for v in hypotheses if v["identical_hypothesis_hash"] is None}),
        "identical_required_auto_labels": (True if same_labels else None) if mode == "auto" else "not_applicable_explicit_mode",
        "planned_auto_label_pairs": len(labels), "hypothesis_identity": hypotheses, "auto_label_identity": labels,
        "status": "observed_match_no_promotion" if same_hashes and same_labels else "inconclusive_no_promotion"}


def assess(report, matrix, matrix_hash, plan):
    cases, models, rows, pairs, expected, expected_pairs, byte_evidence, placeholders = validate_inputs(report, matrix, matrix_hash, plan)
    partition = plan["partition"]
    arms = partition["arms"] if partition["kind"] == "family" else {"original": partition["model"]}
    results = []
    for mode in plan["language_modes"]:
        planned_rows = [key for key in expected if key[2] == mode]
        planned_pairs = [key for key in expected_pairs if key[2] == mode]
        complete_rows = sum(key in rows and public.completed(rows[key]) for key in planned_rows)
        complete_pairs = sum(key in pairs and pairs[key].get("status") == "paired_exploratory" for key in planned_pairs)
        coverage = {"planned_inference_cells": len(planned_rows), "completed_inference_cells": complete_rows,
                    "planned_native_parent_pair_cells": len(planned_pairs), "completed_native_parent_pair_cells": complete_pairs}
        gates = {"complete_planned_inference_grid": True if complete_rows == len(planned_rows) else None,
                 "complete_native_parent_pair_grid": True if complete_pairs == len(planned_pairs) else None,
                 "complete_artifact_byte_evidence": True if all(key in byte_evidence and byte_evidence[key] is not None for key in planned_rows) else None}
        artifact_bytes = {}
        for role, model in arms.items():
            keys = [key for key in planned_rows if key[1] == model["id"]]
            observed = sum(key in byte_evidence and byte_evidence[key] is not None for key in keys)
            artifact_bytes[role] = {"id": model["id"], "sha256": model["sha256"], "frozen_model_file_bytes": model["model_file_bytes"],
                                   "observed_model_file_bytes": model["model_file_bytes"] if observed == len(keys) else None,
                                   "planned_cells": len(keys), "measured_byte_cells": observed}
        if partition["kind"] == "reference":
            coverage["legacy_unpaired_reference_placeholders"] = sum(key[2] == mode for key in placeholders)
            metrics = row_contrast(plan, cases, rows, mode, arms["original"], arms["original"])
            reference = {"model": arms["original"],
                "macro_cer": metrics["macro_metrics"]["baseline_macro_cer"], "macro_wer": metrics["macro_metrics"]["baseline_macro_wer"],
                "per_language": [{"language": v["language"], **v["baseline"]} for v in metrics["per_language"]],
                "automatic_labels": [{"id": v["id"], "language": v["language"], "expected_base": v["expected_base"],
                                      "observed": v["baseline"], "unknown_reason": v["baseline_unknown_reason"]}
                                     for v in metrics["auto_labels"]["cases"]]}
            decision = "reference_observed_no_promotion" if all(v is True for v in gates.values()) else "inconclusive_no_promotion"
            results.append({"partition": partition["id"], "kind": "reference", "language_mode": mode, "decision": decision,
                "gates": gates, "coverage": coverage, "artifact_bytes": artifact_bytes, "reference_metrics": reference,
                "native_critical_content": "PENDING", "default_promotion": False})
            continue
        native = {}
        for role in ("balanced_f16", "plain_q5", "balanced_q5"):
            value = row_contrast(plan, cases, rows, mode, arms["original"], arms[role])
            value.update(baseline_arm="original", candidate_arm=role, comparison_id=partition["comparison_ids"][role],
                         baseline_model_kind="pretrained", candidate_model_kind=ARM_KINDS[role],
                         pairing="native original-parent comparison; derived lineage unchanged")
            native[role] = value
        direct = row_contrast(plan, cases, rows, mode, arms["plain_q5"], arms["balanced_q5"])
        direct.update(baseline_arm="plain_q5", candidate_arm="balanced_q5",
                      baseline_model_kind="compression", candidate_model_kind="combined",
                      pairing="assessor-derived canonical-row contrast; not a native parent pair or untouched control")
        panel_control = float_control(plan, cases, rows, mode, arms["original"], arms["balanced_f16"])
        original_bytes, quantized_bytes = [artifact_bytes[role]["observed_model_file_bytes"] for role in ("original", "balanced_q5")]
        saving = 1 - quantized_bytes / original_bytes if original_bytes is not None and quantized_bytes is not None else None
        if plan["stage"] == "panel":
            gates["balanced_f16_identical_required_hypothesis_hashes"] = panel_control["identical_required_hypothesis_hashes"]
            if mode == "auto": gates["balanced_f16_identical_required_auto_labels"] = panel_control["identical_required_auto_labels"]
            decision = "continue_no_promotion" if all(v is True for v in gates.values()) else "inconclusive_no_promotion"
        else:
            gates.update(ai_macro_cer_gain_at_least_10_percent=prior.threshold(direct["macro_metrics"]["cer_relative_gain"], .10, "at_least"),
                ai_macro_wer_gain_at_least_5_percent=prior.threshold(direct["macro_metrics"]["wer_relative_gain"], .05, "at_least"),
                original_macro_cer_increase_at_most_0_0025=prior.threshold(native["balanced_q5"]["macro_metrics"]["macro_cer_delta"], .0025, "at_most"),
                original_macro_wer_increase_at_most_0_005=prior.threshold(native["balanced_q5"]["macro_metrics"]["macro_wer_delta"], .005, "at_most"),
                model_file_saving_at_least_50_percent=prior.threshold(saving, .50, "at_least"))
            for control, contrast in (("original", native["balanced_q5"]), ("plain_q5", direct)):
                gates[control + "_no_new_wrong_auto_base_labels"] = contrast["no_new_wrong_auto_labels"]
                for language in contrast["per_language"]:
                    gates[control + "_" + language["language"] + "_cer_increase_at_most_0_01"] = prior.threshold(language["cer_delta"], .01, "at_most")
                    if language["language"] != "zh": gates[control + "_" + language["language"] + "_wer_increase_at_most_0_02"] = prior.threshold(language["wer_delta"], .02, "at_most")
            decision = "reject" if False in gates.values() else "inconclusive_no_promotion" if None in gates.values() else "continue_no_promotion"
        coverage["planned_assessor_derived_q5_pair_cells"] = direct["canonical_row_pairs"]["planned_pair_cells"]
        coverage["completed_assessor_derived_q5_pair_cells"] = direct["canonical_row_pairs"]["completed_pair_cells"]
        results.append({"partition": partition["id"], "kind": "family", "language_mode": mode, "decision": decision,
            "gates": gates, "coverage": coverage, "artifact_bytes": artifact_bytes, "model_file_saving_vs_original": saving,
            "native_parent_contrasts": native, "balanced_q5_vs_plain_q5": direct, "balanced_f16_control": panel_control,
            "native_critical_content": "PENDING", "default_promotion": False})
    decisions = {v["language_mode"]: v["decision"] for v in results}
    decision = "reject" if "reject" in decisions.values() else "inconclusive_no_promotion" if "inconclusive_no_promotion" in decisions.values() else "reference_observed_no_promotion" if partition["kind"] == "reference" else "continue_no_promotion"
    resources = [{key: cohort.get(key) for key in ("language", "task", "model", "model_sha256", "language_mode", "timing", "peak_process_rss_bytes", "artifact_metrics")} for cohort in report["cohorts"]]
    result = {"schema_version": VERSION, "created_utc": datetime.now(timezone.utc).isoformat(), "stage": plan["stage"], "split": plan["split"],
        "repetitions": plan["repetitions"], "partition": partition, "quality_selection": "successful repeat_1_only; no later fallback or selective retry",
        "scoring_policy": POLICY, "model_mode_assessments": results,
        "partition_assessment": {"id": partition["id"], "kind": partition["kind"], "decision": decision, "mode_decisions": decisions},
        "default_promotion": False, "native_review": "PENDING", "product_acceptance": "PENDING",
        "resource_acceptance": "UNCONTROLLED / NOT EVALUATED", "resource_observations": resources,
        "limitations": ["Counts and matched labels do not establish semantic/native fidelity or independent speakers/sessions",
            "Chinese CER only; no whitespace WER or script conversion", "Every missing/failed/null planned case remains inconclusive; no repeat fallback",
            "Original-parent native pairs and derived Q5 contrasts use the same speech and are not extra independent samples",
            "Balanced F16 is an actual edited conversion control; numerical observation is not real-arithmetic proof",
            "Quality-stage control observations do not replace the separately frozen numerical-panel receipt",
            "Native/critical-content/regional/grouping/live/fallback/independent-channel gates remain pending",
            "Resources are uncontrolled observations; one-repeat quality stages cannot establish repeat stability",
            "Only explicit report/matrix/plan/runtime JSON is read; snapshot attestations bind hashes, raw paths are not followed"]}
    if partition["kind"] == "reference":
        result["legacy_reference_placeholder_evidence"] = {
            "contract_version": "legacy-unpaired-reference-v1", "status": "unpaired_legacy_runtime_evidence_only",
            "observed_placeholder_cells": len(placeholders), "native_parent_pair_cells": 0, "assessor_derived_q5_pair_cells": 0,
            "counts_by_language_mode": {mode: sum(key[2] == mode for key in placeholders) for mode in plan["language_modes"]},
            "cell_identities": [{"id": key[0], "model": key[1], "language_mode": key[2], "repeat": key[3]} for key in sorted(placeholders)],
            "interpretation": "No explicit comparison/baseline profile: pending runtime placeholders are not paired observations or gains"}
    return result


def markdown(result):
    lines = ["# Channel-balance assessment", "", "No default promotion. Native/product approval: **PENDING**. Resources: **UNCONTROLLED / NOT EVALUATED**.", ""]
    for value in result["model_mode_assessments"]:
        lines += ["## " + value["partition"] + " / " + value["language_mode"] + ": " + value["decision"], "",
                  "Gate values are numerical evidence only; unknown never passes.", ""]
        lines += ["- " + key + ": " + ("unknown" if state is None else str(state).lower()) for key, state in value["gates"].items()]
        if value["kind"] == "reference":
            lines += ["", "Legacy unpaired runtime placeholders: " + str(value["coverage"]["legacy_unpaired_reference_placeholders"])
                      + "; counted separately from zero native parent comparisons and zero Q5 contrasts.", ""]
        if value["kind"] == "family":
            lines += ["", "Balanced Q5 versus ordinary Q5 is an assessor-derived contrast, not a native pretrained-parent pair.",
                      "Model-file saving: " + prior.number(value["model_file_saving_vs_original"]), ""]
            for label, comparison in (("Original F16 → balanced Q5", value["native_parent_contrasts"]["balanced_q5"]),
                                      ("Ordinary Q5 → balanced Q5", value["balanced_q5_vs_plain_q5"])):
                m = comparison["macro_metrics"]
                lines += [label, "", "| Metric | Control | Candidate | Relative gain |", "| --- | --- | --- | --- |"]
                for metric in ("cer", "wer"):
                    lines.append("| " + metric.upper() + " | " + " | ".join(prior.number(m[key]) for key in ("baseline_macro_" + metric, "candidate_macro_" + metric, metric + "_relative_gain")) + " |")
                lines.append("")
    return "\n".join(lines + [*result["limitations"], ""])


def write_assessment(report_path, matrix_path, plan_path, output):
    report, report_hash = read(report_path); matrix, matrix_hash = read(matrix_path); plan, plan_hash = read(plan_path)
    result = assess(report, matrix, matrix_hash, plan)
    result["evidence"] = {"report_sha256": report_hash, "matrix_sha256": matrix_hash, "plan_sha256": plan_hash,
        "runtime_record_sha256": plan["runtime_record"]["sha256"], "analyzer_sha256": prior.digest(Path(__file__).read_bytes()),
        "reused_affine_helpers_sha256": prior.digest(Path(prior.__file__).read_bytes()), "public_reporter_sha256": prior.digest(Path(public.__file__).read_bytes())}
    output = Path(output)
    require(output.is_absolute() and ".." not in output.parts and not any(p.is_symlink() for p in (output, *output.parents)), "Use a new absolute non-symlink output")
    repo = Path(__file__).resolve().parents[2]
    require(output != repo and repo not in output.parents, "Assessment output must be protected externally")
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    with (output / "assessment.json").open("x") as stream: json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False); stream.write("\n")
    with (output / "assessment.md").open("x") as stream: stream.write(markdown(result))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", type=Path); parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument("--plan", type=Path, required=True); parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try: result = write_assessment(args.report, args.matrix, args.plan, args.output)
    except (ValueError, OSError) as error: parser.exit(1, type(error).__name__ + ": " + str(error) + "\n")
    print(json.dumps({"output": str(args.output), "partition_assessment": result["partition_assessment"], "default_promotion": False}))


if __name__ == "__main__": main()
