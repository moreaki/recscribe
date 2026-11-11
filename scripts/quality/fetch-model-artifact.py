#!/usr/bin/env python3
"""Fetch exact anonymous Hugging Face assets into a NEW protected directory.

No inference, model imports, publication, credentials, resume, or retry. Plans
bind repository URL, full revision, remote/local path, exact bytes and SHA-256.
Interrupted files and all completed receipts remain retained. Use the managed
work-artifacts wrapper for logs and an explicit external location for assets.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MAX_BYTES = 8 * 1024 ** 3
RATE_BYTES = 8 * 1024 ** 2
DISK_RESERVE = 20 * 1024 ** 3
MAX_PLAN = 1024 ** 2
MAX_HEADERS = 65536
MAX_FILES = 128
MAX_REDIRECTS = 5
CHUNK_BYTES = 65536
SOCKET_TIMEOUT = 2.0
MAX_SECONDS = 6 * 3600


class DownloadError(Exception):
    """A bounded public reason code, never a remote body or signed URL."""


class Cancelled(DownloadError):
    pass


class Deadline(DownloadError):
    pass


def fail(code):
    raise DownloadError(code)


def positive_integer(value, maximum):
    return type(value) is int and 0 < value <= maximum


def safe_absolute(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts or any(p.is_symlink() for p in (path, *path.parents)):
        fail("unsafe_absolute_path")
    return path


def relative_file(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 512 or not re.fullmatch(r"[A-Za-z0-9._/-]+", value):
        fail("unsafe_relative_file")
    parts = value.split("/")
    if value.startswith("/") or len(parts) > 16 or any(p in ("", ".", "..") for p in parts):
        fail("unsafe_relative_file")
    return PurePosixPath(value)


def repo_url(value, repo_type="model"):
    if not isinstance(value, str) or len(value) > 256:
        fail("unsafe_repository_url")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "https" or parsed.netloc != "huggingface.co" or parsed.query or parsed.fragment:
        fail("unsafe_repository_url")
    if repo_type not in ("model", "dataset"):
        fail("unsupported_repository_type")
    path = parsed.path
    if repo_type == "dataset" and not path.startswith("/datasets/"):
        path = "/datasets" + path
    prefix = "/datasets" if repo_type == "dataset" else ""
    if not re.fullmatch(prefix + r"/[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}", path):
        fail("unsafe_repository_url")
    return "https://huggingface.co" + path


def validate_headers(headers):
    size = 0
    for key, value in headers.items():
        size += len(str(key).encode("utf-8")) + len(str(value).encode("utf-8")) + 4
        if size > MAX_HEADERS:
            fail("response_headers_exceed_bound")


def redirect_url(value):
    if not isinstance(value, str) or len(value) > 16384:
        fail("unsafe_redirect_url")
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError:
        fail("unsafe_redirect_url")
    host = parsed.hostname or ""
    if parsed.scheme != "https" or port not in (None, 443) or parsed.username or parsed.password or parsed.fragment:
        fail("unsafe_redirect_url")
    if not any(host == domain or host.endswith("." + domain) for domain in ("huggingface.co", "hf.co", "cloudfront.net")):
        fail("redirect_host_not_allowed")
    return parsed


class Redirects(urllib.request.HTTPRedirectHandler):
    def __init__(self, check):
        super().__init__()
        self.check = check
        self.count = 0

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.check()
        validate_headers(headers)
        redirect_url(newurl)
        self.count += 1
        if self.count > MAX_REDIRECTS:
            fail("redirect_limit_exceeded")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def opener_for(check):
    # Explicitly disable environment proxies; no token store, .netrc or user
    # authorization is consulted. Server-issued signed HF redirects are normal.
    redirects = Redirects(check)
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), redirects)


def write_bytes(path, data):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags, 0o600), "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def write_json(path, value):
    write_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def reason(exc):
    if isinstance(exc, DownloadError):
        return str(exc)
    if isinstance(exc, urllib.error.HTTPError):
        return "http_error_" + str(exc.code)
    if isinstance(exc, (TimeoutError, urllib.error.URLError)):
        return "network_error_or_socket_timeout"
    return "local_error_" + re.sub(r"[^A-Za-z0-9_]", "", type(exc).__name__)[:100]


def validate_plan(plan, wall_now):
    if not isinstance(plan, dict) or plan.get("schema_version") != "1.0":
        fail("unsupported_plan_schema")
    deadline = plan.get("deadline_utc")
    if not isinstance(deadline, str) or not 1 <= len(deadline) <= 64:
        fail("explicit_utc_deadline_required")
    try:
        date = datetime.fromisoformat(deadline.replace("Z", "+00:00"))
        if date.tzinfo is None or date.utcoffset().total_seconds() != 0:
            fail("explicit_utc_deadline_required")
        remaining = date.timestamp() - wall_now
    except (ValueError, OverflowError):
        fail("explicit_utc_deadline_required")
    if not math.isfinite(remaining) or remaining > MAX_SECONDS:
        fail("deadline_exceeds_six_hour_bound")
    maximum = plan.get("maximum_total_bytes", MAX_BYTES)
    rate = plan.get("rate_bytes_per_second", RATE_BYTES)
    if not positive_integer(maximum, MAX_BYTES) or not positive_integer(rate, RATE_BYTES):
        fail("invalid_byte_or_rate_budget")
    artifacts = plan.get("artifacts")
    if not isinstance(artifacts, list) or not 1 <= len(artifacts) <= MAX_FILES:
        fail("bounded_artifact_list_required")
    ids, outputs, total = set(), [], 0
    for item in artifacts:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", item["id"]):
            fail("invalid_artifact_id")
        if item["id"] in ids:
            fail("duplicate_artifact_id")
        ids.add(item["id"])
        repo_url(item.get("repo"), item.get("repo_type", "model"))
        if not isinstance(item.get("revision"), str) or not re.fullmatch(r"[0-9a-f]{40}", item["revision"]):
            fail("full_pinned_revision_required")
        relative_file(item.get("file"))
        output = relative_file(item.get("output"))
        if not isinstance(item.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]):
            fail("explicit_sha256_required")
        if not positive_integer(item.get("bytes"), MAX_BYTES):
            fail("invalid_artifact_bytes")
        # Reserve internal names and all sidecar paths; no artifact can replace
        # another asset, its partial data or its receipt.
        paths = [output, PurePosixPath(str(output) + ".partial"), PurePosixPath(str(output) + ".receipt.json")]
        for path in paths:
            if path.parts[0] in ("plan.original.json", "download.started.json", "download.receipt.json", "events.jsonl", "cancel.request"):
                fail("reserved_output_path")
            if any(path == old or path in old.parents or old in path.parents for old in outputs):
                fail("overlapping_output_paths")
            outputs.append(path)
        total += item["bytes"]
        if total > maximum:
            fail("aggregate_byte_budget_exceeded")
    return dict(plan=plan, artifacts=artifacts, remaining_seconds=remaining, deadline_unix=date.timestamp(), maximum=maximum, rate=rate, expected_bytes=total)


class Downloader:
    def __init__(self, plan_path, output, *, clock=time.monotonic, wall_time=time.time,
                 sleep=time.sleep, free_bytes=None, opener_factory=opener_for, cancelled=lambda: False):
        self.plan_path, self.output = safe_absolute(plan_path), safe_absolute(output)
        self.output.mkdir(mode=0o700)  # Existing even-empty/failed outputs fail; no resume.
        self.clock, self.wall_time, self.sleep = clock, wall_time, sleep
        self.free_bytes = free_bytes or (lambda: shutil.disk_usage(self.output).free)
        self.opener_factory, self.cancelled = opener_factory, cancelled
        self.started = clock()
        self.deadline, self.wall_deadline, self.rate, self.maximum = None, None, RATE_BYTES, MAX_BYTES
        self.network_bytes, self.rows = 0, []
        self.receipt = dict(schema_version="hf-artifact-download-v1", status="running", artifacts=self.rows,
                            output=str(self.output), partial_data_retained=True, resume_allowed=False,
                            retries=0, inference_performed=False, publication_performed=False,
                            user_credentials_requested_or_read=False, disk_reserve_bytes=DISK_RESERVE,
                            downloader_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                            python_version=sys.version.split()[0],
                            maximum_redirects=MAX_REDIRECTS, maximum_header_bytes=MAX_HEADERS,
                            maximum_read_chunk_bytes=CHUNK_BYTES, socket_timeout_seconds=SOCKET_TIMEOUT)

    def event(self, kind, **extra):
        value = dict(event=kind, elapsed_seconds=self.clock() - self.started, **extra)
        encoded = (json.dumps(value, separators=(",", ":")) + "\n").encode()
        if len(encoded) > 4096:
            fail("event_exceeds_bound")
        with (self.output / "events.jsonl").open("ab") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())

    def check(self):
        if self.cancelled() or (self.output / "cancel.request").exists():
            raise Cancelled("cancelled")
        if (self.deadline is not None and self.clock() >= self.deadline) or (self.wall_deadline is not None and self.wall_time() >= self.wall_deadline):
            raise Deadline("deadline_exhausted")

    def disk(self, needed=0):
        if self.free_bytes() < DISK_RESERVE + needed:
            fail("insufficient_free_disk_reserve")

    def stop_reason(self, error):
        # A cancellation/deadline that arrived during a blocking socket call
        # remains that terminal outcome even if the call exits with a timeout.
        try:
            self.check()
        except (Cancelled, Deadline) as stopped:
            return stopped
        return error

    def wait_until(self, target):
        while True:
            remaining = target - self.clock()
            if remaining <= 0:
                break
            self.check()
            self.sleep(min(0.1, remaining))
        self.check()

    def fetch(self, item):
        row = dict(item, repo_type=item.get("repo_type", "model"), status="running", bytes_received=0, bytes_stored=0)
        self.rows.append(row)
        self.event("artifact-started", id=item["id"])
        target = self.output.joinpath(*relative_file(item["output"]).parts)
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        safe_absolute(target)
        partial = Path(str(target) + ".partial")
        digest, response = hashlib.sha256(), None
        try:
            self.check()
            if target.exists() or Path(str(target) + ".receipt.json").exists():
                fail("artifact_output_already_exists")
            url = repo_url(item["repo"], row["repo_type"]) + "/resolve/" + item["revision"] + "/" + urllib.parse.quote(item["file"], safe="/")
            request = urllib.request.Request(url, headers={"User-Agent": "RecScribe-pinned-artifact/1", "Accept-Encoding": "identity"}, method="GET")
            timeout = min(SOCKET_TIMEOUT, max(0.001, self.deadline - self.clock()))
            try:
                response = self.opener_factory(self.check).open(request, timeout=timeout)
            except urllib.error.HTTPError as error:
                # An HTTPError is also a response handle. Close it without
                # reading or logging the untrusted error body/signed URL.
                error.close()
                raise
            self.check()
            validate_headers(response.headers)
            if response.getcode() != 200:
                fail("expected_full_http_200_response")
            final = redirect_url(response.geturl())
            row["effective_origin"] = final.scheme + "://" + final.netloc
            row["effective_url_sha256"] = hashlib.sha256(response.geturl().encode()).hexdigest()
            if hasattr(response.headers, "get_all") and len(response.headers.get_all("Content-Length") or []) != 1:
                fail("ambiguous_content_length")
            encoding = response.headers.get("Content-Encoding", "identity").lower()
            transfer = response.headers.get("Transfer-Encoding", "identity").lower()
            length = response.headers.get("Content-Length", "")
            if encoding != "identity" or transfer != "identity":
                fail("encoded_or_chunked_response_not_allowed")
            if not re.fullmatch(r"[0-9]{1,20}", length) or int(length) != item["bytes"]:
                fail("exact_content_length_required")
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            with os.fdopen(os.open(partial, flags, 0o600), "wb", buffering=0) as stream:
                try:
                    while row["bytes_stored"] < item["bytes"]:
                        self.check()
                        wanted = min(CHUNK_BYTES, item["bytes"] - row["bytes_stored"], self.maximum - self.network_bytes)
                        if wanted <= 0:
                            fail("aggregate_byte_budget_exhausted")
                        before = self.clock()
                        # read1 performs at most one underlying socket read. A
                        # slow trickle cannot keep read(n) blocked indefinitely.
                        if not callable(getattr(response, "read1", None)):
                            fail("bounded_stream_read1_required")
                        data = response.read1(wanted)
                        row["bytes_received"] += len(data)
                        self.network_bytes += len(data)
                        self.check()
                        if len(data) > wanted:
                            fail("response_exceeded_requested_bytes")
                        if not data:
                            fail("truncated_response")
                        self.disk(len(data))
                        view = memoryview(data)
                        while view:
                            self.check()
                            written = stream.write(view)
                            if not written:
                                fail("short_local_write")
                            digest.update(view[:written])
                            row["bytes_stored"] += written
                            view = view[written:]
                        self.wait_until(before + len(data) / self.rate)
                finally:
                    stream.flush()
                    os.fsync(stream.fileno())
            row["actual_sha256"] = digest.hexdigest()
            if row["bytes_stored"] != item["bytes"] or digest.hexdigest() != item["sha256"]:
                fail("artifact_size_or_sha256_mismatch")
            self.check()
            closing, response = response, None
            closing.close()
            # Atomic, no-overwrite promotion. A concurrent target is never replaced.
            os.link(partial, target)
            partial.unlink()
            row["status"] = "completed"
        except BaseException as exc:
            exc = self.stop_reason(exc)
            row.update(status="cancelled" if isinstance(exc, Cancelled) else "timed_out" if isinstance(exc, Deadline) else "failed",
                       reason=reason(exc), actual_sha256=digest.hexdigest())
            raise exc
        finally:
            if response is not None:
                try:
                    response.close()
                except Exception:
                    row["response_cleanup_error"] = "response_close_failed"
            row["partial_retained"] = partial.exists()
            write_json(Path(str(target) + ".receipt.json"), row)
            self.event("artifact-terminal", id=item["id"], status=row["status"])

    def run(self):
        try:
            self.check()
            with self.plan_path.open("rb") as stream:
                raw = stream.read(MAX_PLAN + 1)
            if len(raw) > MAX_PLAN:
                fail("plan_exceeds_one_mib_bound")
            write_bytes(self.output / "plan.original.json", raw)
            self.receipt["plan_sha256"] = hashlib.sha256(raw).hexdigest()
            try:
                document = json.loads(raw)
            except (ValueError, UnicodeError):
                fail("invalid_plan_json")
            plan = validate_plan(document, self.wall_time())
            self.deadline = self.clock() + plan["remaining_seconds"]
            self.wall_deadline = plan["deadline_unix"]
            self.rate, self.maximum = plan["rate"], plan["maximum"]
            self.receipt.update(deadline_utc=document["deadline_utc"], maximum_total_bytes=self.maximum,
                                rate_bytes_per_second=self.rate, expected_bytes=plan["expected_bytes"],
                                planned_artifacts=len(plan["artifacts"]))
            write_json(self.output / "download.started.json", self.receipt)
            self.event("download-started")
            self.check()
            self.disk(plan["expected_bytes"])
            for item in plan["artifacts"]:
                self.fetch(item)
            self.receipt["status"] = "completed"
        except BaseException as exc:
            exc = self.stop_reason(exc)
            self.receipt.update(status="cancelled" if isinstance(exc, Cancelled) else "timed_out" if isinstance(exc, Deadline) else "failed", reason=reason(exc))
        finally:
            self.receipt.update(network_bytes=self.network_bytes, stored_bytes=sum(v["bytes_stored"] for v in self.rows),
                                completed_artifacts=sum(v["status"] == "completed" for v in self.rows),
                                unstarted_artifacts=self.receipt.get("planned_artifacts", 0) - len(self.rows),
                                elapsed_seconds=self.clock() - self.started)
            write_json(self.output / "download.receipt.json", self.receipt)
        return self.receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    cancelled = [False]
    def stop(_signum, _frame):
        cancelled[0] = True
    previous = {number: signal.signal(number, stop) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        receipt = Downloader(args.plan, args.output, cancelled=lambda: cancelled[0]).run()
        print(json.dumps({key: receipt[key] for key in ("status", "completed_artifacts", "network_bytes", "stored_bytes")}))
        return 0 if receipt["status"] == "completed" else 1
    except BaseException as exc:
        print("Artifact download did not start or persist its terminal receipt: " + reason(exc), file=sys.stderr)
        return 1
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
