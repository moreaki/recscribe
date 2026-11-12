#!/usr/bin/env python3
"""Prepare retained meeting/ZIP originals; never run ASR or approve references."""
import argparse
import csv
from decimal import Decimal, InvalidOperation
import hashlib
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import re
import signal
import stat
import time
from urllib.parse import urlparse
import wave
import zipfile

_SPEC = importlib.util.spec_from_file_location("realworld_sources", Path(__file__).with_name("acquire-realworld.py"))
rw = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(rw)

MAX_ANNOTATION = 4 * 1024 ** 2
MAX_MEMBER = 32 * 1024 ** 2
MAX_INTERVALS = 10000
MAX_ROWS = 100000
MAX_METADATA = 8 * 1024 ** 2


def sha(path, check=lambda: None):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            check()
            data = stream.read(1024 ** 2)
            if not data:
                break
            digest.update(data)
    check()
    return digest.hexdigest()


def read_bound(path, maximum, check=lambda: None):
    chunks, total = [], 0
    with path.open("rb") as stream:
        while True:
            check()
            data = stream.read(min(65536, maximum + 1 - total))
            if not data:
                return b"".join(chunks)
            chunks.append(data); total += len(data)
            if total > maximum:
                raise rw.Failure("local_input_size_bound")


def quoted(value):
    match = re.fullmatch(r'"((?:[^"]|"")*)"\s*', value)
    if not match:
        raise rw.Failure("unsupported_annotation_quoting")
    return match[1].replace('""', '"')


def logical_lines(lines, check):
    """Praat quoted strings may contain literal newlines; preserve their bytes."""
    index = 0
    while index < len(lines):
        check()
        first, raw = index, lines[index]
        index += 1
        if not raw.lstrip().startswith("text = "):
            yield first, raw
            continue
        prefix, fragment = raw.split("=", 1)
        fragment = fragment.lstrip()
        if not fragment.startswith('"'):
            raise rw.Failure("unsupported_annotation_quoting")
        pieces, size, position = [], 0, 1
        while True:
            check()
            pieces.append(fragment)
            size += len(fragment.encode("utf-8")) + 1
            if size > rw.MAX_REFERENCE + 16:
                raise rw.Failure("reference_size_bound")
            closed = False
            while position < len(fragment):
                if fragment[position] != '"':
                    position += 1
                elif position + 1 < len(fragment) and fragment[position + 1] == '"':
                    position += 2
                else:
                    if fragment[position + 1:].strip():
                        raise rw.Failure("unsupported_annotation_quoting")
                    closed = True
                    break
            if closed:
                yield first, prefix + "= " + "\n".join(pieces)
                break
            if index >= len(lines):
                raise rw.Failure("unterminated_annotation_string")
            fragment, position = lines[index], 0
            index += 1


def textgrid(data, check=lambda: None):
    """Parse the bounded long TextGrid form; uncertain formats fail explicitly."""
    if len(data) > MAX_ANNOTATION:
        raise rw.Failure("annotation_size")
    lines = data.decode("utf-8-sig").splitlines()
    if not any('Object class = "TextGrid"' in line for line in lines[:5]):
        raise rw.Failure("annotation_type")
    check()
    speaker, interval, records, tier_class, last_end = None, None, [], None, None
    tier_names, tier_numbers = set(), set()

    def finish():
        nonlocal interval, last_end
        if interval is None:
            return
        if speaker is None or tier_class != "IntervalTier" or set(interval) != {"xmin", "xmax", "text"}:
            raise rw.Failure("annotation_interval_fields")
        start, end = interval["xmin"], interval["xmax"]
        if not start.is_finite() or not end.is_finite() or not Decimal(0) <= start < end:
            raise rw.Failure("annotation_time_bounds")
        if last_end is not None and start < last_end:
            raise rw.Failure("same_tier_interval_overlap")
        if len(interval["text"].encode("utf-8")) > rw.MAX_REFERENCE:
            raise rw.Failure("reference_size_bound")
        records.append(dict(speaker=speaker, start=start, end=end, text=interval["text"]))
        last_end = end
        interval = None
        if len(records) > MAX_INTERVALS:
            raise rw.Failure("annotation_interval_count")

    for index, raw in logical_lines(lines, check):
        if index % 128 == 0:
            check()
        line = raw.strip()
        tier = re.fullmatch(r"item \[(\d+)\]:", line)
        if tier:
            finish(); speaker, tier_class, last_end = None, None, None
            if tier[1] in tier_numbers or len(tier_numbers) >= 64:
                raise rw.Failure("ambiguous_or_excessive_annotation_tiers")
            tier_numbers.add(tier[1])
        elif line.startswith("class = "):
            if tier_class is not None:
                raise rw.Failure("duplicate_annotation_tier_class")
            tier_class = quoted(line.split("=", 1)[1].strip())
            if tier_class != "IntervalTier":
                raise rw.Failure("unsupported_annotation_tier_class")
        elif line.startswith("name = "):
            if speaker is not None:
                raise rw.Failure("duplicate_annotation_tier_name")
            speaker = quoted(line.split("=", 1)[1].strip())
            if not rw.safe_text(speaker, 160) or speaker in tier_names:
                raise rw.Failure("local_speaker_label")
            tier_names.add(speaker)
        elif re.fullmatch(r"intervals \[\d+\]:", line):
            finish(); interval = {}
        elif interval is not None and "=" in line:
            key, value = (part.strip() for part in line.split("=", 1))
            if key in interval or key not in {"xmin", "xmax", "text"}:
                raise rw.Failure("annotation_interval_fields")
            try:
                interval[key] = quoted(value) if key == "text" else Decimal(value)
            except InvalidOperation as error:
                raise rw.Failure("annotation_time_number") from error
    finish()
    check()
    if not records:
        raise rw.Failure("empty_annotation")
    return records


