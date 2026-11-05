import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("sanitizer_check",
    Path(__file__).resolve().parents[1] / "check-sanitizer-results.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class SanitizerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.clean = dict(result="Passed", failedTests=0, runtimeWarnings=[],
                          testFailures=[], totalTestCount=557)

    def test_complete_clean_run(self):
        self.assertFalse(checker.problems(self.clean, self.clean, "** TEST SUCCEEDED **"))

    def test_success_marker_does_not_hide_original_race_or_host_restart(self):
        for diagnostic in ["WARNING: ThreadSanitizer: data race (pid=47472)",
                           "SUMMARY: ThreadSanitizer: data race in WAVWriter.writeFrames",
                           "Restarting after unexpected exit, crash, or test timeout"]:
            with self.subTest(diagnostic=diagnostic):
                self.assertTrue(checker.problems(self.clean, self.clean,
                    diagnostic + "\n✔ Test run passed\n** TEST SUCCEEDED **"))

    def test_structured_warning_cannot_be_lost_in_log_filtering(self):
        warned = dict(self.clean, runtimeWarnings=[{"message": "data race"}])
        self.assertTrue(checker.problems(warned, self.clean, "** TEST SUCCEEDED **"))

    def test_restarted_partial_run_is_not_a_full_pass(self):
        partial = dict(self.clean, totalTestCount=516)
        self.assertTrue(checker.problems(partial, self.clean, "** TEST SUCCEEDED **"))

    def test_failed_or_missing_summary_is_not_a_pass(self):
        for invalid in [dict(self.clean, result="Failed", failedTests=1), {}]:
            self.assertTrue(checker.problems(invalid, self.clean, ""))

    def test_empty_or_incomplete_log_is_not_a_pass(self):
        self.assertTrue(checker.problems(self.clean, self.clean, ""))

    def test_missing_warning_field_is_not_assumed_clean(self):
        incomplete = dict(self.clean)
        del incomplete["runtimeWarnings"]
        self.assertTrue(checker.problems(incomplete, self.clean, "** TEST SUCCEEDED **"))


if __name__ == "__main__":
    unittest.main()
