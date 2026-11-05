#!/usr/bin/env python3
"""Acquire an opaque, bounded public development-validation/fresh-heldout slice.

No ASR, uploads or human approval. Explicit prior manifests are exclusions, not
training inputs. Use scripts/work-artifacts.py and a NEW protected external root.
"""
import argparse
import copy
import csv
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import signal
import struct
import subprocess
import tempfile
import time
import wave
import zipfile
import tarfile

SPEC = importlib.util.spec_from_file_location("public_pilot_source", Path(__file__).with_name("acquire-pilot.py"))
base = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(base)
POLICY = "swift-nfc-casefold-alphanumeric-v1"
SWISS_ETAG = "1675691554462869d"
SWISS_BYTES = 1603017371
SOURCE_HASHES = {"card": "3a67ecf5611e582451b2d064aae1cf713be8f06073a4d6a6bcf7eca3f9a05ac5",
                 "swiss_readme": "5468f8707d4d86d1ba73e1808293906707bbf1accefb5be4c372510e3c201bb5",
                 "public": "7b84623cc1369fdacc310cf15c15d78b4d31e62422afbd4b0372f469d468ba82",
                 "private": "5a81fdddfba87e697794f630feadd25f3eeb9c278b1638e374a6cf8f71382020"}
LIMITS = ["Exploratory public read-speech data; public-pretraining overlap is possible",
          "No native-language reference/audio adjudication or human approval",
          "FLEURS individual speaker/session IDs are unavailable; unknowns remain unknown",
          "Published train/dev/test names do not prove dev/test speaker independence",
          "Swiss published speaker IDs are retained; session grouping remains unknown",
          "Natural long-form, adverse conditions, switches and regional/script coverage remain incomplete",
          "Legacy-v1 scoring only; unreviewed v2 metadata does not establish v2 eligibility"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("Use absolute non-symlink paths without traversal")
    return path


class Exclusions:
    def __init__(self):
        self.values = {key: set() for key in ("id", "source_id", "audio", "reference", "speaker", "session")}
        self.manifests = []

    def add(self, case):
        for key in ("id", "source_id"):
            if case.get(key): self.values[key].add(case[key])
        for key in ("sha256", "original_audio_sha256"):
            if case.get(key): self.values["audio"].add(case[key])
        if case.get("reference_sha256"): self.values["reference"].add(case["reference_sha256"])
        self.values["speaker"].update(case.get("speaker_ids") or [])
        if case.get("session_id"): self.values["session"].add(case["session_id"])

    def load(self, path):
        path = safe(path)
        with path.open("rb") as stream: data = stream.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024: raise ValueError("Exclusion manifest exceeds 4 MiB")
        document = json.loads(data)
        if not isinstance(document.get("cases"), list): raise ValueError("Exclusion cases required")
        for case in document["cases"]: self.add(case)
        self.manifests.append({"path": str(path), "sha256": sha(data), "cases": len(document["cases"])})

    def reasons(self, identifier, source_id, audio_hash, reference_hash, speakers=(), session=None):
        tests = {"id": identifier in self.values["id"], "source_id": source_id in self.values["source_id"],
                 "audio": audio_hash in self.values["audio"], "reference": reference_hash in self.values["reference"],
                 "speaker": bool(set(speakers) & self.values["speaker"]), "session": bool(session and session in self.values["session"])}
        return [key for key, overlaps in tests.items() if overlaps]


class Acquisition(base.Acquisition):
    def __init__(self, root, exclusions, seconds=1200):
        super().__init__(root)
        self.exclusions, self.deadline = exclusions, time.monotonic() + seconds
        self.output_bytes, self.cases, self.skipped = 0, [], {}

    def check(self):
        super().check()
        if time.monotonic() >= self.deadline: raise TimeoutError("Acquisition time budget exhausted")

    def open(self, url, headers=None, method="GET"):
        response = super().open(url, headers, method)
        if url == base.SWISS_ZIP and (response.headers.get("ETag", "").strip('"') != SWISS_ETAG or
                                    method == "HEAD" and int(response.headers.get("Content-Length", 0)) != SWISS_BYTES):
            response.close()
            raise ValueError("Pinned Swiss archive ETag/size changed")
        return response

    def read(self, response, size):
        self.check()
        remaining = base.MAX_NETWORK_BYTES - self.network_bytes
        if remaining <= 0: raise ValueError("256 MiB network budget exhausted")
        data = response.read(min(size, remaining))
        self.network_bytes += len(data)
        self.check()
        return data

    def reserve(self, size, final=False):
        if not final: self.check()
        maximum = 256 * 1024 * 1024 - (0 if final else 16 * 1024 * 1024)
        if size < 0 or self.output_bytes + size > maximum: raise ValueError("Protected output byte budget exhausted")
        self.output_bytes += size

    def save(self, path, data, final=False):
        self.reserve(len(data), final)
        base.save(path, data)

    def json(self, path, value, final=False):
        self.save(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode(), final)

    def skip(self, reasons):
        for reason in reasons: self.skipped[reason] = self.skipped.get(reason, 0) + 1


def source_frames(data, extension):
    if extension == "wav":
        with wave.open(io.BytesIO(data), "rb") as stream:
            return stream.getnframes(), stream.getframerate()
    if data[:4] != b"fLaC" or len(data) < 42 or data[4] & 0x7f != 0 or int.from_bytes(data[5:8], "big") != 34:
        raise ValueError("Expected FLAC STREAMINFO")
    packed = int.from_bytes(data[18:26], "big")
    return packed & ((1 << 36) - 1), packed >> 44


def convert(acquisition, source, target, maximum_bytes):
    acquisition.reserve(maximum_bytes)
    command = ["ffmpeg", "-nostdin", "-v", "error", "-n", "-threads", "1", "-i", str(source),
               "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(target)]
    with tempfile.TemporaryFile() as error_log:
        child = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=error_log)
        deadline = time.monotonic() + 45
        try:
            while child.poll() is None:
                acquisition.check()
                if time.monotonic() >= deadline or target.exists() and target.stat().st_size > maximum_bytes:
                    raise ValueError("Bounded PCM preparation exceeded time/bytes")
                try: child.wait(timeout=0.1)
                except subprocess.TimeoutExpired: pass
            if child.returncode: raise ValueError("PCM conversion failed; original retained")
        except BaseException:
            child.terminate()
            try: child.wait(timeout=2)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=2)
            raise
    return command


