#!/usr/bin/env python3
"""Bounded, pinned real-world corpus acquisition; never recognizes or approves.

CLI: acquire-realworld.py PLAN.json --output NEW_PROTECTED_ROOT
     --exclude-manifest PRIOR.json [--exclude-manifest ...] [--metadata-only]
     acquire-realworld.py PLAN.json --validate-plan

Plan schema: realworld-acquisition-v1, corpus_version, languages,
counts_per_language={development:2,held_out:16,resource:1},
budgets={network_bytes,output_bytes,timeout_seconds}, sources=[{
 id,kind:voxpopuli|swiss_spc|casablanca,dataset,revision:40hex,config,language,
 split:development|held_out|resource,source_split,license,source_use_review:pending,
 variety,script,conditions,files:[{path,bytes,etag?}],grouping?:{
 parent_separator,parent_parts,session_from_parent:false}}].

Sources and file order are prospective selection order. Metadata-only mode
never requests audio/reference columns. Resources are separate original groups
and derive at most20 seconds; they never load/reference-score text. Published
reference bytes stay opaque until downstream candidate/configuration freezes.
All output is legacy-v1/unreviewed. Requires pyarrow only for actual Parquet reads.
Buffered decoding streams one forward-only row batch, never the full source
rowgroup. Selected column chunks are first staged in an owned sparse transport
file beneath RECSCRIBE_RUN_DIR, then read through a native Arrow memory map.
Only the requested column chunks, PAR1 header and footer are populated; this is
not an original complete Parquet file and its whole-file SHA is not verified.
Transport is disposable, capped at2GiB physical allocation, one URL at a time.
Materialized batches and observed Arrow allocations/peak are capped
at128MiB; source-rowgroup metadata is separately capped at1GiB. Transient native
decoder pages are not guaranteed128MiB, so acquisition RSS/Arrow observations
are retained and do not establish model-resource acceptance.

RangeFile(acquisition,url,size,expected_etag=None) exposes bounded seek/read for
Parquet or ZIP reuse. Acquisition supplies check(), read_response(), network_bytes
and requests. Complete-file SHA is not inferred from partial range reads.
ParquetRows.transport_preflight([(row_group, with_reference), ...]) returns
conservative compressed transfer/physical-allocation costs without audio or
reference reads. Metadata-only receipts include these per-source costs. Optional
plan transport={strategy:sparse-mmap-v1,physical_bytes:<=2GiB}; optional
reuse_development=[{manifest:absolute_path,sha256:...}] imports verified source
preparation only, read-only, and reserves its groups against every other split.
Prospective isolated_decoder_limits may opt VoxPopuli into observed2GiB Arrow /
3GiB RSS, or Casablanca into256MiB Arrow /512MiB RSS, in an owned worker per
selected row. Materialized batches remain128MiB and source columns<=900000000B.
The parent samples exact-child RSS every250ms; worker lifetime Arrow/RSS peaks
are checked before acceptance. These observed limits cannot guarantee against
sub-sample transient RSS spikes. Each helper is reaped before audio conversion.
Scratch source inputs remain pinned until verified protected copies exist;
failed copies retain their only originals and disable transport eviction.
quality_pending_languages:[ar] retains missing2/16 quality counts. A prospective
Casablanca resource source may select resource_channel:0 and selected_source_id;
that reference-free physical-channel view never mixes original stereo channels.
"""
import argparse
from collections import Counter, OrderedDict
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from urllib.parse import quote, urlparse
import wave

_SPEC = importlib.util.spec_from_file_location("realworld_fresh_helpers", Path(__file__).with_name("acquire-fresh-slice.py"))
fresh = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(fresh)
_GUARD_SPEC = importlib.util.spec_from_file_location("realworld_owned_guard", Path(__file__).with_name("run-guard.py"))
guard = importlib.util.module_from_spec(_GUARD_SPEC)
_GUARD_SPEC.loader.exec_module(guard)

VERSION = "realworld-acquisition-v1"
MIB = 1024 * 1024
GIB = 1024 * MIB
MAX_RANGE = 8 * MIB
MAX_READ = 64 * MIB
MAX_ROW_GROUP = 128 * MIB  # Materialized batch / observed Arrow allocation bound.
MAX_SOURCE_ROW_GROUP = GIB
MAX_METADATA = 16 * MIB
MAX_AUDIO = 32 * MIB
MAX_REFERENCE = MIB
MAX_TRANSPORT = 2 * GIB
MAX_SELECTED_COLUMN = 900000000
MAX_WORKER_JSON = 65536
ISOLATED_LIMITS = {"voxpopuli": {"observed_arrow_bytes": 2 * GIB, "process_rss_bytes": 3 * GIB},
                   "casablanca": {"observed_arrow_bytes": 256 * MIB, "process_rss_bytes": 512 * MIB}}
FINAL_RESERVE = 8 * MIB
LANGUAGES = {"de-CH", "de", "fr", "it", "en", "ar", "zh", "es", "pt"}
SPLITS = ("development", "resource", "held_out")
KINDS = {
    "voxpopuli": {"dataset": "facebook/voxpopuli", "id": "audio_id", "reference": "raw_text",
                   "metadata": ["audio_id", "speaker_id", "is_gold_transcript"], "speaker": "speaker_id", "namespace": "voxpopuli"},
    "swiss_spc": {"dataset": "i4ds/SPC_test", "id": "path", "reference": "sentence",
                   "metadata": ["path", "client_id", "iou_estimate"], "speaker": "client_id", "namespace": "swiss-spc"},
    "casablanca": {"dataset": "UBC-NLP/Casablanca", "id": "seg_id", "reference": "transcription",
                    "metadata": ["seg_id", "gender", "duration"], "speaker": None, "namespace": "casablanca"},
}


class Failure(ValueError):
    """Messages are controlled labels, never source/reference/hypothesis words."""


