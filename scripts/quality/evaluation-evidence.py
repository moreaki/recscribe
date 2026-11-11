#!/usr/bin/env python3
"""Metadata-only preparation evidence for the existing corpus/matrix reporter.

No reference text, recognition, download, normalization or corpus approval.
"""
from collections import Counter, defaultdict
from decimal import Decimal
import math
import re

PRIORITY_LANGUAGES = ("de-CH", "de", "fr", "it", "en", "ar", "zh", "es", "pt")
VERSION = "evaluation-preparation-v1"


def corpus_preparation(corpus):
    """Inventory declarations; native CorpusManifest remains eligibility authority."""
    groups = defaultdict(list)
    for case in corpus.get("cases", []):
        groups[(case.get("language"), case.get("split"), case.get("task"))].append(case)
    cohorts = []
    for (language, split, task), cases in sorted(groups.items(), key=str):
        gaps = Counter()
        for case in cases:
            for field in ("audio", "reference", "sha256", "reference_sha256", "license", "source_url",
                          "variety", "script", "domain", "session_id", "source_id", "reference_conventions"):
                if not case.get(field):
                    gaps[field] += 1
            if task != "non_speech" and not case.get("speaker_ids"):
                gaps["speaker_ids"] += 1
            if case.get("reviewed") is not True:
                gaps["human_review"] += 1
            if not isinstance(case.get("duration_seconds"), (int, float)) or isinstance(case.get("duration_seconds"), bool) or not math.isfinite(case["duration_seconds"]) or not case["duration_seconds"] > 0:
                gaps["duration_seconds"] += 1
            if case.get("source_channel") is None:
                gaps["source_channel"] += 1
        cohorts.append({"language": language, "split": split, "task": task, "declared_cases": len(cases),
            "declared_reviewed_cases": sum(c.get("reviewed") is True for c in cases),
            "known_speakers": len({s for c in cases for s in c.get("speaker_ids", [])}),
            "known_sessions": len({c["session_id"] for c in cases if c.get("session_id")}),
            "declared_varieties": sorted({c["variety"] for c in cases if c.get("variety")}),
            "declared_scripts": sorted({c["script"] for c in cases if c.get("script")}),
            "declared_conditions": sorted({v for c in cases for v in c.get("conditions", [])}),
            "missing_evidence_counts": dict(sorted(gaps.items())),
            "cases_needing_preparation": [{"id": c.get("id"), "reviewed": c.get("reviewed") is True}
                                           for c in cases if c.get("reviewed") is not True]})
    primary = [c for c in corpus.get("cases", []) if c.get("coverage_role") != "optional" and not c.get("parent_case_id")
               and c.get("task") != "non_speech"]
    return {"version": VERSION, "schema_version": corpus.get("schema_version"), "cohorts": cohorts,
        "missing_priority_language_splits": [{"language": language, "split": split}
            for language in PRIORITY_LANGUAGES for split in ("development", "held_out")
            if not any(c.get("language") == language and c.get("split") == split for c in primary)],
        "approval": "NOT_ASSESSED; declarations do not verify files, reference correctness, timing or independence",
        "eligibility_authority": "native CorpusManifest validation and eligibility; no legacy-to-v2 approval inferred"}


def model_size_decisions(policy, models, observations):
    """Evaluate ONLY file-size gates against explicitly named artifact identities."""
    if policy is None:
        return {"status": "not_requested", "comparisons": []}
    if policy.get("schema_version") != "1.0" or set(policy) != {"schema_version", "minimum_reduction_percent", "comparisons"}:
        raise ValueError("Invalid model_size_policy schema/fields")
    percent = policy["minimum_reduction_percent"]
    if isinstance(percent, bool) or not isinstance(percent, (int, float)):
        raise ValueError("Model-size threshold must be a finite percentage")
    threshold = Decimal(str(percent))
    if not threshold.is_finite() or not 0 < threshold < 100:
        raise ValueError("Model-size threshold must be between zero and 100")
    specs = policy["comparisons"]
    if not isinstance(specs, list) or not 1 <= len(specs) <= 1000:
        raise ValueError("Declare 1–1000 size comparisons")
    model_map = {m["id"]: m for m in models}
    if len(model_map) != len(models):
        raise ValueError("Duplicate model identities")
    sizes = {}
    for row in observations:
        key = (row.get("model"), row.get("model_sha256"))
        value = (row.get("artifact_metrics") or {}).get("model_file_bytes")
        if value is None:
            continue
        if type(value) is not int or value <= 0:
            raise ValueError("Model-file bytes must be positive integers")
        if key in sizes and sizes[key] != value:
            raise ValueError("Conflicting model-file byte observations")
        sizes[key] = value
    results, ids = [], set()
    for spec in specs:
        if set(spec) != {"id", "baseline_model_id", "candidate_model_id", "purpose"} or spec["id"] in ids:
            raise ValueError("Invalid or duplicate size comparison")
        ids.add(spec["id"])
        purpose = spec["purpose"]
        before = model_map.get(spec["baseline_model_id"])
        after = model_map.get(spec["candidate_model_id"])
        if not before or not after or before["id"] == after["id"] or purpose not in {"same_model_compression", "cross_model_replacement"}:
            raise ValueError("Size comparison needs distinct configured models and an explicit purpose")
        for m in (before, after):
            if not re.fullmatch(r"[0-9a-f]{64}", m.get("sha256") or ""):
                raise ValueError("Size comparison needs exact model SHA-256 identities")
        if purpose == "same_model_compression" and (before.get("kind", "pretrained") != "pretrained" or
                after["sha256"] == before["sha256"] or after.get("kind") != "compression" or
                after.get("baseline_model_id") != before["id"] or after.get("baseline_model_sha256") != before["sha256"]):
            raise ValueError("Compression size gate must name its declared unchanged parent")
        a, b = (sizes.get((m["id"], m["sha256"])) for m in (before, after))
        result = {**spec, "baseline_sha256": before["sha256"], "candidate_sha256": after["sha256"],
            "baseline_model_file_bytes": a, "candidate_model_file_bytes": b,
            "minimum_reduction_percent": percent, "reduction_percent": None, "size_gate": "pending",
            "quality_gate": "NOT_EVALUATED", "latency_memory_gate": "NOT_EVALUATED",
            "promotion": "NOT_AUTHORIZED_BY_SIZE_GATE"}
        if a is not None and b is not None:
            result["reduction_percent"] = float(100 * (Decimal(a) - Decimal(b)) / Decimal(a))
            result["size_gate"] = "pass" if Decimal(b) * 100 <= Decimal(a) * (100 - threshold) else "fail"
        results.append(result)
    return {"status": "evaluated_file_size_only", "comparisons": results}