def choose_interval(records, check=lambda: None):
    """First eligible non-overlap interval, using a bounded O(n log n) sweep."""
    if not isinstance(records, list) or not 1 <= len(records) <= MAX_INTERVALS:
        raise rw.Failure("annotation_interval_count")
    speech = []
    for record in records:
        check()
        if any(c.isalnum() for c in record["text"]):
            speech.append(record)
    speech.sort(key=lambda r: (r["start"], r["end"], r["speaker"]))
    check()
    previous_end = Decimal(-1)
    for index, item in enumerate(speech):
        check()
        overlaps = previous_end > item["start"] or index + 1 < len(speech) and speech[index + 1]["start"] < item["end"]
        previous_end = max(previous_end, item["end"])
        if not Decimal(4) <= item["end"] - item["start"] <= Decimal(20):
            continue
        if overlaps:
            continue
        return item
    raise rw.Failure("no_predeclared_single_speaker_interval")


def corpus(acquisition, case, source, original, reference, start, end, channel, original_hash, annotation_snapshot=None):
    acquisition.check()
    if reference is not None and (not isinstance(reference, bytes) or not 1 <= len(reference) <= rw.MAX_REFERENCE):
        raise rw.Failure("reference_size_bound")
    reasons = rw.rejection(acquisition, case, original_hash, rw.digest(reference) if reference is not None else None)
    if reasons:
        raise rw.Failure("prior_source_or_group_overlap")
    with original.open("rb") as stream:
        header = stream.read(42)
    if original.suffix == ".flac":
        frames, rate, channels = rw.fresh.source_layout(header, "flac")
    elif original.suffix == ".wav":
        with wave.open(str(original), "rb") as stream:
            frames, rate, channels = stream.getnframes(), stream.getframerate(), stream.getnchannels()
    else:
        raise rw.Failure("original_audio_type")
    if type(channel) is not int or not 0 <= channel < channels or not 1 <= rate <= 384000:
        raise rw.Failure("selected_original_channel")
    if start is None:
        start, end = Decimal(0), min(Decimal(frames) / rate, Decimal(20))
    if not Decimal(0) <= start < end <= Decimal(frames) / rate or end - start > 60:
        raise rw.Failure("original_interval_bounds")
    folder = acquisition.root / case["split"] / case["id"]
    folder.mkdir(parents=True, exist_ok=False)
    case = dict(case)
    if annotation_snapshot is not None:
        annotation_path, annotation_bytes = annotation_snapshot
        if len(annotation_bytes) > MAX_ANNOTATION or rw.digest(annotation_bytes) != case["original_annotation_sha256"]:
            raise rw.Failure("annotation_snapshot_identity")
        retained = folder / "annotation.original.TextGrid"
        acquisition.save(retained, annotation_bytes)
        case.update(original_annotation=str(retained), source_annotation=str(annotation_path))
    prepared = folder / "benchmark.pcm16.wav"
    seconds = end - start
    maximum = int(seconds * 16000 + 1) * 2 + 8192
    acquisition.reserve(maximum)
    command = ["ffmpeg", "-nostdin", "-v", "error", "-n", "-threads", "1", "-ss", str(start),
               "-i", str(original), "-t", str(seconds), "-map", "0:a:0", "-af", "pan=mono|c0=c" + str(channel),
               "-ar", "16000", "-c:a", "pcm_s16le", str(prepared)]
    rw.run_bounded(acquisition, command, 45, target=prepared, maximum_bytes=maximum)
    with wave.open(str(prepared), "rb") as stream:
        if (stream.getnchannels(), stream.getsampwidth(), stream.getframerate()) != (1, 2, 16000):
            raise rw.Failure("prepared_PCM_layout")
        measured = stream.getnframes() / 16000
    if abs(measured - float(seconds)) > .001:
        raise rw.Failure("prepared_frame_duration")
    prepared_hash = sha(prepared, acquisition.check)
    if sha(original, acquisition.check) != original_hash:
        raise rw.Failure("original_audio_changed_during_preparation")
    if prepared_hash in acquisition.exclusions.values["audio"]:
        raise rw.Failure("prior_prepared_audio")
    result = dict(case, language=source["language"], task="transcription", category="realworld-published-reference-pending-review",
                  audio=str(prepared), sha256=prepared_hash, original_audio_sha256=original_hash,
                  original_audio=str(original), duration_seconds=measured, source_channel=0,
                  original_source_channel=channel, source_interval_seconds=[str(start), str(end)],
                  source_url=source["source_url"], license=source["license"], source_use_review="pending",
                  reviewed=False, variety=source["variety"], script=source["script"], conditions=source["conditions"],
                  scoring_policy=rw.fresh.POLICY, evaluation_tier="legacy-v1; not native/v2 approved")
    result.update(grouping_review="Distinct source/meeting groups; real participant identity is unknown. Local tier labels are not global speaker IDs.",
                  independent_speaker_units_verified=False,
                  reference_conventions="Exact publisher field; content/timing/native review not performed" if reference is not None else "Reference-free resource excerpt")
    if reference is not None:
        acquisition.save(folder / "reference.original.txt", reference)
        result.update(reference=str(folder / "reference.original.txt"), reference_sha256=rw.digest(reference))
    else:
        result["measurement_scope"] = "resources_only"
    if acquisition.converter_version is None:
        version = rw.run_bounded(acquisition, ["ffmpeg", "-version"], 5, capture=True)
        acquisition.converter_version = version.decode("utf-8", errors="strict").splitlines()[0]
    provenance = dict(source=source, original_audio=str(original), original_audio_sha256=original_hash,
                      original_frames=frames, original_sample_rate=rate, original_channels=channels,
                      original_channel_selected=channel, channel_mixing=False, source_interval_seconds=[str(start), str(end)],
                      preparation_command=command, prepared_sha256=prepared_hash,
                      preparation_version=acquisition.converter_version, human_approval=False,
                      reference_sha256=rw.digest(reference) if reference is not None else None,
                      reference_source={k: case[k] for k in ("original_annotation", "source_annotation", "original_annotation_sha256", "published_local_speaker_label", "published_metadata", "published_metadata_sha256", "published_metadata_row", "published_metadata_remote_url", "remote_archive") if k in case},
                      reference_review="not performed", source_use_review="pending")
    acquisition.json(folder / "provenance.json", provenance)
    result["provenance"] = str(folder / "provenance.json")
    acquisition.exclusions.add(result)
    acquisition.cases.append(result)
    return result


