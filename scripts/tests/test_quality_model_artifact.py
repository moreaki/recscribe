"""Offline contracts for pinned bounded asset acquisition; no model imports."""
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

SPEC = importlib.util.spec_from_file_location("model_artifact", Path(__file__).resolve().parents[1] / "quality/fetch-model-artifact.py")
fetch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetch)


class Clock:
    def __init__(self):
        self.now = 0.0
        self.wall = 1700000000.0
        self.waits = []

    def monotonic(self):
        return self.now

    def wall_time(self):
        return self.wall

    def sleep(self, seconds):
        self.waits.append(seconds)
        self.now += seconds
        self.wall += seconds

    def deadline(self, seconds=60):
        return datetime.fromtimestamp(self.wall + seconds, timezone.utc).isoformat()


class Response:
    def __init__(self, body, *, length=None, status=200, headers=None, callback=None):
        self.body = io.BytesIO(body)
        self.headers = {"Content-Length": str(len(body) if length is None else length)}
        self.headers.update(headers or {})
        self.status, self.callback = status, callback
        self.closed, self.read_sizes = False, []

    def getcode(self):
        return self.status

    def geturl(self):
        return "https://cas-bridge.xethub.hf.co/file?server-signed-secret=never-log-me"

    def read1(self, size):
        self.read_sizes.append(size)
        data = self.body.read(size)
        if self.callback:
            self.callback()
        return data

    def close(self):
        self.closed = True
        self.body.close()


class Opener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def artifact(body=b"opaque artifact", identifier="one", **changes):
    return dict(id=identifier, repo="https://huggingface.co/owner/model", revision="a" * 40,
                file="model.safetensors", output=identifier + "/model.safetensors",
                bytes=len(body), sha256=hashlib.sha256(body).hexdigest(), **changes)


