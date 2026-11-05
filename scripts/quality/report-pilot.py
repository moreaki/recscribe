#!/usr/bin/env python3
"""Summarize retained benchmark metrics without reading speech/reference text.

Only matrix.json and its corpus/experiment snapshots are read. Quality uses the
first requested repeat; repeated inference is performance/variation evidence,
not additional independent audio. Held-out reports require an explicit opt-in
and retained freeze evidence. No recognition, model loading or rescoring occurs.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import statistics

VERSION = "quality-pilot-report-1.0"
MAXIMUM_JSON_BYTES = 64 * 1024 * 1024
COMPLETED = {"completed", "completed_with_review"}
GROUP_FIELDS = ("language", "task", "model", "model_sha256", "profile", "language_mode", "path", "scoring_policy", "runtime_settings_sha256")
ARTIFACT_FIELDS = ("model_file_bytes", "filesystem_allocated_bytes", "download_artifact_bytes", "download_artifact_sha256", "incremental_bundle_bytes", "bundle_size_status", "parameter_count", "parameter_count_status")
PROVENANCE_FIELDS = ("baseline_revision", "configuration_sha256", "corpus_sha256", "corpus_version", "runner_sha256", "whisper_binary_sha256", "freeze_sha256", "source_revision_verification", "split", "threads", "serial_jobs", "dry_run", "capture_inactive_attestation", "workload_attestation")
LANGUAGE_ORDER = {name: index for index, name in enumerate(["de-CH", "de", "fr", "it", "en", "ar", "zh", "es", "pt"])}


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def distribution(values):
    values = sorted(float(value) for value in values if finite_number(value) and value >= 0)
    return {"measured_count": len(values), "median": statistics.median(values) if values else None,
            "minimum": values[0] if values else None, "maximum": values[-1] if values else None}


def completed(row):
    measurement = row.get("measurement")
    return row.get("status") in COMPLETED and isinstance(measurement, dict) and measurement.get("status", row["status"]) in COMPLETED


def chinese_cer_only(language, scoring):
    return str(language).split("-")[0].lower() in {"zh", "cmn", "yue"} or scoring == "unicode-nfc-cer-v2"


def metric(rows, name):
    """Aggregate counted errors only when an actual compatible rate was measured."""
    prefix, denominator_key = ("word", "reference_words") if name == "wer" else ("character", "reference_characters")
    eligible = []
    for row in rows:
        value = row["measurement"]
        rate, errors, denominator = value.get(name), value.get(prefix + "_errors"), value.get(denominator_key)
        if not finite_number(rate) or rate < 0 or not isinstance(errors, int) or isinstance(errors, bool) or errors < 0:
            continue
        if not isinstance(denominator, int) or isinstance(denominator, bool) or denominator <= 0:
            continue
        if not math.isclose(rate, errors / denominator, rel_tol=1e-9, abs_tol=1e-12):
            raise ValueError("Retained scoring rate disagrees with its error count/denominator")
        eligible.append((value, rate, errors, denominator))
    errors = sum(item[2] for item in eligible)
    denominator = sum(item[3] for item in eligible)
    operations = {}
    for operation in ["insertions", "deletions", "substitutions"]:
        values = [item[0].get(prefix + "_" + operation) for item in eligible]
        operations[operation] = sum(values) if values and all(isinstance(value, int) and not isinstance(value, bool) and value >= 0 for value in values) else None
    return {"scored_unique_utterances": len(eligible), "errors": errors if eligible else None,
            "reference_units": denominator if eligible else None,
            "corpus_weighted_rate": errors / denominator if denominator else None,
            "macro_utterance_rate": statistics.mean(item[1] for item in eligible) if eligible else None, **operations}


def case_identity(row):
    return (row.get("id"), row.get("source_sha256"), row.get("reference_sha256"), str(row.get("source_channel")))


def group_identity(row):
    measurement = row.get("measurement") or {}
    return tuple((row.get(key) or measurement.get("scoring_version")) if key == "scoring_policy" else row.get(key) for key in GROUP_FIELDS)


def source_seconds(row, corpus_by_id):
    seconds = row.get("measurement", {}).get("source_audio_seconds")
    if not finite_number(seconds) or seconds <= 0:
        seconds = corpus_by_id.get(row.get("id"), {}).get("duration_seconds")
    return seconds if finite_number(seconds) and seconds > 0 else None


def load_observations(rows):
    values, parsers, invocations = [], set(), 0
    for row in rows:
        for invocation in row["measurement"].get("engine_runtime_measurements", []):
            invocations += 1
            timing = invocation.get("runtime_timings", {})
            if isinstance(timing.get("parser_version"), str):
                parsers.add(timing["parser_version"])
            for observation in timing.get("observations", {}).get("load", []):
                seconds = observation.get("seconds")
                if finite_number(seconds) and seconds >= 0:
                    values.append(seconds)
    return {**distribution(values), "native_invocations_recorded": invocations, "parser_versions": sorted(parsers),
            "scope": "Upstream model-load timer per native invocation; not total process initialization or first-result latency"}


def summarize_group(rows, corpus_by_id):
    identity = dict(zip(GROUP_FIELDS, group_identity(rows[0])))
    expected_cases = {case_identity(row) for row in rows}
    cells = [(case_identity(row), row.get("repeat")) for row in rows]
    if len(cells) != len(set(cells)):
        raise ValueError("Duplicate benchmark cell would double-count a sample/repeat")
    first = [row for row in rows if row.get("repeat") == 1 and completed(row)]
    measured = [row for row in rows if completed(row)]
    for row in measured:
        observed = row["measurement"].get("scoring_version")
        if observed is not None and row.get("scoring_policy") is not None and observed != row["scoring_policy"]:
            raise ValueError("Measured scoring version differs from cohort identity")
    suppress_wer = chinese_cer_only(identity.get("language"), identity.get("scoring_policy"))
    quality = {"selection": "Successful repeat 1 only; no fallback to later repeats", "planned_unique_utterances": len(expected_cases),
               "completed_unique_utterances": len(first), "wer": None if suppress_wer else metric(first, "wer"), "cer": metric(first, "cer"),
               "wer_status": "unreported; whitespace WER is misleading for this script" if suppress_wer else "counted lexical metric where measured",
               "critical_content_accuracy": None, "semantic_accuracy": None, "language_id_accuracy": None, "timestamp_accuracy": None,
               "human_review_status": "Unmeasured; published references have not been independently adjudicated for this pilot"}
    false_speech = [row["measurement"].get("false_speech_characters") for row in first]
    false_speech = [value for value in false_speech if isinstance(value, int) and not isinstance(value, bool) and value >= 0]
    quality["empty_reference_cases_measured"] = len(false_speech)
    quality["false_speech_characters"] = sum(false_speech) if false_speech else None

    utterances = []
    for case in sorted(expected_cases, key=lambda item: tuple(str(value) for value in item)):
        same_case = [row for row in rows if case_identity(row) == case]
        successful = [row for row in same_case if completed(row)]
        hashes = {row["measurement"].get("hypothesis_sha256") for row in successful if row["measurement"].get("hypothesis_sha256")}
        utterances.append({"id": case[0], "requested_repeats": len(same_case), "completed_repeats": len(successful),
            "wall_seconds": distribution(row["measurement"].get("wall_seconds") for row in successful),
            "distinct_hypothesis_hashes": len(hashes) if hashes else None,
            "transcript_variation": len(hashes) > 1 if hashes else None,
            "evidence_directories": sorted({row["evidence_directory"] for row in same_case if row.get("evidence_directory")})})

    workloads = []
    for repeat in sorted({row.get("repeat") for row in rows}, key=str):
        repeat_rows = [row for row in rows if row.get("repeat") == repeat]
        successes = [row for row in repeat_rows if completed(row)]
        valid_wall = all(finite_number(row["measurement"].get("wall_seconds")) and row["measurement"]["wall_seconds"] >= 0 for row in successes)
        all_present = {case_identity(row) for row in successes} == expected_cases and valid_wall
        wall = sum(row["measurement"]["wall_seconds"] for row in successes) if all_present else None
        durations = [source_seconds(row, corpus_by_id) for row in successes]
        audio = sum(durations) if all_present and all(value is not None for value in durations) else None
        workloads.append({"repeat": repeat, "status": "completed" if all_present else "incomplete",
            "completed_utterances": len(successes), "planned_utterances": len(expected_cases), "wall_seconds": wall,
            "audio_seconds": audio, "real_time_factor": wall / audio if wall is not None and audio else None,
            "end_to_end_audio_seconds_per_second": audio / wall if audio and wall else None})

    corpus_cases = [corpus_by_id.get(case[0], {}) for case in expected_cases]
    speaker_ids = {speaker for case in corpus_cases for speaker in case.get("speaker_ids", [])}
    session_ids = {case.get("session_id") for case in corpus_cases if case.get("session_id")}
    artifact_values = []
    for row in rows:
        artifact = row.get("artifact_metrics") or (row.get("measurement") or {}).get("artifact_metrics") or {}
        value = {key: artifact.get(key) for key in ARTIFACT_FIELDS}
        if value not in artifact_values:
            artifact_values.append(value)
    if len(artifact_values) > 1:
        # Missing metrics alongside available observations are allowed; conflicting observations are not.
        for field in ARTIFACT_FIELDS:
            observations = {value[field] for value in artifact_values if value[field] is not None}
            if len(observations) > 1:
                raise ValueError("Artifact identity has conflicting retained size/provenance observations")
    artifact = {key: next((value[key] for value in artifact_values if value[key] is not None), None) for key in ARTIFACT_FIELDS}
    return {**identity, "model_kind": rows[0].get("model_kind"), "baseline_model_id": rows[0].get("baseline_model_id"),
        "baseline_model_sha256": rows[0].get("baseline_model_sha256"), "coverage_role": rows[0].get("coverage_role"),
        "requested_cells": len(rows), "cell_status_counts": dict(sorted(Counter(row.get("status", "unknown") for row in rows).items())),
        "quality": quality, "timing": {"completed_cells": len(measured), "wall_seconds_per_utterance_invocation": distribution(row["measurement"].get("wall_seconds") for row in measured),
            "complete_workload_repeats": sum(item["status"] == "completed" for item in workloads),
            "complete_workload_wall_seconds": distribution(item["wall_seconds"] for item in workloads),
            "complete_workload_real_time_factor": distribution(item["real_time_factor"] for item in workloads),
            "complete_workload_end_to_end_audio_seconds_per_second": distribution(item["end_to_end_audio_seconds_per_second"] for item in workloads),
            "workloads": workloads, "model_load_seconds_per_native_invocation": load_observations(measured),
            "first_result_latency_seconds": None, "first_result_latency_status": "Unobserved in file-output CLI",
            "scope": "Wall time and derived throughput include job setup/inspection/load/inference/rendering; not steady decoder throughput"},
        "peak_process_rss_bytes": distribution(row["measurement"].get("peak_rss_bytes") for row in measured), "artifact_metrics": artifact,
        "sample_grouping": {"known_published_speaker_ids": len(speaker_ids), "unknown_speaker_cases": sum(not case.get("speaker_ids") for case in corpus_cases),
            "known_session_ids": len(session_ids), "unknown_session_cases": sum(not case.get("session_id") for case in corpus_cases),
            "source_manifest_reviewed_cases": sum(case.get("reviewed") is True for case in corpus_cases)},
        "utterance_repeats": utterances}


def summarize_comparisons(comparisons):
    groups = defaultdict(list)
    for row in comparisons:
        key = tuple(row.get(field) for field in ["comparison_id", "intervention", "baseline_model", "candidate_model", "candidate_profile", "language", "task", "language_mode", "path"])
        groups[key].append(row)
    result = []
    for key, rows in sorted(groups.items(), key=lambda item: tuple(str(value) for value in item[0])):
        fields = ["comparison_id", "intervention", "baseline_model", "candidate_model", "candidate_profile", "language", "task", "language_mode", "path"]
        value = dict(zip(fields, key))
        value.update(requested_pair_cells=len(rows), pair_status_counts=dict(sorted(Counter(row.get("status", "unknown") for row in rows).items())),
                     selection="Quality deltas use paired repeat 1 only; mean is per-utterance macro, not corpus weighted")
        required = ["id", "task", "language_mode", "path"]
        missing_direct_identity = any(any(not isinstance(row.get(field), str) or not row[field] for field in required)
            or not isinstance(row.get("repeat"), int) or isinstance(row.get("repeat"), bool) or row["repeat"] < 1 for row in rows)
        if missing_direct_identity:
            value.update(aggregation_status="unavailable; direct id/task/repeat/language_mode/path fields are required; legacy identity strings are not parsed",
                paired_first_repeat_utterances=None, macro_utterance_wer_delta=None, macro_utterance_cer_delta=None,
                critical_content_review="unmeasured")
            result.append(value)
            continue
        cells = [(row["id"], row["repeat"], str(row.get("source_channel"))) for row in rows]
        if len(cells) != len(set(cells)):
            raise ValueError("Duplicate paired comparison cell would double-count a sample/repeat")
        first = []
        for row in rows:
            if row["repeat"] == 1 and row.get("status") == "paired_exploratory":
                first.append(row)
        value.update(aggregation_status="observed direct comparison identities", paired_first_repeat_utterances=len(first))
        for field in ["baseline_model_sha256", "candidate_model_sha256"]:
            hashes = {row[field] for row in rows if row.get(field) is not None}
            if len(hashes) > 1:
                raise ValueError("Paired comparison changes its retained model artifact hash")
            value[field] = next(iter(hashes)) if hashes else None
        for metric_name in ["wer_delta", "cer_delta"]:
            values = [row.get(metric_name) for row in first if finite_number(row.get(metric_name))]
            value["macro_utterance_" + metric_name] = statistics.mean(values) if values and not (metric_name == "wer_delta" and chinese_cer_only(value.get("language"), "")) else None
        value["critical_content_review"] = "unmeasured"
        result.append(value)
    return result


def summarize(matrix, corpus=None, experiment=None, allow_held_out=False, freeze_verified=False):
    if matrix.get("split") == "held_out" and not (allow_held_out and freeze_verified and matrix.get("freeze_sha256")):
        raise ValueError("Held-out outcomes require explicit report opt-in after retained freeze evidence; no references will be read")
    rows = matrix.get("rows")
    if not isinstance(rows, list):
        raise ValueError("Expected retained benchmark rows")
    corpus, experiment = corpus or {}, experiment or {}
    cases = corpus.get("cases", [])
    corpus_by_id = {case.get("id"): case for case in cases}
    if len(corpus_by_id) != len(cases):
        raise ValueError("Duplicate corpus IDs")
    groups = defaultdict(list)
    for row in rows:
        groups[group_identity(row)].append(row)
    cohorts = [summarize_group(group, corpus_by_id) for _, group in sorted(groups.items(), key=lambda item: tuple(str(value) for value in item[0]))]
    cohorts.sort(key=lambda item: (LANGUAGE_ORDER.get(item.get("language"), 99), str(item.get("model")), str(item.get("language_mode")), str(item.get("profile")), str(item.get("task"))))
    model_sources = {model.get("id"): {key: model.get(key) for key in ["id", "checkpoint", "precision", "sha256", "kind", "baseline_model_id", "baseline_model_sha256", "intervention_id", "license"]} for model in experiment.get("models", [])}
    credits = {(case.get("license"), case.get("source_url")) for case in cases if case.get("license") or case.get("source_url")}
    host = matrix.get("host", {})
    return {"schema_version": VERSION, "created_utc": datetime.now(timezone.utc).isoformat(), "provenance": {key: matrix.get(key) for key in PROVENANCE_FIELDS},
        "host": {key: host.get(key) for key in ["os", "cpu_count", "physical_memory_bytes", "thermal_state", "hardware_evidence", "power_evidence", "toolchain_evidence"]},
        "model_sources": model_sources, "unique_source_utterances_planned": len({case_identity(row) for row in rows}),
        "requested_cells": len(rows), "completed_cells": sum(completed(row) for row in rows),
        "cell_status_counts": dict(sorted(Counter(row.get("status", "unknown") for row in rows).items())),
        "corpus_evaluation_tier": corpus.get("evaluation_tier"), "source_credits": [{"license": license, "source_url": url} for license, url in sorted(credits, key=str)],
        "cohorts": cohorts, "comparisons": summarize_comparisons(matrix.get("paired_comparisons", [])),
        "limitations": ["Exploratory published-reference pilot; review the per-language utterance counts before drawing representative multilingual accuracy conclusions",
            "Repeated inference is latency/variation evidence, not independent corpus samples; quality uses successful repeat 1 only",
            "Individual FLEURS speaker/session grouping, natural long-form/adverse conditions and independent native reference adjudication remain incomplete",
            "Swiss speech targets written Standard German; lexical scores alone do not establish preserved meaning or equivalent rendering variants",
            "Chinese whitespace WER is not reported; CER is reported under the exact retained normalization version",
            "Peak process RSS does not measure total unified CPU/GPU allocation; GPU memory and first-result latency remain unmeasured",
            "Upstream model-load timers are not complete process initialization; end-to-end throughput is not steady decoder throughput",
            "Public-source pretraining overlap is possible; no model/default promotion follows from this pilot",
            "No raw reference, hypothesis, private log or held-out reference files were read by this reporter"]}


def text(value):
    return str(value if value is not None else "—").replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def rate(value):
    return f"{100 * value:.2f}%" if finite_number(value) else "—"


def span(value, divisor=1, places=3):
    if value.get("median") is None:
        return "—"
    return f"{value['median'] / divisor:.{places}f} [{value['minimum'] / divisor:.{places}f}–{value['maximum'] / divisor:.{places}f}]"


def markdown(report):
    lines = ["# Exploratory Whisper pilot report", "", "This report summarizes retained measurements. It does not establish representative multilingual accuracy or authorize default promotion.", "",
        f"Source utterances: **{report['unique_source_utterances_planned']}**; completed inference cells: **{report['completed_cells']}/{report['requested_cells']}**.",
        "Quality uses successful repeat 1 only. Repeats do not increase the number of independent utterances. Missing/failed rows contribute no invented zero-error score.", "",
        "## Quality by language, task, model and language mode", "",
        "| Language | Task | Model | Mode / profile | Repeat-1 complete / planned utterances | WER (corpus weighted) | CER (corpus weighted) | Reference words / scalars |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for cohort in report["cohorts"]:
        quality = cohort["quality"]; wer, cer = quality.get("wer") or {}, quality["cer"]
        lines.append("| " + " | ".join([text(cohort.get("language")), text(cohort.get("task")), text(cohort.get("model")),
            text(str(cohort.get("language_mode")) + " / " + str(cohort.get("profile"))),
            f"{quality['completed_unique_utterances']} / {quality['planned_unique_utterances']}", rate(wer.get("corpus_weighted_rate")), rate(cer.get("corpus_weighted_rate")),
            text(wer.get("reference_units")) + " / " + text(cer.get("reference_units"))]) + " |")
    lines += ["", "Chinese WER is intentionally unreported. JSON includes edit counts, denominators, per-utterance macro rates, status counts and grouping gaps. Critical-content, semantic, language-ID and timing accuracy remain unmeasured.", "",
        "## Latency and resources", "", "Each workload repeat contains all planned utterances in that cohort. Incomplete workloads have no aggregate timing. Values are median [minimum–maximum].", "",
        "| Language | Model | Mode / profile | Completed cells | Complete workload repeats | Workload wall seconds | Workload RTF | Peak process RSS MiB | Upstream load seconds / invocation |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for cohort in report["cohorts"]:
        timing = cohort["timing"]
        lines.append("| " + " | ".join([text(cohort.get("language")), text(cohort.get("model")), text(str(cohort.get("language_mode")) + " / " + str(cohort.get("profile"))),
            f"{timing['completed_cells']} / {cohort['requested_cells']}", str(timing["complete_workload_repeats"]), span(timing["complete_workload_wall_seconds"]),
            span(timing["complete_workload_real_time_factor"]), span(cohort["peak_process_rss_bytes"], divisor=1024 * 1024, places=1), span(timing["model_load_seconds_per_native_invocation"])]) + " |")
    lines += ["", "RTF/throughput are end-to-end job measurements. Upstream load is a recognizer timer, not complete process initialization. RSS excludes a reliable total unified GPU allocation; first-result latency remains unobserved.", "",
        "## Model artifacts", "", "| Model | SHA-256 | Model bytes | Download artifact bytes | Allocated filesystem bytes | Incremental bundle bytes |", "| --- | --- | --- | --- | --- | --- |"]
    artifacts = {}
    for cohort in report["cohorts"]:
        artifacts[(cohort.get("model"), cohort.get("model_sha256"))] = cohort["artifact_metrics"]
    for (model, sha), metrics in sorted(artifacts.items(), key=str):
        lines.append("| " + " | ".join(text(value) for value in [model, sha, metrics.get("model_file_bytes"), metrics.get("download_artifact_bytes"), metrics.get("filesystem_allocated_bytes"), metrics.get("incremental_bundle_bytes")]) + " |")
    if report["comparisons"]:
        lines += ["", "## Paired comparisons", "", "Quality changes below are per-utterance macro deltas from paired repeat 1; they are not corpus-weighted deltas. Values are percentage-point changes. Negative error-rate changes indicate fewer lexical errors. Older rows without direct comparison identity fields remain unavailable for aggregation.", "",
            "| Comparison | Intervention | Language | Baseline → candidate | Paired first-repeat utterances | WER change (pp) | CER change (pp) |", "| --- | --- | --- | --- | --- | --- | --- |"]
        for comparison in report["comparisons"]:
            lines.append("| " + " | ".join([text(comparison.get("comparison_id")), text(comparison.get("intervention")), text(comparison.get("language")),
                text(str(comparison.get("baseline_model")) + " → " + str(comparison.get("candidate_model"))), text(comparison["paired_first_repeat_utterances"]),
                rate(comparison.get("macro_utterance_wer_delta")), rate(comparison.get("macro_utterance_cer_delta"))]) + " |")
    lines += ["", "## Provenance and limits", "", "Machine/software, model/checkpoint/precision identities, artifact hashes, experiment/corpus/scoring identities and raw-evidence pointers are retained in the JSON report and original matrix snapshots.", ""]
    for limitation in report["limitations"]:
        lines.append("- " + text(limitation))
    lines += ["", "Source attribution:", ""]
    for credit in report["source_credits"]:
        lines.append("- " + text(credit.get("license")) + " — " + text(credit.get("source_url")))
    return "\n".join(lines) + "\n"


def read_json(path):
    with path.open("rb") as source:
        data = source.read(MAXIMUM_JSON_BYTES + 1)
    if len(data) > MAXIMUM_JSON_BYTES:
        raise ValueError("Retained report input exceeds the 64 MiB bound")
    return data, json.loads(data)


def write_report(matrix_path, output, allow_held_out=False):
    matrix_path = matrix_path.resolve()
    if matrix_path.is_dir():
        matrix_path /= "matrix.json"
    data, matrix = read_json(matrix_path)
    if matrix.get("split") == "held_out" and not (allow_held_out and matrix.get("freeze_sha256")):
        raise ValueError("Held-out outcomes require explicit report opt-in after retained freeze evidence")
    snapshots, snapshot_evidence = [], {}
    for name, hash_field in [("corpus.original.json", "corpus_sha256"), ("experiment.original.json", "configuration_sha256")]:
        path = matrix_path.parent / name
        expected_hash = matrix.get(hash_field)
        if not path.is_file():
            snapshots.append({})
            snapshot_evidence[name] = {"status": "unavailable; metadata not inferred", "expected_sha256": expected_hash, "observed_sha256": None}
            continue
        snapshot_bytes, snapshot = read_json(path)
        actual_hash = hashlib.sha256(snapshot_bytes).hexdigest()
        if expected_hash is not None and expected_hash != actual_hash:
            raise ValueError("Retained " + name + " hash differs from the matrix evidence")
        snapshots.append(snapshot)
        snapshot_evidence[name] = {"status": "verified" if expected_hash is not None else "observed but not hash-locked by matrix",
                                  "expected_sha256": expected_hash, "observed_sha256": actual_hash}
    freeze_verified = False
    if matrix.get("split") == "held_out":
        freeze_path = matrix_path.parent / "freeze.original.json"
        if not freeze_path.is_file():
            raise ValueError("Held-out report requires the retained freeze.original.json snapshot")
        freeze_bytes, freeze = read_json(freeze_path)
        actual_hash = hashlib.sha256(freeze_bytes).hexdigest()
        if actual_hash != matrix.get("freeze_sha256"):
            raise ValueError("Retained freeze.original.json hash differs from the matrix evidence")
        if freeze.get("corpus_sha256") != matrix.get("corpus_sha256") or freeze.get("experiment_sha256") != matrix.get("configuration_sha256"):
            raise ValueError("Held-out freeze does not bind the same corpus/experiment")
        if freeze.get("frozen_before_held_out") is not True or not isinstance(freeze.get("budgets"), dict) or not freeze["budgets"]:
            raise ValueError("Held-out freeze lacks predeclared budgets/review attestation")
        if any(snapshot_evidence[name]["status"] != "verified" for name in ["corpus.original.json", "experiment.original.json"]):
            raise ValueError("Held-out report requires verified corpus and experiment snapshots")
        snapshot_evidence["freeze.original.json"] = {"status": "verified", "expected_sha256": matrix["freeze_sha256"], "observed_sha256": actual_hash}
        freeze_verified = True
    report = summarize(matrix, *snapshots, allow_held_out=allow_held_out, freeze_verified=freeze_verified)
    report["snapshot_evidence"] = snapshot_evidence
    report["source_matrix_sha256"] = hashlib.sha256(data).hexdigest()
    report["source_matrix"] = str(matrix_path)
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    with (output / "report.json").open("x") as destination:
        json.dump(report, destination, ensure_ascii=False, indent=2, allow_nan=False)
        destination.write("\n")
    with (output / "report.md").open("x") as destination:
        destination.write(markdown(report))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("matrix", type=Path)
    parser.add_argument("--output", type=Path, required=True, help="New protected external report directory")
    parser.add_argument("--allow-held-out", action="store_true", help="Use only after candidate/settings freeze and held-out execution")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.expanduser().resolve()
    if output == repo or repo in output.parents:
        parser.error("Retained corpus results must be outside the checkout/disposable root")
    report = write_report(args.matrix, output, allow_held_out=args.allow_held_out)
    print(json.dumps({"report_directory": str(output), "completed_cells": report["completed_cells"], "requested_cells": report["requested_cells"],
                      "unique_source_utterances": report["unique_source_utterances_planned"], "recognition_or_rescoring_performed": False}))


if __name__ == "__main__":
    main()