def prepare(acquisition, audio, reference, identifier, language, metadata, extension):
    if len(audio) > base.MAX_MEMBER_BYTES or not base.re.fullmatch(r"[A-Za-z0-9_-]{1,200}", identifier):
        raise ValueError("Unsafe/oversized source member")
    reference_bytes = reference.encode("utf-8")
    if len(reference_bytes) > 1024 * 1024: raise ValueError("Oversized human reference")
    reasons = acquisition.exclusions.reasons(identifier, metadata["source_id"], sha(audio), sha(reference_bytes),
                                           metadata.get("speaker_ids", []), metadata.get("session_id"))
    if reasons: acquisition.skip(reasons); return None
    frames, rate = source_frames(audio, extension)
    if rate <= 0 or frames <= 0 or frames / rate > 60: acquisition.skip(["source_duration_outside_bound"]); return None
    folder = acquisition.root / metadata["evaluation_split"] / identifier
    original, derived, ref = folder / ("source.original." + extension), folder / "benchmark.pcm16.wav", folder / "reference.original.txt"
    acquisition.save(original, audio)
    acquisition.save(ref, reference_bytes)
    command = convert(acquisition, original, derived, math.ceil(frames / rate * 16000) * 2 + 8192)
    with wave.open(str(derived), "rb") as stream:
        if (stream.getnchannels(), stream.getsampwidth(), stream.getframerate()) != (1, 2, 16000): raise ValueError("Invalid derived PCM layout")
        duration = stream.getnframes() / 16000
    derived_hash = sha(derived.read_bytes())
    if derived_hash in acquisition.exclusions.values["audio"]:
        acquisition.skip(["derived_audio"])
        acquisition.json(folder / "REJECTED.json", {"reason": "prior/selected derived audio hash", "source_retained": True})
        return None
    provenance = {**metadata, "original_audio_sha256": sha(audio), "reference_sha256": sha(reference_bytes),
        "derived_audio_sha256": derived_hash, "source_audio_modified": False, "conversion_command": command,
        "conversion_tool": subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0], "human_review": "not_performed"}
    acquisition.json(folder / "provenance.json", provenance)
    case = {"id": identifier, "category": "read-speech-fresh-slice", "language": language, "audio": str(derived), "reference": str(ref),
        "sha256": derived_hash, "reference_sha256": sha(reference_bytes), "original_audio_sha256": sha(audio),
        "task": "standard_rendering" if language == "de-CH" else "transcription", "split": metadata["evaluation_split"],
        "development_role": "validation" if metadata["evaluation_split"] == "development" else None,
        "duration_seconds": duration, "source_channel": 0, "variety": metadata["variety"], "script": metadata["script"],
        "speaker_ids": metadata.get("speaker_ids", []), "session_id": metadata.get("session_id"), "source_id": metadata["source_id"],
        "source_url": metadata["source_url"], "license": metadata["license"], "reference_conventions": metadata["reference_conventions"],
        "conditions": ["read_speech", "short_utterance"], "domain": "read-sentence", "code_switches": [], "reviewed": False,
        "scoring_policy": POLICY, "evaluation_tier": "fresh_public_slice_exploratory_not_v2_approved",
        "coverage_limitations": LIMITS, "provenance": str(folder / "provenance.json")}
    acquisition.cases.append(case)
    acquisition.exclusions.add(case)
    return case


