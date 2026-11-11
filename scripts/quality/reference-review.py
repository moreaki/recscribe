#!/usr/bin/env python3
"""Prepare pending local reviews; audit/export explicitly reviewed segment targets.

No inference, playback, network, credential access or automatic human approval.
Packets and exports contain private text: use a new protected external location.
"""
import argparse
import datetime
import hashlib
import io
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


def frame_view(mapping, number, segment, entry, audio_data, rate, frames, budget):
    """Verify a source-EOF view without realigning the original decoder entry."""
    view = mapping["views"][number]
    start, end = entry["offsets"]["from"], entry["offsets"]["to"]
    first, last = start * rate // 1000, min(end * rate // 1000, frames)
    if start * rate % 1000 or not first < last:
        raise ValueError("Frame view requires an exact original start frame")
    expected = {"segmentID": segment["id"], "rawIndex": number,
        "rawEntrySHA256": digest(encoded(entry)), "rawOffsetsMs": entry["offsets"],
        "canonicalOffsetsMs": {"from": segment["start_ms"], "to": segment["end_ms"]},
        "startFrame": first, "endFrame": last, "sampleRate": rate,
        "startMs": first * 1000 / rate, "endMs": last * 1000 / rate,
        "removedNonexistentTailMs": max(0, end - frames * 1000 / rate)}
    if encoded({k: view.get(k) for k in expected}) != encoded(expected):
        raise ValueError("Frame mapping does not match source/decoder coordinates")
    if view.get("tokenTimingReused") is not False or view.get("tokenProbabilitiesAssignedToView") is not False:
        raise ValueError("A frame view cannot reassign token evidence")
    tokens = entry.get("tokens")
    if not isinstance(tokens, list) or not 1 <= len(tokens) <= 4096:
        raise ValueError("Frame view requires bounded original token timing")
    lexical, special_outside = 0, 0
    for token in tokens:
        text, offsets = token.get("text"), token.get("offsets", {})
        a, b = offsets.get("from"), offsets.get("to")
        if not isinstance(text, str) or type(a) is not int or type(b) is not int or not start <= a <= b <= end:
            raise ValueError("Invalid original frame-view token timing")
        if text.startswith("[_") or text.startswith("<|"):
            if b * rate > frames * 1000:
                if a != b or b != end:
                    raise ValueError("Only a zero-length decoder end marker may exceed EOF")
                special_outside += 1
        elif text.strip():
            if a * rate < first * 1000 or b * rate > last * 1000:
                raise ValueError("Lexical token crosses physical frame-view bounds")
            lexical += 1
    if not lexical or type(view.get("lexicalTokensWithinSource")) is not int or type(view.get("outsideSourceSpecialTokens")) is not int or view["lexicalTokensWithinSource"] != lexical or view["outsideSourceSpecialTokens"] != special_outside:
        raise ValueError("Frame-view token coverage proof changed")
    view_path = Path(view["path"]).absolute()
    data, view_sha = budget.file(view_path)
    with wave.open(io.BytesIO(audio_data), "rb") as source, wave.open(io.BytesIO(data), "rb") as selected:
        if selected.getnchannels() != 1 or selected.getsampwidth() != 2 or selected.getframerate() != rate or selected.getnframes() != last - first:
            raise ValueError("Frame-view WAV format/bounds changed")
        source.setpos(first)
        pcm = source.readframes(last - first)
        if selected.readframes(last - first) != pcm:
            raise ValueError("Frame-view PCM differs from original source")
    if view_sha != view.get("sha256") or digest(pcm) != view.get("pcmSHA256"):
        raise ValueError("Frame-view audio hash changed")
    return {**expected, "path": str(view_path), "sha256": view_sha, "pcmSHA256": digest(pcm)}


