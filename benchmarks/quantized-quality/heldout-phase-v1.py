#!/usr/bin/env python3
"""Fixed-artifact held-out phase with explicitly incomplete development.

The original development-completeness requirement remains NOT_MET. This phase
does not repair a missing measurement or change a lexical acceptance gate.
"""
from datetime import datetime, timezone, timedelta
import importlib.util
import json
import os
from pathlib import Path
import sys
import threading
import time

SPEC = importlib.util.spec_from_file_location("heldout_phase_continuation", Path(__file__).with_name("continue-after-build-v1.py"))
continuation = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(continuation)
original = continuation.original


def development_inventory(cases, rows, originals):
    by_id = {case["id"]: case for case in cases}
    expected = {(model, case["id"], mode) for model in originals for case in cases for mode in ("known", "auto")}
    observed, measured, groups = set(), set(), set()
    statuses = {}
    for row in rows:
        status = row.get("status")
        if status not in ("completed", "completed_with_review", "failed", "cancelled", "queued", "pending"):
            raise ValueError("Development checkpoint is still active or has an unknown status")
        statuses[status] = statuses.get(status, 0) + 1
        if row["model"] not in originals:
            continue
        key = (row["model"], row["id"], row["language_mode"])
        if key not in expected or key in observed:
            raise ValueError("Unexpected or duplicate original development cell")
        observed.add(key)
        case = by_id[row["id"]]
        if (row.get("repeat") != 1 or row.get("path") != "final"
                or row.get("source_sha256") != case["sha256"]
                or row.get("reference_sha256") != case["reference_sha256"]):
            raise ValueError("Original development identity differs from the fixed corpus")
        if status in ("completed", "completed_with_review"):
            m = row.get("measurement", {})
            if (m.get("status", status) not in ("completed", "completed_with_review")
                    or type(m.get("reference_characters")) is not int or m["reference_characters"] <= 0
                    or m.get("scoring_version") != "swift-nfc-casefold-alphanumeric-v1"):
                raise ValueError("Completed original development cell has no valid counted measurement")
            measured.add(key)
            groups.add((row["model"], case["language"], row["language_mode"]))
    expected_groups = {(model, case["language"], mode) for model in originals for case in cases for mode in ("known", "auto")}
    if observed != expected or groups != expected_groups:
        raise ValueError("Every original model/language/mode must retain an observed development baseline")
    completed = sum(statuses.get(s, 0) for s in ("completed", "completed_with_review"))
    return dict(planned_cells=len(rows), completed_cells=completed, missing_cells=len(rows) - completed,
        status_counts=statuses, original_planned_cells=len(expected), original_completed_cells=len(measured),
        original_missing_cells=len(expected) - len(measured),
        original_development_completeness="complete" if measured == expected else "NOT_MET",
        missing_measurements_retried=False, development_acceptance="pending" if measured != expected or completed != len(rows) else "complete")