def fleurs(acquisition, language, count, heldout):
    locale, variety, script = base.LOCALES[language]
    split, evaluation = ("test", "held_out") if heldout else ("dev", "development")
    url = base.FLEURS_BASE + f"data/{locale}/{split}.tsv"
    metadata = acquisition.fetch(url)
    acquisition.save(acquisition.root / evaluation / "sources/fleurs" / locale / (split + ".original.tsv"), metadata)
    rows = {}
    for line in metadata.decode("utf-8").splitlines():
        values = line.split("\t")
        if len(values) != 7: raise ValueError("Pinned FLEURS metadata layout changed")
        rows[values[1]] = values
    archive_url = base.FLEURS_BASE + f"data/{locale}/audio/{split}.tar.gz"
    selected = 0
    with acquisition.open(archive_url) as response, tarfile.open(fileobj=base.BoundedStream(acquisition, response), mode="r|gz") as archive:
        for member in archive:
            acquisition.check()
            if PurePosixPath(member.name).is_absolute() or ".." in PurePosixPath(member.name).parts: raise ValueError("Unsafe tar member path")
            filename = PurePosixPath(member.name).name
            if not member.isfile() or filename not in rows: continue
            if member.size > base.MAX_MEMBER_BYTES: raise ValueError("Source member exceeds 16 MiB")
            values = rows[filename]
            identifier = "fleurs-" + locale.replace("_", "-") + "-" + split + "-" + Path(filename).stem
            source = archive.extractfile(member).read(base.MAX_MEMBER_BYTES + 1)
            if len(source) != member.size: raise ValueError("Truncated source member")
            case = prepare(acquisition, source, values[2], identifier, language, {
                "dataset": "google/fleurs", "dataset_revision": base.FLEURS_REVISION, "dataset_split": split, "evaluation_split": evaluation,
                "source_id": "fleurs:" + locale + ":" + split + ":" + filename, "source_url": archive_url,
                "metadata_url": url, "metadata_sha256": sha(metadata), "archive_member": member.name,
                "published_utterance_id": values[0], "published_num_samples": int(values[5]), "speaker_ids": [],
                "variety": variety, "script": script, "license": "CC BY 4.0; Google FLEURS; retain pinned card and attribution",
                "reference_conventions": "Exact published raw_transcription field; human read-speech reference, unadjudicated"}, "wav")
            selected += case is not None
            if selected == count: break
    if selected < count: raise ValueError("Bounded FLEURS prefix did not fill requested fresh count")


