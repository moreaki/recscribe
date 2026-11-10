#!/usr/bin/env python3
"""Bounded audio/caption preparation; subtitles never become approved references.

Run through work-artifacts.py with a NEW protected external output directory.
No ASR, uploads, cookies, video download, reference correction or approval.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time

VERSION = "video-evaluation-preparation-v1.2"
_GUARD_SPEC = importlib.util.spec_from_file_location("video_recording_guard", Path(__file__).with_name("run-guard.py"))
guard = importlib.util.module_from_spec(_GUARD_SPEC)
_GUARD_SPEC.loader.exec_module(guard)
MAX_OUTPUT_BYTES = 256 * 1024 * 1024
MAX_METADATA_BYTES = 4 * 1024 * 1024


def validate(plan):
    cases = plan.get("cases")
    if plan.get("schema_version") != "1.0" or not isinstance(cases, list) or not 1 <= len(cases) <= 18:
        raise ValueError("Declare 1–18 video sources in a schema_version 1.0 plan")
    ids, sources = set(), {}
    for c in cases:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", c.get("id", "")) or c["id"] in ids:
            raise ValueError("Unique safe case IDs required")
        ids.add(c["id"])
        if not re.fullmatch(r"https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}", c.get("url", "")):
            raise ValueError("Use an exact public YouTube watch URL without playlist/auth parameters")
        if c.get("split") not in {"development", "held_out"}:
            raise ValueError("Declare development or held_out")
        if c["url"] in sources and sources[c["url"]] != c["split"]:
            raise ValueError("One original video cannot cross development/held-out partitions")
        sources[c["url"]] = c["split"]
        for k in ("language", "subtitle_language"):
            if not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*", c.get(k, "")):
                raise ValueError("Explicit language and same-source subtitle-language tags required")
        if c["language"].split("-")[0] != c["subtitle_language"].split("-")[0]:
            raise ValueError("Translated subtitle tracks cannot serve as same-language references")
        start, duration = c.get("start_seconds"), c.get("duration_seconds")
        if any(type(v) not in (int, float) or not math.isfinite(v) for v in (start, duration)) or start < 0 or not 2 <= duration <= 600:
            raise ValueError("Use finite source intervals, with 2–600 seconds per case")
    return cases


def manual_caption_languages(info, language):
    # Discover regional/script tags, but never choose a rendering convention.
    return sorted(tag for tag, tracks in (info.get("subtitles") or {}).items()
                  if tag.split("-")[0] == language.split("-")[0]
                  and any(t.get("ext") == "vtt" and "tlang=" not in t.get("url", "")
                          and "kind=asr" not in t.get("url", "") for t in tracks))


def caption_status(info, language):
    # Translated or automatic tracks are never used as original human references.
    manual = manual_caption_languages(info, language)
    if language in manual:
        return "manual_source_track_unreviewed"
    if manual:
        return "manual_regional_track_requires_explicit_selection"
    if language in info.get("automatic_captions", {}):
        return "automatic_only_not_reference"
    return "no_downloadable_same_language_reference"


class Preparation:
    def __init__(self, root, seconds=1200):
        self.root, self.deadline = root, time.monotonic() + seconds
        self.commands = []
        self.owned_session = None
        self.last_probe = float("-inf")

    def check(self):
        if (self.root / "cancel.request").exists():
            raise InterruptedError("Preparation cancelled; partial evidence retained")
        if time.monotonic() >= self.deadline:
            raise TimeoutError("Preparation's 1200-second total budget exhausted")
        total = 0
        for p in self.root.rglob("*"):
            if p.is_symlink():
                raise ValueError("Preparation output cannot contain symlinks")
            if p.is_file():
                total += p.stat().st_size
        if total > MAX_OUTPUT_BYTES:
            raise ValueError("Preparation's 256 MiB retained-output budget exhausted")
        if time.monotonic() - self.last_probe >= 1:
            self.last_probe = time.monotonic()
            reason = guard.capture_or_competing_work(2, owned_session=self.owned_session)
            if reason:
                raise InterruptedError("Preparation deferred/cancelled for recording priority: " + reason)

    def run(self, command, directory, label, timeout):
        self.check()
        self.commands.append(command)
        log = directory / (label + ".log")
        with log.open("xb") as output:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            self.owned_session = child.pid
            deadline = min(self.deadline, time.monotonic() + timeout)
            try:
                while child.poll() is None:
                    self.check()
                    if time.monotonic() >= deadline or log.stat().st_size > 1024 * 1024:
                        raise TimeoutError("Preparation helper exceeded time/log budget")
                    time.sleep(.1)
                self.check()
                if child.returncode:
                    raise ValueError(f"{label} failed; retained log, no retry")
            finally:
                # Reuse the existing verified owned-session cleanup, including
                # descendants that survive their direct downloader/JS parent.
                events = []
                try:
                    shutdown = guard.stop_owned(child, child.pid, directory,
                        lambda event, **fields: events.append({"event": event, **fields}),
                        1, 1, 1, 1, {child.pid: {child.pid}})
                    (directory / (label + ".cleanup.json")).write_text(json.dumps({"events": events, **shutdown}, indent=2) + "\n")
                    if shutdown["owned_session_present"] is not False or shutdown["shutdown_errors"]:
                        raise RuntimeError("Helper owned-session cleanup is uncertain; retained evidence")
                finally:
                    self.owned_session = None


def prepare(plan, output):
    cases = validate(plan)
    repo = Path(__file__).resolve().parents[2]
    output = output.expanduser()
    if not output.is_absolute() or ".." in output.parts or any(p.is_symlink() for p in (output, *output.parents)):
        raise ValueError("Use an absolute protected non-symlink output path")
    if output == repo or repo in output.parents:
        raise ValueError("Audio/captions must remain outside the checkout/disposable root")
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    (output / "plan.original.json").write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n")
    work = Preparation(output)
    results = []
    work.run(["yt-dlp", "--ignore-config", "--no-plugin-dirs", "--version"], output, "yt-dlp-version", 5)
    work.run(["ffmpeg", "-version"], output, "ffmpeg-version", 5)
    common = ["yt-dlp", "--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--no-playlist",
              "--socket-timeout", "12", "--retries", "0", "--fragment-retries", "0", "--extractor-retries", "0",
              "--no-progress", "--no-overwrites", "--quiet", "--limit-rate", "512K"]
    for case in cases:
        work.check()
        directory = output / case["id"]
        directory.mkdir(mode=0o700)
        row = {**case, "source_id": case["url"], "session_id": None, "speaker_ids": [],
               "reviewed": False, "quality_status": "PENDING_REFERENCE_REVIEW", "status": "pending"}
        results.append(row)
        try:
            template = str(directory / "source.%(ext)s")
            work.run(common + ["--skip-download", "--write-info-json", "-o", template, case["url"]], directory, "metadata", 60)
            info_path = directory / "source.info.json"
            if info_path.stat().st_size > MAX_METADATA_BYTES:
                raise ValueError("Source metadata exceeds 4 MiB")
            info = json.loads(info_path.read_bytes())
            duration = info.get("duration")
            if info.get("is_live") or type(duration) not in (int, float) or not math.isfinite(duration) or not 2 <= duration <= 1200 or case["start_seconds"] + case["duration_seconds"] > duration:
                raise ValueError("Source must have known duration ≤1200 seconds and contain the requested interval")
            row.update(caption_status=caption_status(info, case["subtitle_language"]),
                       available_manual_subtitle_languages=manual_caption_languages(info, case["subtitle_language"]),
                       title=info.get("title"), source_channel_id=info.get("channel_id"),
                       declared_source_language=info.get("language"), source_license=info.get("license"),
                       permitted_use_review="PENDING; public access does not grant redistribution rights")
            subtitles = ["--write-subs", "--sub-format", "vtt", "--sub-langs", case["subtitle_language"]] if row["caption_status"] == "manual_source_track_unreviewed" else []
            work.run(common + ["-f", "bestaudio", "--max-filesize", "24M", "-o", template] + subtitles + [case["url"]], directory, "audio", 180)
            audio = [p for p in directory.glob("source.*") if p.suffix in {".m4a", ".webm", ".opus", ".ogg", ".mp3"}]
            if len(audio) != 1:
                raise ValueError("Expected one retained audio-only original")
            work.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type", "-of", "json", str(audio[0])], directory, "stream-layout", 10)
            streams = json.loads((directory / "stream-layout.log").read_bytes()).get("streams", [])
            if not streams or any(s.get("codec_type") != "audio" for s in streams):
                raise ValueError("Downloaded source must contain audio streams only")
            # ffmpeg derives a mono evaluation view; original channels remain retained.
            work.run(["ffmpeg", "-nostdin", "-v", "error", "-n", "-threads", "1", "-i", str(audio[0]),
                      "-ss", str(case["start_seconds"]), "-t", str(case["duration_seconds"]),
                      "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(directory / "prepared.wav")], directory, "preparation", 45)
            row["status"] = "prepared_unreviewed"
            row["source_timing"] = "Requested original-source interval retained; caption cue alignment and boundary audibility require review"
            row["channel_policy"] = "Derived mono mix, not an independent-channel preservation test"
        except (OSError, ValueError) as error:
            row["status"], row["failure"] = "pending_source_or_reference", str(error)
        finally:
            row["files"] = [{"path": str(p.relative_to(output)), "bytes": p.stat().st_size,
                             "sha256": hashlib.sha256(p.read_bytes()).hexdigest() if p.stat().st_size <= 32 * 1024 * 1024 else None,
                             "hash_status": "observed" if p.stat().st_size <= 32 * 1024 * 1024 else "pending_oversized_partial_file_retained"}
                            for p in sorted(directory.iterdir()) if p.is_file()]
            receipt = {"version": VERSION, "created_utc": datetime.now(timezone.utc).isoformat(), "cases": results,
                       "commands": work.commands, "recognition_executed": False, "reference_approval": False,
                       "network_scope": "512 KiB/s downloader limit and finite command deadlines; retained-output budget is not a network-byte measurement"}
            (output / "preparation.receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = args.plan.read_bytes()
    if len(data) > 1024 * 1024:
        parser.error("Source plan exceeds 1 MiB")
    results = prepare(json.loads(data), args.output)
    print(json.dumps({"output": str(args.output), "cases": len(results), "reference_approval": False}))


if __name__ == "__main__":
    main()
