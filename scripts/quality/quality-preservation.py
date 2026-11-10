#!/usr/bin/env python3
"""Paired lexical non-inferiority from retained counts, never reference text.

Source-unit intervals are descriptive when speaker/session independence is
unknown. A numerical pass never authorizes corpus approval or model promotion.
"""
from fractions import Fraction
import hashlib
import math
import random
import re

VERSION = "paired-quality-preservation-v1"
COMPLETED = {"completed", "completed_with_review"}
FIELDS = {"schema_version", "languages", "primary_languages", "word_metric_excluded_languages",
          "macro_cer_margin", "macro_wer_margin", "language_cer_margin", "language_wer_margin",
          "paired_sources_per_language", "bootstrap_draws", "bootstrap_seed", "confidence"}
IDENTITY = ("source_sha256", "reference_sha256", "task", "source_channel", "scoring_policy",
            "runtime_settings_sha256", "transcription_runner_sha256", "whisper_binary_sha256",
            "profile_sha256", "vad_model_sha256")


def validate(policy):
    if set(policy) != FIELDS or policy["schema_version"] != "1.0":
        raise ValueError("Invalid quality_preservation_policy fields/schema")
    for field in ("languages", "primary_languages", "word_metric_excluded_languages"):
        values = policy[field]
        if not isinstance(values, list) or any(
                not isinstance(v, str) or not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*", v) for v in values) or len(set(values)) != len(values):
            raise ValueError("Quality preservation needs unique language tags")
    if not 1 <= len(policy["languages"]) <= 30 or not policy["primary_languages"] or not set(
            policy["primary_languages"]) <= set(policy["languages"]) or not set(
            policy["word_metric_excluded_languages"]) <= set(policy["languages"]):
        raise ValueError("Invalid primary/excluded language cohorts")
    for key in ("macro_cer_margin", "macro_wer_margin", "language_cer_margin", "language_wer_margin"):
        value = policy[key]
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value < 1:
            raise ValueError("Quality margins must be finite rates in [0,1)")
    for key, lower, upper in (("paired_sources_per_language", 1, 1000), ("bootstrap_draws", 100, 10000),
                               ("bootstrap_seed", 0, 2 ** 64 - 1)):
        if type(policy[key]) is not int or not lower <= policy[key] <= upper:
            raise ValueError("Quality bootstrap/count budget is invalid")
    if type(policy["confidence"]) not in (int, float) or not math.isfinite(policy["confidence"]) or not .5 < policy["confidence"] < 1:
        raise ValueError("Use a one-sided confidence level between .5 and 1")


def digest(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def key(row):
    return tuple(row.get(k) for k in ("model", "profile", "language_mode", "language", "id", "source_channel", "task"))


def counts(measurement, metric):
    prefix, units = ("character", "reference_characters") if metric == "cer" else ("word", "reference_words")
    fields = [prefix + "_errors", units] + [prefix + "_" + op for op in ("insertions", "deletions", "substitutions")]
    values = [measurement.get(field) for field in fields]
    if any(type(v) is not int or v < 0 for v in values) or values[1] <= 0 or values[0] != sum(values[2:]):
        raise ValueError("Quality preservation requires consistent integer edit counts and positive denominators")
    return dict(zip(("errors", "units", "insertions", "deletions", "substitutions"), values))


def measured(pairs, metric, margin, draws, confidence):
    before = {field: sum(pair[metric][0][field] for pair in pairs) for field in ("errors", "units", "insertions", "deletions", "substitutions")}
    after = {field: sum(pair[metric][1][field] for pair in pairs) for field in before}
    point = Fraction(after["errors"] - before["errors"], before["units"])
    samples = [Fraction(sum(pairs[i][metric][1]["errors"] - pairs[i][metric][0]["errors"] for i in indices),
                        sum(pairs[i][metric][0]["units"] for i in indices)) for indices in draws]
    return decision(point, samples, margin, confidence, baseline=before, candidate=after), point, samples


def decision(point, samples, margin, confidence, **extra):
    rank = math.ceil(confidence * len(samples)) - 1
    upper = sorted(samples)[rank]
    return dict(point_delta=float(point), one_sided_upper_delta=float(upper), margin=margin,
                gate="pass_exploratory" if upper <= Fraction(str(margin)) else "fail_exploratory", **extra)


def evaluate(matrix, corpus, experiment):
    policy = experiment.get("quality_preservation_policy")
    if policy is None:
        return {"version": VERSION, "status": "not_requested", "comparisons": []}
    validate(policy)
    if matrix.get("measurement_scope") == "resources_only":
        return {"version": VERSION, "status": "UNMEASURED; resource-only scope", "comparisons": []}
    models = {m["id"]: m for m in experiment.get("models", [])}
    rows, index = matrix.get("rows", []), {}
    for row in rows:
        if row.get("repeat") != 1 or row.get("path") != "final":
            continue
        identity = key(row)
        if identity in index:
            raise ValueError("Duplicate first-repeat quality cell")
        index[identity] = row
    selected = [c for c in corpus.get("cases", []) if c.get("split") == matrix.get("split")]
    cases = {c["id"]: c for c in selected}
    if len(cases) != len(selected):
        raise ValueError("Duplicate quality corpus ID")
    specifications = experiment.get("comparisons", [])
    if not 1 <= len(specifications) <= 100:
        raise ValueError("Quality preservation requires 1–100 declared parent comparisons")
    results = []
    for spec in specifications:
        before, after = (models.get(spec.get(k)) for k in ("baseline_model_id", "candidate_model_id"))
        if (not before or not after or spec.get("intervention") != "compression"
                or before.get("kind", "pretrained") != "pretrained" or after.get("kind") != "compression"
                or not all(digest(m.get("sha256")) for m in (before, after)) or before["sha256"] == after["sha256"]
                or after.get("baseline_model_id") != before["id"] or after.get("baseline_model_sha256") != before["sha256"]
                or spec.get("baseline_profile_id") != spec.get("candidate_profile_id")):
            raise ValueError("Quality preservation requires isolated compression and one hashed untouched parent/profile")
        for mode in experiment.get("language_modes", []):
            languages, points, samples = [], {}, {}
            for language in policy["languages"]:
                language_cases = sorted((c for c in cases.values() if c.get("language") == language), key=lambda c: c["id"])
                pairs, sources = [], set()
                for case in language_cases:
                    source = case.get("source_id")
                    if not source or source in sources:
                        raise ValueError("Quality source units must be declared and unique")
                    sources.add(source)
                    common = (mode, language, case["id"], case.get("source_channel"), case.get("task"))
                    a = index.get((before["id"], spec["baseline_profile_id"], *common))
                    b = index.get((after["id"], spec["candidate_profile_id"], *common))
                    if not a or not b or any(r.get("status") not in COMPLETED or (r.get("measurement") or {}).get("status") not in COMPLETED for r in (a, b)):
                        continue
                    if (any(a.get(k) != b.get(k) for k in IDENTITY) or any(not digest(a.get(k)) for k in (
                            "source_sha256", "reference_sha256", "runtime_settings_sha256", "transcription_runner_sha256",
                            "whisper_binary_sha256", "profile_sha256")) or a["source_sha256"] != case.get("sha256")
                            or a["reference_sha256"] != case.get("reference_sha256")
                            or a.get("model_sha256") != before["sha256"] or b.get("model_sha256") != after["sha256"]):
                        raise ValueError("Paired quality model/source/reference/runtime identity mismatch")
                    if a.get("measurement_scope") == "resources_only" or b.get("measurement_scope") == "resources_only" or a["measurement"].get("measurement_scope") == "resources_only" or b["measurement"].get("measurement_scope") == "resources_only":
                        raise ValueError("Unscored resource row cannot become a quality observation")
                    if a["measurement"].get("scoring_version") != b["measurement"].get("scoring_version") or a["measurement"].get("scoring_version") != a.get("scoring_policy"):
                        raise ValueError("Paired quality scorer versions differ")
                    pair = {}
                    for metric in ("cer", "wer"):
                        if metric == "wer" and language in policy["word_metric_excluded_languages"]:
                            continue
                        x, y = (counts(r["measurement"], metric) for r in (a, b))
                        if x["units"] != y["units"]:
                            raise ValueError("Paired quality reference denominators differ")
                        pair[metric] = (x, y)
                    pairs.append(pair)
                required = policy["paired_sources_per_language"]
                complete = len(language_cases) == required and len(pairs) == required
                value = dict(language=language, planned_source_units=len(language_cases), paired_source_units=len(pairs), required_source_units=required,
                             completeness="complete" if complete else "pending", cer=None, wer=None)
                if complete:
                    seed = int.from_bytes(hashlib.sha256(f'{policy["bootstrap_seed"]}:{spec["id"]}:{mode}:{language}'.encode()).digest()[:8], "big")
                    rng = random.Random(seed)
                    draws = [[rng.randrange(required) for _ in range(required)] for _ in range(policy["bootstrap_draws"])]
                    value["resampling_seed"] = seed
                    for metric in pairs[0]:
                        value[metric], points[(language, metric)], samples[(language, metric)] = measured(
                            pairs, metric, policy["language_" + metric + "_margin"], draws, policy["confidence"])
                languages.append(value)
            macros = {}
            for metric in ("cer", "wer"):
                names = [name for name in policy["primary_languages"] if metric != "wer" or name not in policy["word_metric_excluded_languages"]]
                if names and all((name, metric) in samples for name in names):
                    point = sum((points[(name, metric)] for name in names), Fraction()) / len(names)
                    values = [sum((samples[(name, metric)][i] for name in names), Fraction()) / len(names) for i in range(policy["bootstrap_draws"])]
                    macros[metric] = decision(point, values, policy["macro_" + metric + "_margin"], policy["confidence"], languages=names)
                else:
                    macros[metric] = None
            gates = [v[metric]["gate"] for v in languages for metric in ("cer", "wer") if v[metric] is not None]
            gates += [v["gate"] for v in macros.values() if v is not None]
            complete = all(v["completeness"] == "complete" for v in languages) and all(v is not None for v in macros.values())
            status = "fail_exploratory" if "fail_exploratory" in gates else ("pass_exploratory" if complete else "pending")
            results.append(dict(comparison_id=spec["id"], baseline_model=before["id"], candidate_model=after["id"], language_mode=mode,
                status=status, complete=complete, languages=languages, primary_macro=macros,
                aggregation="Equal primary languages; corpus-weighted edit counts within each language; Swiss has a separate floor"))
    return dict(version=VERSION, status="exploratory", policy=policy, comparisons=results,
                source_unit_independence="Unknown speaker/session dependence; unadjusted descriptive intervals, not population equivalence",
                bootstrap_method="Stratified source resampling with replacement; nearest-rank one-sided upper quantile; fixed SHA-derived cohort seeds",
                reference_review="NOT_ASSESSED", product_acceptance="NOT_AUTHORIZED; native/representative/reference/resource gates remain required")
