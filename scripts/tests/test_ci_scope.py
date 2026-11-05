import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ci_scope', Path(__file__).resolve().parents[1] / 'ci-scope.py')
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)
UI = 'RecScribe/RecScribe/UI/RecordingLibraryView.swift'


class ScopeTests(unittest.TestCase):
    def change(self, added, removed, path=UI, status='M'):
        return scope.classify([(status, path, added, removed)])[0]

    def test_small_styles_and_labels(self):
        for added, removed in [(['.padding(12)'], ['.padding(8)']),
                               (['.font(.headline)'], []),
                               (['Text("New label").font(.headline)'], ['Text("Old label").font(.headline)']),
                               (['Button("Delete…") { delete() }'], ['Button("Remove…") { delete() }']),
                               (['Image(systemName: "pencil")'], ['Image(systemName: "pen")'])]:
            with self.subTest(added=added):
                self.assertEqual(self.change(added, removed), 'focused')

    def test_behavior_inside_ui_is_full(self):
        for line in ['.task { await delete() }', '.onAppear { startCapture() }',
                     '.disabled(false)', '@State private var recording = false',
                     'library.moveToTrash(entry)', '.padding(deleteAll())',
                     '.background { delete() }', '/*', '*/']:
            with self.subTest(line=line):
                self.assertEqual(self.change([line], []), 'full')
        self.assertEqual(self.change(['Button("Delete") { deleteAll() }'],
                                     ['Button("Delete") { deleteOne() }']), 'full')
        self.assertEqual(self.change(['Text("\\(deleteAll())")'], ['Text("Safe")']), 'full')
        self.assertEqual(self.change(['open("other-path")'], ['open("old-path")']), 'full')

    def test_sensitive_and_unknown_paths_always_full(self):
        for path in ['RecScribe/RecScribe/Capture/AudioRecorder.swift',
                     'RecScribe/RecScribe/Sessions/SessionLibrary.swift',
                     'RecScribe/RecScribe/Transcription/TranscriptStorage.swift',
                     'core/Sources/Audio.swift', 'App.entitlements', 'scripts/ci-scope.py',
                     '.github/workflows/ci.yml', 'RecScribe/RecScribeTests/UITests.swift',
                     'RecScribe/RecScribe.xcodeproj/project.pbxproj']:
            self.assertEqual(self.change(['Text("New")'], ['Text("Old")'], path), 'full')

    def test_no_broad_binary_rename_or_empty_shortcuts(self):
        self.assertEqual(scope.classify([])[0], 'full')
        for status in ['A', 'D', 'R100', 'T']:
            self.assertEqual(self.change([], [], status=status), 'full')
        self.assertEqual(self.change(['.padding(2)'] * 81, []), 'full')
        self.assertEqual(scope.classify([('M', UI, ['.padding(2)'], [])] * 6)[0], 'full')
        self.assertEqual(self.change(['new'], ['old'], 'docs/design.png'), 'full')
        self.assertEqual(self.change(['new'], ['old'], 'docs/design.md'), 'focused')

    def test_agents_documentation_is_focused_but_policy_code_is_full(self):
        self.assertEqual(self.change(['New guidance'], ['Old guidance'], 'AGENTS.md'), 'focused')
        self.assertEqual(scope.classify([
            ('M', 'AGENTS.md', ['New guidance'], ['Old guidance']),
            ('M', 'scripts/ci-scope.py', ['new_policy()'], ['old_policy()'])
        ])[0], 'full')

    def test_missing_baseline_or_event_is_full(self):
        for env in [{}, {'CI_EVENT':'push','CI_PUSH_BASE':'0'*40},
                    {'CI_EVENT':'pull_request'}, {'CI_EVENT':'push','CI_PUSH_BASE':'unknown'}]:
            self.assertEqual(scope.detect(env)[0], 'full')

    def test_complete_git_diff_and_moved_behavior(self):
        with tempfile.TemporaryDirectory() as directory:
            old_cwd = os.getcwd()
            os.chdir(directory)
            try:
                def git(*args):
                    return subprocess.check_output(['git',*args], stderr=subprocess.PIPE).decode().strip()
                git('init'); git('config','user.email','test@example.invalid'); git('config','user.name','CI test')
                file = Path(UI); file.parent.mkdir(parents=True)
                file.write_text('Text("Old")\n.padding(8)\n' + '// unchanged\n' * 10 + 'deleteAll()\n')
                Path('AGENTS.md').write_text('Old guidance\n')
                git('add','.'); git('commit','-m','base'); base = git('rev-parse','HEAD')
                file.write_text(file.read_text().replace('Old','New').replace('padding(8)','padding(12)'))
                git('commit','-am','presentation')
                env = {'CI_EVENT':'push','CI_PUSH_BASE':base}
                self.assertEqual(scope.detect(env)[0], 'focused')
                # The entire multi-commit push/PR must include the earlier behavior edit.
                file.write_text(file.read_text().replace('deleteAll()', 'startRecording()'))
                git('commit','-am','behavior')
                file.write_text(file.read_text().replace('New','Latest'))
                git('commit','-am','label')
                self.assertEqual(scope.detect(env)[0], 'full')
                self.assertEqual(scope.detect({'CI_EVENT':'pull_request','CI_PR_BASE':base,
                                             'CI_PR_HEAD':git('rev-parse','HEAD')})[0], 'full')
                base = git('rev-parse','HEAD')
                file.write_text('startRecording()\n' + file.read_text().replace('startRecording()\n',''))
                git('commit','-am','move behavior')
                self.assertEqual(scope.detect({'CI_EVENT':'push','CI_PUSH_BASE':base})[0], 'full')
                base = git('rev-parse','HEAD'); file.chmod(0o755); git('commit','-am','mode')
                self.assertEqual(scope.detect({'CI_EVENT':'push','CI_PUSH_BASE':base})[0], 'full')
                base = git('rev-parse','HEAD')
                Path('AGENTS.md').write_text('New guidance\n')
                git('commit','-am','instructions documentation')
                self.assertEqual(scope.detect({'CI_EVENT':'push','CI_PUSH_BASE':base})[0], 'focused')
                self.assertEqual(scope.detect({'CI_EVENT':'pull_request','CI_PR_BASE':base,
                                             'CI_PR_HEAD':git('rev-parse','HEAD')})[0], 'focused')
            finally:
                os.chdir(old_cwd)

    def test_focused_suites_exist(self):
        root = Path(__file__).resolve().parents[2]
        for name in ['RecordingReviewNotesTests', 'OverflowMenuTests', 'AudioRoutingSummaryTests',
                     'RoutingControlsTests', 'RecordingBulkDeletionTests', 'RecordingSessionTests']:
            self.assertIn('struct ' + name, (root / 'RecScribe/RecScribeTests' / (name + '.swift')).read_text())


if __name__ == '__main__':
    unittest.main()
