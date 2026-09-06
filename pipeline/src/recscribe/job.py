"""One immutable-source job, with an atomically published lifecycle manifest."""

import json
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from importlib.resources import files
from pathlib import Path

from jsonschema import Draft202012Validator

from . import __version__
from .audio import inspect_wav, prepare_channel
from .engines import TranscriptEngine
from .local_ai import process as process_language
from .process import Cancellation, Cancelled, run_local
from .quality import flag_repetition
from .renderers import render
from .storage import sha256, write_json, write_text


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def validate(document: dict) -> None:
    schema = json.loads(files("recscribe").joinpath("transcript.schema.json").read_text())
    Draft202012Validator(schema).validate(document)
    duration = document["source"]["duration_ms"]
    language = document["language_processing"]
    if language["mode"] != document["processing"]["mode"]:
        raise ValueError("Language stage mode differs from requested processing mode")
    requires_review = bool(document["review_reasons"]) or any(s["needs_review"] for s in document["segments"])
    if (document["status"] == "completed_with_review") != requires_review:
        raise ValueError("Terminal status does not match review requirements")
    ids = {s["id"] for s in document["segments"]}
    for note in document.get("summary", {}).get("notes", []):
        if not set(note["segment_ids"]) <= ids:
            raise ValueError("Summary references unknown source segments")
    seen = set()
    previous = -1
    for segment in document["segments"]:
        if segment["id"] in seen or segment["start_ms"] < previous:
            raise ValueError("Segment IDs must be unique and sorted by start time")
        if not 0 <= segment["start_ms"] < segment["end_ms"] <= duration:
            raise ValueError("Segment timestamps outside source duration")
        if segment["channel"] >= document["source"]["channels"]:
            raise ValueError("Segment channel outside source channel count")
        if segment["needs_review"] != bool(segment["review_reasons"]):
            raise ValueError("Review flag does not match reasons")
        if segment.get("timing_adjustment") is not None:
            adjustment = segment["timing_adjustment"]
            if (adjustment["original_end_ms"] <= segment["end_ms"]
                    or segment["end_ms"] not in [duration, *[p["offset_ms"] + p["report"]["duration_ms"] for p in document["source"].get("parts", []) if p["report"]]]
                    or "engine_end_exceeds_source; trimmed_with_provenance" not in segment["review_reasons"]):
                raise ValueError("Invalid source-boundary timing adjustment")
        for field in ("normalized_text", "translated_text"):
            if segment[field] is not None and not any(
                    d["segment_id"] == segment["id"] and d["field"] == field
                    for d in language["derivations"]):
                raise ValueError("Derived text requires explicit source-linked provenance")
        seen.add(segment["id"])
        previous = segment["start_ms"]