class QualityModelArtifactTests(unittest.TestCase):
    def test_clock_crossing_rate_boundary_never_requests_negative_sleep(self):
        runner = object.__new__(fetch.Downloader)
        ticks = iter((0.0, .01, .02))
        sleeps = []
        runner.clock = lambda: next(ticks)
        runner.check = lambda: None
        def sleep(seconds):
            if seconds < 0:
                raise ValueError("sleep length must be non-negative")
            sleeps.append(seconds)
        runner.sleep = sleep
        runner.wait_until(.005)
        self.assertEqual(sleeps, [.005])

    def execute(self, root, items=None, responses=None, *, change=None, free_bytes=None, clock=None, cancelled=lambda: False):
        clock = clock or Clock()
        plan = dict(schema_version="1.0", deadline_utc=clock.deadline(), artifacts=items or [artifact()])
        if change:
            plan.update(change)
        source = root / "plan.json"
        source.write_text(json.dumps(plan))
        opener = Opener(responses or [Response(b"opaque artifact")])
        output = root / "new-output"
        runner = fetch.Downloader(source, output, clock=clock.monotonic, wall_time=clock.wall_time,
                                  sleep=clock.sleep, free_bytes=free_bytes or (lambda: 100 * 1024 ** 3),
                                  opener_factory=lambda _check: opener, cancelled=cancelled)
        return runner.run(), output, opener, clock

    def test_success_is_hash_locked_closed_and_retains_source_and_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            response = Response(b"opaque artifact")
            result, output, opener, _ = self.execute(root, responses=[response])
            self.assertEqual(result["status"], "completed")
            self.assertEqual(result["completed_artifacts"], 1)
            self.assertTrue(response.closed)
            self.assertEqual((output / "one/model.safetensors").read_bytes(), b"opaque artifact")
            self.assertFalse((output / "one/model.safetensors.partial").exists())
            self.assertEqual((output / "plan.original.json").read_bytes(), (root / "plan.json").read_bytes())
            receipt = json.loads((output / "one/model.safetensors.receipt.json").read_text())
            self.assertEqual(receipt["actual_sha256"], artifact()["sha256"])
            self.assertEqual(receipt["bytes_stored"], artifact()["bytes"])
            self.assertNotIn("never-log-me", (output / "download.receipt.json").read_text())
            self.assertNotIn("Authorization", dict(opener.requests[0][0].header_items()))
            self.assertTrue(opener.requests[0][0].full_url.endswith("/resolve/" + "a" * 40 + "/model.safetensors"))
            self.assertLessEqual(opener.requests[0][1], 2)
            self.assertFalse(result["inference_performed"])
            self.assertFalse(result["publication_performed"])

    def test_wrong_digest_retains_partial_and_never_promotes_or_retries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            wrong = dict(artifact(), sha256="0" * 64)
            result, output, opener, _ = self.execute(root, [wrong])
            self.assertEqual((result["status"], result["reason"]), ("failed", "artifact_size_or_sha256_mismatch"))
            self.assertFalse((output / "one/model.safetensors").exists())
            self.assertEqual((output / "one/model.safetensors.partial").read_bytes(), b"opaque artifact")
            before = (output / "download.receipt.json").read_bytes()
            with self.assertRaises(FileExistsError):
                fetch.Downloader(root / "plan.json", output)
            self.assertEqual((output / "download.receipt.json").read_bytes(), before)
            self.assertEqual(len(opener.requests), 1)

    def test_truncation_and_header_size_mismatch_do_not_become_complete_files(self):
        for response, expected in [(Response(b"short", length=15), "truncated_response"),
                                   (Response(b"opaque artifact", length=999), "exact_content_length_required")]:
            with self.subTest(reason=expected), tempfile.TemporaryDirectory() as directory:
                result, output, _, _ = self.execute(Path(directory).resolve(), responses=[response])
                self.assertEqual(result["reason"], expected)
                self.assertFalse((output / "one/model.safetensors").exists())
                self.assertTrue(response.closed)

    def test_cancel_file_and_signal_flag_close_response_and_preserve_partial(self):
        for use_file in (True, False):
            with self.subTest(file=use_file), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                flag = [False]
                def cancel():
                    if use_file:
                        (root / "new-output/cancel.request").touch()
                    else:
                        flag[0] = True
                response = Response(b"opaque artifact", callback=cancel)
                result, output, _, _ = self.execute(root, responses=[response], cancelled=lambda: flag[0])
                self.assertEqual(result["status"], "cancelled")
                self.assertFalse((output / "one/model.safetensors").exists())
                self.assertTrue((output / "one/model.safetensors.partial").exists())
                self.assertTrue(response.closed)

    def test_deadline_during_read_and_wall_clock_jump_are_terminal(self):
        for use_wall in (True, False):
            with self.subTest(wall=use_wall), tempfile.TemporaryDirectory() as directory:
                clock = Clock()
                def advance():
                    if use_wall:
                        clock.wall += 61
                    else:
                        clock.now += 61
                response = Response(b"opaque artifact", callback=advance)
                result, output, _, _ = self.execute(Path(directory).resolve(), responses=[response], clock=clock)
                self.assertEqual((result["status"], result["reason"]), ("timed_out", "deadline_exhausted"))
                self.assertFalse((output / "one/model.safetensors").exists())
                self.assertTrue(response.closed)

    def test_cancel_during_socket_timeout_is_still_recorded_as_cancelled(self):
        with tempfile.TemporaryDirectory() as directory:
            cancelled = [False]
            response = Response(b"opaque artifact")
            def stopped_read(_size):
                cancelled[0] = True
                raise TimeoutError("untrusted network detail")
            response.read1 = stopped_read
            result, _, _, _ = self.execute(Path(directory).resolve(), responses=[response], cancelled=lambda: cancelled[0])
            self.assertEqual((result["status"], result["reason"]), ("cancelled", "cancelled"))
            self.assertTrue(response.closed)

    def test_expired_deadline_and_disk_reserve_block_network(self):
        for change, space, expected in [({"deadline_utc": "2000-01-01T00:00:00Z"}, None, "deadline_exhausted"),
                                       ({}, lambda: fetch.DISK_RESERVE + 1, "insufficient_free_disk_reserve")]:
            with self.subTest(reason=expected), tempfile.TemporaryDirectory() as directory:
                result, output, opener, _ = self.execute(Path(directory).resolve(), change=change, free_bytes=space)
                self.assertEqual(result["reason"], expected)
                self.assertEqual(opener.requests, [])
                self.assertTrue((output / "download.receipt.json").exists())

    def test_rate_limit_waits_are_cancellable_small_steps(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _, _, clock = self.execute(Path(directory).resolve(), change={"rate_bytes_per_second": 5})
            self.assertEqual(result["status"], "completed")
            self.assertAlmostEqual(sum(clock.waits), 3, places=9)
            self.assertLessEqual(max(clock.waits), .1)

    def test_cancellation_during_throttle_does_not_wait_for_the_rate_window(self):
        with tempfile.TemporaryDirectory() as directory:
            clock, cancelled = Clock(), [False]
            original = clock.sleep
            def sleep(seconds):
                original(seconds)
                cancelled[0] = True
            clock.sleep = sleep
            result, output, _, _ = self.execute(Path(directory).resolve(), clock=clock,
                                               change={"rate_bytes_per_second": 1}, cancelled=lambda: cancelled[0])
            self.assertEqual(result["status"], "cancelled")
            self.assertLessEqual(clock.now, .1)
            self.assertFalse((output / "one/model.safetensors").exists())
            self.assertTrue((output / "one/model.safetensors.partial").exists())

    def test_later_failure_keeps_previous_completed_file_and_unstarted_count(self):
        with tempfile.TemporaryDirectory() as directory:
            items = [artifact(identifier="one"), dict(artifact(identifier="two"), sha256="0" * 64), artifact(identifier="three")]
            result, output, opener, _ = self.execute(Path(directory).resolve(), items, [Response(b"opaque artifact"), Response(b"opaque artifact")])
            self.assertEqual((result["completed_artifacts"], result["unstarted_artifacts"]), (1, 1))
            self.assertEqual((output / "one/model.safetensors").read_bytes(), b"opaque artifact")
            self.assertTrue((output / "two/model.safetensors.partial").exists())
            self.assertEqual(len(opener.requests), 2)

    def test_dataset_repository_route_is_explicit_and_revision_pinned(self):
        for repo in ("https://huggingface.co/datasets/owner/source", "https://huggingface.co/owner/source"):
            with self.subTest(repo=repo), tempfile.TemporaryDirectory() as directory:
                item = dict(artifact(), repo=repo, repo_type="dataset", file="audio/source.flac")
                result, _, opener, _ = self.execute(Path(directory).resolve(), [item])
                self.assertEqual(result["status"], "completed")
                self.assertEqual(result["artifacts"][0]["repo_type"], "dataset")
                self.assertEqual(opener.requests[0][0].full_url, "https://huggingface.co/datasets/owner/source/resolve/" + "a" * 40 + "/audio/source.flac")

    def test_unsafe_urls_paths_and_nonpinned_identities_fail_before_network(self):
        variants = [dict(repo="http://huggingface.co/a/b"), dict(repo="https://secret@huggingface.co/a/b"),
                    dict(repo="https://huggingface.co.evil/a/b"), dict(repo="https://huggingface.co/a/b?token=secret"),
                    dict(repo_type="space"), dict(revision="main"), dict(file="../private"), dict(file="x%2fsecret"),
                    dict(output="../outside"), dict(output="cancel.request"), dict(bytes=True), dict(bytes=fetch.MAX_BYTES + 1)]
        for fields in variants:
            with self.subTest(fields=fields), tempfile.TemporaryDirectory() as directory:
                result, _, opener, _ = self.execute(Path(directory).resolve(), [dict(artifact(), **fields)])
                self.assertEqual(result["status"], "failed")
                self.assertEqual(opener.requests, [])

    def test_aggregate_cap_and_overlapping_output_sidecars_fail_preflight(self):
        cases = [([artifact(identifier="a"), artifact(identifier="b")], {"maximum_total_bytes": 20}),
                 ([artifact(), dict(artifact(identifier="two"), output="one/model.safetensors.partial")], {}),
                 ([artifact(), dict(artifact(identifier="two"), output="one/model.safetensors/child")], {})]
        for items, change in cases:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                result, _, opener, _ = self.execute(Path(directory).resolve(), items, change=change)
                self.assertEqual(result["status"], "failed")
                self.assertEqual(opener.requests, [])

    def test_concurrently_created_target_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            def create():
                (root / "new-output/one/model.safetensors").write_bytes(b"unrelated")
            result, output, _, _ = self.execute(root, responses=[Response(b"opaque artifact", callback=create)])
            self.assertEqual(result["status"], "failed")
            self.assertEqual((output / "one/model.safetensors").read_bytes(), b"unrelated")
            self.assertEqual((output / "one/model.safetensors.partial").read_bytes(), b"opaque artifact")

    def test_http_range_encoding_headers_and_error_bodies_are_not_accepted(self):
        responses = [Response(b"opaque artifact", status=206), Response(b"opaque artifact", headers={"Content-Encoding": "gzip"}),
                     Response(b"opaque artifact", headers={"Transfer-Encoding": "chunked"}),
                     Response(b"opaque artifact", headers={"Untrusted": "x" * fetch.MAX_HEADERS}),
                     urllib.error.HTTPError("https://secret.example/?token=never-log-me", 403, "secret body", {}, None)]
        for response in responses:
            with self.subTest(response=type(response).__name__), tempfile.TemporaryDirectory() as directory:
                result, output, opener, _ = self.execute(Path(directory).resolve(), responses=[response])
                self.assertEqual(result["status"], "failed")
                self.assertEqual(len(opener.requests), 1)
                self.assertNotIn("never-log-me", (output / "download.receipt.json").read_text())
                self.assertNotIn("secret body", (output / "download.receipt.json").read_text())

    def test_redirects_are_https_host_bounded_and_never_read_proxy_credentials(self):
        handler = fetch.Redirects(lambda: None)
        request = urllib.request.Request("https://huggingface.co/owner/model/resolve/" + "a" * 40 + "/file")
        for unsafe in ("http://cdn-lfs.huggingface.co/file", "https://127.0.0.1/file", "https://huggingface.co.evil/file", "https://name:secret@cdn-lfs.hf.co/file"):
            with self.assertRaises(fetch.DownloadError):
                handler.redirect_request(request, None, 302, "", {}, unsafe)
        for _ in range(fetch.MAX_REDIRECTS):
            handler.redirect_request(request, None, 302, "", {}, "https://cas-bridge.xethub.hf.co/file?signature=secret")
        with self.assertRaisesRegex(fetch.DownloadError, "redirect_limit"):
            handler.redirect_request(request, None, 302, "", {}, "https://cdn-lfs.hf.co/file")
        with patch.dict("os.environ", {"HTTPS_PROXY": "https://username:password@proxy.example", "HF_TOKEN": "secret"}), patch.object(fetch.urllib.request, "build_opener") as build:
            fetch.opener_for(lambda: None)
            self.assertEqual(build.call_args.args[0].proxies, {})

    def test_cli_signal_handlers_cancel_and_restore_without_inference(self):
        with tempfile.TemporaryDirectory() as directory:
            root, clock = Path(directory).resolve(), Clock()
            plan = root / "plan.json"
            plan.write_text(json.dumps(dict(schema_version="1.0", deadline_utc="2100-01-01T00:00:00Z", artifacts=[artifact()])))
            handlers = {}
            def install(number, handler):
                old = handlers.get(number, "original-handler")
                handlers[number] = handler
                return old
            with patch.object(fetch.signal, "signal", side_effect=install), patch.object(fetch, "Downloader") as runner:
                def run():
                    check = runner.call_args.kwargs["cancelled"]
                    self.assertFalse(check())
                    handlers[signal.SIGTERM](signal.SIGTERM, None)
                    self.assertTrue(check())
                    return dict(status="cancelled", completed_artifacts=0, network_bytes=0, stored_bytes=0)
                runner.return_value.run.side_effect = run
                with patch("sys.stdout", new=io.StringIO()):
                    result = fetch.main(["--plan", str(plan), "--output", str(root / "output")])
                self.assertEqual(result, 1)
            self.assertEqual(handlers, {signal.SIGINT: "original-handler", signal.SIGTERM: "original-handler"})


if __name__ == "__main__":
    unittest.main()