def bindings(manifest, case_id, job, scoring_policy, budget, frame_mapping=None):
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
        width = stream.getsampwidth()
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
    mapping = None
    if frame_mapping is not None:
        frame_mapping = Path(frame_mapping).absolute()
        mapping, mapping_sha = budget.json(frame_mapping)
        proof = {"schema": "recscribe.frame-exact-review-mapping.v1", "caseID": case_id,
            "source": str(audio), "sourceSHA256": audio_sha, "sourceFrames": frames, "sampleRate": rate,
            "sourceDurationMs": duration, "job": str(job), "rawSHA256": raw_sha,
            "canonicalSHA256": canonical_sha, "rawIndexSHA256": index_sha, "jobManifestSHA256": lifecycle_sha}
        if any(mapping.get(k) != v or type(mapping.get(k)) is not type(v) for k, v in proof.items()):
            raise ValueError("Frame mapping provenance changed")
        if channels != 1 or width != 2 or rate != 16000 or channel != 0 or not isinstance(mapping.get("views"), list) or len(mapping["views"]) != len(entries):
            raise ValueError("Unsupported frame-view format/coverage")
        audio_data, checked_sha = budget.file(audio)
        if checked_sha != audio_sha:
            raise ValueError("Source changed during frame verification")
    used = set()
    padded = False
    for number, entry in enumerate(entries):
        start, end = entry["offsets"]["from"], entry["offsets"]["to"]
        if type(start) is not int or type(end) is not int or start < cursor or not 0 <= start < end or start >= duration:
            raise ValueError("Overlapping, padded or adjusted raw timing needs explicit remapping review")
        overhang = end > duration
        if overhang and (mapping is None or number != len(entries) - 1 or not 0 < end - duration < 10 or end != math.ceil(duration / 10) * 10):
            raise ValueError("Unsupported decoder overhang; only the final sub-10ms EOF tick is allowed")
        canonical_end = math.ceil(duration) if overhang else end
        adjustment = {"original_end_ms": end, "reason": "decoder_padding_beyond_source"} if overhang else None
        matches = [s for s in selected if s.get("start_ms") == start and s.get("end_ms") == canonical_end and s.get("source_text") == entry["text"]]
        if len(matches) != 1 or matches[0]["id"] in used or (matches[0].get("timing_adjustment") != adjustment if overhang else bool(matches[0].get("timing_adjustment"))):
            raise ValueError("Ambiguous/adjusted canonical-to-raw segment mapping")
        used.add(matches[0]["id"])
        if start > cursor:
            gaps.append({"startMs": cursor, "endMs": start})
        segments.append({"id": matches[0]["id"], "rawIndex": number, "startMs": start, "endMs": end,
                         "recognition": entry, "recognitionSHA256": digest(encoded(entry))})
        if mapping is not None:
            view = frame_view(mapping, number, matches[0], entry, audio_data, rate, frames, budget)
            segments[-1].update(startMs=view["startMs"], endMs=view["endMs"], frameView=view)
        cursor = min(end, duration)
        padded |= overhang
    if len(used) != len(selected):
        raise ValueError("Canonical segments are not one-to-one with original speech entries")
    if cursor < duration:
        gaps.append({"startMs": cursor, "endMs": duration})
    if mapping is not None and not padded:
        raise ValueError("Frame-view admission requires proven decoder EOF padding")
    ancestors = [case["source_id"]] if case.get("source_id") else []
    if case.get("original_audio_sha256"):
        if not re.fullmatch("[0-9a-f]{64}", case["original_audio_sha256"]):
            raise ValueError("Invalid original-audio ancestor hash")
        ancestors.append("audio-sha256:" + case["original_audio_sha256"])
    result = {"manifest": str(manifest), "manifestSHA256": corpus_sha, "caseID": case_id, "job": str(job),
            "canonicalSHA256": canonical_sha, "jobManifestSHA256": lifecycle_sha, "rawIndexSHA256": index_sha, "rawSHA256": raw_sha,
            "audio": str(audio), "audioSHA256": audio_sha, "reference": str(reference), "referenceSHA256": reference_sha,
            "publishedReference": text.decode("utf-8"), "channel": channel, "scope": scope, "decodingRecipe": recipe,
            "runtimePath": command[0], "assets": assets, "licenseDeclaration": case.get("license"),
            "sourceID": case.get("source_id"), "requiredSourceIDs": ancestors, "segments": segments, "gaps": gaps}
    if mapping is not None:
        result["frameMapping"] = {"path": str(frame_mapping), "sha256": mapping_sha, "policy": "decoder-eof-frame-view-v1"}
    return result


def pending():
    return {"status": "pending", "reviewer": "", "reviewedAt": "", "evidence": ""}


def frame_approval_binding(frozen, segment):
    view = segment["frameView"]
    return {"mappingSHA256": frozen["frameMapping"]["sha256"], "viewSHA256": view["sha256"],
            **{k: view[k] for k in ("startFrame", "endFrame", "sampleRate")}}


