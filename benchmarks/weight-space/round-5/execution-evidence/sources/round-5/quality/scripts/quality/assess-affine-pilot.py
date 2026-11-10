#!/usr/bin/env python3
"""Assess frozen round-2 metrics; no ASR, rescoring or raw-evidence reads.

CLI: assess-affine-pilot.py REPORT --matrix MATRIX --plan PLAN --output NEW
All paths are explicit absolute JSON paths; output must be new and external.
Only REPORT, MATRIX, PLAN and the plan's runtime_record JSON are read. Paths
inside these documents (audio/reference/model/library/log/evidence) are ignored.

Plan contract (all SHA256 placeholders must be 64 lowercase hexadecimal chars):
{
  "schema_version": "affine-assessment-plan-v1", "mode": "quality",
  "split": "development", "repetitions": 3, "language_modes": ["known"],
  "cases": [{"id":"published-id", "language":"de-CH",
    "task":"standard_rendering", "source_channel":0,
    "source_sha256":"SHA256", "reference_sha256":"SHA256",
    "source_id":"original-published-recording-id"}],
  "pairs": [{"id":"tiny", "comparison_id":"tiny-affine",
    "baseline":{"id":"tiny", "sha256":"SHA256"},
    "candidate":{"id":"tiny-affine", "sha256":"SHA256"}}],
  "execution": {"profile_id":"current-defaults", "profile_sha256":"SHA256",
    "runtime_settings_sha256":"SHA256", "vad_model_sha256":null,
    "runner_sha256":"SHA256", "whisper_binary_sha256":"SHA256",
    "threads":2, "corpus_sha256":"SHA256", "configuration_sha256":"SHA256"},
  "runtime_record":{"path":"/protected/pre-execution-identities.json",
                    "sha256":"SHA256"}
}
The example case is schematic: quality requires eight explicit cases for EACH
of de-CH/de/fr/it/en/ar/zh/es/pt. Control mode requires one/language, development
split and known+auto; it checks exact repeat-1 scored-hypothesis hashes and
observed coarse auto labels, with unknowns/differences inconclusive. Held-out
quality requires known+auto plus execution.freeze_sha256, matching the matrix,
report provenance and verified freeze.original.json snapshot attestation.
Runtime-record format: runner_sha256 plus files=[{path,sha256,...}], including
the whisper-cli identity. Its referenced files are NEVER opened.

Quality gates are fixed by benchmarks/weight-space-round2-protocol.md. Rates
use complete repeat-1 per-language counts, then equal-language macro rates.
Observed reference units must agree across all models/modes/repeats for each
case/scorer/channel/reference hash; missing/null units remain unmeasured.
Unknown evidence never passes. Numerical success means continue_no_promotion;
native/critical-content/grouping/live/resource acceptance remains pending.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.util
import itertools
import json
import math
from pathlib import Path
import re

SPEC = importlib.util.spec_from_file_location("quality_report", Path(__file__).with_name("report-pilot.py"))
public = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(public)
LANGUAGES = ("de-CH", "de", "fr", "it", "en", "ar", "zh", "es", "pt")
POLICY = "swift-nfc-casefold-alphanumeric-v1"
EMPTY = hashlib.sha256(b"").hexdigest()
MAX_JSON_BYTES = 64 * 1024 * 1024


def require(condition, message):
    if not condition: raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def valid_hash(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON key")
        result[key] = value
    return result


def strict_float(value):
    result = float(value)
    require(math.isfinite(result), "Nonfinite JSON number")
    return result


def strict_int(value):
    result = int(value)
    require(abs(result) <= 2**63 - 1, "JSON integer exceeds supported bound")
    return result


def read(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts and path.suffix == ".json", "Use explicit absolute JSON paths without traversal")
    require(not any(part.is_symlink() for part in (path, *path.parents)), "Symlink inputs prohibited")
    with path.open("rb") as stream: data = stream.read(MAX_JSON_BYTES + 1)
    require(len(data) <= MAX_JSON_BYTES, "JSON input exceeds 64 MiB")
    def nonfinite(_): raise ValueError("Nonfinite JSON constant")
    return json.loads(data, object_pairs_hook=strict_object, parse_constant=nonfinite,
                      parse_float=strict_float, parse_int=strict_int), digest(data)


def equivalent(a, b):
    if isinstance(a, bool) or isinstance(b, bool) or a is None or b is None: return type(a) is type(b) and a == b
    if public.finite_number(a) and public.finite_number(b): return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12)
    if isinstance(a, dict) and isinstance(b, dict): return a.keys() == b.keys() and all(equivalent(a[key], b[key]) for key in a)
    if isinstance(a, list) and isinstance(b, list): return len(a) == len(b) and all(equivalent(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def validate_plan(plan):
    require(plan.get("schema_version") == "affine-assessment-plan-v1" and plan.get("mode") in {"quality", "control"}, "Unsupported assessment plan")
    require(plan.get("split") in {"development", "held_out"} and type(plan.get("repetitions")) is int and plan["repetitions"] == 3, "Plan requires explicit split and three repeats")
    modes = plan.get("language_modes")
    require(isinstance(modes, list) and all(isinstance(value, str) for value in modes) and len(modes) == len(set(modes)) and set(modes) in ({"known"}, {"known", "auto"}), "Known mode and distinct supported language modes required")
    if plan["mode"] == "control": require(plan["split"] == "development" and set(modes) == {"known", "auto"}, "Numerical controls require development known+auto")
    if plan["split"] == "held_out": require(set(modes) == {"known", "auto"}, "Heldout quality requires known+auto")
    cases = plan.get("cases")
    require(isinstance(cases, list) and all(isinstance(case, dict) for case in cases) and len(cases) == (9 if plan["mode"] == "control" else 72), "Plan has incorrect nine-language case count")
    count = 1 if plan["mode"] == "control" else 8
    require(Counter(case.get("language") for case in cases) == Counter({language: count for language in LANGUAGES}), "Each planned language needs its complete fixed case count")
    ids = set()
    for case in cases:
        identifier = case.get("id")
        require(isinstance(identifier, str) and re.fullmatch(r"[A-Za-z0-9_-]+", identifier) and identifier not in ids, "Duplicate/unsafe planned case ID")
        ids.add(identifier)
        require(case.get("task") == ("standard_rendering" if case["language"] == "de-CH" else "transcription"), "Unexpected planned language/task")
        require(type(case.get("source_channel")) is int and case["source_channel"] >= 0, "Explicit source channel required")
        require(valid_hash(case.get("source_sha256")) and valid_hash(case.get("reference_sha256")), "Source/reference SHA256 required")
        require(isinstance(case.get("source_id"), str) and case["source_id"].strip(), "Original published source_id required; do not infer groups")
    pairs = plan.get("pairs")
    require(isinstance(pairs, list) and 1 <= len(pairs) <= 3, "One to three independent model pairs required")
    models, pair_ids, comparisons = {}, set(), set()
    for pair in pairs:
        require(pair.get("id") not in pair_ids and isinstance(pair.get("id"), str) and pair["id"], "Duplicate/missing pair ID")
        require(pair.get("comparison_id") not in comparisons and isinstance(pair.get("comparison_id"), str) and pair["comparison_id"], "Duplicate/missing comparison ID")
        pair_ids.add(pair["id"]); comparisons.add(pair["comparison_id"])
        for side in ("baseline", "candidate"):
            model = pair.get(side, {})
            require(isinstance(model.get("id"), str) and re.fullmatch(r"[A-Za-z0-9_-]+", model["id"]) and model["id"] not in models and valid_hash(model.get("sha256")), "Models need unique IDs and exact hashes")
            models[model["id"]] = model["sha256"]
    execution = plan.get("execution", {})
    for field in ("profile_sha256", "runtime_settings_sha256", "runner_sha256", "whisper_binary_sha256", "corpus_sha256", "configuration_sha256"):
        require(valid_hash(execution.get(field)), "Missing execution checksum: " + field)
    require(isinstance(execution.get("profile_id"), str) and execution["profile_id"] and execution.get("vad_model_sha256") is None and type(execution.get("threads")) is int and execution["threads"] == 2, "Expected one explicit no-VAD, two-thread profile")
    if plan["split"] == "held_out": require(valid_hash(execution.get("freeze_sha256")), "Heldout freeze SHA256 required")
    require(valid_hash(plan.get("runtime_record", {}).get("sha256")), "Runtime metadata checksum required")
    return {case["id"]: case for case in cases}, models


def observation(row, name):
    if row is None or not public.completed(row) or name == "wer" and row["language"] == "zh": return None
    metric = public.metric([row], name)
    return metric["corpus_weighted_rate"]


def native_identities(value, execution, model_hash):
    observed = 0
    if isinstance(value, dict):
        if value.get("engine") == "whisper.cpp":
            require(value.get("binary_sha256") == execution["whisper_binary_sha256"] and value.get("model_sha256") == model_hash, "Native engine/model identity mismatch")
            require(value.get("vad_model_sha256") is None and value.get("decoding", {}).get("profile_sha256") == execution["runtime_settings_sha256"], "Native VAD/profile identity mismatch")
            observed += 1
        for child in value.values(): observed += native_identities(child, execution, model_hash)
    elif isinstance(value, list):
        for child in value: observed += native_identities(child, execution, model_hash)
    return observed


def reference_units(row, ledger, maximum_entries):
    """A fixed reference/scorer/channel has one denominator across every cell.

    Missing/null units are unmeasured, not zero. Observe partial failed rows too:
    failure does not make a conflicting measured denominator disappear.
    """
    measurement = row.get("measurement")
    if not isinstance(measurement, dict): return
    for measured, declared in (("scoring_version", "scoring_policy"), ("reference_sha256", "reference_sha256")):
        require(measurement.get(measured) is None or measurement[measured] == row[declared], "Observed reference/scorer identity mismatch")
    for field in ("reference_words", "reference_characters"):
        units = measurement.get(field)
        if units is None: continue
        require(type(units) is int and units >= 0, "Invalid observed reference units")
        key = (row["id"], row["scoring_policy"], row["source_channel"], row["reference_sha256"], field)
        require(key not in ledger or ledger[key] == units, "Conflicting reference units for the same case/scorer/channel/reference hash")
        ledger[key] = units
        require(len(ledger) <= maximum_entries, "Reference-unit ledger exceeds planned-case bound")


def validate_inputs(report, matrix, matrix_hash, plan):
    cases, models = validate_plan(plan)
    execution = plan["execution"]
    require(public.VERSION == report.get("schema_version") == "quality-pilot-report-1.1", "Public report version 1.1 required")
    require(report.get("source_matrix_sha256") == matrix_hash, "Report does not match exact matrix bytes")
    require(matrix.get("split") == plan["split"] and matrix.get("dry_run") is False and matrix.get("threads") == 2, "Matrix split/path/run scope mismatch")
    for field in ("corpus_sha256", "configuration_sha256", "runner_sha256", "whisper_binary_sha256"):
        require(matrix.get(field) == execution[field] and report.get("provenance", {}).get(field) == execution[field], "Frozen matrix/report identity mismatch: " + field)
    snapshots = [("corpus.original.json", "corpus_sha256"), ("experiment.original.json", "configuration_sha256")]
    if plan["split"] == "held_out":
        require(matrix.get("freeze_sha256") == execution["freeze_sha256"] and report.get("provenance", {}).get("freeze_sha256") == execution["freeze_sha256"], "Heldout freeze identity mismatch")
        snapshots.append(("freeze.original.json", "freeze_sha256"))
    for filename, field in snapshots:
        evidence = report.get("snapshot_evidence", {}).get(filename, {})
        require(evidence.get("status") == "verified" and evidence.get("expected_sha256") == evidence.get("observed_sha256") == execution[field], "Verified snapshot attestation missing/mismatched")
    runtime, runtime_hash = read(plan["runtime_record"]["path"])
    require(runtime_hash == plan["runtime_record"]["sha256"] and runtime.get("runner_sha256") == execution["runner_sha256"], "Runtime record identity mismatch")
    require(any(item.get("sha256") == execution["whisper_binary_sha256"] and item.get("path", "").endswith("/whisper-cli") for item in runtime.get("files", [])), "Runtime record lacks planned whisper-cli")
    expected = set(itertools.product(cases, models, plan["language_modes"], (1, 2, 3)))
    rows, unit_ledger = {}, {}
    for row in matrix.get("rows", []):
        key = (row.get("id"), row.get("model"), row.get("language_mode"), row.get("repeat"))
        require(key in expected and key not in rows and type(key[3]) is int, "Unexpected/duplicate matrix inference cell")
        case = cases[key[0]]
        for field in ("language", "task", "source_channel", "source_sha256", "reference_sha256"):
            require(type(row.get(field)) is type(case[field]) and row[field] == case[field], "Planned source identity mismatch: " + field)
        require(row.get("model_sha256") == models[key[1]] and row.get("path") == "final" and row.get("profile") == execution["profile_id"] and row.get("scoring_policy") == POLICY, "Row model/profile/path/scoring mismatch")
        for field, expected_value in (("profile_sha256", execution["profile_sha256"]), ("runtime_settings_sha256", execution["runtime_settings_sha256"]),
                ("effective_profile_sha256", execution["runtime_settings_sha256"]), ("whisper_binary_sha256", execution["whisper_binary_sha256"]),
                ("transcription_runner_sha256", execution["runner_sha256"]), ("vad_model_sha256", None), ("threads", 2)):
            require(row.get(field) == expected_value, "Row runtime identity mismatch: " + field)
        reference_units(row, unit_ledger, len(cases) * 2)
        if public.completed(row):
            measurement = row["measurement"]
            for actual, expected_field in (("source_sha256", "source_sha256"), ("reference_sha256", "reference_sha256"), ("scoring_version", "scoring_policy")):
                require(measurement.get(actual) == row[expected_field], "Measured source/scorer identity mismatch")
            require(native_identities(measurement.get("engine_passes"), execution, models[key[1]]) > 0, "Completed row lacks native identity evidence")
            for name, prefix in (("wer", "word"), ("cer", "character")):
                if name == "wer" and row["language"] == "zh": continue
                denominator = "reference_words" if name == "wer" else "reference_characters"
                for field in (prefix + "_errors", denominator, *(prefix + "_" + operation for operation in ("insertions", "deletions", "substitutions"))):
                    require(measurement.get(field) is None or type(measurement[field]) is int and measurement[field] >= 0, "Invalid scoring count/denominator")
                require(measurement.get(name) is None or public.finite_number(measurement[name]) and measurement[name] >= 0, "Invalid lexical rate")
                observation(row, name)  # Public counted-rate consistency check.
                operations = [measurement.get(prefix + "_" + operation) for operation in ("insertions", "deletions", "substitutions")]
                if type(measurement.get(prefix + "_errors")) is int and all(type(value) is int and value >= 0 for value in operations):
                    require(sum(operations) == measurement.get(prefix + "_errors"), "Operation counts disagree with errors")
        rows[key] = row
    specifications = {pair["comparison_id"]: pair for pair in plan["pairs"]}
    expected_pairs = set(itertools.product(specifications, cases, plan["language_modes"], (1, 2, 3)))
    pairs = {}
    for pair in matrix.get("paired_comparisons", []):
        key = (pair.get("comparison_id"), pair.get("id"), pair.get("language_mode"), pair.get("repeat"))
        require(key in expected_pairs and key not in pairs and type(key[3]) is int, "Unexpected/duplicate comparison cell")
        specification, case = specifications[key[0]], cases[key[1]]
        for side in ("baseline", "candidate"):
            profile = pair.get(side + "_profile")
            require(pair.get(side + "_model") == specification[side]["id"] and (profile == execution["profile_id"] or side == "baseline" and pair.get("status") != "paired_exploratory" and profile is None), "Pair model/profile identity mismatch")
            if side == "candidate" or pair.get("status") == "paired_exploratory": require(pair.get(side + "_model_sha256") == specification[side]["sha256"], "Pair artifact checksum mismatch")
        require(pair.get("language") == case["language"] and pair.get("task") == case["task"] and type(pair.get("source_channel")) is int and pair["source_channel"] == case["source_channel"] and pair.get("path") == "final", "Pair source identity mismatch")
        if pair.get("status") == "paired_exploratory":
            before, after = [rows.get((key[1], specification[side]["id"], key[2], key[3])) for side in ("baseline", "candidate")]
            require(before is not None and after is not None and public.completed(before) and public.completed(after), "Paired status lacks completed inputs")
            for name in ("wer", "cer"):
                if name == "wer" and case["language"] == "zh": continue
                a, b = observation(before, name), observation(after, name)
                require(equivalent(pair.get(name + "_delta"), b - a if a is not None and b is not None else None), "Pair metric delta mismatch")
        pairs[key] = pair
    # Recompute the public summary from metrics and planned source metadata only.
    rebuilt = public.summarize(matrix, {"cases": list(cases.values())}, allow_held_out=plan["split"] == "held_out", freeze_verified=plan["split"] == "held_out")
    for field in ("requested_cells", "completed_cells", "cell_status_counts", "unique_source_utterances_planned", "comparisons"):
        require(equivalent(report.get(field), rebuilt[field]), "Public report disagrees with matrix: " + field)
    keys = public.GROUP_FIELDS
    index = lambda values: {tuple(value.get(key) for key in keys): value for value in values}
    actual, expected_cohorts = index(report.get("cohorts", [])), index(rebuilt["cohorts"])
    require(len(actual) == len(report.get("cohorts", [])) and actual.keys() == expected_cohorts.keys(), "Missing/duplicate report cohort")
    for key, cohort in actual.items():
        for field in ("requested_cells", "cell_status_counts", "quality", "timing", "peak_process_rss_bytes", "artifact_metrics"):
            require(equivalent(cohort.get(field), expected_cohorts[key][field]), "Public cohort disagrees with matrix: " + field)
    return cases, rows, pairs, expected, expected_pairs


def counted(rows, planned, name):
    measured = public.metric([row for row in rows if public.completed(row)], name)
    complete = len(rows) == planned and measured["scored_unique_utterances"] == planned
    return {"planned_utterances": planned, "observed_scored_utterances": measured["scored_unique_utterances"],
        "rate": measured["corpus_weighted_rate"] if complete else None,
        "errors": measured["errors"] if complete else None, "reference_units": measured["reference_units"] if complete else None,
        "insertions": measured["insertions"] if complete else None, "deletions": measured["deletions"] if complete else None,
        "substitutions": measured["substitutions"] if complete else None, "observed_errors": measured["errors"],
        "observed_reference_units": measured["reference_units"], "status": "complete_counted_rate" if complete else "inconclusive_missing_or_unscored_cases"}


def automatic(row):
    if row is None or not public.completed(row): return None, "missing_or_failed_repeat_1"
    if row["measurement"].get("hypothesis_sha256") == EMPTY: return None, "exact_empty_hypothesis_hash"
    return public.observed_automatic_language(row)


def threshold(value, limit, direction):
    if value is None: return None
    return value + 1e-12 >= limit if direction == "at_least" else value <= limit + 1e-12


def assess(report, matrix, matrix_hash, plan):
    cases, rows, pairs, expected, expected_pairs = validate_inputs(report, matrix, matrix_hash, plan)
    results = []
    for specification in plan["pairs"]:
        for mode in plan["language_modes"]:
            per_language, labels, controls = [], [], []
            for language in LANGUAGES:
                same_cases = [case for case in cases.values() if case["language"] == language]
                observed = {}
                for side in ("baseline", "candidate"):
                    same_rows = [rows[(case["id"], specification[side]["id"], mode, 1)] for case in same_cases if (case["id"], specification[side]["id"], mode, 1) in rows]
                    observed[side] = {"cer": counted(same_rows, len(same_cases), "cer"), "wer": None if language == "zh" else counted(same_rows, len(same_cases), "wer")}
                value = {"language": language, **observed}
                for name in ("wer", "cer"):
                    a = observed["baseline"][name]["rate"] if observed["baseline"][name] else None
                    b = observed["candidate"][name]["rate"] if observed["candidate"][name] else None
                    value[name + "_delta"] = b - a if a is not None and b is not None else None
                per_language.append(value)
                for case in same_cases:
                    before, after = [rows.get((case["id"], specification[side]["id"], mode, 1)) for side in ("baseline", "candidate")]
                    if mode == "auto":
                        a, ar = automatic(before); b, br = automatic(after)
                        expected_label = public.base_language(language)
                        labels.append({"id": case["id"], "language": language, "expected_base": expected_label, "baseline": a, "candidate": b,
                            "baseline_unknown_reason": ar, "candidate_unknown_reason": br,
                            "newly_wrong": a == expected_label and b is not None and b != expected_label,
                            "changed_already_wrong": a is not None and b is not None and a != expected_label and b != expected_label and a != b})
                    if plan["mode"] == "control":
                        hashes = [row["measurement"].get("hypothesis_sha256") if row and public.completed(row) else None for row in (before, after)]
                        controls.append({"id": case["id"], "language": language, "identical_hypothesis_hash": hashes[0] == hashes[1] if all(valid_hash(value) for value in hashes) else None})
            planned_rows = [key for key in expected if key[1] in {specification[side]["id"] for side in ("baseline", "candidate")} and key[2] == mode]
            planned_pairs = [key for key in expected_pairs if key[0] == specification["comparison_id"] and key[2] == mode]
            completed_rows = sum(key in rows and public.completed(rows[key]) for key in planned_rows)
            complete_pairs = sum(key in pairs and pairs[key].get("status") == "paired_exploratory" for key in planned_pairs)
            coverage = completed_rows == len(planned_rows) and complete_pairs == len(planned_pairs)
            unknown_labels = sum(value["baseline"] is None or value["candidate"] is None for value in labels)
            newly_wrong = sum(value["newly_wrong"] for value in labels)
            label_gate = (False if newly_wrong else None if unknown_labels else True) if mode == "auto" else True
            gates = {"complete_planned_coverage": True if coverage else None, "no_new_wrong_auto_base_labels": label_gate}
            macros = {}
            for name, required in (("cer", 9), ("wer", 8)):
                for side in ("baseline", "candidate"):
                    rates = [value[side][name]["rate"] for value in per_language if value[side][name] is not None]
                    macros[side + "_macro_" + name] = sum(rates) / required if len(rates) == required and all(value is not None for value in rates) else None
                a, b = macros["baseline_macro_" + name], macros["candidate_macro_" + name]
                macros[name + "_relative_gain"] = (a - b) / a if a is not None and b is not None and a > 0 else None
            if plan["mode"] == "quality":
                gates.update(macro_cer_gain_at_least_5_percent=threshold(macros["cer_relative_gain"], 0.05, "at_least"),
                    macro_wer_gain_at_least_2_percent=threshold(macros["wer_relative_gain"], 0.02, "at_least"))
                for language in per_language:
                    gates[language["language"] + "_cer_increase_at_most_0.01"] = threshold(language["cer_delta"], 0.01, "at_most")
                    if language["wer_delta"] is not None or language["language"] != "zh": gates[language["language"] + "_wer_increase_at_most_0.02"] = threshold(language["wer_delta"], 0.02, "at_most")
                    if language["language"] == "de-CH": gates["swiss_written_german_wer_no_increase"] = threshold(language["wer_delta"], 0, "at_most")
                decision = "reject" if False in gates.values() else "inconclusive_no_promotion" if None in gates.values() else "continue_no_promotion"
            else:
                gates["identical_repeat_1_hypothesis_hashes"] = all(value["identical_hypothesis_hash"] is True for value in controls) or None
                if mode == "auto": gates["identical_observed_auto_labels"] = all(value["baseline"] is not None and value["candidate"] is not None and value["baseline"] == value["candidate"] for value in labels) or None
                decision = "continue_no_promotion" if all(value is True for value in gates.values()) else "inconclusive_no_promotion"
            results.append({"pair": specification["id"], "baseline_model": specification["baseline"], "candidate_model": specification["candidate"],
                "language_mode": mode, "decision": decision, "gates": gates, "macro_metrics": macros, "per_language": per_language,
                "coverage": {"planned_inference_cells": len(planned_rows), "completed_inference_cells": completed_rows,
                    "planned_pair_cells": len(planned_pairs), "completed_pair_cells": complete_pairs},
                "auto_labels": {"planned_cases": len(cases) if mode == "auto" else 0, "unknown_cases": unknown_labels,
                    "newly_wrong_cases": newly_wrong, "changed_already_wrong_cases": sum(value["changed_already_wrong"] for value in labels), "cases": labels},
                "control_hypothesis_identity": controls, "native_critical_content": "PENDING; not a pass", "default_promotion": False})
    resources = [{key: cohort.get(key) for key in ("language", "task", "model", "model_sha256", "language_mode", "timing", "peak_process_rss_bytes", "artifact_metrics")} for cohort in report["cohorts"]]
    model_assessments = []
    for specification in plan["pairs"]:
        decisions = {value["language_mode"]: value["decision"] for value in results if value["pair"] == specification["id"]}
        decision = "reject" if "reject" in decisions.values() else "inconclusive_no_promotion" if "inconclusive_no_promotion" in decisions.values() else "continue_no_promotion"
        model_assessments.append({"pair": specification["id"], "decision": decision, "mode_decisions": decisions, "default_promotion": False})
    return {"schema_version": "affine-pilot-assessment-v1", "created_utc": datetime.now(timezone.utc).isoformat(), "mode": plan["mode"],
        "split": plan["split"], "quality_selection": "repeat_1_only; no fallback or selective retry", "scoring_policy": POLICY,
        "model_mode_assessments": results, "model_assessments": model_assessments, "default_promotion": False, "native_review": "PENDING", "resource_acceptance": "UNCONTROLLED / NOT EVALUATED",
        "resource_observations": resources, "limitations": ["Nine-language macro rates do not establish population accuracy or independent speakers",
            "Chinese CER only; no whitespace WER", "Unknown labels are inconclusive; coarse base agreement is not dialect/switch/confidence accuracy",
            "Control equivalence is observed hypothesis/label equality, not proven exact real-arithmetic equivalence",
            "Resources are shared-desktop observations; first-result latency, total GPU memory, energy and bundle increment are unmeasured",
            "Native/critical-content/grouping/natural-coverage/live/independent-channel acceptance is unresolved; numerical success is continue research only",
            "Snapshot validation uses report attestations matching the plan; source corpus/config/raw paths are not followed"]}


def number(value, percent=True):
    return "unknown" if value is None else f"{value * (100 if percent else 1):.3f}" + ("%" if percent else "")


def markdown(result):
    lines = ["# Affine pilot assessment", "", "No default promotion. Native/critical-content review remains pending. Resources: **UNCONTROLLED / NOT EVALUATED**.", ""]
    for value in result["model_mode_assessments"]:
        lines += ["## " + value["pair"] + " / " + value["language_mode"] + ": " + value["decision"], "",
            "| Metric | Parent | Candidate | Relative gain |", "| --- | --- | --- | --- |"]
        for name in ("cer", "wer"):
            m = value["macro_metrics"]; lines.append(f"| Macro {name.upper()} | {number(m['baseline_macro_' + name])} | {number(m['candidate_macro_' + name])} | {number(m[name + '_relative_gain'])} |")
        lines += ["", "| Language | Parent CER (errors/units) | Candidate CER (errors/units) | Parent WER | Candidate WER |", "| --- | --- | --- | --- | --- |"]
        for item in value["per_language"]:
            cells = []
            for side in ("baseline", "candidate"):
                m = item[side]["cer"]; cells.append(f"{number(m['rate'])} ({m['errors']}/{m['reference_units']}; {m['observed_scored_utterances']}/{m['planned_utterances']} cases)")
            words = [number(item[side]["wer"]["rate"]) if item[side]["wer"] else "—" for side in ("baseline", "candidate")]
            lines.append("| " + " | ".join([item["language"], *cells, *words]) + " |")
        lines += ["", "Gate observations (true is numerical evidence only; unknown never passes):", ""]
        lines += ["- " + key + ": " + ("unknown" if status is None else str(status).lower()) for key, status in value["gates"].items()]
        c, labels = value["coverage"], value["auto_labels"]
        lines += ["", f"Completed inference {c['completed_inference_cells']}/{c['planned_inference_cells']}; paired {c['completed_pair_cells']}/{c['planned_pair_cells']}. Auto planned {labels['planned_cases']}, unknown {labels['unknown_cases']}, newly wrong {labels['newly_wrong_cases']}.", ""]
    lines += ["## Retained resource observations", "", "Per-language/model/mode wall/load/RSS and artifact observations are preserved in assessment.json. They are not controlled performance gates or improvement claims.", "", *["- " + value for value in result["limitations"]], ""]
    return "\n".join(lines)


def write_assessment(report_path, matrix_path, plan_path, output):
    report, report_hash = read(report_path); matrix, matrix_hash = read(matrix_path); plan, plan_hash = read(plan_path)
    result = assess(report, matrix, matrix_hash, plan)
    result["evidence"] = {"report_sha256": report_hash, "matrix_sha256": matrix_hash, "plan_sha256": plan_hash,
        "runtime_record_sha256": plan["runtime_record"]["sha256"], "analyzer_sha256": digest(Path(__file__).read_bytes()),
        "public_reporter_sha256": digest(Path(public.__file__).read_bytes())}
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
    print(json.dumps({"output": str(args.output), "model_decisions": result["model_assessments"], "default_promotion": False}))


if __name__ == "__main__": main()
