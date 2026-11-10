#!/usr/bin/env python3
"""Acquire a bounded public evaluation pilot; never performs recognition.

Original source bytes and source references are retained in a new external folder.
The legacy manifest is explicitly exploratory; missing speaker/session evidence
does not become approved v2 corpus coverage. No model or private audio is uploaded.
"""
import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import subprocess
import tarfile
import time
import urllib.request
import wave
import zipfile

FLEURS_REVISION = "b4a42ed06e12025c42f3b4eff6338ace2fe2447a"
FLEURS_BASE = f"https://huggingface.co/datasets/google/fleurs/resolve/{FLEURS_REVISION}/"
SWISS_PAGE = "https://www.cs.technik.fhnw.ch/i4ds-datasets"
SWISS_ZIP = "https://www.dropbox.com/scl/fi/nn6qoovxprt8oc7tso5hg/clickworker_collection_1.zip?rlkey=at3sd27ckcg45x6smok3rwcid&dl=1"
LOCALES = {
    "de": ("de_de", "German; Germany locale", "Latn"),
    "fr": ("fr_fr", "French; France locale", "Latn"),
    "it": ("it_it", "Italian; Italy locale", "Latn"),
    "en": ("en_us", "English; United States locale", "Latn"),
    "ar": ("ar_eg", "Arabic; Egypt locale (audible dialect not independently adjudicated)", "Arab"),
    "zh": ("cmn_hans_cn", "Mandarin; Simplified Chinese; China locale", "Hans"),
    "es": ("es_419", "Spanish; Latin America locale", "Latn"),
    "pt": ("pt_br", "Portuguese; Brazil locale", "Latn"),
}
MAX_NETWORK_BYTES = 256 * 1024 * 1024
MAX_MEMBER_BYTES = 16 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(data)


def save_json(path, value):
    save(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode())


def read_zip_member(archive, name, maximum=4 * 1024 * 1024):
    entry = archive.getinfo(name)
    if entry.file_size > maximum:
        raise ValueError("Source ZIP metadata exceeds its bounded size")
    with archive.open(entry) as stream:
        data = stream.read(maximum + 1)
    if len(data) != entry.file_size or len(data) > maximum:
        raise ValueError("Incomplete or oversized source ZIP metadata")
    return data


class Acquisition:
    def __init__(self, root):
        self.root = root
        self.network_bytes = 0
        self.cancel = root / "cancel.request"
        self.requests = []

    def check(self):
        if self.cancel.exists():
            raise InterruptedError("Acquisition canceled; retained partial source evidence")
        if self.network_bytes > MAX_NETWORK_BYTES:
            raise ValueError("Acquisition exceeded 256 MiB network budget")

    def open(self, url, headers=None, method="GET"):
        self.check()
        response = urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}, method=method), timeout=30)
        self.requests.append({"url": url, "resolved_url": response.geturl(), "status": response.status,
                              "etag": response.headers.get("ETag"), "content_length": response.headers.get("Content-Length"),
                              "content_range": response.headers.get("Content-Range")})
        return response

    def read(self, response, size):
        self.check()
        data = response.read(size)
        self.network_bytes += len(data)
        self.check()
        return data

    def fetch(self, url, maximum=4 * 1024 * 1024):
        with self.open(url) as response:
            data = self.read(response, maximum + 1)
        if len(data) > maximum:
            raise ValueError("Source metadata exceeded its bounded size")
        return data


class BoundedStream:
    def __init__(self, acquisition, response, maximum=32 * 1024 * 1024):
        self.acquisition, self.response, self.maximum, self.count = acquisition, response, maximum, 0

    def read(self, size=-1):
        if size < 0:
            size = min(65536, self.maximum - self.count + 1)
        result = self.acquisition.read(self.response, size)
        self.count += len(result)
        if self.count > self.maximum:
            raise ValueError(f"Source stream exceeded {self.maximum // (1024 * 1024)} MiB selection budget")
        return result


