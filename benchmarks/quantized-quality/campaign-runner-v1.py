#!/usr/bin/env python3
"""Serial frozen quality campaign; delegates all model work to existing tools.

Run through work-artifacts.py with a protected campaign root. No retries,
reference text display, weight edits, source mutation or corpus approval.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save(path, value):
    with Path(path).open("x") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2); stream.write("\n")


class Campaign:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.plan_path = self.root / "campaign.execution-plan.json"
        self.plan = json.loads(self.plan_path.read_text())
        self.repo = Path(self.plan["repository_root"])
        self.output = self.root / "campaign-execution-v1"
        self.output.mkdir(mode=0o700)
        self.cancel = self.root / "cancel.request"
        self.cancelled = False
        self.deadline = time.monotonic() + self.plan["max_campaign_seconds"]
        self.journal = self.output / "events.jsonl"
        self.stop_watch = threading.Event()
        spec = importlib.util.spec_from_file_location("quality_campaign_guard", self.repo / "scripts/quality/run-guard.py")
        self.guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.guard)
        self.admission = json.loads((self.root / "plans-v1/launch.admission.json").read_text())
        observed = datetime.fromisoformat(self.admission["created_utc"])
        if not all(self.admission.get(k) is True for k in ("recording_inactive", "live_off", "user_no_recording")) or not 0 <= (datetime.now(timezone.utc) - observed).total_seconds() <= 300:
            raise ValueError("Campaign needs fresh native idle/live-off admission")
        if sha(__file__) != self.plan["campaign_runner_sha256"]:
            raise ValueError("Campaign runner changed after seal")
        held_seen = False
        for stage in self.plan["stages"]:
            if stage["split"] == "held_out": held_seen = True
            elif held_seen: raise ValueError("Every development stage must precede held-out")
            for field in ("output", "guard_log", "report"):
                target = Path(stage[field])
                if self.root not in target.parents or target.exists() or target.is_symlink():
                    raise ValueError("All stage outputs must be new protected campaign paths")
        self.reset_signals()

    def reset_signals(self):
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, lambda _n, _f: setattr(self, "cancelled", True))

    def event(self, name, **fields):
        with self.journal.open("a") as stream:
            stream.write(json.dumps(dict(event=name, time=datetime.now(timezone.utc).isoformat(), **fields)) + "\n")
            stream.flush(); os.fsync(stream.fileno())

    def check(self):
        if self.cancelled or self.cancel.exists(): raise InterruptedError("Campaign cancelled; completed/raw evidence retained")
        if time.monotonic() >= self.deadline: raise TimeoutError("Campaign wall-time budget exhausted")

    def watch(self):
        while not self.stop_watch.wait(.5):
            if self.cancel.exists() or time.monotonic() >= self.deadline:
                self.cancelled = True
                os.kill(os.getpid(), signal.SIGINT)  # Only this verified calling process.
                return

    def verify(self, stage=None):
        self.check()
        for path, digest in self.plan["analysis_helpers"].items():
            if sha(self.repo / path) != digest: raise ValueError("Sealed analysis/guard source changed")
        product = self.plan["complete_product"]
        for item in [dict(path=product["cli"], sha256=product["cli_sha256"]), *product["resource_bundle"], *product["native_dependencies"]]:
            if sha(item["path"]) != item["sha256"]: raise ValueError("Native product/dependency changed")
        if stage:
            if sha(stage["corpus"]) != stage["corpus_sha256"]: raise ValueError("Sealed corpus changed")
            config = json.loads(Path(stage["experiment"]).read_text())
            for model in config["models"]:
                self.check()
                if sha(model["path"]) != model["sha256"]: raise ValueError("Sealed model changed")
            for case in json.loads(Path(stage["corpus"]).read_text())["cases"]:
                self.check()
                for path, digest in ((case["audio"], case["sha256"]), (case["reference"], case["reference_sha256"])):
                    if sha(path) != digest: raise ValueError("Sealed audio/reference changed")

    def prepare_configs(self):
        for stage in self.plan["stages"]:
            if sha(stage["planned_config"]) != stage["planned_config_sha256"]: raise ValueError("Planned configuration changed")
            config = json.loads(Path(stage["planned_config"]).read_text())
            config.update(capture_inactive=True, workload_attestation="Fresh campaign native idle/live-off admission " + self.admission["created_utc"] + "; continuous recording-priority guards, serial nice 10, two threads; quality only, timing/RSS uncontrolled")
            save(stage["experiment"], config)
        self.event("execution-configs-sealed", configurations={s["id"]: sha(s["experiment"]) for s in self.plan["stages"]})

    def release_heldout(self):
        development = [s for s in self.plan["stages"] if s["split"] == "development"]
        if not all((Path(s["output"]) / "matrix.json").is_file() and (Path(s["report"]) / "report.json").is_file() for s in development):
            raise ValueError("All development baselines/reports required before held-out release")
        freezes = []
        for stage in self.plan["stages"]:
            if stage["split"] != "held_out": continue
            config = json.loads(Path(stage["experiment"]).read_text())
            freeze = dict(schema_version="1.0", created_utc=datetime.now(timezone.utc).isoformat(), actor="AI",
                corpus_sha256=stage["corpus_sha256"], experiment_sha256=sha(stage["experiment"]),
                profiles={p["id"]: sha(p["settings"]) for p in config["profiles"]},
                budgets=self.plan["quality_policy"], frozen_before_held_out=True,
                review_status="Unreviewed published references; legacy exploratory, not native/v2-approved",
                development_matrix_hashes={s["id"]: sha(Path(s["output"]) / "matrix.json") for s in development})
            save(stage["freeze"], freeze); freezes.append(dict(stage=stage["id"], sha256=sha(stage["freeze"])))
        save(self.output / "heldout-family.freeze.json", dict(created_utc=datetime.now(timezone.utc).isoformat(), freezes=freezes, all_development_preceded_release=True))
        self.event("all-heldout-freezes-released", freezes=freezes)

    def run_stage(self, stage):
        self.verify(stage)
        wait_until = min(self.deadline, time.monotonic() + self.plan["max_pre_stage_quiet_wait_seconds"])
        while True:
            self.check()
            reason = self.guard.capture_or_competing_work(2, foreign_cpu_limit=self.plan["foreign_cpu_limit"])
            if not reason: break
            if reason not in ("competing_test_build_or_asr", "competing_high_cpu_process") or time.monotonic() >= wait_until:
                raise InterruptedError("Stage admission deferred: " + reason)
            self.event("waiting-for-stage-admission", stage=stage["id"], reason=reason)
            time.sleep(2)
        self.event("stage-starting", stage=stage["id"])
        command = [self.plan["complete_product"]["cli"], "benchmark", stage["corpus"], "--experiment", stage["experiment"], "--output", stage["output"]]
        remaining = min(stage["deadline_seconds"], self.deadline - time.monotonic())
        try:
            code = self.guard.main(["--output", stage["output"], "--log", stage["guard_log"], "--timeout", str(remaining),
                "--foreign-cpu-limit", str(self.plan["foreign_cpu_limit"]), "--", *command])
        finally:
            self.reset_signals()
        self.check()
        event = json.loads(Path(stage["guard_log"]).read_text().splitlines()[-1])
        if event.get("reason") or event.get("failure") or not event.get("shutdown", {}).get("cli_reaped") or event["shutdown"]["owned_session_present"] is not False or event["shutdown"]["shutdown_errors"]:
            raise InterruptedError("Guard did not complete cleanly; no next stage")
        matrix = json.loads((Path(stage["output"]) / "matrix.json").read_text())
        rows = matrix["rows"]
        if code not in (0, 1) or len(rows) != stage["planned_calls"] or any(r["status"] not in ("completed", "completed_with_review", "failed") for r in rows) or not any(r["status"] in ("completed", "completed_with_review") for r in rows):
            raise ValueError("Stage incomplete or no usable baseline; all raw evidence retained")
        self.verify(stage)
        reporter = [sys.executable, str(self.repo / "scripts/quality/report-pilot.py"), stage["output"], "--output", stage["report"]]
        if stage["split"] == "held_out": reporter.append("--allow-held-out")
        with (self.output / (stage["id"] + ".report.log")).open("x") as log:
            subprocess.run(reporter, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
        self.event("stage-completed", stage=stage["id"], terminal_rows=len(rows), failed_rows=sum(r["status"] == "failed" for r in rows))

    def run(self):
        watcher = threading.Thread(target=self.watch, daemon=True); watcher.start()
        try:
            self.verify(); self.prepare_configs()
            released = False
            for stage in self.plan["stages"]:
                self.check()
                if stage["split"] == "held_out" and not released:
                    self.release_heldout(); released = True
                self.run_stage(stage)
            self.event("campaign-completed", stage_count=len(self.plan["stages"]))
        except BaseException as error:
            self.event("campaign-stopped", error_type=type(error).__name__, error=str(error)); raise
        finally:
            self.stop_watch.set(); watcher.join(timeout=1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    os.nice(10)
    Campaign(args.root).run()
