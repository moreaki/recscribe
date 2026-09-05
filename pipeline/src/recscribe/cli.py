"""Stable local CLI. stdout is the result locator; JSON progress goes to stderr."""

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import uuid

from .engines import WhisperCpp
from .job import Job
from .process import Cancelled


def parser():
    p = argparse.ArgumentParser(description="Local WAV transcription; never downloads models")
    p.add_argument("audio", type=Path)
    p.add_argument("--output", type=Path, help="New, exclusively owned job directory")
    p.add_argument("--source-language", default="auto")
    p.add_argument("--target-language")
    p.add_argument("--mode", choices=("verbatim", "normalize", "translate"), default="verbatim")
    p.add_argument("--profile", choices=("fast", "accurate", "verified"), default="fast")
    p.add_argument("--diarize", choices=("off", "auto"), default="off")
    p.add_argument("--formats", default="json,md,txt,srt,vtt",
                   help="First slice always emits all five canonical views")
    p.add_argument("--local-only", action="store_true", default=True)
    p.add_argument("--whisper-cli", type=Path)
    p.add_argument("--model", type=Path, help="Existing primary ggml model; no automatic model selection")
    p.add_argument("--verify-model", type=Path)
    p.add_argument("--vad-model", type=Path)
    p.add_argument("--ffmpeg", type=Path)
    return p


def main(argv=None):
    p = parser()
    args = p.parse_args(argv)
    if set(args.formats.split(",")) != {"json", "md", "txt", "srt", "vtt"}:
        p.error("The first slice requires --formats json,md,txt,srt,vtt")
    if args.mode != "verbatim" and not args.target_language:
        p.error("normalize and translate require --target-language")
    if args.mode == "verbatim" and args.target_language not in (None, args.source_language):
        p.error("verbatim cannot change language; select normalize or translate")
    if args.profile == "verified" and not args.verify_model:
        p.error("verified requires --verify-model; no silent single-pass fallback")
    if args.verify_model and args.model and args.verify_model.resolve() == args.model.resolve():
        p.error("Verification must use a distinct model")
    binary = args.whisper_cli or Path(shutil.which("whisper-cli") or "whisper-cli")
    ffmpeg = args.ffmpeg or Path(shutil.which("ffmpeg") or "ffmpeg")
    # Lower CPU priority of orchestration and inherited child processes.
    if hasattr(os, "nice"):
        os.nice(10)
    os.umask(0o077)
    options = {"source_language": args.source_language, "target_language": args.target_language,
               "mode": args.mode, "profile": args.profile, "diarize": args.diarize,
               "local_only": True, "formats": ["json", "md", "txt", "srt", "vtt"]}
    try:
        job = Job((args.output or Path("jobs") / str(uuid.uuid4())).resolve(), args.audio, options)
    except OSError as error:
        print(f"Cannot create job: {error}", file=sys.stderr)
        return 1
    previous = {}
    for sig in (signal.SIGINT, signal.SIGTERM):
        previous[sig] = signal.signal(sig, lambda *_: job.cancel.event.set())
    try:
        engine = WhisperCpp(binary.resolve(), (args.model or Path("missing-local-model")).resolve(),
                            args.vad_model.resolve() if args.vad_model else None)
        verifier = WhisperCpp(binary.resolve(), args.verify_model.resolve(), engine.vad_model) if args.verify_model else None
        result = job.run(engine, ffmpeg.resolve(), verifier)
        print(json.dumps({"job": str(job.directory), "status": result["status"]}))
        return 0
    except (Cancelled, KeyboardInterrupt):
        return 130
    except Exception as error:
        print(f"Job failed: {error}", file=sys.stderr)
        return 1
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    raise SystemExit(main())
