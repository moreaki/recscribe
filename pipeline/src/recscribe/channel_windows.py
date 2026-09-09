"""Reuse proven-equal stereo windows; never infer equality from text or correlation."""

import copy
import wave
from dataclasses import dataclass

from .storage import sha256


@dataclass(frozen=True)
class ChannelPolicy:
    window_seconds: int = 30
    context_seconds: int = 2
    maximum_regions: int = 8
    copy_frames: int = 65536


CHANNEL_POLICY = ChannelPolicy()


def recognition_regions(report, channel, policy=CHANNEL_POLICY):
    """Source-frame intervals; None keeps the established full-channel path."""
    if report["channels"] != 2 or channel != 1 or report["channels_bit_identical"]:
        return None
    if policy.context_seconds < 0 or policy.maximum_regions < 1:
        return None
    windows = report.get("channel_windows", {}).get("windows")
    if not windows:
        return None
    # Validate complete, contiguous coverage before suppressing any inference.
    cursor = 0
    for window in windows:
        if (window["start_frame"] != cursor or window["end_frame"] <= cursor
                or window["end_frame"] > report["frames"] or type(window["bit_identical"]) is not bool):
            raise ValueError("Invalid channel analysis coverage")
        cursor = window["end_frame"]
    if cursor != report["frames"]:
        raise ValueError("Incomplete channel analysis coverage")
    margin = policy.context_seconds * report["sample_rate"]
    ranges = []
    for window in windows:
        if window["bit_identical"]:
            continue
        start = max(0, window["start_frame"] - margin)
        end = min(report["frames"], window["end_frame"] + margin)
        if ranges and start <= ranges[-1][1]:
            ranges[-1][1] = end
        else:
            ranges.append([start, end])
    if not ranges or len(ranges) > policy.maximum_regions or ranges == [[0, report["frames"]]]:
        return None
    return ranges


def transcribe_regions(engine, audio, output, language, cancel, report, regions):
    """Keep every backend response unchanged, with explicit source-time mapping."""
    from .engines import EngineResult
    from .storage import write_json
    if regions is None:
        return engine.transcribe(audio, output, language, cancel)
    results, records = [], []
    with wave.open(str(audio), "rb") as source:
        rate, frames = source.getframerate(), source.getnframes()
        for index, (start, end) in enumerate(regions):
            cancel.check()
            # Include fractional resampling boundaries rather than drop a source sample.
            first = start * rate // report["sample_rate"]
            last = min(frames, (end * rate + report["sample_rate"] - 1) // report["sample_rate"])
            part = output.parent / f"{output.name}-region-{index}.wav"
            with part.open("xb") as file:
                with wave.open(file, "wb") as target:
                    target.setparams(source.getparams())
                    source.setpos(first)
                    remaining = last - first
                    while remaining:
                        cancel.check()
                        count = min(remaining, CHANNEL_POLICY.copy_frames)
                        data = source.readframes(count)
                        if len(data) != count * source.getnchannels() * source.getsampwidth():
                            raise ValueError("Working channel changed during slicing")
                        target.writeframesraw(data)
                        remaining -= count
            result = engine.transcribe(part, output.parent / f"{output.name}-region-{index}", language, cancel)
            offset = first * 1000 // rate
            duration = ((last - first) * 1000 + rate - 1) // rate
            mapped = []
            for original in result.segments:
                segment = copy.deepcopy(original)
                # Decoder padding outside this region is not speech evidence.
                begin, finish = max(0, segment["start_ms"]), min(duration, segment["end_ms"])
                if finish <= begin:
                    continue
                segment.update(start_ms=begin + offset, end_ms=finish + offset,
                               review_reasons=["channel_window_boundary; verify_partial_or_duplicate_speech"])
                for word in segment["words"]:
                    for field in ("start_ms", "end_ms"):
                        if word.get(field) is not None:
                            word[field] = min(duration, max(0, word[field])) + offset
                mapped.append(segment)
            results.append((result, mapped))
            records.append({"path": str(result.raw_path.relative_to(output.parent)), "sha256": sha256(result.raw_path, cancel.check),
                            "working_audio": part.name, "working_sha256": sha256(part, cancel.check),
                            "offset_ms": offset, "duration_ms": duration, "source_frames": [start, end],
                            "provenance": result.provenance})
    # This index is explicitly orchestration evidence, not fabricated backend output.
    raw = output.with_suffix(".regions.json")
    write_json(raw, {"kind": "channel_region_output_index", "policy": "exact_pcm_equality_v1",
                     "shared_source_channel": 0, "regions": records,
                     "timing_policy": "region-relative times clipped to region and offset; originals retained"})
    provenance = dict(results[0][0].provenance)
    provenance["duration_seconds"] = sum(item.provenance["duration_seconds"] for item, _ in results)
    provenance["channel_regions"] = records
    provenance["command"] = []  # Each actual command is retained in its region provenance.
    return EngineResult([segment for _, segments in results for segment in segments], raw, provenance)
