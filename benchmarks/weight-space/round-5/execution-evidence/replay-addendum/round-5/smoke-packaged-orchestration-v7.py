#!/usr/bin/env python3
"""Enrich a NEW full15 model-free fixture before its first sealed toy stage.

The frozen earlier smoke driver intercepts only guarded_inference. Its real
classifier, reporter, assessor and held-out sealer CLI writes remain unchanged.
All created inputs and measurements are invented synthetic fixtures, never
native admission, benchmark observations or real corpus/model payloads.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent
DRIVER_SHA = "968bd9ce50ebcc5254ce550f3cad7e7e039695ca1e5f433382628c4075059dad"
FACTORY_SHA = "298eeacd5b50b540eae22a116a5355eea8da909b1ada239f03c212a21ffe85e4"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with Path(path).open("rb") as stream:
        raw = stream.read(1024 * 1024 + 1)
    require(len(raw) <= 1024 * 1024, "Synthetic source exceeds 1MiB")
    return hashlib.sha256(raw).hexdigest()


def load(name, path, expected):
    require(digest(path) == expected, "Pinned synthetic source differs: " + path.name)
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--enrichment-source", type=Path, required=True)
    parser.add_argument("--enrichment-source-sha256", required=True)
    args = parser.parse_args(argv)
    output = args.output
    require(output.is_absolute() and output.parent == ROOT and not output.exists()
            and output.name.startswith("packaged-smoke-fixture-v7")
            and not any(path.is_symlink() for path in (output, *output.parents)),
            "New exclusive protected v7 fixture required")
    require(args.enrichment_source.is_absolute()
            and args.enrichment_source.parent == ROOT,
            "Explicit protected enrichment source required")
    sources = {
        "driver": {"path": str(ROOT / "smoke-packaged-orchestration.py"), "sha256": DRIVER_SHA},
        "factory": {"path": str(ROOT / "test-orchestration.py"), "sha256": FACTORY_SHA},
        "enrichment": {"path": str(args.enrichment_source), "sha256": args.enrichment_source_sha256},
        "v7": {"path": str(Path(__file__).resolve()), "sha256": digest(__file__)},
    }
    driver = load("round5_frozen_model_free_smoke_v7", Path(sources["driver"]["path"]), DRIVER_SHA)
    factory = load("round5_frozen_fixture_factory_v7", Path(sources["factory"]["path"]), FACTORY_SHA)
    enrichment = load("round5_rich_synthetic_enrichment_v7", args.enrichment_source,
                      args.enrichment_source_sha256)

    class DeferredFixture(factory.Fixture):
        def publish(self):
            # Fixture.__init__ calls publish. Delay that first seal until every
            # richer immutable synthetic descriptor has been registered.
            pass

    output.mkdir(mode=0o700)
    fixture = DeferredFixture(output)
    require(not (output / "pre-inference-family-seal.json").exists(),
            "Fixture was published before enrichment")
    enrichment.enrich(fixture)
    factory.Fixture.publish(fixture)
    family = fixture.verified()
    attestation = family.attestation
    context = enrichment.finalize(fixture, attestation)
    require(type(context) is dict, "Explicit rich synthetic admission context required")
    require(digest(fixture.path) == fixture.sha,
            "Post-seal enrichment changed the family")
    family.verify_all()
    require(not Path(fixture.family["paths"]["journal"]).exists(),
            "Toy journal already exists before rich metadata is final")
    original_synthetic_matrix = driver.synthetic_matrix

    def timed_synthetic_matrix(family, stage, *positional, **keywords):
        started = time.time()
        result = original_synthetic_matrix(family, stage, *positional, **keywords)
        matrix_path = Path(stage["paths"]["matrix_json"])
        matrix = json.loads(matrix_path.read_text())
        for row in matrix["rows"]:
            row.setdefault("conditions", None)
            row.setdefault("coverage_role", None)
            measurement = row.get("measurement")
            if row["status"] in ("completed", "completed_with_review"):
                require(type(measurement) is dict, "Successful toy measurement required")
                measurement.update(
                    normalization="swift-nfc-casefold-alphanumeric-v1; punctuation to spaces, collapsed whitespace; CER omits spaces",
                    character_unit="Unicode scalar after normalization; spaces omitted",
                    word_segmentation="whitespace-v1",
                    memory_method="macOS time -l; maximum process RSS, not summed concurrent memory")
                wall = measurement["wall_seconds"]
                duration = measurement["source_audio_seconds"]
                measurement["real_time_factor"] = wall / duration if duration > 0 else None
                measurement["end_to_end_audio_seconds_per_second"] = duration / wall if wall > 0 and duration > 0 else None
        matrix_path.write_text(json.dumps(matrix, allow_nan=False) + "\n")
        ended = time.time()
        path = Path(stage["paths"]["guard_receipt"])
        guard = [json.loads(line) for line in path.read_text().splitlines()]
        require(len(guard) == 2 and guard[0]["event"] == "starting"
                and guard[-1]["event"] == "finished", "Exact invented guard fixture required")
        for event, timestamp in zip(guard, (started, ended)):
            event.update(time=timestamp, synthetic_model_free_fixture=True,
                         time_scope="Actual toy metadata generation; no native process executed")
        path.write_text("".join(json.dumps(event, allow_nan=False) + "\n" for event in guard))
        return result

    driver.synthetic_matrix = timed_synthetic_matrix
    driver.drive(output, fixture.sha, attestation)
    events = [json.loads(line) for line in Path(fixture.family["paths"]["journal"]).read_text().splitlines()]
    finish = events[-1]
    expected = {"attempted_cells": 4554, "completed_cells": 4552, "failed_cells": 2,
                "completed_native_parent_pairs": 2481, "pending_native_parent_pairs": 3,
                "completed_assessor_derived_q4_pairs": 828, "runtime_reference_placeholders": 1242}
    require(finish["event"] == "serial_finished"
            and all(type(finish.get(key)) is int and finish[key] == value
                    for key, value in expected.items()), "Full15 toy terminal counts differ")
    require(finish["all_native_cells_successful"] is False
            and "complete_quality_coverage" not in finish
            and sum(event["event"] == "stage_assessed" for event in events) == 15,
            "Toy failed coverage or stage count changed")
    require(all(event.get("synthetic_model_free_fixture") is True for event in events),
            "Every toy event must remain explicitly synthetic")
    for descriptor in sources.values():
        require(digest(descriptor["path"]) == descriptor["sha256"],
                "Synthetic source changed during CLI-write smoke")
    receipt = {
        "schema_version": "round5-rich-packaged-model-free-cli-write-smoke-v7",
        "status": "passed", "fixture_root": str(output), "synthetic_only": True,
        "recognition_or_model_initialization_or_quantization_executed": False,
        "actual_unmodified_classifier_reporter_assessor_sealer_cli_executed": True,
        "enrichment_finished_before_first_toy_stage": True,
        "immutable_enrichment_finished_before_first_family_publication": True,
        "classifier_receipt_aliases_created": False,
        "canonical_native_row_null_keys_supplied_in_toy_fixture": ["conditions", "coverage_role"],
        "canonical_native_scoring_and_resource_metadata_supplied_in_toy_fixture": True,
        "native_idle_is_synthetic_fixture_only_not_actual_admission": True,
        "stage_count": 15, "terminal_counts": expected, "sources": sources,
        "family_sha256": fixture.sha,
        "journal_sha256": digest(fixture.family["paths"]["journal"]),
        "rich_context": context,
    }
    driver.write(output / "packaged-smoke-v7.receipt.json", receipt)
    print(json.dumps(receipt, allow_nan=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
