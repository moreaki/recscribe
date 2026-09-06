"""Read-only multipart session boundary; corrupt/missing audio is never fabricated."""

import json
import math
import wave
from pathlib import Path

from .audio import inspect_wav
from .storage import sha256


def inspect_session(path, cancel):
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("Session manifest too large")
    digest = sha256(path, cancel.check)
    manifest = json.loads(path.read_text())
    rate, channels = manifest["sampleRate"], manifest["channels"]
    if (manifest["schemaVersion"] != 1 or manifest["bitDepth"] != 16
            or type(rate) is not int or not 1 <= rate <= 384000
            or type(channels) is not int or not 1 <= channels <= 32
            or len(manifest["channelMap"]) != channels):
        raise ValueError("Unsupported session audio format")
    if manifest["status"] == "recording":
        raise ValueError("Finalize or recover recording before transcription")
    parts, reasons, end, names = [], list(manifest.get("issues", [])), 0, set()
    for index, entry in enumerate(manifest["parts"]):
        cancel.check()
        name, start, frames = entry["path"], entry["startSample"], entry["frames"]
        if (not isinstance(name, str) or not name or any(c in name for c in "/\\\n\r\0")
                or name in (".", "..") or name in names
                or type(start) is not int or type(frames) is not int or start < end or frames < 0):
            raise ValueError("Invalid session path/order/sample range")
        names.add(name)
        source = path.parent / name
        if source.resolve().parent != path.parent.resolve():
            raise ValueError("Session path escapes its directory")
        if start != end:
            reasons.append(f"missing_sample_range:{end}:{start}")
        end = start + frames
        item = dict(entry, index=index, offset_ms=start * 1000 // rate, report=None)
        try:
            if entry.get("status") != "verified" or not entry.get("sha256"):
                raise ValueError("Part has not been verified; recover/verify it first")
            report = inspect_wav(source, cancel)
            if (report["sample_rate"], report["channels"], report["bit_depth"], report["frames"], report["size_bytes"], report["sha256"]) != (rate, channels, 16, frames, entry["sizeBytes"], entry["sha256"]):
                raise ValueError("Part checksum, length or format mismatch")
            item["report"] = report
        except (OSError, ValueError, EOFError, wave.Error) as error:
            reasons.append(f"part_{index + 1}_unavailable:{error}")
        parts.append(item)
    if not end or not any(p["report"] for p in parts):
        raise ValueError("No verified audio parts available")
    report = {"path": str(path), "sha256": digest, "container": "WAV", "codec": "PCM",
              "sample_rate": rate, "channels": channels, "bit_depth": 16, "frames": end,
              "duration_ms": math.ceil(end * 1000 / rate), "size_bytes": sum(p["sizeBytes"] for p in parts),
              "channel_metrics": [], "session_id": manifest["id"], "parts": parts,
              "channel_layout": manifest["channelMap"], "kind": "multipart_session"}
    for channel in range(channels):
        metrics = [(p["report"]["channel_metrics"][channel], p["frames"]) for p in parts if p["report"]]
        count = sum(n for _, n in metrics)
        report["channel_metrics"].append({"channel": channel, "peak": max(m["peak"] for m, _ in metrics),
            "rms": math.sqrt(sum(m["rms"] ** 2 * n for m, n in metrics) / count),
            "clipped_samples": sum(m["clipped_samples"] for m, _ in metrics),
            "digital_silence": all(m["digital_silence"] for m, _ in metrics)})
    return report, reasons
