import importlib.util
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import source_baseline

spec = importlib.util.spec_from_file_location("source_boundary", SCRIPTS / "check-source-boundary.py")
boundary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundary)


class SourceBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.historical = source_baseline.identities()
        boundary.RETIRED = cls.historical.pattern()

    def test_every_discovered_marker_is_rejected_in_paths_and_contents(self):
        markers = self.historical.projects + self.historical.contributors + self.historical.other_identifiers
        for marker in markers:
            with self.subTest(marker=marker):
                self.assertTrue(boundary.violation("file.txt", marker.swapcase().encode()))
                self.assertTrue(boundary.violation(marker + "/file.txt", b"ordinary content"))

    def test_project_display_and_namespace_variants_are_rejected(self):
        for project in self.historical.projects:
            parts = re.findall(r"[A-Z][a-z0-9]*|[a-z0-9]+", project)
            for separator in ["", " ", "-", "_", "."]:
                with self.subTest(separator=separator):
                    self.assertTrue(boundary.violation("file.txt", separator.join(parts).encode()))

    def test_all_former_exception_files_are_actually_scanned(self):
        paths = ["LICENSE", "NOTICE", "docs/provenance/recording-foundation.md",
                 "scripts/audit-source-provenance.py", "scripts/check-source-boundary.py"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in paths:
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(self.historical.projects[0])
            self.assertEqual(boundary.inspect([root / path for path in paths], root), paths)

    def test_current_license_vendor_and_binary_content_are_allowed(self):
        self.assertFalse(boundary.violation("LICENSE", b"Apache License Version 2.0 Copyright 2026 moreaki"))
        self.assertFalse(boundary.violation("NOTICE", b"RecScribe Apple ScreenCaptureKit BlackHole Soundflower"))
        self.assertFalse(boundary.violation("signal.wav", bytes(range(256))))

    def test_bundle_paths_are_not_exempt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "Contents/MacOS/RecScribe"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(self.historical.projects[0].encode())
            self.assertEqual(boundary.inspect(root.rglob("*"), root), ["Contents/MacOS/RecScribe"])

    def test_shallow_history_fails_closed(self):
        with patch.object(source_baseline, "git", return_value=b"true\n"):
            with self.assertRaisesRegex(ValueError, "Full Git history is required"):
                source_baseline.identities()

    def test_unavailable_history_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(source_baseline, "ROOT", Path(directory)):
                with self.assertRaisesRegex(ValueError, "Historical baseline unavailable"):
                    source_baseline.identities()


if __name__ == "__main__":
    unittest.main()
