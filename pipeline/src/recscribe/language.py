"""Explicit derived-text boundary; never pretend that ASR translated dialect."""

from typing import Protocol


class LanguageProcessor(Protocol):
    def process(self, segments: list[dict], source_language: str,
                target_language: str, mode: str) -> list[dict]: ...


def mark_pending(segments: list[dict], mode: str) -> dict:
    for segment in segments:
        segment["normalized_text"] = None
        segment["translated_text"] = None
        if mode != "verbatim":
            segment["review_reasons"].append(f"{mode}_processor_not_configured")
    return {"mode": mode, "status": "not_requested" if mode == "verbatim" else "pending",
            "processor": None, "derivations": []}