class RemoteZIP(io.RawIOBase):
    """Only byte-range reads; refuses servers which silently return full archives."""
    def __init__(self, acquisition, url):
        self.acquisition, self.url, self.position = acquisition, url, 0
        with acquisition.open(url, method="HEAD") as response:
            self.length = int(response.headers["Content-Length"])

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        position = offset if whence == 0 else (self.position if whence == 1 else self.length) + offset
        if position < 0:
            raise ValueError("Negative archive seek")
        self.position = position
        return position

    def read(self, size=-1):
        size = self.length - self.position if size < 0 else min(size, self.length - self.position)
        if size <= 0:
            return b""
        if size > MAX_MEMBER_BYTES:
            raise ValueError("Remote archive read exceeds 16 MiB")
        end = self.position + size - 1
        with self.acquisition.open(self.url, {"Range": f"bytes={self.position}-{end}"}) as response:
            if response.status != 206:
                raise ValueError("Source server did not honor archive byte range")
            expected = f"bytes {self.position}-{end}/{self.length}"
            if response.headers.get("Content-Range") != expected:
                raise ValueError("Source archive byte range differs from request")
            data = self.acquisition.read(response, size + 1)
        if len(data) != size:
            raise ValueError("Incomplete source archive range")
        self.position += len(data)
        return data


