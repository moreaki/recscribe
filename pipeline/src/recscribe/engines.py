"""Backend-neutral ASR protocol and the local whisper.cpp reference adapter."""

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .process import Cancellation, run_local
from .storage import sha256
from .vad import validate_vad


@dataclass(frozen=True)
class EngineResult:
    segments: list[dict]
    raw_path: Path
    provenance: dict


class TranscriptEngine(Protocol):
    """Adapters transcribe only. Text transformation is a separate boundary.

    Times are integer milliseconds relative to the complete working WAV.
    Missing confidence and speaker information must remain null.
    raw_path contains unchanged backend bytes; no adapter may rewrite it.
    """

    def transcribe(self, audio: Path, output: Path, language: str,
                   cancel: Cancellation) -> EngineResult: ...


class WhisperCpp:
    def __init__(self, binary: Path, model: Path, vad_model: Path | None = None):
        self.binary, self.model, self.vad_model = binary, model, vad_model

    def transcribe(self, audio, output, language, cancel):
        validate_vad(self.vad_model)
        if output.with_suffix(".json").exists():
            raise FileExistsError("Refusing to overwrite existing raw ASR evidence")
        for path in (self.binary, self.model, self.vad_model):
            if path is not None and not path.is_file():
                raise ValueError(f"Required local asset missing: {path}")
        # de-CH is a dialect request. Whisper's ASR language code is de.
        asr_language = language.split("-")[0] if language != "auto" else "auto"
        version_log = output.with_suffix(".version.log")
        # Homebrew ggml initializes/compiles Metal kernels even for --version.
        # A cold M1 launch can exceed ten seconds; cancellation stays responsive.
        run_local([str(self.binary), "--version"], version_log, cancel, timeout=120)
        version_output = version_log.read_text()
        version_match = re.search(r"whisper\.cpp version:\s*(\S+)", version_output)
        command = [str(self.binary), "-m", str(self.model), "-f", str(audio),
                   "-l", asr_language, "-ojf", "-of", str(output), "-t", "2",
                   "-tp", "0", "-mc", "0"]
        if self.vad_model:
            command += ["--vad", "-vm", str(self.vad_model)]
        elapsed = run_local(command, output.with_suffix(".log"), cancel)
        raw_path = output.with_suffix(".json")
        raw = json.loads(raw_path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict) or not isinstance(raw.get("transcription"), list):
            raise ValueError("Unsupported whisper.cpp JSON: missing transcription array")
        segments = []
        for entry in raw["transcription"]:
            offsets = entry.get("offsets", {})
            start, end, text = offsets.get("from"), offsets.get("to"), entry.get("text")
            if type(start) is not int or type(end) is not int or not isinstance(text, str):
                raise ValueError("Invalid whisper.cpp segment offsets or text")
            if start < 0 or end <= start:
                raise ValueError("Invalid whisper.cpp segment time range")
            if text.strip():
                segments.append({"start_ms": start, "end_ms": end, "source_text": text,
                                 "confidence": None, "speaker": None, "words": []})
        return EngineResult(segments, raw_path, {
            "engine": "whisper.cpp", "version": version_match[1] if version_match else version_output.strip(),
            "binary_sha256": sha256(self.binary, cancel.check),
            "model": self.model.name, "model_sha256": sha256(self.model, cancel.check),
            "vad_model_sha256": sha256(self.vad_model, cancel.check) if self.vad_model else None,
            "asr_language": asr_language,
            "detected_language": raw.get("result", {}).get("language"),
            "command": command, "duration_seconds": elapsed,
            "local_only": True})