def meetings(acquisition, plan):
    for item in plan["cases"]:
        acquisition.check()
        original = rw.fresh.safe(item["audio"])
        if original.stat().st_size != item["audio_bytes"] or sha(original, acquisition.check) != item["audio_sha256"]:
            raise rw.Failure("original_audio_identity")
        case = {k: item[k] for k in ("id", "source_id", "source_group_ids", "session_id", "split")}
        case["published_source_id"] = item.get("published_source_id", original.stem)
        # Published tier labels are local/unverified, never fabricated global people.
        case["speaker_ids"] = []
        chosen, annotation_snapshot = None, None
        if item["split"] != "resource":
            annotation = rw.fresh.safe(item["annotation"])
            raw = read_bound(annotation, MAX_ANNOTATION, acquisition.check)
            if rw.digest(raw) != item["annotation_sha256"]:
                raise rw.Failure("original_annotation_identity")
            case.update(original_annotation=str(annotation), original_annotation_sha256=item["annotation_sha256"])
            annotation_snapshot = (annotation, raw)
            chosen = choose_interval(textgrid(raw, acquisition.check), acquisition.check)
        reference = chosen["text"].encode("utf-8") if chosen else None
        if chosen:
            case["published_local_speaker_label"] = chosen["speaker"]
        corpus(acquisition, case, plan["source"], original, reference,
               chosen["start"] if chosen else None, chosen["end"] if chosen else None,
               item.get("channel", 0), item["audio_sha256"], annotation_snapshot=annotation_snapshot)


