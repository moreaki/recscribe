#!/usr/bin/env python3
"""Continue only unstarted stages; preserve interrupted candidate development.

No inference retries. All five original F16 development baselines must be
complete before any held-out release. Numerical budgets/settings stay fixed.
"""
from datetime import datetime, timezone, timedelta
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time

SPEC = importlib.util.spec_from_file_location("frozen_quality_campaign", Path(__file__).with_name("campaign-runner-v1.py"))
original = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(original)


def validate_baselines(cases, rows, models):
    expected = {(model, c["id"], mode) for model in models for c in cases for mode in ("known", "auto")}
    by_id = {c["id"]: c for c in cases}
    observed = set()
    for row in rows:
        if row["model"] not in models: continue
        key = (row["model"], row["id"], row["language_mode"])
        if key in observed: raise ValueError("Duplicate untouched development baseline")
        observed.add(key)
        case = by_id[row["id"]]
        if (row["status"] not in ("completed", "completed_with_review") or row.get("repeat") != 1
                or row.get("path") != "final" or row.get("source_sha256") != case["sha256"]
                or row.get("reference_sha256") != case["reference_sha256"]
                or row.get("measurement", {}).get("reference_characters", 0) <= 0
                or row.get("measurement", {}).get("scoring_version") != "swift-nfc-casefold-alphanumeric-v1"):
            raise ValueError("Untouched development baseline is incomplete or changed")
    if observed != expected: raise ValueError("All untouched development baselines required")
    return len(observed)


class Continuation(original.Campaign):
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.plan_path = self.root / "campaign.execution-plan.json"
        self.plan = json.loads(self.plan_path.read_text())
        self.repo = Path(self.plan["repository_root"])
        checkpoint = json.loads((self.root / "continuation-v1.plan.json").read_text())
        if original.sha(__file__) != checkpoint["coordinator_sha256"] or original.sha(self.plan_path) != checkpoint["original_execution_plan_sha256"]:
            raise ValueError("Continuation/original source seal differs")
        for item in checkpoint["preserved_files"]:
            if original.sha(item["path"]) != item["sha256"]: raise ValueError("Preserved development checkpoint changed")
        self.output = self.root / "campaign-continuation-v1"; self.output.mkdir(mode=0o700)
        self.cancel = self.root / "cancel.request"; self.cancelled = False
        first = json.loads((self.root / "plans-v1/launch.admission.json").read_text())
        end = datetime.fromisoformat(first["created_utc"]) + timedelta(seconds=self.plan["max_campaign_seconds"])
        remaining = (end - datetime.now(timezone.utc)).total_seconds()
        if remaining <= 0: raise TimeoutError("Original campaign deadline expired; never reset its budget")
        self.deadline = time.monotonic() + remaining
        self.journal = self.output / "events.jsonl"; self.stop_watch = threading.Event()
        spec = importlib.util.spec_from_file_location("continuation_recording_guard", self.repo / "scripts/quality/run-guard.py")
        self.guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.guard)
        self.admission = json.loads((self.root / "plans-v1/continuation.admission.json").read_text())
        age = (datetime.now(timezone.utc) - datetime.fromisoformat(self.admission["created_utc"])).total_seconds()
        if not 0 <= age <= 300 or not all(self.admission.get(k) is True for k in ("recording_inactive", "live_off", "user_no_recording")):
            raise ValueError("Fresh native continuation admission required")
        for stage in self.plan["stages"]:
            if stage["id"] == "dev-large" or stage["split"] == "held_out":
                if any(Path(stage[k]).exists() for k in ("output", "guard_log", "report")):
                    raise ValueError("Continuation cannot retry an attempted stage")
        self.reset_signals()

    def verify(self, stage=None):
        super().verify(stage)
        if original.sha(self.root / "plans-v1/matched.profile.json") != self.plan["profile_sha256"]:
            raise ValueError("Fixed decoding profile changed")

    def release_heldout(self):
        rows = []
        for stage in self.plan["stages"]:
            if stage["split"] == "development":
                rows += json.loads((Path(stage["output"]) / "matrix.json").read_text())["rows"]
        cases = json.loads((self.root / "combined-v1/development.corpus.json").read_text())["cases"]
        count = validate_baselines(cases, rows, ["tiny", "base", "small", "large-v3-turbo", "large-v3"])
        self.event("all-untouched-development-baselines-verified", rows=count, candidate_development_missing=49)
        super().release_heldout()

    def run(self):
        watcher = threading.Thread(target=self.watch, daemon=True); watcher.start()
        try:
            self.verify()
            self.event("continuation-started", unchanged_candidate_settings=True, repeated_inference_calls=0,
                preserved_completed_development=527, unexecuted_or_cancelled_candidate_development=49)
            large = next(s for s in self.plan["stages"] if s["id"] == "dev-large")
            self.run_stage(large)
            self.release_heldout()
            for stage in self.plan["stages"]:
                if stage["split"] == "held_out": self.run_stage(stage)
            self.event("campaign-completed", new_stage_count=5, candidate_development_still_missing=49)
        except BaseException as error:
            self.event("campaign-stopped", error_type=type(error).__name__, error=str(error)); raise
        finally:
            self.stop_watch.set(); watcher.join(timeout=1)


if __name__ == "__main__":
    os.nice(10)
    Continuation(Path(sys.argv[1])).run()