class Job:
    def __init__(self, directory: Path, source: Path, options: dict):
        self.directory, self.source, self.options = directory, source.resolve(), options
        # Exclusive directory creation prevents accidental reuse/overwrite of evidence.
        directory.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.cancel = Cancellation(directory / "cancel.request")
        self.started_monotonic = time.monotonic()
        self.manifest = {"schema_version": "1.0", "job_id": str(uuid.uuid4()),
                         "pipeline_version": __version__, "source_path": str(self.source),
                         "created_at": now(), "options": options,
                         "state": "queued", "history": [], "artifacts": {}, "error": None}
        self.transition("queued", 0)

    def transition(self, state: str, progress: float):
        self.manifest.update(state=state, progress=progress, updated_at=now())
        self.manifest["history"].append({"state": state, "at": now(),
                                         "elapsed_seconds": time.monotonic() - self.started_monotonic})
        write_json(self.directory / "manifest.json", self.manifest)
        print(json.dumps({"job_id": self.manifest["job_id"], "state": state,
                          "progress": progress}), file=sys.stderr, flush=True)

    def inventory(self):
        self.manifest["artifacts"] = {
            str(p.relative_to(self.directory)): {"sha256": sha256(p), "size_bytes": p.stat().st_size}
            for p in sorted(self.directory.rglob("*"))
            if p.is_file() and p.name not in ("manifest.json", "cancel.request")
            and not p.name.endswith(".tmp")}

    def run(self, engine: TranscriptEngine, ffmpeg: Path,
            verification_engine: TranscriptEngine | None = None) -> dict:
        started = time.monotonic()
        raw_records, passes, segments, working = [], [], [], []
        try:
            self.cancel.check()
            if self.options["profile"] == "verified" and verification_engine is None:
                raise ValueError("verified requires an explicit second local model")
            if self.source.name.endswith(".recscribe.json"):
                return self.run_session(engine, ffmpeg, verification_engine, started)
            self.transition("inspecting", 0.05)
            report = inspect_wav(self.source, self.cancel)
            write_json(self.directory / "audio-report.json", report)
            reasons = []
            if report["channels"] > 1:
                reasons.append("multiple_channels; overlapping cues and duplicate speech require review")
            if self.options["diarize"] == "auto":
                reasons.append("diarization_not_available; channel indices are not speaker identities")
            if self.options["source_language"] == "de-CH":
                reasons.append("dialect_fidelity_unverified; Whisper may produce Standard German")
            if self.options["mode"] != "verbatim" and not self.options.get("ollama_model"):
                reasons.append(f"{self.options['mode']}_processor_not_configured")
            self.transition("preparing", 0.15)
            version_path = self.directory / "ffmpeg.version.log"
            run_local([str(ffmpeg), "-version"], version_path, self.cancel, timeout=10)
            self.manifest["normalizer"] = {
                "version": version_path.read_text().splitlines()[0],
                "binary_sha256": sha256(ffmpeg, self.cancel.check)}
            for channel in range(report["channels"]):
                self.cancel.check()
                path = self.directory / f"working-channel-{channel}.wav"
                working.append(prepare_channel(self.source, channel, path, ffmpeg, self.cancel))
            self.manifest["working_audio"] = working
            self.transition("transcribing", 0.3)
            for channel in range(report["channels"]):
                self.cancel.check()
                if report["channel_metrics"][channel]["digital_silence"]:
                    raw_records.append({"channel": channel, "status": "skipped_digital_silence"})
                    continue
                path = self.directory / f"working-channel-{channel}.wav"
                result = engine.transcribe(path, self.directory / f"asr-channel-{channel}",
                                           self.options["source_language"], self.cancel)
                raw_records.append(self.raw_record(result, channel, "primary"))
                passes.append(result.provenance)
                disagreement = False
                if self.options["profile"] == "verified":
                    if verification_engine is None:
                        raise ValueError("verified requires an explicit second local model")
                    second = verification_engine.transcribe(
                        path, self.directory / f"verify-channel-{channel}",
                        self.options["source_language"], self.cancel)
                    raw_records.append(self.raw_record(second, channel, "verification"))
                    if result.provenance["model_sha256"] == second.provenance["model_sha256"]:
                        raise ValueError("verified requires two distinct model checksums")
                    passes.append(second.provenance)
                    # First slice conservatively compares complete channel passes.
                    text = lambda xs: " ".join(" ".join(s["source_text"].split()) for s in xs)
                    disagreement = text(result.segments) != text(second.segments)
                    if disagreement:
                        reasons.append(f"engine_pass_disagreement_channel_{channel}")
                if not result.segments:
                    reasons.append(f"no_speech_recognized_in_non_silent_channel_{channel}")
                for entry in result.segments:
                    self.cancel.check()
                    segment = dict(entry, channel=channel, normalized_text=None,
                                   translated_text=None, review_reasons=[])
                    # Whisper can include decoder padding beyond the last real frame.
                    # Preserve the engine time and explicitly mark this derived bound.
                    if (0 <= segment["start_ms"] < report["duration_ms"] < segment["end_ms"]
                            <= report["duration_ms"] + 30000):
                        segment["timing_adjustment"] = {
                            "original_end_ms": segment["end_ms"],
                            "reason": "decoder_padding_beyond_source"}
                        segment["end_ms"] = report["duration_ms"]
                        segment["review_reasons"].append("engine_end_exceeds_source; trimmed_with_provenance")
                    if segment["confidence"] is None:
                        segment["review_reasons"].append("confidence_unavailable")
                    elif segment["confidence"] < 0.6:
                        segment["review_reasons"].append("low_confidence")
                    if re.fullmatch(r"\s*\[(?:BLANK_AUDIO|NO_SPEECH|SILENCE|MUSIC)\]\s*",
                                    segment["source_text"], flags=re.IGNORECASE):
                        segment["review_reasons"].append("engine_non_speech_marker")
                    if disagreement:
                        segment["review_reasons"].append("engine_pass_disagreement")
                    if report["channel_metrics"][channel]["clipped_samples"]:
                        segment["review_reasons"].append("source_contains_clipping")
                    segments.append(segment)
            write_json(self.directory / "transcript.raw.json", {
                "schema_version": "1.0", "kind": "immutable_engine_output_index",
                "outputs": raw_records})
            # Refuse a result whose original recording changed during processing.
            if sha256(self.source, self.cancel.check) != report["sha256"]:
                raise ValueError("Source changed during processing; result invalidated")
            self.transition("post-processing", 0.7)
            segments.sort(key=lambda s: (s["start_ms"], s["channel"], s["end_ms"]))
            for i, segment in enumerate(segments, 1):
                segment["id"] = f"seg-{i:06d}"
            language, summary = process_language(segments, self.options, self.directory, self.cancel)
            if summary is not None:
                reasons.append("ai_summary_unverified")
            flag_repetition(segments)
            for segment in segments:
                segment["needs_review"] = bool(segment["review_reasons"])
            if passes and self.options["source_language"] == "auto":
                reasons.append("automatic_language_detection_unverified; a quiet opening can select the wrong language")
            if any("engine_non_speech_marker" in s["review_reasons"] for s in segments):
                reasons.append("asr_contains_non_speech_markers; inspect_source_audio")
            if not any(p.get("vad_model_sha256") for p in passes) and passes:
                reasons.append("learned_vad_not_run; silence guard only detects exact digital silence")
            status = "completed_with_review" if reasons or any(s["needs_review"] for s in segments) else "completed"
            document = {"schema_version": "1.0", "job_id": self.manifest["job_id"],
                        "status": status, "source": report,
                        "processing": dict(self.options, engine_passes=passes,
                                           pipeline_version=__version__,
                                           started_at=self.manifest["created_at"],
                                           duration_ms=round((time.monotonic() - started) * 1000)),
                        "language_processing": language, "segments": segments,
                        "review_reasons": reasons}
            if summary is not None:
                document["summary"] = summary
            self.transition("validating", 0.8)
            self.cancel.check()
            validate(document)
            write_json(self.directory / "transcript.json", document)
            self.transition("rendering", 0.9)
            for name, content in render(document).items():
                self.cancel.check()
                write_text(self.directory / name, content)
            self.cancel.check()
            self.inventory()
            self.manifest["duration_seconds"] = time.monotonic() - started
            self.transition(status, 1)
            return document
        except (Exception, KeyboardInterrupt) as error:
            state = "cancelled" if isinstance(error, (Cancelled, KeyboardInterrupt)) else "failed"
            self.manifest["error"] = {"type": type(error).__name__, "message": str(error)}
            write_text(self.directory / "review.md", f"# Job {state}\n\nNo complete transcript is available.\n\n{type(error).__name__}: {error}\n")
            self.inventory()
            self.transition(state, self.manifest["progress"])
            raise

    def run_session(self, engine, ffmpeg, verifier, started):
        from .session import inspect_session
        self.transition("inspecting-session", 0.05)
        report, reasons = inspect_session(self.source, self.cancel)
        write_json(self.directory / "audio-report.json", report)
        segments, passes, raw = [], [], []
        for part in report["parts"]:
            self.cancel.check()
            if part["report"] is None:
                continue
            self.transition("transcribing-parts", 0.1 + 0.55 * part["index"] / len(report["parts"]))
            options = dict(self.options, mode="verbatim", target_language=None, ollama_model=None, summarize=False)
            child = Job(self.directory / f"part-{part['index'] + 1:04d}", self.source.parent / part["path"], options)
            child.cancel = self.cancel
            document = child.run(engine, ffmpeg, verifier)
            if document["source"]["sha256"] != part["sha256"]:
                raise ValueError("Part changed after session inspection")
            reasons.extend(document["review_reasons"])
            passes.extend(document["processing"]["engine_passes"])
            raw.append({"part": part["index"], "offset_ms": part["offset_ms"],
                        "path": str((child.directory / "transcript.raw.json").relative_to(self.directory)),
                        "sha256": sha256(child.directory / "transcript.raw.json", self.cancel.check)})
            for segment in document["segments"]:
                if ((part["index"] > 0 and segment["start_ms"] < 2000)
                        or (part["index"] < len(report["parts"]) - 1 and segment["end_ms"] > part["report"]["duration_ms"] - 2000)):
                    segment["review_reasons"].append("part_boundary; check_cut_or_duplicate_speech")
                for key in ("start_ms", "end_ms"):
                    segment[key] += part["offset_ms"]
                    for word in segment["words"]:
                        word[key] += part["offset_ms"]
                if "timing_adjustment" in segment:
                    segment["timing_adjustment"]["original_end_ms"] += part["offset_ms"]
                segments.append(segment)
        write_json(self.directory / "transcript.raw.json", {"schema_version": "1.0", "kind": "immutable_multipart_engine_output_index", "outputs": raw})
        if sha256(self.source, self.cancel.check) != report["sha256"]:
            raise ValueError("Session manifest changed during transcription")
        for part in report["parts"]:
            if part["report"] and sha256(self.source.parent / part["path"], self.cancel.check) != part["sha256"]:
                raise ValueError("Session audio changed during transcription")
        segments.sort(key=lambda s: (s["start_ms"], s["channel"], s["end_ms"]))
        for index, segment in enumerate(segments, 1):
            segment["id"] = f"seg-{index:06d}"
        self.transition("post-processing", 0.7)
        language, summary = process_language(segments, self.options, self.directory, self.cancel)
        if self.options["mode"] != "verbatim" and not self.options.get("ollama_model"):
            reasons.append(f"{self.options['mode']}_processor_not_configured")
        if summary is not None:
            reasons.append("ai_summary_unverified")
        for segment in segments:
            segment["needs_review"] = bool(segment["review_reasons"])
        status = "completed_with_review" if reasons or any(s["needs_review"] for s in segments) else "completed"
        document = {"schema_version": "1.0", "job_id": self.manifest["job_id"], "status": status,
                    "source": report, "segments": segments, "review_reasons": sorted(set(reasons)),
                    "language_processing": language, "processing": dict(self.options, engine_passes=passes,
                        pipeline_version=__version__, started_at=self.manifest["created_at"],
                        duration_ms=round((time.monotonic() - started) * 1000))}
        if summary is not None:
            document["summary"] = summary
        validate(document)
        write_json(self.directory / "transcript.json", document)
        for name, content in render(document).items():
            self.cancel.check()
            write_text(self.directory / name, content)
        self.inventory()
        self.manifest["duration_seconds"] = time.monotonic() - started
        self.transition(status, 1)
        return document

    def raw_record(self, result, channel, role):
        return {"channel": channel, "role": role, "status": "produced",
                "path": str(result.raw_path.relative_to(self.directory)),
                "sha256": sha256(result.raw_path, self.cancel.check),
                "provenance": result.provenance}