def prepare(manifest, case_id, job, policy, output, frame_mapping=None):
    frozen = bindings(manifest, case_id, job, policy, Budget(), frame_mapping)
    reviews = []
    for segment in frozen["segments"]:
        reviews.append({"id": segment["id"], "referenceText": "", "disposition": "speech",
                        "lexical": pending(), "alignment": pending()})
        if frame_mapping is not None:
            reviews[-1]["frameAlignment"] = {**pending(), **frame_approval_binding(frozen, segment)}
    packet = {"version": 2 if frame_mapping is not None else 1, "bindings": frozen, "review": {"permission": pending(), "grouping": pending(), "scope": pending(),
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
    version = packet.get("version")
    if type(version) is not int or version not in (1, 2):
        raise ValueError("Unsupported review packet version")
    mapping = frozen.get("frameMapping") if version == 2 else None
    if version == 2 and (not isinstance(mapping, dict) or not isinstance(mapping.get("path"), str)):
        raise ValueError("Missing explicit frame mapping")
    if frozen != bindings(frozen["manifest"], frozen["caseID"], frozen["job"], frozen["scope"]["scoringPolicy"], budget,
                          mapping["path"] if mapping else None):
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
        frame_ok = version == 1
        if version == 2:
            frame_alignment = decision.get("frameAlignment")
            frame_ok = isinstance(frame_alignment, dict) and approved(frame_alignment) and not any(
                    frame_alignment.get(k) != v or type(frame_alignment.get(k)) is not type(v)
                    for k, v in frame_approval_binding(frozen, segment).items())
            if not frame_ok:
                blocks.append(segment["id"] + ": explicit frame alignment approval")
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
            "permissionEvidence": json.dumps(review["permission"], sort_keys=True), "alignmentReviewed": approved(decision["alignment"]) and frame_ok,
            "reference": truth, "recognition": segment["recognition"]})
        if version == 2:
            # Features remain original decoder evidence, including its duration;
            # this separate record binds the reference to physical source frames.
            rows[-1]["sourceFrameEvidence"] = {**frame_approval_binding(frozen, segment),
                "rawEntrySHA256": segment["recognitionSHA256"], "rawOffsetsMs": segment["recognition"]["offsets"],
                "alignment": decision.get("frameAlignment"), "tokenTimingRewritten": False}
    for original, gap in zip(frozen["gaps"], review["gaps"]):
        if any(original[key] != gap.get(key) for key in ("startMs", "endMs")):
            raise ValueError("Gap boundary changed")
        if not approved(gap.get("review")) or gap.get("referenceText", "").strip():
            blocks.append("gap: unresolved or missed speech requires separate recall accounting")
    audit = {"packet": str(Path(path).absolute()), "packetSHA256": packet_sha, "blocks": blocks, "excluded": excluded}
    if version == 2:
        audit["frameMapping"] = dict(frozen["frameMapping"])
        audit["frameViews"] = [{"path": s["frameView"]["path"], "sha256": s["frameView"]["sha256"]}
                               for s in frozen["segments"]]
    return frozen, rows, audit


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
    for audit in audits:
        for view in audit.get("frameViews", []):
            if budget.file(view["path"], retain=False)[1] != view["sha256"]:
                raise ValueError("Frame-view WAV changed during export")
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
        if "frameMapping" in audit:
            mapping = audit["frameMapping"]
            original, mapping_sha = budget.file(mapping["path"])
            if mapping_sha != mapping["sha256"]:
                raise ValueError("Frame mapping changed during export")
            mapping["snapshot"] = "mapping-" + str(index) + ".json"
            new_bytes(output / mapping["snapshot"], original)
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
    prep.add_argument("--frame-mapping", help="Explicit source-EOF mapping; creates a version-2 pending packet")
    audit = commands.add_parser("audit"); audit.add_argument("packet")
    emit = commands.add_parser("export"); emit.add_argument("packets", nargs="+"); emit.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        packet = prepare(args.manifest, args.case, args.job, args.scoring_policy, args.output, args.frame_mapping)
        print(json.dumps({"status": "pending_human_review", "segments": len(packet["bindings"]["segments"])}))
    elif args.command == "audit":
        print(json.dumps(audit_packet(args.packet, Budget())[2], indent=2))
    else:
        dataset = export(args.packets, args.output)
        print(json.dumps({"purpose": "research_only", "rows": len(dataset["rows"])}))


if __name__ == "__main__":
    main()