def swiss(acquisition, count):
    source = base.RemoteZIP(acquisition, base.SWISS_ZIP)
    with zipfile.ZipFile(source) as archive:
        readme = base.read_zip_member(archive, "Clickworker_Test_Set/README.txt")
        if sha(readme) != SOURCE_HASHES["swiss_readme"]: raise ValueError("Swiss license/readme identity changed")
        acquisition.save(acquisition.root / "sources/swiss/README.original.txt", readme)
        metadata = {}
        for split in ("public", "private"):
            data = base.read_zip_member(archive, "Clickworker_Test_Set/" + split + ".tsv")
            if sha(data) != SOURCE_HASHES[split]: raise ValueError("Swiss release metadata identity changed")
            evaluation = "development" if split == "public" else "held_out"
            acquisition.save(acquisition.root / evaluation / "sources/swiss" / (split + ".original.tsv"), data)
            metadata[split] = ({row["path"]: row for row in csv.DictReader(io.StringIO(data.decode("utf-8-sig")), delimiter="\t")}, sha(data))
        entry = archive.getinfo("Clickworker_Test_Set/clips.tar")
        if entry.compress_type != zipfile.ZIP_STORED: raise ValueError("Swiss tar is no longer stored")
        source.seek(entry.header_offset)
        header = source.read(30)
        if header[:4] != b"PK\x03\x04": raise ValueError("Invalid Swiss ZIP local header")
        name_size, extra_size = struct.unpack_from("<HH", header, 26)
        offset = entry.header_offset + 30 + name_size + extra_size
        length = min(32 * 1024 * 1024, entry.file_size)
        chunks = []
        for position in range(0, length, 8 * 1024 * 1024):
            source.seek(offset + position)
            chunks.append(source.read(min(8 * 1024 * 1024, length - position)))
        prefix = b"".join(chunks)
        acquisition.save(acquisition.root / "sources/swiss/clips-prefix.original.tar.part", prefix)
        # Select development first so every newly known speaker is excluded from heldout.
        for split in ("public", "private"):
            rows, metadata_hash = metadata[split]
            evaluation = "development" if split == "public" else "held_out"
            selected = 0
            with tarfile.open(fileobj=io.BytesIO(prefix), mode="r|") as clips:
                for member in clips:
                    acquisition.check()
                    if PurePosixPath(member.name).is_absolute() or ".." in PurePosixPath(member.name).parts: raise ValueError("Unsafe Swiss tar member")
                    filename = PurePosixPath(member.name).name
                    if not member.isfile() or filename not in rows: continue
                    row = rows[filename]
                    if not row["client_id"]: acquisition.skip(["unknown_swiss_speaker"]); continue
                    speaker = "all-swiss-dialects:v1:client-" + row["client_id"]
                    if speaker in acquisition.exclusions.values["speaker"]: acquisition.skip(["speaker"]); continue
                    if member.size > base.MAX_MEMBER_BYTES: raise ValueError("Oversized Swiss member")
                    audio = clips.extractfile(member).read(base.MAX_MEMBER_BYTES + 1)
                    if len(audio) != member.size: raise ValueError("Truncated Swiss member")
                    identifier = "all-swiss-dialects-v1-" + ("private-" if split == "private" else "") + Path(filename).stem
                    case = prepare(acquisition, audio, row["sentence"], identifier, "de-CH", {
                        "dataset": "FHNW All Swiss German Dialects Test Set", "dataset_version": "v1; 2021-03-10",
                        "dataset_split": split, "evaluation_split": evaluation, "source_id": "all-swiss-dialects:v1:" + filename,
                        "source_url": base.SWISS_PAGE, "archive_url": base.SWISS_ZIP, "archive_etag": SWISS_ETAG,
                        "archive_bytes": SWISS_BYTES, "archive_member": member.name, "metadata_sha256": metadata_hash,
                        "archive_prefix_sha256": sha(prefix), "archive_prefix_byte_range": [offset, offset + length - 1],
                        "speaker_ids": [speaker], "variety": "Swiss German; published speaker dialect canton " + row["accent"],
                        "script": "Latn", "license": "MIT; FHNW Institute for Data Science; retain release README/source page",
                        "reference_conventions": "Exact published " + split + ".tsv sentence: written Standard German for Swiss German speech; unadjudicated"}, "flac")
                    selected += case is not None
                    if selected == count: break
            if selected < count: raise ValueError("32 MiB Swiss prefix did not fill fresh distinct-speaker count")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--exclude-manifest", type=Path, action="append", required=True)
    parser.add_argument("--count", type=int, default=8, choices=range(4, 9))
    parser.add_argument("--timeout-seconds", type=int, default=1200, choices=range(1, 1801))
    args = parser.parse_args()
    root = safe(args.output)
    if Path(__file__).resolve().parents[2] in root.parents: parser.error("Original corpus must be outside checkout")
    exclusions = Exclusions()
    for path in args.exclude_manifest: exclusions.load(path)
    prior = {key: sorted(value) for key, value in exclusions.values.items()}
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    acquisition = Acquisition(root, exclusions, args.timeout_seconds)
    def interrupt(_signal, _frame): raise InterruptedError("Acquisition interrupted; partial sources retained")
    signal.signal(signal.SIGINT, interrupt); signal.signal(signal.SIGTERM, interrupt)
    errors = []
    try:
        acquisition.json(root / "selection-plan.original.json", {"count_per_language_per_split": args.count,
            "development_source_splits": ["FLEURS dev", "FHNW public"], "heldout_source_splits": ["FLEURS test", "FHNW private"],
            "selection": "First eligible archive members; prior/new IDs, audio, reference hashes and known speakers/sessions excluded",
            "exclusion_manifests": exclusions.manifests, "prior_exclusions": prior, "network_cap_bytes": base.MAX_NETWORK_BYTES,
            "archive_stream_cap_bytes": 32 * 1024 * 1024, "swiss_prefix_cap_bytes": 32 * 1024 * 1024,
            "timeout_seconds": args.timeout_seconds, "heldout_reference_display": False, "human_review": "not_performed"})
        for source_script in (Path(__file__), Path(__file__).with_name("acquire-pilot.py")):
            acquisition.save(root / "recipe" / source_script.name, source_script.read_bytes())
        card = acquisition.fetch(base.FLEURS_BASE + "README.md")
        if sha(card) != SOURCE_HASHES["card"]: raise ValueError("Pinned FLEURS card identity changed")
        acquisition.save(root / "sources/fleurs/README.original.md", card)
        acquisition.save(root / "sources/swiss/source-page.original.html", acquisition.fetch(base.SWISS_PAGE))
        for heldout in (False, True):
            for language in base.LOCALES:
                try: fleurs(acquisition, language, args.count, heldout)
                except (ValueError, OSError, tarfile.TarError) as error:
                    errors.append({"language": language, "split": "held_out" if heldout else "development", "error_type": type(error).__name__, "error": str(error)})
                print(json.dumps({"language": language, "split": "held_out" if heldout else "development",
                    "selected": sum(c["language"] == language and c["split"] == ("held_out" if heldout else "development") for c in acquisition.cases),
                    "network_bytes": acquisition.network_bytes}), flush=True)
        swiss(acquisition, args.count)
    except BaseException as error:
        errors.append({"error_type": type(error).__name__, "error": str(error)})
    finally:
        manifests = []
        for split in ("development", "held_out"):
            cases = [case for case in acquisition.cases if case["split"] == split]
            document = {"schema_version": "1.0", "corpus_version": "round2-corpus-20261106-v1-" + ("dev-validation" if split == "development" else "fresh-heldout"),
                "frozen": False, "evaluation_tier": "fresh_public_slice_exploratory_not_v2_approved", "split": split,
                "cases": cases, "scoring_version": "legacy-v1", "limitations": LIMITS, "errors": errors,
                "reference_displayed_to_ai": False, "human_review": "not_performed"}
            path = root / split / "manifest.exploratory.legacy.json"
            acquisition.json(path, document, final=True)
            pending = copy.deepcopy(document); pending["schema_version"] = "2.0"
            acquisition.json(root / split / "manifest.v2.pending.json", pending, final=True)
            manifests.append({"split": split, "path": str(path), "sha256": sha(path.read_bytes()), "cases": len(cases),
                "counts": {language: sum(c["language"] == language for c in cases) for language in [*base.LOCALES, "de-CH"]}})
        acquisition.save(root / "held_out/NOT-FOR-DEVELOPMENT.txt", b"Fresh exploratory heldout: do not inspect reference text or outcomes before candidate/settings/budgets freeze. No human/native approval has occurred.\n", final=True)
        acquisition.json(root / "acquisition.json", {"created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "network_bytes": acquisition.network_bytes, "reserved_output_bytes": acquisition.output_bytes,
            "requests": acquisition.requests, "excluded_counts": {key: len(value) for key, value in prior.items()},
            "skip_counts": acquisition.skipped, "manifests": manifests, "errors": errors,
            "recognition_performed": False, "reference_text_displayed": False, "human_review_performed": False}, final=True)
        print(json.dumps({"output": str(root), "manifests": manifests, "errors": len(errors), "network_bytes": acquisition.network_bytes}), flush=True)
    if errors or any(m["cases"] != args.count * 9 for m in manifests): raise SystemExit(1)


if __name__ == "__main__":
    main()