class MemoryBound(Failure):
    """Observed decoder allocation breaches abort the whole acquisition."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def integer(value, minimum, maximum, label):
    if type(value) is not int or not minimum <= value <= maximum:
        raise Failure(label)
    return value


def safe_text(value, maximum=256):
    return isinstance(value, str) and 0 < len(value) <= maximum and not any(ord(c) < 32 for c in value)


def pinned_url(source, path):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", source.get("dataset", "")) or not re.fullmatch(r"[0-9a-f]{40}", source.get("revision", "")):
        raise Failure("dataset_or_revision_identity")
    part = PurePosixPath(path)
    if not path or part.is_absolute() or ".." in part.parts or "\\" in path or any(c in path for c in "?#"):
        raise Failure("unsafe_pinned_path")
    return "https://huggingface.co/datasets/" + source["dataset"] + "/resolve/" + source["revision"] + "/" + quote(path, safe="/._-")


def validate_plan(plan):
    if plan.get("schema_version") != VERSION or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", plan.get("corpus_version", "")):
        raise Failure("plan_schema_or_version")
    languages = plan.get("languages")
    if not isinstance(languages, list) or not languages or len(languages) != len(set(languages)) or not set(languages) <= LANGUAGES:
        raise Failure("plan_languages")
    if plan.get("counts_per_language") != {"development": 2, "held_out": 16, "resource": 1}:
        raise Failure("confirmation_requires_2_development_16_heldout_1_resource")
    pending = plan.get("quality_pending_languages", [])
    if not isinstance(pending, list) or pending not in ([], ["ar"]) or not set(pending) <= set(languages):
        raise Failure("pending_quality_languages")
    budget = plan.get("budgets", {})
    integer(budget.get("network_bytes"), MIB, 4 * GIB, "network_budget")
    integer(budget.get("output_bytes"), 16 * MIB, 2 * GIB, "output_budget")
    integer(budget.get("timeout_seconds"), 1, 1800, "time_budget")
    transport = plan.get("transport", {"strategy": "sparse-mmap-v1", "physical_bytes": MAX_TRANSPORT})
    if not isinstance(transport, dict) or set(transport) != {"strategy", "physical_bytes"} or transport.get("strategy") != "sparse-mmap-v1":
        raise Failure("transport_strategy")
    integer(transport.get("physical_bytes"), MAX_RANGE, MAX_TRANSPORT, "transport_physical_budget")
    limits = plan.get("isolated_decoder_limits", {})
    if not isinstance(limits, dict) or set(limits) - set(ISOLATED_LIMITS) or any(value != ISOLATED_LIMITS[kind] for kind, value in limits.items()):
        raise Failure("prospective_isolated_decoder_limits")
    reuse = plan.get("reuse_development", [])
    if not isinstance(reuse, list) or len(reuse) > 8:
        raise Failure("reuse_development_bound")
    for item in reuse:
        if not isinstance(item, dict) or set(item) != {"manifest", "sha256"} or not Path(item.get("manifest", "")).is_absolute() or not re.fullmatch(r"[0-9a-f]{64}", item.get("sha256", "")):
            raise Failure("reuse_development_identity")
    sources = plan.get("sources")
    if not isinstance(sources, list) or not 1 <= len(sources) <= 64:
        raise Failure("plan_sources")
    seen = set()
    for source in sources:
        if not isinstance(source, dict) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", source.get("id", "")) or source["id"] in seen:
            raise Failure("source_id")
        seen.add(source["id"])
        kind = KINDS.get(source.get("kind"))
        if not kind or source.get("dataset") != kind["dataset"]:
            raise Failure("source_kind_dataset_mapping")
        if source.get("language") not in languages or source.get("split") not in SPLITS:
            raise Failure("source_language_or_split")
        if source["kind"] == "swiss_spc" and source["language"] != "de-CH" or source["kind"] == "casablanca" and source["language"] != "ar":
            raise Failure("source_language_mapping")
        for name in ("config", "source_split", "license", "variety", "script"):
            if not safe_text(source.get(name)):
                raise Failure("missing_source_metadata_" + name)
        if source["kind"] == "voxpopuli" and (source["config"] not in {"de", "en", "es", "fr", "it"} or source["language"] != source["config"]):
            raise Failure("voxpopuli_config_language")
        if source.get("source_use_review") != "pending":
            raise Failure("acquisition_cannot_invent_source_use_approval")
        if "resource_channel" in source and not (source["kind"] == "casablanca" and source["split"] == "resource" and type(source["resource_channel"]) is int and source["resource_channel"] == 0):
            raise Failure("reference_free_arabic_resource_channel_policy")
        if "selected_source_id" in source and not (source["kind"] == "casablanca" and source["split"] == "resource" and safe_text(source["selected_source_id"], 2048) and source["selected_source_id"].startswith("casablanca:" + source["config"] + ":")):
            raise Failure("resource_prospective_source_identity")
        if not isinstance(source.get("conditions"), list) or not source["conditions"] or any(not safe_text(v, 80) for v in source["conditions"]):
            raise Failure("conditions_metadata")
        grouping = source.get("grouping", {})
        if grouping:
            if set(grouping) - {"parent_separator", "parent_parts", "session_from_parent"}:
                raise Failure("unknown_grouping_policy")
            if grouping.get("parent_separator") not in ("_", "/", "-", ":"):
                raise Failure("group_separator")
            integer(grouping.get("parent_parts"), 1, 8, "group_parts")
            if type(grouping.get("session_from_parent", False)) is not bool:
                raise Failure("group_session_policy")
        files = source.get("files")
        if not isinstance(files, list) or not 1 <= len(files) <= 32:
            raise Failure("source_files")
        for file in files:
            if not isinstance(file, dict) or not file.get("path", "").endswith(".parquet"):
                raise Failure("pinned_parquet_file")
            pinned_url(source, file["path"])
            if source["kind"] in ("voxpopuli", "casablanca") and not file["path"].startswith(source["config"] + "/" + source["source_split"] + "-"):
                raise Failure("file_config_partition_identity")
            if source["kind"] == "swiss_spc" and (source["source_split"] != "test" or not file["path"].startswith("data/test-")):
                raise Failure("swiss_source_partition")
            integer(file.get("bytes"), 8, 16 * GIB, "declared_file_size")
            if file.get("etag") is not None and not safe_text(file["etag"], 160):
                raise Failure("declared_etag")
        integer(source.get("max_metadata_rows", 20000), 1, 100000, "metadata_row_bound")
    for language in languages:
        for split in SPLITS:
            if not any(s["language"] == language and s["split"] == split for s in sources):
                raise Failure("missing_prospective_source_partition")
    return plan


class Exclusions(fresh.Exclusions):
    def __init__(self):
        super().__init__()
        self.values["parent"] = set()

    def add(self, case):
        super().add(case)
        self.values["parent"].update(case.get("source_group_ids") or [])


def default_priority_probe(owned_session=None):
    """Acquisition-only policy; no controlled resource claim follows1000%CPU."""
    return guard.capture_or_competing_work(2, owned_session=owned_session, foreign_cpu_limit=1000)


def probe_child_rss(pid, timeout):
    """One exact owned PID, bounded platform command, KiB converted to bytes."""
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "rss="], stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=min(1, timeout), check=False)
    if result.returncode or len(result.stdout) > 64 or result.stderr or not re.fullmatch(rb"\s*[0-9]{1,12}\s*", result.stdout):
        raise Failure("owned_child_rss_probe_uncertain")
    return integer(int(result.stdout.strip()) * 1024, 1, 1 << 48, "owned_child_rss_probe_uncertain")


class Acquisition:
    def __init__(self, root, plan, exclusions, opener=None, priority_probe=default_priority_probe):
        self.root, self.plan, self.exclusions = root, plan, exclusions
        self.deadline = time.monotonic() + plan["budgets"]["timeout_seconds"]
        self.deadline_utc_seconds = time.time() + plan["budgets"]["timeout_seconds"]
        self.maximum_network_bytes = plan["budgets"]["network_bytes"]
        self.maximum_output_bytes = plan["budgets"]["output_bytes"]
        self.network_bytes = self.output_bytes = 0
        self.requests, self.cases, self.selected, self.errors = [], [], [], []
        self.skipped = Counter()
        self.opener = opener or urllib.request.urlopen
        self.priority_probe = priority_probe
        self.last_probe = float("-inf")
        self.interrupted_signal = None
        self.converter_version = None
        self.owned_session = None
        self.helper_count = 0
        self.transport = None
        self.transport_preflights, self.transport_events, self.reused_development = [], [], []
        self.decoder_memory = {"maximum_observed_arrow_bytes": 0, "maximum_reported_arrow_pool_peak_bytes": 0,
                               "process_peak_rss_bytes": None,
                               "scope": "Acquisition decoder only; source rowgroup <=1GiB, materialized batch <=128MiB; transient C++ pages not guaranteed128MiB"}
        if plan.get("isolated_decoder_limits"):
            self.decoder_memory["scope"] = "Source preparation only: frozen per-kind owned-worker observed Arrow/RSS limits; materialized batch128MiB; RSS sampled250ms plus reported peak; transient spikes are not guaranteed bounded; no model resource claim"
            self.decoder_memory["isolated_decoder_limits"] = plan["isolated_decoder_limits"]

    @property
    def active_converter_sid(self):
        return self.owned_session

    def check(self):
        if self.interrupted_signal is not None or (self.root / "cancel.request").exists():
            raise InterruptedError("acquisition_cancelled")
        if time.monotonic() >= self.deadline or time.time() >= self.deadline_utc_seconds:
            raise TimeoutError("acquisition_deadline")
        if self.network_bytes > self.maximum_network_bytes:
            raise Failure("network_budget")
        if self.priority_probe and time.monotonic() - self.last_probe >= 1:
            self.last_probe = time.monotonic()
            if self.priority_probe(self.owned_session):
                raise InterruptedError("recording_or_competing_work")

    def open(self, url, headers=None):
        self.check()
        if len(self.requests) >= 10000:
            raise Failure("request_count_bound")
        if urlparse(url).scheme != "https":
            raise Failure("https_required")
        timeout = max(.001, min(8, self.deadline - time.monotonic()))
        response = self.opener(urllib.request.Request(url, headers={"User-Agent": "RecScribe-realworld-acquisition/1.0", "Accept-Encoding": "identity", **(headers or {})}), timeout=timeout)
        try:
            self.check()
            if hasattr(response, "geturl") and urlparse(response.geturl()).scheme != "https":
                raise Failure("redirect_protocol")
        except BaseException:
            response.close()
            raise
        return response

    def read_response(self, response, count):
        self.check()
        remaining = self.maximum_network_bytes - self.network_bytes
        if count > remaining:
            raise Failure("network_budget")
        data = response.read(count)
        self.network_bytes += len(data)
        if len(data) > count:
            raise Failure("response_read_overflow")
        self.check()
        return data

    def fetch(self, url, maximum=MIB):
        with self.open(url) as response:
            if response.status != 200 or response.headers.get("Content-Encoding", "identity") not in ("identity", ""):
                raise Failure("source_card_response")
            declared = response.headers.get("Content-Length")
            if declared is not None and (not declared.isdecimal() or int(declared) > maximum):
                raise Failure("source_card_size")
            chunks, total = [], 0
            while True:
                part = self.read_response(response, min(65536, maximum + 1 - total))
                if not part:
                    break
                chunks.append(part); total += len(part)
                if total > maximum:
                    raise Failure("source_card_size")
            if declared is not None and total != int(declared):
                raise Failure("source_card_truncated")
            data = b"".join(chunks)
            self.requests.append({"url": url, "bytes": total, "sha256": digest(data), "scope": "whole_source_card"})
            return data

    def reserve(self, size, final=False):
        if not final:
            self.check()
        maximum = self.maximum_output_bytes - (0 if final else FINAL_RESERVE)
        if size < 0 or self.output_bytes + size > maximum:
            raise Failure("output_budget")
        self.output_bytes += size

    def save(self, path, data, final=False):
        self.reserve(len(data), final)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as stream:
            stream.write(data)

    def json(self, path, value, final=False):
        self.save(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode(), final)

    def run_command(self, command, timeout, capture=False, target=None, maximum_bytes=None,
                    maximum_rss_bytes=None, rss_probe=probe_child_rss, sidecar_directory=None, maximum_sidecar_bytes=None):
        """Bound/reap only our helper session; recording/foreign work still wins."""
        self.check()
        self.helper_count += 1
        if self.helper_count > 1024:
            raise Failure("helper_count_bound")
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                                     start_new_session=True)
            self.owned_session = child.pid
            deadline = min(self.deadline, time.monotonic() + timeout)
            rss_observation = {"limit_bytes": maximum_rss_bytes, "maximum_observed_rss_bytes": 0, "samples": 0,
                "scope": "Observed exact-child RSS at250ms intervals plus child-reported peak; sub-sample transient spikes are not guaranteed bounded"}
            last_rss = float("-inf")
            try:
                while child.poll() is None:
                    self.check()
                    if time.monotonic() >= deadline:
                        raise TimeoutError("helper_deadline")
                    if os.fstat(output.fileno()).st_size > 65536 or os.fstat(errors.fileno()).st_size > 65536:
                        raise Failure("helper_log_bound")
                    if target is not None and target.exists() and target.stat().st_size > maximum_bytes:
                        raise Failure("prepared_output_bound")
                    if sidecar_directory is not None:
                        observed = 0
                        for path in sidecar_directory.iterdir():
                            if path.is_symlink() or not path.is_file(): raise Failure("worker_sidecar_type")
                            observed += path.stat().st_size
                            if observed > maximum_sidecar_bytes: raise Failure("worker_sidecar_bound")
                    if maximum_rss_bytes is not None and time.monotonic() - last_rss >= .25:
                        last_rss = time.monotonic()
                        try:
                            measured = rss_probe(child.pid, max(.001, min(1, deadline - time.monotonic())))
                        except (OSError, ValueError, subprocess.SubprocessError):
                            if child.poll() is None: raise Failure("owned_child_rss_probe_uncertain")
                        else:
                            integer(measured, 1, 1 << 48, "owned_child_rss_probe_uncertain")
                            rss_observation["samples"] += 1
                            rss_observation["maximum_observed_rss_bytes"] = max(rss_observation["maximum_observed_rss_bytes"], measured)
                            if measured > maximum_rss_bytes: raise MemoryBound("owned_child_rss_bound")
                    time.sleep(.05)
                self.check()
                if os.fstat(output.fileno()).st_size > 65536 or os.fstat(errors.fileno()).st_size > 65536:
                    raise Failure("helper_log_bound")
                if target is not None and target.exists() and target.stat().st_size > maximum_bytes:
                    raise Failure("prepared_output_bound")
                if child.returncode:
                    raise Failure("helper_failed")
                output.seek(0)
                return output.read(65536) if capture else None
            finally:
                events = []
                try:
                    shutdown = guard.stop_owned(child, child.pid, self.root,
                        lambda event, **fields: events.append({"event": event, **fields}),
                        1, 1, 1, 1, {child.pid: {child.pid}})
                    captured = {}
                    for name, stream in (("stdout", output), ("stderr", errors)):
                        observed = os.fstat(stream.fileno()).st_size
                        stream.seek(0); retained = stream.read(65536)
                        filename = f"{name}-{self.helper_count}.log"
                        self.save(self.root / "helpers" / filename, retained, final=True)
                        captured[name] = {"file": filename, "observed_bytes": observed,
                                          "retained_bytes": len(retained), "truncated": observed > len(retained),
                                          "retained_sha256": digest(retained)}
                    self.json(self.root / "helpers" / f"cleanup-{self.helper_count}.json",
                              {"events": events, "helper_logs": captured, "rss_watchdog": rss_observation, **shutdown}, final=True)
                    if shutdown["owned_session_present"] is not False or shutdown["shutdown_errors"]:
                        raise Failure("helper_shutdown_uncertain")
                finally:
                    self.owned_session = None


class RangeFile(io.RawIOBase):
    """Pinned remote file with exact206 ranges, capped reads and a16MiB cache."""
    def __init__(self, acquisition, url, size, expected_etag=None):
        super().__init__()
        self.acquisition, self.url, self.size = acquisition, url, size
        self.position = 0
        self.etag = expected_etag.strip('"') if expected_etag else None
        self.cache = OrderedDict()

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.position

    def seek(self, offset, whence=io.SEEK_SET):
        if self.closed: raise Failure("range_file_closed")
        self.acquisition.check()
        if type(offset) is not int or whence not in (io.SEEK_SET, io.SEEK_CUR, io.SEEK_END):
            raise Failure("range_seek")
        position = offset + (self.position if whence == io.SEEK_CUR else self.size if whence == io.SEEK_END else 0)
        if not 0 <= position <= self.size:
            raise Failure("range_seek")
        self.position = position
        return position

    def _range(self, start, size):
        self.acquisition.check()
        key = (start, size)
        if key in self.cache:
            self.cache.move_to_end(key)
            return self.cache[key]
        end = start + size - 1
        with self.acquisition.open(self.url, {"Range": f"bytes={start}-{end}"}) as response:
            if response.status != 206 or response.headers.get("Content-Range") != f"bytes {start}-{end}/{self.size}":
                raise Failure("content_range_identity")
            if response.headers.get("Content-Encoding", "identity") not in ("identity", ""):
                raise Failure("range_content_encoding")
            length = response.headers.get("Content-Length")
            if length is not None and length != str(size):
                raise Failure("range_content_length")
            etag = response.headers.get("ETag", "").strip('"')
            if not etag or self.etag is not None and etag != self.etag:
                raise Failure("range_etag_identity")
            self.etag = etag
            chunks, total = [], 0
            while total < size:
                part = self.acquisition.read_response(response, min(65536, size - total))
                if not part:
                    raise Failure("range_truncated")
                chunks.append(part); total += len(part)
            if self.acquisition.read_response(response, 1):
                raise Failure("range_overread")
            data = b"".join(chunks)
        self.acquisition.requests.append({"url": self.url, "range": [start, end], "total_file_bytes": self.size,
            "response_bytes": len(data), "etag": etag, "range_sha256": digest(data), "whole_file_sha256_verified": False})
        self.cache[key] = data
        while len(self.cache) > 2:
            self.cache.popitem(last=False)
        return data

    def read(self, size=-1):
        if self.closed: raise Failure("range_file_closed")
        self.acquisition.check()
        if size is None or size == -1:
            size = self.size - self.position
        if type(size) is not int or size < 0 or size > MAX_READ:
            raise Failure("range_read_memory_bound")
        size = min(size, self.size - self.position)
        if not size:
            return b""
        chunks, remaining = [], size
        while remaining:
            count = min(remaining, MAX_RANGE)
            chunks.append(self._range(self.position, count))
            self.position += count; remaining -= count
        return b"".join(chunks)

    def readinto(self, buffer):
        data = self.read(len(buffer)); buffer[:len(data)] = data
        return len(data)


def merged_intervals(intervals):
    """Half-open file ranges; no range contents or reference words involved."""
    result = []
    for start, end in sorted(intervals):
        if type(start) is not int or type(end) is not int or not 0 <= start < end:
            raise Failure("transport_interval")
        if result and start <= result[-1][1]:
            result[-1] = (result[-1][0], max(end, result[-1][1]))
        else:
            result.append((start, end))
    return result


def missing_intervals(required, present):
    result = []
    for start, end in merged_intervals(required):
        cursor = start
        for left, right in present:
            if right <= cursor: continue
            if left >= end: break
            if left > cursor: result.append((cursor, min(left, end)))
            cursor = max(cursor, right)
            if cursor >= end: break
        if cursor < end: result.append((cursor, end))
    return result


def allocation_bound(intervals):
    # macOS allocation units are usually4KiB, but reserve64KiB per disjoint
    # extent plus64KiB bookkeeping; fstat's actual blocks are checked as well.
    block = 65536
    aligned = merged_intervals([(start // block * block, (end + block - 1) // block * block)
                                for start, end in merged_intervals(intervals)])
    return sum(end - start for start, end in aligned) + block


def parquet_chunk_intervals(metadata, group, columns, footer_start):
    row = metadata.row_group(group)
    if not 1 <= row.num_rows <= 100000:
        raise Failure("parquet_row_group_rows")
    intervals, unpacked, found = [], 0, set()
    for index in range(row.num_columns):
        column = row.column(index)
        name = column.path_in_schema.split(".")[0]
        if name not in columns: continue
        found.add(name)
        unpacked += column.total_uncompressed_size
        if not 0 <= unpacked <= MAX_SOURCE_ROW_GROUP:
            raise Failure("source_row_group_uncompressed_bound")
        if getattr(column, "file_path", None):
            raise Failure("external_parquet_column_unsupported")
        offsets = [getattr(column, key, None) for key in ("dictionary_page_offset", "data_page_offset")]
        offsets = [value for value in offsets if type(value) is int and value >= 4]
        length = column.total_compressed_size
        if not offsets or type(length) is not int or length <= 0:
            raise Failure("parquet_chunk_layout")
        start = min(offsets)
        if not 4 <= start < start + length <= footer_start:
            raise Failure("parquet_chunk_outside_data")
        intervals.append((start, start + length))
    if found != set(columns):
        raise Failure("parquet_required_leaf_columns")
    if not 0 <= unpacked <= MAX_SOURCE_ROW_GROUP:
        raise Failure("source_row_group_uncompressed_bound")
    return merged_intervals(intervals), unpacked


class SparseTransport:
    """Owned, partial, disposable container. Never an original media artifact.

    All decoder-required ranges must be present before memory_map is handed to
    Arrow. A single URL can accumulate chunks within the physical cap. Switching
    URL unlinks only this manager's own file after the caller closes its mmap.
    """
    def __init__(self, acquisition):
        self.acquisition = acquisition
        managed = os.environ.get("RECSCRIBE_RUN_DIR", "")
        root = fresh.safe(managed) if managed else Path("")
        if not managed or not root.is_absolute() or not root.is_dir() or root.is_symlink():
            raise Failure("managed_transport_directory_required")
        self.directory = Path(tempfile.mkdtemp(prefix="parquet-transport-", dir=root))
        self.pin = root / ".pin"
        self.pin_body = ("Source transport in progress or recovery pending: " + self.directory.name + "\n").encode()
        self.owned_pin = False
        if not self.pin.exists():
            with self.pin.open("xb") as stream: stream.write(self.pin_body)
            self.owned_pin = True
        self.path = self.directory / "partial-transport.parquet"
        self.url = self.size = self.etag = None
        self.present = []
        self.maximum = acquisition.plan.get("transport", {}).get("physical_bytes", MAX_TRANSPORT)
        self.stream = None
        self.closed = False
        self.recovery_pending = False

    def preserve_recovery(self, reason):
        self.recovery_pending = True
        pin = self.directory.parent / ".pin"
        if not pin.exists():
            with pin.open("xb") as stream: stream.write(b"Protected source-copy recovery pending; do not delete this run.\n")
        self.acquisition.transport_events.append({"event": "source_scratch_recovery_preserved", "directory": str(self.directory),
            "reason": reason, "automatic_eviction_disabled": True, "managed_run_pinned": True})

    def _evict(self):
        if self.stream is not None:
            physical = os.fstat(self.stream.fileno()).st_blocks * 512
            self.stream.close(); self.stream = None
            self.acquisition.transport_events.append({"event": "evict_disposable_partial_transport", "url": self.url,
                "logical_bytes": self.size, "physical_bytes": physical,
                "staged_ranges": self.present, "whole_file_sha256_verified": False})
            self.path.unlink()
        self.present = []

    def stage(self, remote, intervals):
        self.acquisition.check()
        if self.closed: raise Failure("transport_closed")
        if self.recovery_pending: raise Failure("transport_recovery_pending")
        required = merged_intervals(intervals)
        if any(end > remote.size for _, end in required):
            raise Failure("transport_range_outside_file")
        same = (self.url, self.size, self.etag) == (remote.url, remote.size, remote.etag)
        present = self.present if same else []
        combined = merged_intervals(present + required)
        bound = allocation_bound(combined)
        missing = missing_intervals(required, present)
        anticipated = sum(end - start for start, end in missing)
        if bound > self.maximum:
            raise Failure("transport_physical_preflight_bound")
        if self.acquisition.network_bytes + anticipated > self.acquisition.maximum_network_bytes:
            raise Failure("transport_network_preflight_bound")
        if not same:
            self._evict()
            self.stream = self.path.open("x+b", buffering=0)
            os.chmod(self.path, 0o600)
            self.stream.truncate(remote.size)
            if os.fstat(self.stream.fileno()).st_blocks * 512 > self.maximum:
                raise Failure("transport_sparse_allocation_unsupported")
            self.url, self.size, self.etag = remote.url, remote.size, remote.etag
        for start, end in missing:
            cursor = start
            while cursor < end:
                self.acquisition.check()
                count = min(MAX_RANGE, end - cursor)
                remote.seek(cursor)
                data = remote.read(count)
                if len(data) != count: raise Failure("transport_range_truncated")
                self.stream.seek(cursor)
                if self.stream.write(data) != count: raise Failure("transport_write_truncated")
                self.present = merged_intervals(self.present + [(cursor, cursor + count)])
                physical = os.fstat(self.stream.fileno()).st_blocks * 512
                if physical > self.maximum:
                    raise Failure("transport_physical_observed_bound")
                cursor += count
        self.stream.flush()
        self.etag = remote.etag
        if missing_intervals(required, self.present):
            raise Failure("transport_required_range_missing")
        self.acquisition.transport_events.append({"event": "stage_required_column_chunks", "url": self.url,
            "required_ranges": required, "new_transport_bytes": anticipated,
            "physical_allocation_upper_bound": bound, "observed_physical_bytes": os.fstat(self.stream.fileno()).st_blocks * 512,
            "logical_file_bytes": remote.size, "scope": "sparse incomplete transport only; not original Parquet",
            "whole_file_sha256_verified": False})
        return self.path

    def close(self):
        if self.closed: return
        if self.recovery_pending:
            if self.stream is not None: self.stream.close(); self.stream = None
            self.closed = True
            return
        self._evict()
        # rmdir never follows links or recursively removes unexpected material.
        self.directory.rmdir()
        if self.owned_pin and self.pin.is_file() and self.pin.read_bytes() == self.pin_body:
            self.pin.unlink()
        self.closed = True


def run_bounded(acquisition, command, timeout, capture=False, target=None, maximum_bytes=None):
    """Public supplement adapter; delegates to bounded/reaped owned helper session."""
    return acquisition.run_command(command, timeout, capture=capture, target=target, maximum_bytes=maximum_bytes)


def process_peak_rss():
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return value if sys.platform == "darwin" else value * 1024


def decode_mmap_worker(request_path, output):
    """Internal, owned-process source decoder. Never ASR; never prints content."""
    request_path, output = fresh.safe(request_path), fresh.safe(output)
    if not request_path.is_file() or request_path.stat().st_size > MAX_WORKER_JSON or not output.is_dir():
        raise Failure("worker_request_bound")
    request = json.loads(request_path.read_bytes())
    kind = KINDS.get(request.get("kind"))
    limits = request.get("limits")
    if not kind or request.get("kind") not in ISOLATED_LIMITS or limits != ISOLATED_LIMITS[request["kind"]]:
        raise Failure("worker_limits_identity")
    group = integer(request.get("row_group"), 0, 9999, "worker_group")
    offset = integer(request.get("row_in_group"), 0, 99999, "worker_offset")
    if type(request.get("with_reference")) is not bool: raise Failure("worker_reference_policy")
    columns = ["audio"] + ([kind["reference"]] if request["with_reference"] else [])
    path = fresh.safe(request.get("mmap_path", ""))
    if not path.is_file() or path.stat().st_size != request.get("logical_file_bytes"):
        raise Failure("worker_transport_identity")
    footer_start = integer(request.get("footer_start"), 4, path.stat().st_size - 9, "worker_footer_identity")
    present = merged_intervals([tuple(value) for value in request.get("staged_ranges", [])])
    if missing_intervals([(0, 4), (footer_start, path.stat().st_size)], present):
        raise Failure("worker_unstaged_footer")
    with path.open("rb") as stream:
        if stream.read(4) != b"PAR1": raise Failure("worker_header_identity")
        stream.seek(-8, io.SEEK_END);tail = stream.read(8)
    length = int.from_bytes(tail[:4], "little")
    if tail[4:] != b"PAR1" or not 1 <= length <= MAX_METADATA or path.stat().st_size - 8 - length != footer_start:
        raise Failure("worker_footer_identity")
    for key in ("deadline_monotonic", "deadline_utc_seconds"):
        if type(request.get(key)) not in (int, float) or not math.isfinite(request[key]): raise Failure("worker_deadline")
    observed = {"maximum_observed_arrow_bytes": 0, "maximum_reported_arrow_pool_peak_bytes": 0,
                "process_peak_rss_bytes": 0}
    def check(pool=None):
        if time.monotonic() >= request["deadline_monotonic"] or time.time() >= request["deadline_utc_seconds"]:
            raise TimeoutError("worker_deadline")
        observed["process_peak_rss_bytes"] = process_peak_rss()
        if observed["process_peak_rss_bytes"] > limits["process_rss_bytes"]: raise MemoryBound("worker_peak_rss_bound")
        if pool is not None:
            allocated, peak = pool.bytes_allocated(), pool.max_memory()
            if allocated < 0 or peak < 0: raise Failure("worker_arrow_measurement_unavailable")
            observed["maximum_observed_arrow_bytes"] = max(observed["maximum_observed_arrow_bytes"], allocated)
            observed["maximum_reported_arrow_pool_peak_bytes"] = max(observed["maximum_reported_arrow_pool_peak_bytes"], peak)
            if max(allocated, peak) > limits["observed_arrow_bytes"]: raise MemoryBound("worker_arrow_pool_bound")
    mapped = parquet = iterator = batch = None
    result = {"passed": False, "error": None, "memory": observed, "recognition_performed": False,
              "reference_text_displayed": False}
    try:
        check()
        import pyarrow as pa
        import pyarrow.parquet as pq
        mapped = pa.memory_map(str(path), "r")
        parquet = pq.ParquetFile(mapped, pre_buffer=False, buffer_size=0)
        required, unpacked = parquet_chunk_intervals(parquet.metadata, group, columns, request["footer_start"])
        if missing_intervals(required, merged_intervals([tuple(v) for v in request["staged_ranges"]])):
            raise Failure("worker_unstaged_column_chunk")
        metadata = parquet.metadata.row_group(group)
        for index in range(metadata.num_columns):
            column = metadata.column(index)
            if column.path_in_schema.split(".")[0] in columns and not 0 <= column.total_uncompressed_size <= MAX_SELECTED_COLUMN:
                raise Failure("worker_selected_column_bound")
        if offset >= metadata.num_rows: raise Failure("worker_offset")
        pool = pa.default_memory_pool()
        check(pool)
        iterator = parquet.iter_batches(batch_size=1, row_groups=[group], columns=columns, use_threads=False)
        for index in range(offset + 1):
            batch = None
            check(pool)
            try: batch = next(iterator)
            except StopIteration as error: raise Failure("worker_row_group_truncated") from error
            if batch.num_rows != 1: raise Failure("worker_batch_progress")
            if not 0 <= batch.nbytes <= MAX_ROW_GROUP: raise MemoryBound("worker_materialized_batch_bound")
            check(pool)
        audio = batch.column("audio")[0].as_py()
        reference = batch.column(kind["reference"])[0].as_py() if request["with_reference"] else None
        if not isinstance(audio, dict) or not isinstance(audio.get("bytes"), bytes) or not 1 <= len(audio["bytes"]) <= MAX_AUDIO:
            raise Failure("worker_audio_bound")
        raw_reference = None if reference is None else reference.encode("utf-8") if isinstance(reference, str) else None
        if request["with_reference"] and (raw_reference is None or not 1 <= len(raw_reference) <= MAX_REFERENCE):
            raise Failure("worker_reference_bound")
        check(pool)
        assets = {"audio.original.bin": audio["bytes"]}
        if raw_reference is not None: assets["reference.original.txt"] = raw_reference
        for name, data in assets.items():
            with (output / name).open("xb") as stream: stream.write(data)
        check(pool)
        result.update(passed=True, source_uncompressed_bytes=unpacked,
                      assets={name: {"bytes": len(data), "sha256": digest(data)} for name, data in assets.items()})
    except BaseException as error:
        result["error"] = {"type": type(error).__name__, "reason": str(error) if isinstance(error, Failure) else "worker_interrupted_or_failed"}
    finally:
        iterator = batch = None
        if parquet is not None: parquet.close()
        if mapped is not None: mapped.close()
        result["memory"] = observed
        raw = (json.dumps(result, indent=2) + "\n").encode()
        if len(raw) > MAX_WORKER_JSON: raise Failure("worker_result_bound")
        with (output / "result.json").open("xb") as stream: stream.write(raw)
    return 0 if result["passed"] else 1


class ParquetRows:
    """Optional dependency is imported only when real acquisition reads Parquet."""
    def __init__(self, acquisition, source, file):
        try:
            import pyarrow as pa
            import pyarrow.parquet as pq
        except ImportError as error:
            raise Failure("optional_pyarrow_required_for_acquisition") from error
        self.acquisition, self.source, self.file = acquisition, source, file
        self.arrow, self.parquet_module = pa, pq
        self.remote = RangeFile(acquisition, pinned_url(source, file["path"]), file["bytes"], file.get("etag"))
        self._footer_start = None
        self._base_intervals()  # Reject oversized/malformed footers before Arrow allocates.
        self.parquet = pq.ParquetFile(self.remote, buffer_size=MAX_RANGE, pre_buffer=False)
        self.columns = set(self.parquet.schema_arrow.names)
        self.kind = KINDS[source["kind"]]
        self._selected_key = self._selected_iterator = self._selected_batch = None
        self._selected_file = self._selected_mmap = None
        self._selected_offset = -1
        required = {"audio", self.kind["reference"], *self.kind["metadata"]}
        if not required <= self.columns or not 1 <= self.parquet.metadata.num_row_groups <= 10000:
            raise Failure("parquet_schema_or_group_bound")

    def _base_intervals(self):
        if self._footer_start is None:
            self.remote.seek(0)
            if self.remote.read(4) != b"PAR1": raise Failure("parquet_header_magic")
            self.remote.seek(-8, io.SEEK_END)
            tail = self.remote.read(8)
            if len(tail) != 8 or tail[4:] != b"PAR1": raise Failure("parquet_footer_magic")
            length = int.from_bytes(tail[:4], "little")
            if not 1 <= length <= MAX_METADATA or length + 12 > self.remote.size:
                raise Failure("parquet_footer_size")
            self._footer_start = self.remote.size - 8 - length
        return [(0, 4), (self._footer_start, self.remote.size)]

    def transport_preflight(self, selections):
        """Metadata-only required-chunk cost; no audio/reference bytes fetched.

        Each pair is(row_group,with_reference). The resulting unique chunk cost
        includes whole compressed leaf chunks even for just one selected row.
        Summing per-file/source profiles is a conservative job transfer estimate.
        It excludes already-accounted discovery/card requests and must fit within
        the prospective network budget with room for those bounded operations.
        """
        selections = list(selections)
        required = self._base_intervals()
        groups, maximum_unpacked = [], 0
        for group, with_reference in sorted(set(selections)):
            if type(group) is not int or not 0 <= group < self.parquet.metadata.num_row_groups or type(with_reference) is not bool:
                raise Failure("transport_selection_group")
            columns = ["audio"] + ([self.kind["reference"]] if with_reference else [])
            intervals, unpacked = parquet_chunk_intervals(self.parquet.metadata, group, columns, self._footer_start)
            required += intervals
            maximum_unpacked = max(maximum_unpacked, unpacked)
            groups.append({"row_group": group, "columns": columns, "source_uncompressed_bytes": unpacked})
        intervals = merged_intervals(required)
        if self.source["kind"] in self.acquisition.plan.get("isolated_decoder_limits", {}):
            for group, _with_reference in selections:
                metadata = self.parquet.metadata.row_group(group)
                for index in range(metadata.num_columns):
                    column = metadata.column(index)
                    if column.path_in_schema.split(".")[0] in {"audio", self.kind["reference"]} and not 0 <= column.total_uncompressed_size <= MAX_SELECTED_COLUMN:
                        raise Failure("prospective_selected_column_uncompressed_bound")
        return {"url": self.remote.url, "file": self.file["path"], "declared_file_bytes": self.remote.size,
            "etag": self.remote.etag, "required_ranges": intervals,
            "required_transport_bytes": sum(end - start for start, end in intervals),
            "physical_allocation_upper_bound": allocation_bound(intervals),
            "maximum_source_row_group_uncompressed_bytes": maximum_unpacked,
            "groups": groups, "audio_or_reference_columns_read": False,
            "strategy": "sparse-mmap-v1", "whole_file_sha256_verified": False}

    def _table(self, group, columns, maximum):
        self.acquisition.check()
        metadata = self.parquet.metadata.row_group(group)
        if not 1 <= metadata.num_rows <= 100000:
            raise Failure("parquet_row_group_rows")
        unpacked = sum(metadata.column(i).total_uncompressed_size for i in range(metadata.num_columns)
                       if metadata.column(i).path_in_schema.split(".")[0] in columns)
        if unpacked < 0 or unpacked > maximum:
            raise Failure("parquet_row_group_memory_bound")
        table = self.parquet.read_row_group(group, columns=columns, use_threads=False)
        if table.nbytes > maximum:
            raise Failure("parquet_materialized_memory_bound")
        self.acquisition.check()
        return table

    def metadata_rows(self):
        read = 0
        for group in range(self.parquet.metadata.num_row_groups):
            if self._selected_key is not None and self._selected_key[0] != group:
                self._clear_selected()
            table = self._table(group, self.kind["metadata"], MAX_METADATA)
            for offset, row in enumerate(table.to_pylist()):
                self.acquisition.check()
                read += 1
                if read > self.source.get("max_metadata_rows", 20000):
                    return
                yield group, offset, row

    def selected(self, group, offset, with_reference):
        columns = ["audio"] + ([self.kind["reference"]] if with_reference else [])
        key = (group, tuple(columns))
        metadata = self.parquet.metadata.row_group(group)
        if type(offset) is not int or not 0 <= offset < metadata.num_rows:
            raise Failure("selected_row_outside_source_group")
        if self.source["kind"] in self.acquisition.plan.get("isolated_decoder_limits", {}):
            return self._isolated_selected(group, offset, with_reference)
        if self._selected_key != key:
            self._clear_selected()
            profile = self.transport_preflight([(group, with_reference)])
            if self.acquisition.transport is None:
                self.acquisition.transport = SparseTransport(self.acquisition)
            path = self.acquisition.transport.stage(self.remote, profile["required_ranges"])
            self._selected_mmap = self.arrow.memory_map(str(path), "r")
            self._selected_file = self.parquet_module.ParquetFile(self._selected_mmap, pre_buffer=False, buffer_size=0)
            self._selected_iterator = self._selected_file.iter_batches(batch_size=1, row_groups=[group], columns=columns,
                                                                      use_threads=False)
            self._selected_key = key
        elif offset < self._selected_offset:
            raise Failure("selected_rows_must_advance")
        while self._selected_offset < offset:
            self.acquisition.check()
            # Drop the previous batch before requesting another decoder allocation.
            self._selected_batch = None
            try:
                batch = next(self._selected_iterator)
            except StopIteration as error:
                raise Failure("selected_row_group_truncated") from error
            self.acquisition.check()
            if batch.num_rows != 1:
                raise Failure("materialized_batch_progress_bound")
            if not 0 <= batch.nbytes <= MAX_ROW_GROUP:
                raise MemoryBound("materialized_batch_memory_bound")
            self._observe_memory()
            self._selected_batch = batch
            self._selected_offset += 1
        table = self._selected_batch
        audio = table.column("audio")[0].as_py()
        reference = table.column(self.kind["reference"])[0].as_py() if with_reference else None
        return audio, reference

    def _isolated_selected(self, group, offset, with_reference):
        acquisition = self.acquisition
        if shutil.disk_usage(acquisition.root).free < 20 * GIB: raise Failure("source_free_disk_bound")
        profile = self.transport_preflight([(group, with_reference)])
        if acquisition.transport is None: acquisition.transport = SparseTransport(acquisition)
        path = acquisition.transport.stage(self.remote, profile["required_ranges"])
        maximum = MAX_AUDIO + (MAX_REFERENCE if with_reference else 0) + 2 * MAX_WORKER_JSON
        physical = os.fstat(acquisition.transport.stream.fileno()).st_blocks * 512
        if physical + maximum + 4 * 65536 > acquisition.transport.maximum:
            raise Failure("worker_transport_physical_preflight_bound")
        acquisition.reserve(maximum)
        number = len([item for item in acquisition.transport_events if item.get("event") == "owned_decoder_worker"]) + 1
        scratch = acquisition.transport.directory / ("worker-" + str(number))
        scratch.mkdir(mode=0o700)
        limits = acquisition.plan["isolated_decoder_limits"][self.source["kind"]]
        request = {"kind": self.source["kind"], "limits": limits, "mmap_path": str(path),
            "logical_file_bytes": self.remote.size, "footer_start": self._footer_start,
            "staged_ranges": acquisition.transport.present, "row_group": group, "row_in_group": offset,
            "with_reference": with_reference, "deadline_monotonic": acquisition.deadline,
            "deadline_utc_seconds": acquisition.deadline_utc_seconds}
        raw_request = (json.dumps(request, indent=2) + "\n").encode()
        if len(raw_request) > MAX_WORKER_JSON: raise Failure("worker_request_bound")
        request_path = scratch / "request.json"
        with request_path.open("xb") as stream: stream.write(raw_request)
        failure = None
        retained = {}
        try:
            try:
                acquisition.run_command([sys.executable, str(Path(__file__).resolve()), "--decode-mmap-worker", str(request_path), str(scratch)],
                    120, maximum_rss_bytes=limits["process_rss_bytes"], sidecar_directory=scratch, maximum_sidecar_bytes=maximum)
            except BaseException as error:
                failure = error
        finally:
            allowed = {"request.json": MAX_WORKER_JSON, "result.json": MAX_WORKER_JSON,
                       "audio.original.bin": MAX_AUDIO, "reference.original.txt": MAX_REFERENCE if with_reference else 0}
            total = 0
            copied = 0
            try:
                for candidate in scratch.iterdir():
                    if candidate.is_symlink() or not candidate.is_file() or candidate.name not in allowed:
                        raise Failure("worker_sidecar_type")
                    size = candidate.stat().st_size
                    total += size
                    if not 0 <= size <= allowed[candidate.name] or total > maximum:
                        raise Failure("worker_sidecar_bound")
                    raw = candidate.read_bytes()
                    retained[candidate.name] = raw
                    protected = acquisition.root / "decoder-sidecars" / ("worker-" + str(number)) / candidate.name
                    protected.parent.mkdir(parents=True, exist_ok=True)
                    # The complete maximum was reserved before starting the child.
                    with protected.open("xb") as stream: stream.write(raw)
                    if protected.stat().st_size != len(raw) or digest(protected.read_bytes()) != digest(raw):
                        raise Failure("protected_worker_copy_hash")
                    copied += len(raw)
                    candidate.unlink()
                acquisition.output_bytes -= maximum - copied
            except BaseException:
                acquisition.transport.preserve_recovery("sidecar_validation_or_protected_copy_failed")
                raise
            finally:
                if not any(scratch.iterdir()): scratch.rmdir()
        result = json.loads(retained.get("result.json", b"{}"))
        acquisition.transport_events.append({"event": "owned_decoder_worker", "number": number, "source": self.source["id"],
            "row_group": group, "row_in_group": offset, "limits": limits, "result_passed": result.get("passed") is True,
            "source_use_review": "pending", "recognition_performed": False})
        if not result and failure is not None: raise failure
        memory = result.get("memory", {})
        for field in ("maximum_observed_arrow_bytes", "maximum_reported_arrow_pool_peak_bytes", "process_peak_rss_bytes"):
            value = memory.get(field)
            integer(value, 1 if field == "process_peak_rss_bytes" else 0, 1 << 48, "worker_memory_measurement_missing")
            acquisition.decoder_memory[field] = max(acquisition.decoder_memory.get(field) or 0, value)
        if max(memory["maximum_observed_arrow_bytes"], memory["maximum_reported_arrow_pool_peak_bytes"]) > limits["observed_arrow_bytes"] or memory["process_peak_rss_bytes"] > limits["process_rss_bytes"]:
            raise MemoryBound("isolated_worker_memory_bound")
        if failure is not None: raise failure
        if result.get("passed") is not True: raise Failure("worker_source_decode_failed")
        expected = {"audio.original.bin"} | ({"reference.original.txt"} if with_reference else set())
        if set(result.get("assets", {})) != expected: raise Failure("worker_result_assets")
        for name in expected:
            raw = retained.get(name)
            proof = result["assets"][name]
            if raw is None or proof.get("bytes") != len(raw) or proof.get("sha256") != digest(raw):
                raise Failure("worker_asset_hash_or_length")
        return {"bytes": retained["audio.original.bin"]}, retained["reference.original.txt"].decode("utf-8") if with_reference else None

    def _clear_selected(self):
        self._selected_key = self._selected_iterator = self._selected_batch = None
        self._selected_offset = -1
        if self._selected_file is not None:
            self._selected_file.close(); self._selected_file = None
        if self._selected_mmap is not None:
            self._selected_mmap.close(); self._selected_mmap = None

    def close(self):
        self._clear_selected()
        self.parquet.close()
        self.remote.close()

    def _observe_memory(self):
        pool = self.arrow.default_memory_pool()
        allocated, peak = pool.bytes_allocated(), pool.max_memory()
        observed = self.acquisition.decoder_memory
        if allocated < 0 or peak < 0:
            raise Failure("arrow_pool_measurement_unavailable")
        observed["maximum_observed_arrow_bytes"] = max(observed["maximum_observed_arrow_bytes"], allocated)
        observed["maximum_reported_arrow_pool_peak_bytes"] = max(observed["maximum_reported_arrow_pool_peak_bytes"], peak)
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        observed["process_peak_rss_bytes"] = max(observed["process_peak_rss_bytes"] or 0, rss if sys.platform == "darwin" else rss * 1024)
        if allocated > MAX_ROW_GROUP or peak > MAX_ROW_GROUP:
            raise MemoryBound("observed_arrow_pool_memory_bound")


def identity(source, row):
    kind = KINDS[source["kind"]]
    raw_id = row.get(kind["id"])
    if not safe_text(raw_id, 1024):
        raise Failure("source_row_identity")
    namespace = kind["namespace"] + (":" + source["config"] if source["kind"] == "casablanca" else "")
    source_id = namespace + ":" + raw_id
    grouping = source.get("grouping", {})
    parent = raw_id
    if grouping:
        parts = raw_id.split(grouping["parent_separator"])
        if len(parts) < grouping["parent_parts"]:
            raise Failure("declared_grouping_does_not_match_source")
        parent = grouping["parent_separator"].join(parts[:grouping["parent_parts"]])
    parent_id = namespace + ":parent:" + parent
    raw_speaker = row.get(kind["speaker"]) if kind["speaker"] else None
    if raw_speaker is None or isinstance(raw_speaker, str) and raw_speaker.strip().casefold() in {"", "none", "null", "unknown", "nan", "n/a"}:
        speakers = []
    elif isinstance(raw_speaker, (str, int)) and not isinstance(raw_speaker, bool) and len(str(raw_speaker)) <= 160:
        speakers = [namespace + ":speaker:" + str(raw_speaker)]
    else:
        raise Failure("published_speaker_identity")
    return {"id": "real-" + source["language"] + "-" + digest(source_id.encode())[:24],
            "source_id": source_id, "published_source_id": raw_id,
            "source_group_ids": [parent_id], "speaker_ids": speakers,
            "session_id": parent_id if grouping.get("session_from_parent") else None,
            "grouping_review": "declared source-parent rule; publisher IDs only; real identities and sessions not independently verified"}


def rejection(acquisition, item, audio_hash=None, reference_hash=None):
    reasons = acquisition.exclusions.reasons(item["id"], item["source_id"], audio_hash, reference_hash,
                                            item["speaker_ids"], item["session_id"])
    if set(item["source_group_ids"]) & acquisition.exclusions.values["parent"]:
        reasons.append("source_parent")
    if item["published_source_id"] in acquisition.exclusions.values["id"] or item["published_source_id"] in acquisition.exclusions.values["source_id"]:
        reasons.append("published_source")
    return reasons


def audio_extension(data):
    if data.startswith(b"RIFF") and data[8:12] == b"WAVE": return "wav"
    if data.startswith(b"fLaC"): return "flac"
    if data.startswith(b"OggS"): return "ogg"
    if data.startswith(b"ID3") or data[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"): return "mp3"
    raise Failure("unsupported_original_audio")


def probe_audio(acquisition, path, extension):
    if extension in ("wav", "flac"):
        frames, rate, channels = fresh.source_layout(path.read_bytes(), extension)
        return {"duration_seconds": frames / rate, "source_frames": frames, "source_sample_rate": rate, "source_channels": channels}
    result = acquisition.run_command(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type,sample_rate,channels", "-of", "json", str(path)], 8, capture=True)
    value = json.loads(result)
    streams = value.get("streams", [])
    if len(streams) != 1 or streams[0].get("codec_type") != "audio":
        raise Failure("original_audio_stream_layout")
    return {"duration_seconds": float(value["format"]["duration"]), "source_frames": None,
            "source_sample_rate": int(streams[0]["sample_rate"]), "source_channels": int(streams[0]["channels"])}


def prepare_selected(acquisition, source, item, audio, reference, pointer):
    if not isinstance(audio, dict) or not isinstance(audio.get("bytes"), bytes) or not 1 <= len(audio["bytes"]) <= MAX_AUDIO:
        raise Failure("embedded_audio_bytes_bound")
    data = audio["bytes"]
    resource = source["split"] == "resource"
    if not resource and (not isinstance(reference, str) or not 1 <= len(reference.encode("utf-8")) <= MAX_REFERENCE):
        raise Failure("raw_reference_bytes_bound")
    ref = None if resource else reference.encode("utf-8")
    reasons = rejection(acquisition, item, digest(data), digest(ref) if ref is not None else None)
    if reasons:
        acquisition.skipped.update(reasons)
        return None
    folder = acquisition.root / source["split"] / item["id"]
    extension = audio_extension(data)
    original, prepared = folder / ("source.original." + extension), folder / "benchmark.pcm16.wav"
    acquisition.save(original, data)
    if ref is not None:
        acquisition.save(folder / "reference.original.txt", ref)
    layout = probe_audio(acquisition, original, extension)
    duration = layout["duration_seconds"]
    project_channel = resource and source.get("kind") == "casablanca" and source.get("resource_channel") == 0 and layout["source_channels"] == 2
    if not math.isfinite(duration) or not 2 <= duration <= (600 if resource else 60) or (layout["source_channels"] != 1 and not project_channel) or not 1 <= layout["source_sample_rate"] <= 384000:
        acquisition.skipped["duration_or_mono_source_policy"] += 1
        acquisition.json(folder / "REJECTED.json", {"reason": "duration_or_mono_source_policy", "observed_layout": layout,
            "originals_retained": True, "recognition_performed": False})
        return None
    # Explicit projection is reference-free resources only; it never downmixes.
    seconds = min(duration, 20) if resource else duration
    maximum = math.ceil(seconds * 16000) * 2 + 8192
    acquisition.reserve(maximum)
    command = ["ffmpeg", "-nostdin", "-v", "error", "-n", "-threads", "1", "-i", str(original), "-t", str(seconds)]
    if project_channel: command += ["-af", "pan=mono|c0=c0"]
    command += ["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(prepared)]
    acquisition.run_command(command, 30 if resource else 45, target=prepared, maximum_bytes=maximum)
    with wave.open(str(prepared), "rb") as stream:
        if (stream.getnchannels(), stream.getsampwidth(), stream.getframerate()) != (1, 2, 16000):
            raise Failure("prepared_PCM_layout")
        measured = stream.getnframes() / 16000
    if not 0 < measured <= seconds + .1:
        raise Failure("prepared_duration")
    if layout["source_frames"] is not None and abs(measured - seconds) > .001:
        raise Failure("prepared_duration_does_not_match_source_frames")
    derived_hash = digest(prepared.read_bytes())
    if derived_hash in acquisition.exclusions.values["audio"]:
        acquisition.skipped["prepared_audio"] += 1
        acquisition.json(folder / "REJECTED.json", {"reason": "prior_prepared_audio_hash", "originals_retained": True})
        return None
    case = {**item, "language": source["language"], "split": source["split"], "task": "standard_rendering" if source["language"] == "de-CH" else "transcription",
            "category": "real-world-published-reference-pending-review" if not resource else "reference-free-real-world-resource",
            "audio": str(prepared), "sha256": derived_hash, "original_audio": str(original), "original_audio_sha256": digest(data),
            "duration_seconds": measured, "source_channel": 0, "source_interval_seconds": [0, measured],
            "variety": source["variety"], "script": source["script"], "conditions": source["conditions"],
            "source_url": pointer["url"], "license": source["license"], "source_use_review": "pending",
            "reviewed": False, "evaluation_tier": "realworld_exploratory_not_v2_approved",
            "reference_conventions": "Exact publisher field; no independent content/timing/native adjudication" if not resource else "Reference-free resource run",
            "scoring_policy": fresh.POLICY}
    if ref is not None:
        case.update(reference=str(folder / "reference.original.txt"), reference_sha256=digest(ref))
    else:
        case["measurement_scope"] = "resources_only"
        if project_channel:
            case["channel_view"] = {"original_channels": 2, "selected_physical_channel": 0, "mixing": False,
                                    "independent_channel_quality_assessed": False, "reference_applicability_claimed": False}
    provenance = {"source_row": pointer, "dataset": source["dataset"], "dataset_revision": source["revision"],
                  "dataset_config": source["config"], "dataset_split": source["source_split"], **layout,
                  "original_audio_sha256": digest(data), "reference_sha256": digest(ref) if ref is not None else None,
                  "prepared_audio_sha256": derived_hash, "channel_preparation": "Explicit reference-free resource physical-channel0 projection; original stereo preserved; no downmix" if project_channel else "verified mono original; no mixing",
                  "source_audio_modified": False, "conversion_command": command,
                  "conversion_tool": converter_version(acquisition), "reference_field": None if resource else KINDS[source["kind"]]["reference"],
                  "source_use_review": "pending", "reference_review": "not_performed", "human_approval": False}
    acquisition.json(folder / "provenance.json", provenance)
    case["provenance"] = str(folder / "provenance.json")
    acquisition.cases.append(case)
    acquisition.exclusions.add(case)
    return case


def converter_version(acquisition):
    if acquisition.converter_version is None:
        value = acquisition.run_command(["ffmpeg", "-version"], 5, capture=True)
        lines = value.decode("utf-8", errors="replace").splitlines()
        if not lines or not lines[0].strip(): raise Failure("converter_version_unavailable")
        acquisition.converter_version = lines[0]
    return acquisition.converter_version


def import_development(acquisition, metadata_only=False):
    """Read-only reuse of verified prepared source inputs, never ASR evidence."""
    for declared in acquisition.plan.get("reuse_development", []):
        path = fresh.safe(declared["manifest"])
        if not path.is_file() or path.stat().st_size > 4 * MIB:
            raise Failure("reuse_manifest_bound")
        raw = path.read_bytes()
        if digest(raw) != declared["sha256"]: raise Failure("reuse_manifest_hash")
        document = json.loads(raw)
        cases = document.get("cases")
        if document.get("split") != "development" or document.get("recognition_performed") is not False or not isinstance(cases, list) or not 1 <= len(cases) <= 18:
            raise Failure("reuse_source_preparation_only")
        imported = []
        for case in cases:
            acquisition.check()
            if case.get("split") != "development" or case.get("language") not in acquisition.plan["languages"] or case.get("reviewed") is not False:
                raise Failure("reuse_development_partition")
            folder = fresh.safe(case.get("audio", "")).parent
            try: folder.relative_to(path.parent)
            except ValueError as error: raise Failure("reuse_paths_outside_source_manifest") from error
            provenance_path = fresh.safe(case.get("provenance", ""))
            if provenance_path.parent != folder or provenance_path.stat().st_size > MIB:
                raise Failure("reuse_provenance_bound")
            provenance = json.loads(provenance_path.read_bytes())
            matches = [source for source in acquisition.plan["sources"] if source["split"] == "development" and
                source["language"] == case["language"] and source["dataset"] == provenance.get("dataset") and
                source["revision"] == provenance.get("dataset_revision") and source["config"] == provenance.get("dataset_config") and
                source["source_split"] == provenance.get("dataset_split")]
            pointer = provenance.get("source_row", {})
            if not matches or not any(pointer.get("url") == pinned_url(source, file["path"]) for source in matches for file in source["files"]):
                raise Failure("reuse_pinned_source_identity")
            if case.get("id") != "real-" + case["language"] + "-" + digest(case.get("source_id", "").encode())[:24]:
                raise Failure("reuse_case_identity")
            originals = list(folder.glob("source.original.*"))
            if len(originals) != 1: raise Failure("reuse_original_identity")
            required = [(fresh.safe(case["audio"]), case.get("sha256"), MAX_AUDIO),
                        (fresh.safe(case.get("reference", "")), case.get("reference_sha256"), MAX_REFERENCE),
                        (fresh.safe(originals[0]), case.get("original_audio_sha256"), MAX_AUDIO)]
            for asset, expected, maximum in required:
                if asset.parent != folder or not re.fullmatch(r"[0-9a-f]{64}", expected or "") or not 1 <= asset.stat().st_size <= maximum or digest(asset.read_bytes()) != expected:
                    raise Failure("reuse_asset_hash_or_bound")
            if rejection(acquisition, case, case["original_audio_sha256"], case["reference_sha256"]):
                raise Failure("reuse_prior_exclusion_conflict")
            records = acquisition.selected if metadata_only else acquisition.cases
            if sum(v["split"] == "development" and v["language"] == case["language"] for v in records) >= 2:
                raise Failure("reuse_development_count")
            acquisition.exclusions.add(case)
            if metadata_only:
                acquisition.selected.append({**{key: case[key] for key in ("id", "source_id", "source_group_ids", "speaker_ids", "session_id", "language", "split")},
                                             "source_row": pointer, "reused_source_preparation": True})
            else:
                acquisition.cases.append(case)
            imported.append({"id": case["id"], "language": case["language"], "original_audio_sha256": case["original_audio_sha256"],
                             "prepared_audio_sha256": case["sha256"], "reference_sha256": case["reference_sha256"]})
        acquisition.reused_development.append({"manifest": str(path), "sha256": digest(raw), "cases": imported,
            "source_inputs_only": True, "prior_source_evidence_modified": False, "recognition_performed": False})


def collect_source(acquisition, source, table_factory=ParquetRows, metadata_only=False):
    target = acquisition.plan["counts_per_language"][source["split"]]
    def completed():
        records = acquisition.selected if metadata_only else acquisition.cases
        return sum(v["language"] == source["language"] and v["split"] == source["split"] for v in records)
    for file in source["files"]:
        if completed() >= target: break
        rows = table_factory(acquisition, source, file)
        groups = set()
        try:
            for group, offset, row in rows.metadata_rows():
                acquisition.check()
                if completed() >= target: break
                if source["kind"] == "voxpopuli" and row.get("is_gold_transcript") is not True:
                    acquisition.skipped["not_publisher_gold"] += 1
                    continue
                if source["kind"] == "casablanca" and type(row.get("duration")) in (int, float):
                    duration = row["duration"]
                    if not math.isfinite(duration) or not 2 <= duration <= (600 if source["split"] == "resource" else 60):
                        acquisition.skipped["published_duration_outside_bound"] += 1
                        continue
                item = identity(source, row)
                if source.get("selected_source_id") and item["source_id"] != source["selected_source_id"]:
                    acquisition.skipped["not_prospective_resource_source"] += 1
                    continue
                reasons = rejection(acquisition, item)
                if reasons:
                    acquisition.skipped.update(reasons)
                    continue
                pointer = {"url": pinned_url(source, file["path"]), "declared_file_bytes": file["bytes"],
                           "file": file["path"], "row_group": group, "row_in_group": offset,
                           "whole_file_sha256_verified": False, "identity_scope": "pinned HF revision, exact ranges/length and stable provider ETag"}
                groups.add((group, source["split"] != "resource"))
                if metadata_only:
                    acquisition.selected.append({**item, "language": source["language"], "split": source["split"], "source_row": pointer})
                    acquisition.exclusions.add(item)
                    continue
                audio, reference = rows.selected(group, offset, source["split"] != "resource")
                prepare_selected(acquisition, source, item, audio, reference, pointer)
            if groups and hasattr(rows, "transport_preflight"):
                acquisition.transport_preflights.append({"source": source["id"], **rows.transport_preflight(groups)})
        finally:
            if hasattr(rows, "close"): rows.close()


def run(plan, output, exclusion_paths, table_factory=ParquetRows, opener=None, priority_probe=default_priority_probe,
        metadata_only=False, install_signals=False):
    validate_plan(plan)
    root = fresh.safe(output)
    # A frozen external recipe has a different parent layout. Detect actual Git
    # checkouts instead of mistaking the protected campaign root for the repo.
    repositories = set()
    for location in (Path.cwd().resolve(), Path(__file__).resolve().parent, root):
        repositories.update(parent for parent in (location, *location.parents) if (parent / ".git").exists())
    if any(root == repo or repo in root.parents for repo in repositories):
        raise Failure("protected_output_outside_checkout_required")
    exclusions = Exclusions()
    for path in exclusion_paths:
        exclusions.load(path)
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    acquisition = Acquisition(root, plan, exclusions, opener, priority_probe)
    old_handlers = {}
    if install_signals:
        for number in (signal.SIGINT, signal.SIGTERM):
            old_handlers[number] = signal.getsignal(number)
            signal.signal(number, lambda observed, _frame: setattr(acquisition, "interrupted_signal", observed))
    try:
        acquisition.json(root / "plan.original.json", plan)
        acquisition.save(root / "recipe/acquire-realworld.executed.py", Path(__file__).read_bytes())
        import_development(acquisition, metadata_only)
        saved_cards = set()
        for source in plan["sources"]:
            key = (source["dataset"], source["revision"])
            if key not in saved_cards:
                card = acquisition.fetch(pinned_url(source, "README.md"))
                acquisition.save(root / "sources" / source["id"] / "README.original.md", card)
                saved_cards.add(key)
        for split in SPLITS:
            for source in plan["sources"]:
                if source["split"] != split: continue
                if split != "resource" and source["language"] in plan.get("quality_pending_languages", []): continue
                try:
                    collect_source(acquisition, source, table_factory, metadata_only)
                except (InterruptedError, TimeoutError, MemoryBound):
                    raise
                except (Failure, OSError, ValueError) as error:
                    acquisition.errors.append({"source": source["id"], "error_type": type(error).__name__,
                                               "reason": str(error) if isinstance(error, Failure) else "source_acquisition_failed"})
    except BaseException as error:
        acquisition.errors.append({"error_type": type(error).__name__, "reason": str(error) if isinstance(error, Failure) else "acquisition_interrupted_or_failed"})
    finally:
        for number, handler in old_handlers.items(): signal.signal(number, handler)
        if acquisition.transport is not None:
            try: acquisition.transport.close()
            except (OSError, Failure): acquisition.errors.append({"reason": "transport_cleanup_failed"})
        manifests = []
        for split in SPLITS:
            cases = [v for v in acquisition.cases if v["split"] == split]
            document = {"schema_version": "1.0", "corpus_version": plan["corpus_version"] + "-" + split,
                        "frozen": False, "evaluation_tier": "realworld_exploratory_not_v2_approved", "split": split,
                        "cases": cases, "recognition_performed": False, "human_review_performed": False,
                        "source_use_review": "pending", "reference_text_displayed": False,
                        "speaker_session_independence": "publisher/declarative groups only; independent verification pending",
                        "errors": acquisition.errors}
            path = root / split / "manifest.exploratory.legacy.json"
            acquisition.json(path, document, final=True)
            manifests.append({"split": split, "path": str(path), "sha256": digest(path.read_bytes()),
                              "counts": {language: sum(v["language"] == language for v in cases) for language in plan["languages"]}})
        if metadata_only: acquisition.json(root / "selection.metadata.json", {"selected": acquisition.selected, "audio_or_reference_columns_read": False}, final=True)
        selected = acquisition.selected if metadata_only else acquisition.cases
        counts = {split: {language: sum(v["split"] == split and v["language"] == language for v in selected) for language in plan["languages"]} for split in SPLITS}
        complete = all(n == plan["counts_per_language"][split] for split, languages in counts.items() for n in languages.values())
        acquisition.json(root / "acquisition.receipt.json", {"schema_version": VERSION, "created_utc": datetime.now(timezone.utc).isoformat(),
            "plan_sha256": digest((root / "plan.original.json").read_bytes()), "metadata_only": metadata_only,
            "complete_requested_selection": complete, "counts": counts, "network_bytes": acquisition.network_bytes,
            "reserved_output_bytes": acquisition.output_bytes, "budgets": plan["budgets"], "requests": acquisition.requests,
            "deadline_utc_seconds": acquisition.deadline_utc_seconds,
            "decoder_memory_observations": acquisition.decoder_memory,
            "transport_preflights": acquisition.transport_preflights, "transport_events": acquisition.transport_events,
            "reused_development": acquisition.reused_development,
            "exclusion_manifests": exclusions.manifests, "skip_counts": dict(acquisition.skipped), "errors": acquisition.errors,
            "manifests": manifests, "source_use_review": "pending", "human_review_performed": False,
            "reference_text_displayed": False, "recognition_performed": False,
            "missing_counts_remain_pending": True, "inference_retries": 0}, final=True)
    return acquisition, complete and not acquisition.errors


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--exclude-manifest", action="append", type=Path, default=[])
    parser.add_argument("--metadata-only", action="store_true")
    parser.add_argument("--validate-plan", action="store_true")
    args = parser.parse_args(argv)
    if not args.validate_plan and (args.output is None or not args.exclude_manifest):
        parser.error("Actual/metadata acquisition requires NEW --output and explicit --exclude-manifest")
    return args


def main(argv=None):
    actual = list(sys.argv[1:] if argv is None else argv)
    if actual and actual[0] == "--decode-mmap-worker":
        if len(actual) != 3: raise Failure("worker_cli_arguments")
        return decode_mmap_worker(Path(actual[1]), Path(actual[2]))
    args = arguments(argv)
    with args.plan.open("rb") as stream: raw = stream.read(MIB + 1)
    if len(raw) > MIB: raise Failure("plan_size")
    plan = validate_plan(json.loads(raw))
    if args.validate_plan:
        print(json.dumps({"valid": True, "schema_version": VERSION, "recognition_performed": False}))
        return 0
    acquisition, passed = run(plan, args.output, args.exclude_manifest, metadata_only=args.metadata_only,
        priority_probe=default_priority_probe, install_signals=True)
    print(json.dumps({"output": str(acquisition.root), "complete_requested_selection": passed,
                      "network_bytes": acquisition.network_bytes, "recognition_performed": False, "human_approval": False}))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
