"""Pure deterministic views of canonical JSON, never an additional truth source."""

import html
import re


def timestamp(ms: int, separator: str = ".") -> str:
    seconds, millis = divmod(ms, 1000)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}{separator}{millis:03d}"


def line(text: str) -> str:
    return " ".join(text.split())


def selected_text(segment: dict, mode: str) -> str:
    key = {"normalize": "normalized_text", "translate": "translated_text"}.get(mode)
    return segment.get(key) or segment["source_text"]


def markdown(text: str) -> str:
    return re.sub(r"([\\`*_{}\[\]()#+.!|>~-])", r"\\\1", html.escape(line(text)))


def render(document: dict) -> dict[str, str]:
    segments = document["segments"]
    mode = document["processing"]["mode"]
    issues = document["review_reasons"]
    md = ["# RecScribe transcript", "", f"Requested mode: {mode}", ""]
    review = ["# Review", ""] + [f"- {reason}" for reason in issues] + [""]
    if document["language_processing"]["status"] == "pending":
        md += ["Language processing is pending; the text below remains raw ASR source text.", ""]
    srt, vtt = [], ["WEBVTT", ""]
    for i, segment in enumerate(segments, 1):
        text = line(selected_text(segment, mode))
        marker = "[REVIEW] " if segment["needs_review"] else ""
        # A plain-text cue payload cannot inject subtitle markup or timestamps.
        payload = html.escape(marker + text).replace("-->", "—>")
        start, end = segment["start_ms"], segment["end_ms"]
        md += [f"## {timestamp(start)} · {segment['id']} · channel {segment['channel'] + 1}",
               "", marker + markdown(text), ""]
        if segment["needs_review"]:
            review += [f"## {segment['id']} ({timestamp(start)})", "",
                       markdown(segment["source_text"]), "",
                       *[f"- {r}" for r in segment["review_reasons"]], ""]
        srt += [str(i), f"{timestamp(start, ',')} --> {timestamp(end, ',')}", payload, ""]
        vtt += [segment["id"], f"{timestamp(start)} --> {timestamp(end)}", payload, ""]
    return {"transcript.verbatim.txt": "\n".join(s["source_text"] for s in segments) + ("\n" if segments else ""),
            "transcript.cleaned.md": "\n".join(md), "transcript.srt": "\n".join(srt),
            "transcript.vtt": "\n".join(vtt), "review.md": "\n".join(review)}
