"""Conservative review signals; never rewrite or suppress ASR evidence."""

from collections import Counter
from dataclasses import dataclass


@dataclass(frozen=True)
class ReviewPolicy:
    minimum_confidence: float = 0.6
    part_boundary_ms: int = 2000
    decoder_padding_ms: int = 30000
    repetition_count: int = 3


REVIEW_POLICY = ReviewPolicy()


def flag_repetition(segments: list[dict]) -> None:
    # Channel-local counts avoid confusing stereo copies with repeated decoding.
    key = lambda s: (s["channel"], " ".join(s["source_text"].casefold().split()))
    counts = Counter(key(segment) for segment in segments)
    for segment in segments:
        if counts[key(segment)] >= REVIEW_POLICY.repetition_count:
            segment["review_reasons"].append("repeated_asr_text; verify_against_audio")