def coraa(acquisition, plan):
    metadata = rw.fresh.safe(plan["metadata"])
    raw = read_bound(metadata, MAX_METADATA, acquisition.check)
    if len(raw) != plan["metadata_bytes"] or rw.digest(raw) != plan["metadata_sha256"]:
        raise rw.Failure("published_metadata_identity")
    acquisition.save(acquisition.root / "originals" / "metadata.original.csv", raw)
    by_path = {}
    old_limit = csv.field_size_limit(rw.MAX_REFERENCE)
    try:
        reader = csv.DictReader(io.StringIO(raw.decode("utf-8-sig")))
        if not {"file_path", "text"} <= set(reader.fieldnames or []):
            raise rw.Failure("metadata_columns")
        for row in reader:
            acquisition.check()
            if len(by_path) >= MAX_ROWS or not rw.safe_text(row.get("file_path"), 1024) or row["file_path"] in by_path:
                raise rw.Failure("ambiguous_or_excessive_metadata_identity")
            by_path[row["file_path"]] = row
    finally:
        csv.field_size_limit(old_limit)
    pointer = dict(url=rw.pinned_url(plan["source"], plan["archive"]["path"]), bytes=plan["archive"]["bytes"],
                   etag=plan["archive"]["etag"], whole_file_sha256_verified=False)
    remote = rw.RangeFile(acquisition, pointer["url"], pointer["bytes"], pointer["etag"])
    with remote, zipfile.ZipFile(remote) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_ROWS:
            raise rw.Failure("archive_entry_count")
        selected = {item["member"] for item in plan["cases"]}
        occurrences = {name: 0 for name in selected}
        for entry in entries:
            acquisition.check()
            if entry.filename in occurrences:
                occurrences[entry.filename] += 1
        if any(count != 1 for count in occurrences.values()):
            raise rw.Failure("ambiguous_or_missing_zip_member")
        for item in plan["cases"]:
            acquisition.check()
            name = item["member"]
            if name not in by_path:
                raise rw.Failure("selected_zip_member_identity")
            info = archive.getinfo(name)
            mode = stat.S_IFMT(info.external_attr >> 16)
            if info.is_dir() or mode not in (0, stat.S_IFREG) or info.flag_bits & 1 or not 1 <= info.file_size <= MAX_MEMBER or not 1 <= info.compress_size <= MAX_MEMBER:
                raise rw.Failure("selected_zip_member_bound")
            with archive.open(info) as stream:
                chunks, total = [], 0
                while total < info.file_size:
                    acquisition.check()
                    part = stream.read(min(65536, info.file_size - total))
                    if not part:
                        break
                    chunks.append(part); total += len(part)
                if stream.read(1):
                    raise rw.Failure("selected_zip_member_overread")
                audio = b"".join(chunks)
            if len(audio) != info.file_size:
                raise rw.Failure("selected_zip_member_truncated")
            original = acquisition.root / "originals" / name
            acquisition.save(original, audio)
            row = by_path[name]
            reference = None
            if item["split"] != "resource":
                if not isinstance(row.get("text"), str) or not 1 <= len(row["text"].encode("utf-8")) <= rw.MAX_REFERENCE:
                    raise rw.Failure("reference_size_bound")
                reference = row["text"].encode("utf-8")
            case = {k: item[k] for k in ("id", "source_id", "source_group_ids", "session_id", "split")}
            case["published_source_id"] = name
            case["speaker_ids"] = []
            case.update(published_metadata=str(acquisition.root / "originals" / "metadata.original.csv"),
                        published_metadata_sha256=plan["metadata_sha256"], published_metadata_row=name,
                        published_metadata_remote_url=rw.pinned_url(plan["source"], plan["metadata_remote_path"]),
                        remote_archive=pointer)
            case["published_condition_metadata"] = {k: row.get(k) for k in ("dataset", "accent", "speech_genre", "speech_style", "votes_for_noise_or_low_voice", "votes_for_second_voice")}
            with wave.open(io.BytesIO(audio), "rb") as wav:
                duration = Decimal(wav.getnframes()) / wav.getframerate()
                if wav.getnchannels() != 1:
                    raise rw.Failure("zip_original_not_mono")
            end = min(duration, Decimal(20)) if reference is None else duration
            corpus(acquisition, case, plan["source"], original, reference, Decimal(0), end, 0, rw.digest(audio))


