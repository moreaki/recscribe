"""Conservative review signals; never rewrite or suppress ASR evidence."""

from collections import Counter


def flag_repetition(segments: list[dict]) -> None:
    # Channel-local counts avoid confusing stereo copies with repeated decoding.
    key = lambda s: (s["channel"], " ".join(s["source_text"].casefold().split()))
    counts = Counter(key(segment) for segment in segments)
    for segment in segments:
        if counts[key(segment)] >= 3:
            segment["review_reasons"].append("repeated_asr_text; verify_against_audio")
