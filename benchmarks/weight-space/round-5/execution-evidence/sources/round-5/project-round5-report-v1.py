#!/usr/bin/env python3
"""Project a complete frozen formatter output; never open raw/model/reference paths."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import io
import json
import math
from pathlib import Path
import re
import signal
import stat
import sys
import time

R = Path(__file__).absolute().parent
VERSION = "round5-report-projection-v1"
FORMATTER = "89400055507fa0e0a0f07e2352b53d5a5548a6fbf173c46cab672bd7e1663f81"
FAMILY = '0'*64
ADMISSION = '0'*64
LANGUAGES = ("de-CH", "de", "fr", "it", "en", "ar", "zh", "es", "pt")
FAMILIES = ("tiny", "base", "small", "large-v3-turbo", "large-v3")
STAGES = tuple(prefix + family for prefix in ("panel-", "dev-validation-", "heldout-") for family in FAMILIES)
MODEL_KINDS = {family + suffix: kind for family in ("small", "large-v3-turbo") for suffix, kind in
               (("", "pretrained"), ("-permuted-f16", "conversion_control"),
                ("-plain-q4", "compression"), ("-permuted-q4", "combined"))}
MODEL_KINDS.update({family: "pretrained" for family in ("tiny", "base", "large-v3")})
MAX_INPUT = 64 * 1024 * 1024
MAX_OUTPUT = 8 * 1024 * 1024
STOP = False
DEADLINE = None


def require(ok, message):
    if not ok:
        raise ValueError(message)


def check():
    if STOP or (R / "cancel-report-projection.request").exists():
        raise InterruptedError("Projection canceled; original metadata preserved")
    if DEADLINE is not None and time.monotonic() >= DEADLINE:
        raise TimeoutError("Projection exceeded finite metadata-only time bound")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def valid_sha(value):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value) is not None


def safe(path, existing=True):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts and R in path.parents,
            "Explicit protected path required")
    require(not any(p.is_symlink() for p in (path, *path.parents)), "Symlink metadata paths unsupported")
    if existing:
        require(stat.S_ISREG(path.stat().st_mode), "Regular metadata input required")
    return path


def read(path, digest, maximum):
    require(valid_sha(digest), "Exact input SHA required")
    path = safe(path)
    before = path.stat()
    require(before.st_size <= maximum, "Metadata input exceeds bound")
    data = bytearray()
    with path.open("rb") as stream:
        while True:
            check()
            block = stream.read(min(65536, maximum + 1 - len(data)))
            if not block:
                break
            data.extend(block)
            require(len(data) <= maximum, "Metadata input exceeds bound")
    after = path.stat()
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    require(identity(before) == identity(after) and sha(data) == digest, "Input changed or SHA differs")
    return bytes(data), {"path": str(path), "sha256": digest, "bytes": len(data)}


def pairs(items):
    value = {}
    for key, child in items:
        require(key not in value, "Duplicate JSON key")
        value[key] = child
    return value


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def near(actual, expected):
    return number(actual) and number(expected) and abs(actual - expected) <= 1e-12 * max(1, abs(expected))


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def distribution(value, maximum):
    require(isinstance(value, dict) and integer(value.get("measured_count"))
            and value["measured_count"] <= maximum, "Resource observation count differs")
    n = value["measured_count"]
    entries = [value.get(key) for key in ("minimum", "median", "maximum")]
    require((all(number(x) and x >= 0 for x in entries) and entries == sorted(entries)) if n else
            all(x is None for x in entries), "Resource distribution shape differs")
    return {"count": n, "minimum": entries[0], "median": entries[1], "maximum": entries[2]}


def metric(value, quality, planned, chinese_wer):
    if chinese_wer:
        require(value == {"status": "not_reported_chinese_whitespace_wer"}, "Chinese WER must remain unreported")
        return {"status": "not_reported_chinese_whitespace_wer", "planned": planned,
                "scored": None, "errors": None, "units": None, "observed_rate": None, "full_rate": None}
    require(value.get("planned_unique_sources") == planned and integer(value.get("scored_unique_sources"))
            and value["scored_unique_sources"] <= planned, "Quality source denominator differs")
    n = value["scored_unique_sources"]
    errors, units, observed = (value.get(key) for key in ("observed_errors", "observed_reference_units", "observed_rate"))
    require(quality.get("scored_unique_utterances") == n and quality.get("errors") == errors
            and quality.get("reference_units") == units, "Counted metric does not match retained quality")
    if n:
        require(integer(errors) and integer(units, 1) and near(observed, errors / units)
                and near(quality.get("corpus_weighted_rate"), observed), "Projected count/rate mismatch")
        components = [quality.get(key) for key in ("insertions", "deletions", "substitutions")]
        require(all(integer(x) for x in components) and sum(components) == errors, "Edit counts disagree")
    else:
        require(observed is None and quality.get("corpus_weighted_rate") is None, "Unscored metric must stay null")
    complete = n == planned
    require(value.get("coverage_complete") is complete, "Metric completeness flag differs")
    full = value.get("full_planned_rate")
    require(near(full, observed) if complete else full is None, "Missing full planned rate was replaced")
    return {"status": "complete" if complete else "PENDING_missing_quality", "planned": planned,
            "scored": n, "errors": errors, "units": units, "observed_rate": observed, "full_rate": full}


def project(summary):
    require(summary.get("schema_version") == "round5-retained-numeric-summary-v1"
            and summary.get("summary_source_sha256") == FORMATTER
            and summary.get("frozen_family_seal_sha256") == FAMILY
            and summary.get("admission_sha256") == ADMISSION, "Frozen formatter/family/admission differs")
    require(summary.get("terminal_plan_complete") is True and summary.get("integrity_failures") == []
            and summary.get("default_promotion") is False, "All15 verified terminal stages required; incomplete remains PENDING")
    require(summary.get("resource_acceptance") == "UNCONTROLLED / NOT EVALUATED"
            and summary.get("native_review") == summary.get("product_acceptance") == "PENDING", "Acceptance claims changed")
    require(isinstance(summary.get("preservation"), dict) and summary["preservation"]
            and all(v is False for v in summary["preservation"].values()), "Frozen preservation flags changed")
    stages = summary.get("stages")
    require(isinstance(stages, list) and [v.get("id") for v in stages] == list(STAGES), "All15 ordered stages required")
    artifacts = summary.get("artifacts", [])
    require(len(artifacts) == 11 and {v.get("id") for v in artifacts} == set(MODEL_KINDS), "All11 artifact identities required")
    models = {v["id"]: v for v in artifacts}
    for model in artifacts:
        require(model["kind"] == MODEL_KINDS[model["id"]] and valid_sha(model.get("sha256"))
                and integer(model.get("model_file_bytes"), 1), "Artifact kind/hash/positive file bytes differ")
    quality_rows, resource_rows, macro_rows, cohort_rows = [], [], [], []
    for index, stage in enumerate(stages):
        check()
        require(stage.get("status") == "COMPLETE_TERMINAL_ATTEMPT_EVIDENCE", "Stage lacks complete terminal evidence")
        phase = ("panel", "development", "held_out")[index // 5]
        family = FAMILIES[index % 5]
        require(stage.get("stage") == phase, "Stage phase differs")
        planned = (1, 8, 16)[index // 5]
        repeats = 3 if phase == "panel" else 1
        modes = ("known",) if phase == "development" else ("known", "auto")
        expected_models = {family + suffix for suffix in ("", "-permuted-f16", "-plain-q4", "-permuted-q4")} if family in ("small", "large-v3-turbo") else {family}
        observations = stage.get("artifact_observations", [])
        require(len(observations) == len(expected_models) and {v.get("id") for v in observations} == expected_models, "Artifact cohort grid differs")
        measured_cells = 0
        for observation in observations:
            model = models[observation["id"]]
            require(observation.get("kind") == model["kind"] and observation.get("sha256") == model["sha256"]
                    and observation.get("actual_model_file_bytes") == model["model_file_bytes"], "Observed artifact differs from frozen identity")
            require(len(observation.get("modes", [])) == len(modes)
                    and {v.get("language_mode") for v in observation["modes"]} == set(modes), "Mode grid differs")
            for mode in observation["modes"]:
                languages = mode.get("per_language", [])
                require(len(languages) == 9 and {v.get("language") for v in languages} == set(LANGUAGES), "Nine-language cohort grid differs")
                rates = {"cer": [], "wer": []}
                by_language = {v["language"]: v for v in languages}
                for language in LANGUAGES:
                    row = by_language[language]
                    require(row.get("task") == ("standard_rendering" if language == "de-CH" else "transcription")
                            and row.get("planned_unique_sources") == planned and integer(row.get("completed_unique_sources"))
                            and row["completed_unique_sources"] <= planned, "Language/task/source coverage differs")
                    prefix = {"stage": stage["id"], "phase": phase, "model": model["id"], "kind": model["kind"],
                              "mode": mode["language_mode"], "language": language, "task": row["task"],
                              "model_file_bytes": model["model_file_bytes"]}
                    projected = {key: metric(row["counted_metric_coverage"][key], row["quality"][key], planned,
                                             language == "zh" and key == "wer") for key in ("cer", "wer")}
                    for key in ("cer", "wer"):
                        if not (language == "zh" and key == "wer"):
                            rates[key].append(projected[key]["full_rate"])
                    quality_rows.append({**prefix, "completed_sources": row["completed_unique_sources"],
                        **{key + "_" + name: value for key, values in projected.items() for name, value in values.items()}})
                    timing = row["timing"]
                    require(integer(timing.get("completed_cells")) and timing["completed_cells"] <= planned * repeats, "Resource completed-cell denominator differs")
                    measured_cells += timing["completed_cells"]
                    distributions = {"wall_seconds": distribution(timing["wall_seconds_per_utterance_invocation"], timing["completed_cells"]),
                                     "workload_rtf": distribution(timing["complete_workload_real_time_factor"], repeats),
                                     "peak_process_rss_bytes": distribution(row["peak_process_rss_bytes"], timing["completed_cells"])}
                    load=timing['model_load_seconds_per_native_invocation']
                    require(integer(load.get('native_invocations_recorded')) and isinstance(load.get('parser_versions'),list)
                            and integer(load.get('measured_count')), 'Load observation provenance/count differs')
                    distributions['model_load_seconds']=distribution(load,load['measured_count'])
                    recorded_bytes = row["artifact_metrics"].get("model_file_bytes")
                    require(recorded_bytes is None or type(recorded_bytes) is int and recorded_bytes == model["model_file_bytes"], "Measured artifact bytes differ")
                    resource = {**prefix, "artifact_bytes_observed": recorded_bytes, "planned_sources": planned,
                                "completed_sources": row["completed_unique_sources"], "repeats": repeats,
                                "completed_invocations": timing["completed_cells"], "resource_acceptance": "UNCONTROLLED / NOT EVALUATED",
                                "model_load_native_invocations":load['native_invocations_recorded'],
                                "model_load_scope":"Upstream model load per native invocation; not full initialization/first result",
                                **{key + "_" + name: value for key, values in distributions.items() for name, value in values.items()}}
                    resource_rows.append(resource)
                    cohort_rows.append({**prefix, "quality": projected, "resources": distributions})
                macro = {}
                for key, count in (("cer", 9), ("wer", 8)):
                    valid = sum(value is not None for value in rates[key])
                    expected = sum(rates[key]) / count if valid == count else None
                    actual = mode.get("macro_" + key)
                    require(mode.get("macro_" + key + "_complete_languages") == valid
                            and (near(actual, expected) if expected is not None else actual is None), "Nine/eight-language macro projection differs")
                    macro.update({key + "_full_planned_rate": actual, key + "_complete_languages": valid,
                                  key + "_planned_languages": count})
                macro_rows.append({"stage": stage["id"], "phase": phase, "model": model["id"], "kind": model["kind"],
                                   "mode": mode["language_mode"], "model_file_bytes": model["model_file_bytes"], **macro})
        require(measured_cells == stage.get("completed_cells"), "Resource cohorts do not reconcile completed invocations")
    require((len(quality_rows), len(resource_rows), len(macro_rows)) == (495, 495, 55), "Final canonical projection grid differs")
    coverage = summary["coverage"]
    full_metrics=all(row['cer_full_rate'] is not None and (row['language']=='zh' or row['wer_full_rate'] is not None) for row in quality_rows)
    require(summary.get('complete_quality_coverage') is full_metrics,'Counted quality completeness differs from terminal-row success')
    for key in ("planned_cells", "attempted_cells", "completed_cells", "failed_cells"):
        require(integer(coverage.get(key)) and coverage[key] == sum(v.get(key, 0) for v in stages), "Stage/total attempt coverage differs")
    require(coverage["planned_cells"] == coverage["attempted_cells"] == 4554
            and coverage["completed_cells"] + coverage["failed_cells"] == 4554, "Terminal and successful quality coverage confused")
    return quality_rows, resource_rows, macro_rows, cohort_rows


def csv_bytes(rows):
    stream = io.StringIO(newline="")
    writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return stream.getvalue().encode()


def percent(value):
    return "PENDING" if value is None else f"{100 * value:.3f}%"


def stat_text(value, divisor=1):
    if not value["count"]:
        return "PENDING (n=0)"
    return f'{value["median"] / divisor:.3f} [{value["minimum"] / divisor:.3f}..{value["maximum"] / divisor:.3f}]; n={value["count"]}'


def markdown(summary, models, macros, cohorts):
    lines = ["# Round5 retained quality and resource projection", "", summary["status"], "",
             "All 4,554 fixed cells reached a terminal attempt. Failed cells remain unscored. Full planned metrics stay PENDING wherever quality is missing; observed partial counts are retained separately in quality.csv. No scoring, gate, selection or default change is made.", "",
             "Swiss de-CH speech uses a written Standard German rendering reference. Native approval, regional/script coverage and product acceptance remain pending. Chinese whitespace WER is unreported; macro CER averages nine languages and macro WER eight. Panel repeats are timing observations, not independent quality samples.", "",
             "Resource observations are UNCONTROLLED on a shared desktop. Wall latency includes each invocation; workload RTF, upstream model-load timers and process RSS retain their own observation counts. Load is not full initialization or first-result latency. Medians are never pooled or averaged across cohorts. GPU memory, energy and controlled resource acceptance are not inferred.", "",
             "| Artifact | Kind | Frozen file MiB | SHA-256 |", "| --- | --- | ---: | --- |"]
    for model in models:
        lines.append(f'| {model["id"]} | {model["kind"]} | {model["model_file_bytes"] / 1048576:.3f} | {model["sha256"]} |')
    lines += ["", "Plain Q4 versus original describes conventional compression; permuted Q4 versus plain Q4 isolates the additional AI effect. Derived arms retain the original F16 parent. This projection creates no new contrast or acceptance decision.", "",
              "## Held-out full planned macros", "", "| Model | Mode | Macro CER | Macro WER | Complete CER/WER languages |", "| --- | --- | ---: | ---: | --- |"]
    for row in macros:
        if row["phase"] == "held_out":
            lines.append(f'| {row["model"]} | {row["mode"]} | {percent(row["cer_full_planned_rate"])} | {percent(row["wer_full_planned_rate"])} | {row["cer_complete_languages"]}/9; {row["wer_complete_languages"]}/8 |')
    for mode in ("known", "auto"):
        for language in LANGUAGES:
            lines += ["", "## Held-out " + language + " / " + mode, "",
                      "| Model | Full planned CER (scored/planned) | Full planned WER (scored/planned) | File MiB | Wall seconds median [min..max]; n | Workload RTF median [min..max]; n | Upstream load seconds median [min..max]; n | Peak process RSS MiB median [min..max]; n |",
                      "| --- | --- | --- | ---: | --- | --- | --- | --- |"]
            for row in cohorts:
                if row["phase"] != "held_out" or row["mode"] != mode or row["language"] != language:
                    continue
                def quality(key):
                    value = row["quality"][key]
                    return "unreported" if value["scored"] is None else percent(value["full_rate"]) + f' ({value["scored"]}/{value["planned"]})'
                resource = row["resources"]
                lines.append(f'| {row["model"]} | {quality("cer")} | {quality("wer")} | {row["model_file_bytes"] / 1048576:.3f} | {stat_text(resource["wall_seconds"])} | {stat_text(resource["workload_rtf"])} | {stat_text(resource["model_load_seconds"])} | {stat_text(resource["peak_process_rss_bytes"], 1048576)} |')
    lines += ["", "CSV files retain all panel, development and held-out cohort counts/rates/resources without rounding. These tables are a projection of the frozen formatter, not independent rescoring or native semantic review.", ""]
    return "\n".join(lines).encode()


def main(argv=None):
    global STOP, DEADLINE, FAMILY, ADMISSION
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("summary", "summary-sha256", "family-seal-sha256", "admission-capsule-sha256", "expected-source-sha256", "output"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args(argv)
    require(valid_sha(args.family_seal_sha256) and valid_sha(args.admission_capsule_sha256), 'Explicit frozen family/admission hashes required')
    FAMILY=args.family_seal_sha256; ADMISSION=args.admission_capsule_sha256
    STOP = False
    DEADLINE = time.monotonic() + 45
    def stop(_number, _frame):
        global STOP
        STOP = True
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, stop)
    _, source = read(Path(__file__).absolute(), args.expected_source_sha256, 1024 * 1024)
    raw, input_descriptor = read(Path(args.summary), args.summary_sha256, MAX_INPUT)
    summary = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                         parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite JSON unsupported")))
    quality, resources, macros, cohorts = project(summary)
    files = {"quality.csv": csv_bytes(quality), "resources.csv": csv_bytes(resources),
             "macros.csv": csv_bytes(macros), "report.md": markdown(summary, summary["artifacts"], macros, cohorts)}
    audit = {"schema_version": VERSION, "created_utc": datetime.now(timezone.utc).isoformat(),
             "input_summary": input_descriptor, "projection_source": source, "formatter_sha256": FORMATTER,
             "frozen_family_sha256": FAMILY, "admission_sha256": ADMISSION,
             "status": "PASSED_NUMERIC_PROJECTION_AUDIT_NO_ACCEPTANCE_CLAIM", "summary_status": summary["status"],
             "all_terminal_attempts": True, "complete_quality_coverage": summary["complete_quality_coverage"],
             "coverage": summary["coverage"], "artifacts": 11, "language_cohorts": 495, "canonical_model_modes": 55,
             "checks": ["count/denominator rates", "edit-count sums", "full-planned null coverage", "CER9/WER8 macros",
                        "canonical source versus repeated timing denominators", "artifact identity/file bytes", "resource distribution shape/counts"],
             "frozen_family_conclusions": summary["family_conclusions"],
             "resource_acceptance": "UNCONTROLLED / NOT EVALUATED", "native_review": "PENDING", "product_acceptance": "PENDING",
             "raw_reference_audio_model_paths_followed": False, "rescoring_performed": False,
             "new_gates_or_statistical_claims": False, "default_promotion": False,
             "output_sha256": {name: sha(data) for name, data in files.items()}}
    files["audit.json"] = (json.dumps(audit, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode()
    require(sum(len(data) for data in files.values()) <= MAX_OUTPUT, "Projection output exceeds fixed bound")
    output = safe(Path(args.output), existing=False)
    require(not output.exists(), "New protected projection directory required")
    check()
    output.mkdir(mode=0o700)
    for name, data in files.items():
        check()
        with (output / name).open("xb") as stream:
            stream.write(data)
        (output / name).chmod(0o600)
    print(json.dumps({"output": str(output), "input_sha256": input_descriptor["sha256"], "source_sha256": source["sha256"],
                      "status": audit["status"], "output_sha256": {name: sha(data) for name, data in files.items()},
                      "default_promotion": False}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except InterruptedError as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        raise SystemExit(130)
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        raise SystemExit(1)
