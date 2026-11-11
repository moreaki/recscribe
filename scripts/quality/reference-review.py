#!/usr/bin/env python3
"""Prepare pending local reviews; audit/export explicitly reviewed segment targets.

No inference, playback, network, credential access or automatic human approval.
Packets and exports contain private text: use a new protected external location.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import time
import wave

ROOT = Path(__file__).resolve().parents[2]
POLICIES = {"swift-nfc-casefold-alphanumeric-v1", "unicode-nfc-apostrophe-v2", "unicode-nfc-cer-v2",
            "arabic-nfc-strict-v2", "arabic-nfc-no-diacritics-v2"}


class Budget:
    def __init__(self):
        self.deadline = time.monotonic() + 90
        self.bytes = 0
        self.cache = {}

    def check(self):
        if time.monotonic() > self.deadline:
            raise ValueError("Review preparation/export deadline exceeded")

    def file(self, path, maximum=16 * 1024 * 1024, retain=True):
        self.check()
        path = Path(path).absolute()
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
                raise ValueError("Expected bounded regular evidence file")
            identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            key = (str(path), identity)
            if not retain and key in self.cache:
                return None, self.cache[key]
            digest, blocks = hashlib.sha256(), []
            while block := stream.read(1024 * 1024):
                self.check()
                self.bytes += len(block)
                if self.bytes > 16 * 1024**3:
                    raise ValueError("Evidence verification exceeds 16 GiB total budget")
                digest.update(block)
                if retain:
                    blocks.append(block)
            after = os.fstat(stream.fileno())
            if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise ValueError("Evidence changed during verification")
            if sum(map(len, blocks)) > maximum or after.st_size != before.st_size:
                raise ValueError("Evidence size changed")
            self.cache[key] = digest.hexdigest()
            return b"".join(blocks) if retain else None, digest.hexdigest()

    def json(self, path):
        data, digest = self.file(path)
        return json.loads(data), digest


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def child(root, name):
    if not isinstance(name, str) or Path(name).name != name or name in {"", ".", ".."}:
        raise ValueError("Evidence path must name a file directly inside its job")
    return root / name


def resolved(value, base):
    path = Path(value)
    if ".." in path.parts:
        raise ValueError("Lexical path traversal is unsupported")
    return (path if path.is_absolute() else base / path).absolute()


def new_bytes(path, data):
    path = Path(path).absolute()
    if path.is_symlink() or path.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError("Write review text outside the source checkout")
    if len(data) > 16 * 1024**2:
        raise ValueError("Review output exceeds 16 MiB")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)


def new_json(path, value):
    new_bytes(path, encoded(value) + b"\n")


def bindings(manifest, case_id, job, scoring_policy, budget):
    manifest, job = Path(manifest).absolute(), Path(job).absolute()
    corpus, corpus_sha = budget.json(manifest)
    cases = [row for row in corpus["cases"] if row["id"] == case_id]
    if len(cases) != 1 or scoring_policy not in POLICIES:
        raise ValueError("Choose one explicit corpus case and scoring policy")
    case = cases[0]
    if case.get("task") not in {"transcription", "dialect_transcription", "standard_rendering"}:
        raise ValueError("Non-speech/translation needs a separate negative/task review workflow")
    audio = resolved(case["audio"], manifest.parent)
    reference = resolved(case["reference"], manifest.parent)
    _, audio_sha = budget.file(audio, maximum=512 * 1024**2, retain=False)
    text, reference_sha = budget.file(reference, maximum=65_536)
    if audio_sha != case["sha256"] or reference_sha != case["reference_sha256"]:
        raise ValueError("Published audio/reference hash mismatch")
    with wave.open(str(audio), "rb") as stream:
        channels, rate, frames = stream.getnchannels(), stream.getframerate(), stream.getnframes()
    duration = frames * 1000 / rate
    channel = case.get("source_channel")
    if type(channel) is not int or not 0 <= channel < channels <= 32 or not 0 < duration <= 120_000:
        raise ValueError("Unsupported channel or reference duration")
    canonical, canonical_sha = budget.json(job / "transcript.json")
    index, index_sha = budget.json(job / "transcript.raw.json")
    lifecycle, lifecycle_sha = budget.json(job / "manifest.json")
    if lifecycle.get("state") not in {"completed", "completed_with_review"} or canonical.get("processing", {}).get("mode") != "verbatim":
        raise ValueError("Select a completed original verbatim audio job")
    if index.get("kind") != "immutable_engine_output_index":
        raise ValueError("Multipart/region-remapped recognition is not supported by this first workflow")
    source = canonical["source"]
    if source.get("sha256") != audio_sha or source.get("channels") != channels or source.get("sample_rate") != rate:
        raise ValueError("Job is not bound to the selected original audio")
    outputs = [row for row in index["outputs"] if row.get("channel") == channel and row.get("role") == "primary" and row.get("status") == "produced"]
    if len(outputs) != 1:
        raise ValueError("Cannot map one primary recognition to the selected channel")
    output = outputs[0]
    raw_path = child(job, output["path"])
    raw, raw_sha = budget.json(raw_path)
    if raw_sha != output["sha256"]:
        raise ValueError("Original recognition hash mismatch")
    engine = output["provenance"]
    if engine.get("engine") != "whisper.cpp" or engine not in canonical["processing"].get("engine_passes", []):
        raise ValueError("Only original local Whisper evidence is supported")
    for key in ("model_sha256", "binary_sha256"):
        if not re.fullmatch("[0-9a-f]{64}", engine.get(key, "")):
            raise ValueError("Missing model/runtime identity")
    profile_path = raw_path.with_suffix(".profile.json")
    profile, profile_sha = budget.json(profile_path)
    if profile != engine["decoding"]["profile"] or profile_sha != engine["decoding"]["profile_sha256"]:
        raise ValueError("Decoding profile hash/provenance mismatch")
    for path, sha in ((job / "transcript.json", canonical_sha), (job / "transcript.raw.json", index_sha),
                      (raw_path, raw_sha), (profile_path, profile_sha)):
        artifact = lifecycle.get("artifacts", {}).get(path.name, {})
        if artifact.get("sha256") != sha or artifact.get("size_bytes") != path.stat().st_size:
            raise ValueError("Job artifact inventory no longer matches immutable evidence")
    command = engine.get("command", [])
    # Strip only location/output arguments. Retain every actual inference flag,
    # including language, threads, VAD thresholds and future advertised options.
    options, assets = [], []
    i = 1
    while i < len(command):
        value = command[i]
        if value in {"-m", "-f", "-of", "--vad-model", "-vm"}:
            if i + 1 >= len(command):
                raise ValueError("Incomplete recorded invocation")
            if value in {"-m", "--vad-model", "-vm"}:
                assets.append({"flag": value, "path": command[i + 1]})
            options.append(value)  # Asset identity is separately hash-bound.
            i += 2
        else:
            options.append(value)
            i += 1
    if not command or not any(a["flag"] == "-m" for a in assets) or engine.get("asr_language") is None:
        raise ValueError("Complete invocation evidence is required")
    recipe = {"version": "review-decoding-v1", "profileSHA256": profile_sha, "options": options,
              "asrLanguage": engine["asr_language"], "speech": engine.get("speech"), "vadSHA256": engine.get("vad_model_sha256")}
    scope = {"modelSHA256": engine["model_sha256"], "runtimeSHA256": engine["binary_sha256"],
             "decodingSHA256": digest(encoded(recipe)), "language": case["language"], "scoringPolicy": scoring_policy,
             "unit": "studioSegment", "referenceTask": "standard_rendering" if case["task"] == "standard_rendering" else "verbatim"}
    entries, segments, cursor, gaps = raw["transcription"], [], 0, []
    if not isinstance(entries, list) or not 1 <= len(entries) <= 512:
        raise ValueError("Empty/missing speech needs negative or missed-speech accounting, not a 100% target")
    selected = [s for s in canonical["segments"] if s.get("channel") == channel]
    used = set()
    for number, entry in enumerate(entries):
        start, end = entry["offsets"]["from"], entry["offsets"]["to"]
        if type(start) is not int or type(end) is not int or start < cursor or not start < end <= duration:
            raise ValueError("Overlapping, padded or adjusted raw timing needs explicit remapping review")
        matches = [s for s in selected if s.get("start_ms") == start and s.get("end_ms") == end and s.get("source_text") == entry["text"]]
        if len(matches) != 1 or matches[0]["id"] in used or matches[0].get("timing_adjustment"):
            raise ValueError("Ambiguous/adjusted canonical-to-raw segment mapping")
        used.add(matches[0]["id"])
        if start > cursor:
            gaps.append({"startMs": cursor, "endMs": start})
        segments.append({"id": matches[0]["id"], "rawIndex": number, "startMs": start, "endMs": end,
                         "recognition": entry, "recognitionSHA256": digest(encoded(entry))})
        cursor = end
    if len(used) != len(selected):
        raise ValueError("Canonical segments are not one-to-one with original speech entries")
    if cursor < duration:
        gaps.append({"startMs": cursor, "endMs": duration})
    ancestors = [case["source_id"]] if case.get("source_id") else []
    if case.get("original_audio_sha256"):
        if not re.fullmatch("[0-9a-f]{64}", case["original_audio_sha256"]):
            raise ValueError("Invalid original-audio ancestor hash")
        ancestors.append("audio-sha256:" + case["original_audio_sha256"])
    return {"manifest": str(manifest), "manifestSHA256": corpus_sha, "caseID": case_id, "job": str(job),
            "canonicalSHA256": canonical_sha, "jobManifestSHA256": lifecycle_sha, "rawIndexSHA256": index_sha, "rawSHA256": raw_sha,
            "audio": str(audio), "audioSHA256": audio_sha, "reference": str(reference), "referenceSHA256": reference_sha,
            "publishedReference": text.decode("utf-8"), "channel": channel, "scope": scope, "decodingRecipe": recipe,
            "runtimePath": command[0], "assets": assets, "licenseDeclaration": case.get("license"),
            "sourceID": case.get("source_id"), "requiredSourceIDs": ancestors, "segments": segments, "gaps": gaps}


def pending():
    return {"status": "pending", "reviewer": "", "reviewedAt": "", "evidence": ""}


def prepare(manifest, case_id, job, policy, output):
    frozen = bindings(manifest, case_id, job, policy, Budget())
    reviews = []
    for segment in frozen["segments"]:
        reviews.append({"id": segment["id"], "referenceText": "", "disposition": "speech",
                        "lexical": pending(), "alignment": pending()})
    packet = {"version": 1, "bindings": frozen, "review": {"permission": pending(), "grouping": pending(), "scope": pending(),
        "recordingID": "", "sessionID": "", "speakerIDs": [], "sourceIDs": [], "split": None,
        "segments": reviews, "gaps": [{**gap, "referenceText": "", "review": pending()} for gap in frozen["gaps"]]}}
    new_json(output, packet)
    return packet


def approved(value):
    if not (isinstance(value, dict) and value.get("status") == "approved" and all(
            isinstance(value.get(key), str) and value[key].strip() for key in ("reviewer", "reviewedAt", "evidence"))):
        return False
    try:
        return datetime.datetime.fromisoformat(value["reviewedAt"].replace("Z", "+00:00")).utcoffset() is not None
    except ValueError:
        return False


def audit_packet(path, budget):
    packet, packet_sha = budget.json(path)
    frozen, review = packet["bindings"], packet["review"]
    if packet.get("version") != 1 or frozen != bindings(frozen["manifest"], frozen["caseID"], frozen["job"], frozen["scope"]["scoringPolicy"], budget):
        raise ValueError("Review bindings changed; prepare a new pending packet")
    blocks = [name for name in ("permission", "grouping", "scope") if not approved(review.get(name))]
    groups = [review.get("recordingID"), review.get("sessionID"), *(review.get("speakerIDs") or []), *(review.get("sourceIDs") or [])]
    if not review.get("speakerIDs") or not review.get("sourceIDs") or any(not isinstance(g, str) or not g.strip() or g.lower() in {"unknown", "pending"} for g in groups):
        blocks.append("known recording/session/speaker/ancestor source groups")
    if not set(frozen["requiredSourceIDs"]).issubset(review.get("sourceIDs", [])):
        blocks.append("original source ancestor must remain in sourceIDs")
    if review.get("split") not in {"training", "calibration", "evaluation"}:
        blocks.append("declared split (old holdouts are consumed development material)")
    if len(review["segments"]) != len(frozen["segments"]) or len(review["gaps"]) != len(frozen["gaps"]):
        raise ValueError("Review coverage changed")
    rows, excluded = [], []
    for segment, decision in zip(frozen["segments"], review["segments"]):
        if decision["id"] != segment["id"]:
            raise ValueError("Review segment identity/order changed")
        if not approved(decision.get("lexical")) or not approved(decision.get("alignment")):
            blocks.append(segment["id"] + ": lexical/alignment review")
        truth = decision.get("referenceText")
        if not isinstance(truth, str) or len(truth.encode()) > 65_536:
            raise ValueError("Invalid reviewed reference")
        if decision.get("disposition") == "non_speech":
            if truth.strip():
                blocks.append(segment["id"] + ": non-speech cannot carry speech reference")
            excluded.append({"id": segment["id"], "reason": "reviewed_non_speech; no accuracy denominator"})
            continue
        if decision.get("disposition") != "speech" or not truth.strip():
            blocks.append(segment["id"] + ": unresolved/empty speech reference")
        rows.append({"id": frozen["caseID"] + ":" + segment["id"], "split": review.get("split"),
            "recordingID": review.get("recordingID"), "sessionID": review.get("sessionID"), "channel": frozen["channel"],
            "speakerIDs": review.get("speakerIDs"), "sourceIDs": review.get("sourceIDs"),
            "audioSHA256": frozen["audioSHA256"], "referenceSHA256": digest(truth.encode()),
            "lexicalReviewEvidence": json.dumps({"lexical": decision["lexical"], "alignment": decision["alignment"], "packetSHA256": packet_sha}, sort_keys=True),
            "permissionEvidence": json.dumps(review["permission"], sort_keys=True), "alignmentReviewed": approved(decision["alignment"]),
            "reference": truth, "recognition": segment["recognition"]})
    for original, gap in zip(frozen["gaps"], review["gaps"]):
        if any(original[key] != gap.get(key) for key in ("startMs", "endMs")):
            raise ValueError("Gap boundary changed")
        if not approved(gap.get("review")) or gap.get("referenceText", "").strip():
            blocks.append("gap: unresolved or missed speech requires separate recall accounting")
    return frozen, rows, {"packet": str(Path(path).absolute()), "packetSHA256": packet_sha,
                          "blocks": blocks, "excluded": excluded}


def validate_row(row):
    for key, maximum in (("id", 1024), ("recordingID", 1024), ("sessionID", 1024),
                         ("lexicalReviewEvidence", 2048), ("permissionEvidence", 2048), ("reference", 65_536)):
        value = row[key]
        if not isinstance(value, str) or not value.strip() or len(value.encode()) > maximum:
            raise ValueError("Reviewed row exceeds fitter bounds: " + key)
    for key in ("speakerIDs", "sourceIDs"):
        if not isinstance(row[key], list) or not 1 <= len(row[key]) <= 64 or any(
                not isinstance(x, str) or not x.strip() or len(x.encode()) > 1024 for x in row[key]):
            raise ValueError("Invalid reviewed grouping: " + key)
    entry = row["recognition"]
    if not isinstance(entry["text"], str) or not entry["text"].strip() or len(entry["text"].encode()) > 65_536:
        raise ValueError("No bounded original speech hypothesis; retain as a coverage gap")
    tokens = entry.get("tokens")
    if tokens is not None:
        if not isinstance(tokens, list) or len(tokens) > 4096:
            raise ValueError("Token evidence exceeds fitter bounds")
        for token in tokens:
            if not isinstance(token.get("text"), str):
                raise ValueError("Invalid original token text")
            p = token.get("p")
            if p is not None and (type(p) not in {int, float} or not math.isfinite(p) or not 0 <= p <= 1):
                raise ValueError("Invalid original token probability")


def export(paths, output):
    if not 1 <= len(paths) <= 32:
        raise ValueError("Export accepts 1–32 packets per bounded invocation")
    budget, all_rows, audits, scope, assignments = Budget(), [], [], None, {}
    for path in paths:
        frozen, rows, audit = audit_packet(path, budget)
        if audit["blocks"]:
            raise ValueError("Unfinished reference review: " + "; ".join(audit["blocks"]))
        if scope is not None and frozen["scope"] != scope:
            raise ValueError("Do not pool incompatible model/language/task/decoding scopes")
        scope = frozen["scope"]
        assets = [(frozen["runtimePath"], scope["runtimeSHA256"])]
        for asset in frozen["assets"]:
            expected = scope["modelSHA256"] if asset["flag"] == "-m" else frozen["decodingRecipe"]["vadSHA256"]
            assets.append((asset["path"], expected))
        for asset, expected in assets:
            if budget.file(asset, maximum=4 * 1024**3, retain=False)[1] != expected:
                raise ValueError("Model/runtime/VAD asset changed or is unavailable")
        all_rows += rows; audits.append(audit)
    if not 3 <= len(all_rows) <= 2_000 or len({r["id"] for r in all_rows}) != len(all_rows):
        raise ValueError("Need 3–2000 uniquely identified reviewed speech rows")
    for row in all_rows:
        validate_row(row)
        groups = [("recording", row["recordingID"]), ("session", row["sessionID"]), ("audio", row["audioSHA256"]),
                  ("reference", row["referenceSHA256"])] + [("speaker", x) for x in row["speakerIDs"]] + [("source", x) for x in row["sourceIDs"]]
        for group in groups:
            if group in assignments and assignments[group] != row["split"]:
                raise ValueError("Review export split leakage")
            assignments[group] = row["split"]
    if {r["split"] for r in all_rows} != {"training", "calibration", "evaluation"}:
        raise ValueError("Export requires three explicitly disjoint partitions")
    output = Path(output).absolute()
    if output.is_symlink() or output.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError("Export review data outside the source checkout")
    output.mkdir(mode=0o700)  # Exclusive creation: never replace existing review/data.
    dataset = {"version": 1, "scope": scope, "rows": all_rows}
    for index, audit in enumerate(audits):
        original, packet_sha = budget.file(audit["packet"])
        if packet_sha != audit["packetSHA256"]:
            raise ValueError("Review changed during export")
        audit["snapshot"] = "packet-" + str(index) + ".json"
        new_bytes(output / audit["snapshot"], original)
    new_json(output / "audit.json", {"purpose": "research_only", "packets": audits,
        "speechRows": len(all_rows), "excludedNonSpeech": sum(len(a["excluded"]) for a in audits),
        "limitations": ["Declared research partitions do not establish fresh independent final evaluation; consumed benchmark data cannot qualify a Studio model."],
        "datasetSHA256": digest(encoded(dataset) + b"\n")})
    new_json(output / "dataset.json", dataset)  # Publication marker, written last.
    return dataset


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    for flag in ("manifest", "case", "job", "output", "scoring-policy"):
        prep.add_argument("--" + flag, required=True)
    audit = commands.add_parser("audit"); audit.add_argument("packet")
    emit = commands.add_parser("export"); emit.add_argument("packets", nargs="+"); emit.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        packet = prepare(args.manifest, args.case, args.job, args.scoring_policy, args.output)
        print(json.dumps({"status": "pending_human_review", "segments": len(packet["bindings"]["segments"])}))
    elif args.command == "audit":
        print(json.dumps(audit_packet(args.packet, Budget())[2], indent=2))
    else:
        dataset = export(args.packets, args.output)
        print(json.dumps({"purpose": "research_only", "rows": len(dataset["rows"])}))


if __name__ == "__main__":
    main()