class HeldOutPhase(original.Campaign):
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.plan_path = self.root / "campaign.execution-plan.json"
        self.plan = json.loads(self.plan_path.read_text())
        self.repo = Path(self.plan["repository_root"])
        phase_path = self.root / "heldout-phase-v1.plan.json"
        phase = json.loads(phase_path.read_text())
        if (original.sha(__file__) != phase["coordinator_sha256"]
                or original.sha(self.plan_path) != phase["original_execution_plan_sha256"]):
            raise ValueError("Held-out phase source/original plan seal differs")
        for item in phase["preserved_files"]:
            if original.sha(item["path"]) != item["sha256"]:
                raise ValueError("Preserved development/source/configuration changed")
        large = next(s for s in self.plan["stages"] if s["id"] == "held-large")
        split = continuation.split_large_heldout(large, json.loads(Path(large["experiment"]).read_text()))
        for stage, config in split:
            if json.loads(Path(stage["experiment"]).read_text()) != config:
                raise ValueError("Mode partition changes the original settings")
        self.plan["stages"] = [s for s in self.plan["stages"] if s["id"] != "held-large"] + [s for s, _ in split]
        rows = []
        for stage in self.plan["stages"]:
            if stage["split"] == "development":
                rows += json.loads((Path(stage["output"]) / "matrix.json").read_text())["rows"]
                if not (Path(stage["report"]) / "report.json").is_file():
                    raise ValueError("Every development checkpoint needs a retained report, including partial reports")
        cases = json.loads((self.root / "combined-v1/development.corpus.json").read_text())["cases"]
        self.development = development_inventory(cases, rows, ["tiny", "base", "small", "large-v3-turbo", "large-v3"])
        if self.development != phase["development_checkpoint"]:
            raise ValueError("Development checkpoint differs from the prospective partial-data declaration")
        self.admission = json.loads((self.root / "plans-v1/heldout.admission.json").read_text())
        age = (datetime.now(timezone.utc) - datetime.fromisoformat(self.admission["created_utc"])).total_seconds()
        if (not 0 <= age <= 300 or self.admission.get("phase_plan_sha256") != original.sha(phase_path)
                or not all(self.admission.get(k) is True for k in ("recording_inactive", "live_off", "user_no_recording"))):
            raise ValueError("Fresh native held-out admission bound to this phase is required")
        first = json.loads((self.root / "plans-v1/launch.admission.json").read_text())
        end = datetime.fromisoformat(first["created_utc"]) + timedelta(seconds=self.plan["max_campaign_seconds"])
        remaining = (end - datetime.now(timezone.utc)).total_seconds()
        if remaining <= 0:
            raise TimeoutError("Original campaign deadline expired; no budget reset")
        for stage in self.plan["stages"]:
            if stage["split"] == "held_out" and any(Path(stage[k]).exists() for k in ("output", "guard_log", "report", "freeze")):
                raise ValueError("Every held-out stage must still be unstarted and unsealed")
        self.output = self.root / "campaign-heldout-v1"; self.output.mkdir(mode=0o700)
        self.deadline = time.monotonic() + remaining
        self.cancel = self.root / "cancel.request"; self.cancelled = False
        self.journal = self.output / "events.jsonl"; self.stop_watch = threading.Event()
        spec = importlib.util.spec_from_file_location("heldout_phase_guard", self.repo / "scripts/quality/run-guard.py")
        self.guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.guard)
        self.reset_signals()

    def verify(self, stage=None):
        super().verify(stage)
        if original.sha(self.root / "plans-v1/matched.profile.json") != self.plan["profile_sha256"]:
            raise ValueError("Fixed decoding profile changed")

    def release_heldout(self):
        development = [s for s in self.plan["stages"] if s["split"] == "development"]
        freezes = []
        for stage in self.plan["stages"]:
            if stage["split"] != "held_out": continue
            config = json.loads(Path(stage["experiment"]).read_text())
            freeze = dict(schema_version="1.0", created_utc=datetime.now(timezone.utc).isoformat(), actor="AI",
                corpus_sha256=stage["corpus_sha256"], experiment_sha256=original.sha(stage["experiment"]),
                profiles={p["id"]: original.sha(p["settings"]) for p in config["profiles"]}, budgets=self.plan["quality_policy"],
                frozen_before_held_out=True, review_status="Unreviewed published references; exploratory legacy, not native/v2-approved",
                development_checkpoint=self.development, development_acceptance_remains_pending=True,
                development_matrix_hashes={s["id"]: original.sha(Path(s["output"]) / "matrix.json") for s in development})
            original.save(stage["freeze"], freeze)
            freezes.append(dict(stage=stage["id"], sha256=original.sha(stage["freeze"])))
        original.save(self.output / "heldout-family.freeze.json", dict(created_utc=datetime.now(timezone.utc).isoformat(), freezes=freezes,
            development_checkpoint=self.development, all_development_reports_preceded_release=True, original_development_completeness="NOT_MET"))
        self.event("all-heldout-freezes-released", freezes=freezes, development=self.development)

    def run(self):
        watcher = threading.Thread(target=self.watch, daemon=True); watcher.start()
        try:
            self.verify()
            self.event("heldout-phase-started", development=self.development, lexical_gates_unchanged=True, repeated_inference_calls=0)
            self.release_heldout()
            for stage in self.plan["stages"]:
                if stage["split"] == "held_out": self.run_stage(stage)
            self.event("heldout-phase-completed", development_acceptance="pending", heldout_stages=5)
        except BaseException as error:
            self.event("heldout-phase-stopped", error_type=type(error).__name__, error=str(error)); raise
        finally:
            self.stop_watch.set(); watcher.join(timeout=1)


if __name__ == "__main__":
    os.nice(10)
    HeldOutPhase(Path(sys.argv[1])).run()