def relative_path(value):
    if not rw.safe_text(value, 1024) or "\\" in value or ":" in value:
        raise rw.Failure("supplement_relative_path")
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value or any(part in ("", ".", "..") for part in path.parts):
        raise rw.Failure("supplement_relative_path")
    return path


def validate_plan(plan):
    if not isinstance(plan, dict) or plan.get("schema_version") != "realworld-supplement-v1" or plan.get("kind") not in {"aishell4", "coraa"}:
        raise rw.Failure("supplement_schema")
    if not isinstance(plan.get("corpus_version"), str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", plan["corpus_version"]):
        raise rw.Failure("supplement_corpus_version")
    source = plan.get("source")
    if not isinstance(source, dict) or source.get("language") != {"aishell4": "zh", "coraa": "pt"}[plan["kind"]]:
        raise rw.Failure("supplement_source_language")
    for field in ("source_url", "license", "variety", "script"):
        if not rw.safe_text(source.get(field), 1024):
            raise rw.Failure("supplement_source_metadata")
    pointer = urlparse(source["source_url"])
    if pointer.scheme != "https" or not pointer.hostname or pointer.username or pointer.password or pointer.fragment:
        raise rw.Failure("supplement_source_url")
    if source.get("source_use_review") != "pending" or source.get("reviewed") or source.get("human_approval"):
        raise rw.Failure("supplement_cannot_invent_approval")
    conditions = source.get("conditions")
    if not isinstance(conditions, list) or not 1 <= len(conditions) <= 32 or any(not rw.safe_text(v, 160) for v in conditions):
        raise rw.Failure("supplement_source_conditions")
    if not isinstance(plan.get("cases"), list) or not 1 <= len(plan["cases"]) <= 128:
        raise rw.Failure("supplement_case_bound")
    budget = plan.get("budgets", {})
    if not isinstance(budget, dict):
        raise rw.Failure("supplement_budget")
    for key, minimum, maximum in (("network_bytes", 1024 ** 2, 4 * 1024 ** 3),
                                  ("output_bytes", 16 * 1024 ** 2, 2 * 1024 ** 3),
                                  ("timeout_seconds", 1, 1800)):
        rw.integer(budget.get(key), minimum, maximum, "supplement_budget")
    if plan["kind"] == "coraa":
        archive = plan.get("archive")
        if not isinstance(archive, dict):
            raise rw.Failure("supplement_archive_identity")
        relative_path(archive.get("path"))
        url = rw.pinned_url(source, archive["path"])
        if archive.get("url", url) != url:
            raise rw.Failure("supplement_archive_url_identity")
        rw.integer(archive.get("bytes"), 1, 16 * 1024 ** 3, "supplement_archive_size")
        if not isinstance(archive.get("etag"), str) or not re.fullmatch(r"[0-9a-f]{64}", archive["etag"]):
            raise rw.Failure("supplement_archive_etag")
        if not rw.safe_text(plan.get("metadata"), 4096):
            raise rw.Failure("supplement_metadata_path")
        rw.fresh.safe(plan["metadata"])
        rw.integer(plan.get("metadata_bytes"), 1, MAX_METADATA, "supplement_metadata_size")
        if not isinstance(plan.get("metadata_sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", plan["metadata_sha256"]):
            raise rw.Failure("supplement_metadata_hash")
        relative_path(plan.get("metadata_remote_path"))
        rw.pinned_url(source, plan["metadata_remote_path"])
    seen, sources, groups, sessions, hashes, members = set(), set(), set(), set(), set(), set()
    for item in plan["cases"]:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", item["id"]) or item["id"] in seen:
            raise rw.Failure("supplement_case_identity")
        seen.add(item["id"])
        if item.get("split") not in rw.SPLITS or not rw.safe_text(item.get("source_id"), 1024):
            raise rw.Failure("supplement_case_partition")
        if item["source_id"] in sources:
            raise rw.Failure("supplement_duplicate_source")
        sources.add(item["source_id"])
        if "published_source_id" in item and not rw.safe_text(item["published_source_id"], 1024):
            raise rw.Failure("supplement_published_source_identity")
        declared = item.get("source_group_ids")
        if not isinstance(declared, list) or not 1 <= len(declared) <= 8 or any(not rw.safe_text(v, 1024) for v in declared) or len(set(declared)) != len(declared):
            raise rw.Failure("supplement_source_group")
        if groups.intersection(declared):
            raise rw.Failure("supplement_source_groups_not_disjoint")
        groups.update(declared)
        session = item.get("session_id")
        if "session_id" not in item or session is not None and (not rw.safe_text(session, 1024) or session in sessions):
            raise rw.Failure("supplement_session_identity")
        if session is not None:
            sessions.add(session)
        if item.get("speaker_ids", []) != []:
            raise rw.Failure("supplement_global_speaker_identity_unverified")
        if plan["kind"] == "aishell4":
            if not rw.safe_text(item.get("audio"), 4096):
                raise rw.Failure("supplement_audio_path")
            rw.fresh.safe(item["audio"])
            rw.integer(item.get("channel", 0), 0, 255, "supplement_selected_channel")
            rw.integer(item.get("audio_bytes"), 1, 512 * 1024 ** 2, "meeting_audio_bound")
            keys = ["audio_sha256"]
            if item["split"] != "resource":
                if not rw.safe_text(item.get("annotation"), 4096):
                    raise rw.Failure("supplement_annotation_path")
                rw.fresh.safe(item["annotation"])
                keys.append("annotation_sha256")
            for key in keys:
                if not isinstance(item.get(key), str) or not re.fullmatch(r"[0-9a-f]{64}", item[key]):
                    raise rw.Failure("meeting_identity_hash")
            if item["audio_sha256"] in hashes:
                raise rw.Failure("supplement_duplicate_original_audio")
            hashes.add(item["audio_sha256"])
        else:
            relative_path(item.get("member"))
            if item["member"] in members:
                raise rw.Failure("supplement_duplicate_member")
            members.add(item["member"])
    return plan


def run(plan_path, output, exclusions):
    raw = read_bound(rw.fresh.safe(plan_path), 4 * 1024 ** 2)
    plan = validate_plan(json.loads(raw))
    excluded = rw.Exclusions()
    if len(exclusions) > 512:
        raise rw.Failure("supplement_exclusion_count")
    for path in exclusions:
        excluded.load(path)
    output = rw.fresh.safe(output)
    output.mkdir(mode=0o700, parents=False)
    acquisition = rw.Acquisition(output, plan, excluded)
    acquisition.save(output / "plan.original.json", raw)
    status, error = "failed", None
    def cancelled(number, frame):
        acquisition.interrupted_signal = number
    previous = {number: signal.signal(number, cancelled) for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        (meetings if plan["kind"] == "aishell4" else coraa)(acquisition, plan)
        status = "completed"
    except BaseException as exc:
        status = "cancelled" if isinstance(exc, InterruptedError) else "timed_out" if isinstance(exc, TimeoutError) else "failed"
        error = str(exc) if isinstance(exc, (rw.Failure, InterruptedError, TimeoutError)) else type(exc).__name__
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
        for split in rw.SPLITS:
            acquisition.json(output / (split + ".corpus.json"), dict(schema_version="1.0", corpus_version=plan["corpus_version"] + "-" + split,
                             cases=[c for c in acquisition.cases if c["split"] == split]), final=True)
        acquisition.json(output / "preparation.receipt.json", dict(schema_version="realworld-supplement-receipt-v1", status=status,
                         error=error, completed_cases=len(acquisition.cases), planned_cases=len(plan["cases"]),
                         plan_sha256=rw.digest(raw), network_bytes=acquisition.network_bytes, output_reserved_bytes=acquisition.output_bytes,
                         range_requests=acquisition.requests, human_approval=False, reference_words_logged=False), final=True)
    print(json.dumps(dict(status=status, completed_cases=len(acquisition.cases), planned_cases=len(plan["cases"]), error=error)))
    return 0 if status == "completed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--exclude-manifest", type=Path, action="append", default=[])
    args = parser.parse_args()
    raise SystemExit(run(args.plan, args.output, args.exclude_manifest))