def prepare_case(acquisition, source_bytes, reference, identifier, language, metadata, source_extension="wav"):
    evaluation_split = metadata.get("evaluation_split", "development")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", identifier) or evaluation_split not in {"development", "held_out"}:
        raise ValueError("Unsafe corpus case identity or evaluation split")
    if source_extension not in {"wav", "flac"} or len(source_bytes) > MAX_MEMBER_BYTES or len(reference.encode()) > 1024 * 1024:
        raise ValueError("Unsupported or oversized corpus source/reference")
    folder = acquisition.root / evaluation_split / identifier
    original = folder / ("source.original." + source_extension)
    audio = folder / "benchmark.pcm16.wav"
    reference_path = folder / "reference.original.txt"
    save(original, source_bytes)
    save(reference_path, reference.encode("utf-8"))
    # Explicit derived preparation only. The exact original bytes remain retained.
    command = ["ffmpeg", "-nostdin", "-v", "error", "-n", "-i", str(original), "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(audio)]
    subprocess.run(command, check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    with wave.open(str(audio), "rb") as stream:
        frames, rate = stream.getnframes(), stream.getframerate()
        if stream.getnchannels() != 1 or stream.getsampwidth() != 2:
            raise ValueError("Derived benchmark audio is not mono PCM16")
    save_json(folder / "provenance.json", {**metadata, "original_audio_sha256": digest(source_bytes),
              "reference_sha256": digest(reference.encode()), "derived_audio_sha256": digest(audio.read_bytes()),
              "source_audio_modified": False, "conversion_command": command,
              "conversion_tool": subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0]})
    return {"id": identifier, "category": "read-speech-pilot", "language": language,
            "audio": str(audio), "reference": str(reference_path), "sha256": digest(audio.read_bytes()),
            "reference_sha256": digest(reference.encode()), "license": metadata["license"],
            "task": "standard_rendering" if language == "de-CH" else "transcription",
            "split": evaluation_split, "duration_seconds": frames / rate,
            "source_channel": 0, "variety": metadata["variety"], "script": metadata["script"],
            "speaker_ids": metadata.get("speaker_ids", []), "session_id": metadata.get("session_id"),
            "source_id": metadata["source_id"], "source_url": metadata["source_url"],
            "original_audio_sha256": digest(source_bytes), "conditions": ["read_speech", "short_utterance"],
            "code_switches": [], "reviewed": False, "evaluation_tier": "exploratory_published_references",
            "reference_conventions": metadata["reference_conventions"],
            "scoring_policy": "unicode-nfc-cer-v2" if language == "zh" else ("arabic-nfc-strict-v2" if language == "ar" else "unicode-nfc-apostrophe-v2"),
            "coverage_limitations": metadata["limitations"], "provenance": str(folder / "provenance.json")}


def acquire_fleurs(acquisition, language, count, held_out=False):
    locale, variety, script = LOCALES[language]
    dataset_split = "test" if held_out else "train"
    metadata_url = FLEURS_BASE + f"data/{locale}/{dataset_split}.tsv"
    archive_url = FLEURS_BASE + f"data/{locale}/audio/{dataset_split}.tar.gz"
    metadata_bytes = acquisition.fetch(metadata_url)
    metadata_root = acquisition.root / "held_out" if held_out else acquisition.root
    save(metadata_root / "sources" / "fleurs" / locale / (dataset_split + ".original.tsv"), metadata_bytes)
    rows = {}
    for line in metadata_bytes.decode("utf-8").splitlines():
        values = line.split("\t")
        if len(values) != 7:
            raise ValueError("Unexpected pinned FLEURS metadata schema")
        rows[values[1]] = values
    cases = []
    with acquisition.open(archive_url) as response:
        stream = BoundedStream(acquisition, response)
        with tarfile.open(fileobj=stream, mode="r|gz") as archive:
            for member in archive:
                acquisition.check()
                basename = Path(member.name).name
                if not member.isfile() or basename not in rows:
                    continue
                if member.size > MAX_MEMBER_BYTES:
                    raise ValueError("Source utterance exceeds 16 MiB")
                values = rows[basename]
                original = archive.extractfile(member).read(MAX_MEMBER_BYTES + 1)
                if len(original) != member.size:
                    raise ValueError("Incomplete source utterance")
                identifier = "fleurs-" + locale.replace("_", "-") + ("-test-" if held_out else "-") + Path(basename).stem
                cases.append(prepare_case(acquisition, original, values[2], identifier, language, {
                    "dataset": "google/fleurs", "dataset_revision": FLEURS_REVISION, "dataset_split": dataset_split,
                    "evaluation_split": "held_out" if held_out else "development",
                    "metadata_url": metadata_url, "metadata_sha256": digest(metadata_bytes), "archive_url": archive_url,
                    "archive_member": member.name, "source_url": archive_url, "source_id": "fleurs:" + locale + ":" + dataset_split + ":" + basename,
                    "published_utterance_id": values[0], "published_num_samples": int(values[5]),
                    "speaker_ids": [], "session_id": None, "variety": variety, "script": script,
                    "license": "CC BY 4.0; Google FLEURS; retain pinned dataset card and attribution",
                    "reference_conventions": "Exact published raw_transcription TSV field; human read-speech reference; no new ASR or normalization",
                    "limitations": ["Three-utterance exploratory pilot; not representative language accuracy", "Individual speaker/session IDs unavailable in release metadata", "Train speakers are documented disjoint from dev/test; no dev/test speaker independence inference", "Read speech and public-pretraining contamination limitations", "No native-language reference/audio adjudication performed"]
                }))
                if len(cases) >= count:
                    break
    if len(cases) != count:
        raise ValueError("Not enough matching source utterances")
    return cases


def acquire_swiss(acquisition, count, excluded_speakers=None, held_out=False):
    """Read a bounded stored-tar prefix; holdout labels stay out of tool output."""
    source = RemoteZIP(acquisition, SWISS_ZIP)
    with zipfile.ZipFile(source) as archive:
        readme = read_zip_member(archive, "Clickworker_Test_Set/README.txt")
        dataset_split = "private" if held_out else "public"
        metadata_bytes = read_zip_member(archive, "Clickworker_Test_Set/" + dataset_split + ".tsv")
        metadata_root = acquisition.root / "held_out" if held_out else acquisition.root
        for filename, data in [("README.txt", readme), (dataset_split + ".tsv", metadata_bytes)]:
            destination = metadata_root / "sources" / "swiss" / filename
            if destination.exists():
                if destination.read_bytes() != data:
                    raise ValueError("Previously retained Swiss source metadata differs")
            else:
                save(destination, data)
        rows = {row["path"]: row for row in csv.DictReader(io.StringIO(metadata_bytes.decode("utf-8-sig")), delimiter="\t")}
        entry = archive.getinfo("Clickworker_Test_Set/clips.tar")
        if entry.compress_type != zipfile.ZIP_STORED:
            raise ValueError("Swiss clips member requires unsupported full decompression")
        source.seek(entry.header_offset)
        header = source.read(30)
        if header[:4] != b"PK\x03\x04":
            raise ValueError("Invalid local ZIP member header")
        name_bytes, extra_bytes = struct.unpack_from("<HH", header, 26)
        member_start = entry.header_offset + 30 + name_bytes + extra_bytes
        prefix_bytes = min(8 * 1024 * 1024, entry.file_size)
        prefix_path = acquisition.root / "sources" / "swiss" / "clips-prefix.original.tar.part"
        if held_out and prefix_path.exists():
            prefix = prefix_path.read_bytes()
        else:
            source.seek(member_start)
            prefix = source.read(prefix_bytes)
            save(prefix_path, prefix)
        cases, speakers = [], set()
        with tarfile.open(fileobj=io.BytesIO(prefix), mode="r|") as clips:
            for clip in clips:
                acquisition.check()
                basename = Path(clip.name).name
                if not clip.isfile() or basename not in rows:
                    continue
                row = rows[basename]
                speaker_id = "all-swiss-dialects:v1:client-" + row["client_id"]
                if not row["client_id"] or row["client_id"] in speakers or speaker_id in (excluded_speakers or set()):
                    continue
                if clip.size > MAX_MEMBER_BYTES:
                    raise ValueError("Swiss utterance exceeds its bounded size")
                speakers.add(row["client_id"])
                original = clips.extractfile(clip).read(MAX_MEMBER_BYTES + 1)
                if len(original) != clip.size:
                    raise ValueError("Incomplete Swiss source utterance")
                identifier = "all-swiss-dialects-v1-" + ("private-" if held_out else "") + Path(basename).stem
                cases.append(prepare_case(acquisition, original, row["sentence"], identifier, "de-CH", {
                    "dataset": "FHNW All Swiss German Dialects Test Set", "dataset_version": "v1; 2021-03-10", "dataset_split": dataset_split,
                    "evaluation_split": "held_out" if held_out else "development",
                    "source_url": SWISS_PAGE, "archive_url": SWISS_ZIP, "outer_member": entry.filename, "archive_member": clip.name,
                    "metadata_sha256": digest(metadata_bytes), "archive_prefix_sha256": digest(prefix),
                    "archive_prefix_byte_range": [member_start, member_start + prefix_bytes - 1],
                    "source_id": "all-swiss-dialects:v1:" + basename,
                    "speaker_ids": [speaker_id], "session_id": None,
                    "variety": "Swiss German; published speaker dialect canton " + row["accent"], "script": "Latn",
                    "license": "MIT; FHNW Institute for Data Science; retain source page and archive README",
                    "reference_conventions": "Exact published " + dataset_split + ".tsv sentence: Standard German text spoken in Swiss German; no generated dialect text or new ASR",
                    "limitations": ["Three-utterance exploratory pilot; not representative dialect coverage", "Published speaker IDs retained; session IDs unavailable", "Read speech, uneven regional coverage and possible public-pretraining contamination", "No independent native-language audio/reference adjudication performed"]
                }, source_extension="flac"))
                if len(cases) >= count:
                    break
    if len(cases) != count:
        raise ValueError("Bounded Swiss tar prefix lacks enough distinct public speakers")
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--languages", default=",".join(LOCALES))
    parser.add_argument("--count", type=int, default=3, choices=range(1, 6))
    parser.add_argument("--inspect-swiss", action="store_true")
    parser.add_argument("--append-swiss", action="store_true", help="Add Swiss development files to a previous pilot without overwriting retained manifests")
    parser.add_argument("--seal-holdout", action="store_true", help="Acquire separate test/private originals and references without displaying their text")
    args = parser.parse_args()
    root = args.output.expanduser().resolve()
    repo = Path(__file__).resolve().parents[2]
    if root == repo or repo in root.parents:
        parser.error("Corpus originals/results must be outside the checkout")
    if args.append_swiss and args.seal_holdout:
        parser.error("Choose append-swiss or seal-holdout separately")
    if not args.append_swiss and not args.seal_holdout:
        root.mkdir(parents=True, exist_ok=False, mode=0o700)
    elif not (root / "development.exploratory.legacy.json").is_file():
        parser.error("Appending Swiss files requires an existing retained pilot")
    acquisition = Acquisition(root)
    if args.seal_holdout:
        development = json.loads((root / "development.with-swiss.exploratory.legacy.json").read_text())
        excluded = {speaker for case in development["cases"] for speaker in case.get("speaker_ids", [])}
        cases, errors = [], []
        for language in args.languages.split(","):
            try:
                selected = acquire_fleurs(acquisition, language, args.count, held_out=True)
                cases.extend(selected)
                print(json.dumps({"language": language, "sealed_holdout_files": len(selected)}), flush=True)
            except Exception as error:
                errors.append({"language": language, "error": str(error)})
        cases.extend(acquire_swiss(acquisition, args.count, excluded_speakers=excluded, held_out=True))
        save_json(root / "held_out" / "manifest.exploratory.legacy.json", {"schema_version": "1.0", "corpus_version": "public-pilot-20261105-v1-heldout",
                  "frozen": False, "evaluation_tier": "exploratory_published_references_not_v2_approved", "cases": cases, "errors": errors})
        save(root / "held_out" / "NOT-FOR-DEVELOPMENT.txt", b"Do not inspect references or evaluation outcomes while adapting candidates. Freeze candidate artifacts, settings and budgets before held-out evaluation. These are public-source exploratory heldouts, not fresh comprehensive validation.\n")
        save_json(root / "held_out" / "acquisition.json", {"script_sha256": digest(Path(__file__).read_bytes()), "network_bytes": acquisition.network_bytes,
                  "requests": acquisition.requests, "case_count": len(cases), "errors": errors, "recognition_performed": False,
                  "heldout_text_displayed_to_ai": False, "swiss_development_speakers_excluded": sorted(excluded)})
        print(json.dumps({"sealed_holdout_files": len(cases), "errors": len(errors), "network_bytes": acquisition.network_bytes}), flush=True)
        if errors:
            raise SystemExit(1)
        return
    if args.append_swiss:
        original = json.loads((root / "development.exploratory.legacy.json").read_text())
        swiss = acquire_swiss(acquisition, args.count)
        original["cases"] += swiss
        original["corpus_version"] = "public-pilot-20261105-v1-with-swiss"
        save_json(root / "development.with-swiss.exploratory.legacy.json", original)
        save_json(root / "acquisition.swiss.json", {"script_sha256": digest(Path(__file__).read_bytes()), "network_bytes": acquisition.network_bytes,
                  "requests": acquisition.requests, "case_count": len(swiss), "recognition_performed": False})
        print(json.dumps({"swiss_cases": len(swiss), "total_cases": len(original["cases"]), "output": str(root)}), flush=True)
        return
    cases, errors = [], []
    try:
        card = acquisition.fetch(FLEURS_BASE + "README.md")
        save(root / "sources" / "fleurs" / "README.original.md", card)
        script = acquisition.fetch(FLEURS_BASE + "fleurs.py")
        save(root / "sources" / "fleurs" / "fleurs.original.py", script)
        for language in args.languages.split(","):
            if language not in LOCALES:
                raise ValueError("Unsupported source locale: " + language)
            try:
                selected = acquire_fleurs(acquisition, language, args.count)
                cases.extend(selected)
                print(json.dumps({"language": language, "acquired": len(selected), "network_bytes": acquisition.network_bytes}), flush=True)
            except Exception as error:
                errors.append({"language": language, "error": str(error)})
                print(json.dumps(errors[-1]), flush=True)
        if args.inspect_swiss:
            save(root / "sources" / "swiss" / "source-page.original.html", acquisition.fetch(SWISS_PAGE))
            with zipfile.ZipFile(RemoteZIP(acquisition, SWISS_ZIP)) as archive:
                selected = [{"name": entry.filename, "bytes": entry.file_size, "compressed_bytes": entry.compress_size}
                            for entry in archive.infolist() if entry.filename.lower().endswith((".tsv", ".csv", ".txt", ".json", ".md"))]
                save_json(root / "sources" / "swiss" / "archive-inventory.json", selected)
                print(json.dumps({"swiss_metadata_files": selected[:30], "archive_members": len(archive.infolist())}), flush=True)
    finally:
        save_json(root / "development.exploratory.legacy.json", {"schema_version": "1.0", "corpus_version": "public-pilot-20261105-v1", "frozen": False,
                  "evaluation_tier": "exploratory_published_references_not_v2_approved", "cases": cases,
                  "limitations": ["No held-out evaluation performed", "Incomplete speaker/session/condition/long-form coverage; not an approved v2 corpus"], "errors": errors})
        save_json(root / "acquisition.json", {"schema_version": "1.0", "script_sha256": digest(Path(__file__).read_bytes()),
                  "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "network_bytes": acquisition.network_bytes,
                  "requests": acquisition.requests, "case_count": len(cases), "errors": errors, "recognition_performed": False})
    print(json.dumps({"output": str(root), "cases": len(cases), "errors": len(errors), "network_bytes": acquisition.network_bytes}), flush=True)
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
