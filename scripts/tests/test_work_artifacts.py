import fcntl
import importlib.util
import json
import shutil
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'work-artifacts.py'
spec = importlib.util.spec_from_file_location('work_artifacts', SCRIPT)
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)


class ArtifactRetentionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / 'Build/Artifacts'
        self.now = time.time()

    def tearDown(self):
        self.temporary.cleanup()

    def completed(self, name, age=0, category='test', state='complete'):
        run = self.root / category / name
        run.mkdir(parents=True)
        (run / '.lease').touch()
        (run / artifacts.MARKER).write_text(json.dumps(dict(version=1, category=category,
            disposable=True, state=state, started=self.now-age, finished=self.now-age)))
        (run / 'console.log').write_text('diagnostic output')
        return run

    def test_count_bound_and_dry_run_then_actual_pruning(self):
        runs = [self.completed(str(i), i+1) for i in range(8)]
        expected = set(runs[5:])
        self.assertEqual(set(artifacts.prune(self.root, self.now)), expected)
        self.assertTrue(all(p.exists() for p in runs))
        self.assertEqual(set(artifacts.prune(self.root, self.now, apply=True)), expected)
        self.assertTrue(all(p.exists() for p in runs[:5]))
        self.assertTrue(all(not p.exists() for p in expected))

    def test_age_limit_retains_latest_in_each_fixed_category(self):
        for category in artifacts.CATEGORIES:
            latest = self.completed('latest', 9*86400, category)
            expired = self.completed('expired', 10*86400, category)
            artifacts.prune(self.root, self.now, apply=True)
            self.assertTrue(latest.exists())
            self.assertFalse(expired.exists())

    def test_active_and_pinned_outputs_survive_pressure(self):
        self.completed('newest', 1)
        active = self.completed('active', 20*86400)
        pinned = self.completed('pinned', 20*86400)
        (pinned / '.pin').touch()
        with (active / '.lease').open('r+') as lease:
            fcntl.flock(lease, fcntl.LOCK_EX)
            artifacts.prune(self.root, self.now, keep=1, apply=True)
        self.assertTrue(active.exists())
        self.assertTrue(pinned.exists())

    def test_required_data_unknown_folders_and_current_build_state_survive(self):
        self.completed('newest', 1)
        protected = ['take.wav', 'raw-transcript.json', 'source.recscribe.json', 'canonical.json',
                     'Fixtures/expected.json', 'ReferenceCapture/expected.json', 'old.app/Contents/Info.plist',
                     'asr/output.json', 'ai-raw-normalize.json', 'vad.regions.json', 'previous-app.zip', 'installer.dmg']
        runs = []
        for index, name in enumerate(protected):
            run = self.completed(str(index), 20*86400)
            payload = run / name
            payload.parent.mkdir(parents=True, exist_ok=True)
            payload.write_text('must survive')
            runs.append(payload)
        unknown = self.root / 'test/unknown'
        unknown.mkdir(); (unknown/'valuable.txt').write_text('unknown')
        for name in ['DerivedData', 'Products', 'InstalledBackups', 'ReferenceCapture', 'LegacyCache']:
            p = self.base/'Build'/name
            p.mkdir(parents=True); (p/'data').write_text('unchanged')
        artifacts.prune(self.root, self.now, keep=1, apply=True)
        self.assertTrue(all(p.exists() for p in runs))
        self.assertTrue((unknown/'valuable.txt').exists())
        self.assertTrue(all((self.base/'Build'/n/'data').exists() for n in ['DerivedData','Products','InstalledBackups','ReferenceCapture','LegacyCache']))

    def test_missing_or_invalid_metadata_and_symlinks_are_not_removed(self):
        self.completed('newest', 1)
        invalid = self.completed('invalid', 20*86400)
        (invalid/artifacts.MARKER).write_text('{}')
        outside = self.base/'outside'; outside.mkdir(); (outside/'data').write_text('safe')
        linked = self.completed('linked', 20*86400)
        (linked/'external').symlink_to(outside, target_is_directory=True)
        artifacts.prune(self.root, self.now, keep=1, apply=True)
        self.assertTrue(invalid.exists()); self.assertTrue(linked.exists())
        self.assertTrue((outside/'data').exists())
        other = self.base/'linked-build'; other.symlink_to(self.base/'Build', target_is_directory=True)
        with self.assertRaises(ValueError):
            artifacts.prune(other/'Artifacts', self.now, apply=True)

    def test_crash_output_has_grace_period_then_expires(self):
        recent = self.completed('recent', 86400, state='running')
        abandoned = self.completed('abandoned', 8*86400, state='running')
        artifacts.prune(self.root, self.now, apply=True)
        self.assertTrue(recent.exists()); self.assertFalse(abandoned.exists())

    def test_managed_command_preserves_exit_status_output_and_complete_record(self):
        code = 'import os; print(os.environ["RECSCRIBE_RUN_DIR"]); print("failed diagnostic"); raise SystemExit(7)'
        driver = 'import importlib.util, pathlib, sys; s=importlib.util.spec_from_file_location("a",sys.argv[1]); a=importlib.util.module_from_spec(s); s.loader.exec_module(a); raise SystemExit(a.run_command(pathlib.Path(sys.argv[2]),"test","failure",[sys.executable,"-c",sys.argv[3]]))'
        result = subprocess.run([sys.executable,'-c',driver,str(SCRIPT),str(self.root),code],capture_output=True,text=True)
        self.assertEqual(result.returncode,7,result.stderr)
        runs=list((self.root/'test').iterdir()); self.assertEqual(len(runs),1)
        record=json.loads((runs[0]/artifacts.MARKER).read_text())
        self.assertEqual(record['exit_code'],7); self.assertEqual(record['state'],'complete')
        self.assertIn('failed diagnostic',(runs[0]/'console.log').read_text())
        self.assertIn(str(runs[0]),result.stdout)

    def test_missing_executable_is_recorded_as_failed(self):
        with patch.object(artifacts.signal, 'signal', return_value=None):
            self.assertEqual(artifacts.run_command(self.root,'test','missing',[str(self.base/'missing-command')]),127)
        run=next((self.root/'test').iterdir())
        record=json.loads((run/artifacts.MARKER).read_text())
        self.assertEqual(record['exit_code'],127)
        self.assertEqual(record['state'],'complete')

    def test_documented_cli_argument_order_and_cleanup_preview(self):
        driver = 'import importlib.util,pathlib,sys; s=importlib.util.spec_from_file_location("a",sys.argv.pop(1)); a=importlib.util.module_from_spec(s); s.loader.exec_module(a); a.PROJECT=pathlib.Path(sys.argv.pop(1)); raise SystemExit(a.main())'
        result = subprocess.run([sys.executable,'-c',driver,str(SCRIPT),str(self.base),
            'run','--label','cli-check','scratch','--',sys.executable,'-c','print("ok")'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('ok',result.stdout)
        self.assertEqual(len(list((self.root/'scratch').iterdir())),1)

    def test_build_hook_preserves_product_path_cache_and_failure_status(self):
        project=self.base/'project'
        scripts=project/'scripts'; scripts.mkdir(parents=True)
        shutil.copy(SCRIPT.parent/'build-app.sh',scripts/'build-app.sh')
        (project/'RecScribe/RecScribe.xcodeproj').mkdir(parents=True)
        calls=self.base/'calls.txt'
        (scripts/'work-artifacts.py').write_text('import os; open(os.environ["FAKE_CALLS"],"a").write("prune\\n")')
        binaries=self.base/'bin'; binaries.mkdir()
        (binaries/'python3').symlink_to(sys.executable)
        command = '#!/bin/bash\n'
        command += 'printf "xcodebuild %s\\n" "$*" >> "$FAKE_CALLS"\n'
        command += 'if [[ "${FAIL_BUILD:-0}" != 0 ]]; then exit "$FAIL_BUILD"; fi\n'
        command += 'app="$RECSCRIBE_BUILD_DIR/Products/Release/RecScribe.app/Contents"\n'
        command += 'mkdir -p "$app/MacOS"; touch "$app/MacOS/RecScribe"; chmod +x "$app/MacOS/RecScribe"; printf plist > "$app/Info.plist"\n'
        (binaries/'xcodebuild').write_text(command)
        for name in ['codesign','plutil']:
            (binaries/name).write_text('#!/bin/bash\nexit 0\n')
        for executable in binaries.iterdir():
            if not executable.is_symlink(): executable.chmod(0o755)
        products=self.base/'cache'
        env=dict(os.environ,PATH=str(binaries)+':'+os.environ['PATH'],FAKE_CALLS=str(calls),RECSCRIBE_BUILD_DIR=str(products))
        for code in [0,17]:
            with self.subTest(exit_code=code):
                calls.write_text('')
                result=subprocess.run(['/bin/bash',str(scripts/'build-app.sh'),'--ad-hoc'],env=dict(env,FAIL_BUILD=str(code)),capture_output=True,text=True)
                self.assertEqual(result.returncode,code,result.stderr)
                recorded=calls.read_text().splitlines()
                self.assertEqual(recorded[0],'prune'); self.assertEqual(recorded[-1],'prune')
                self.assertIn('-derivedDataPath '+str(products/'DerivedData'),recorded[1])
                self.assertNotIn('clean build',recorded[1])
                if code==0: self.assertEqual(result.stdout.strip(),str(products/'Products/Release/RecScribe.app'))

    def test_child_inherits_lease_if_wrapper_disappears(self):
        # An independent child process holds the lease across wrapper death.
        run=self.completed('active-child',20*86400,state='running')
        with (run/'.lease').open('r+') as lease:
            fcntl.flock(lease,fcntl.LOCK_EX)
            child=subprocess.Popen([sys.executable,'-c','import sys; sys.stdin.read()'],stdin=subprocess.PIPE,
                pass_fds=(lease.fileno(),))
        try:
            artifacts.prune(self.root,self.now,apply=True)
            self.assertTrue(run.exists())
        finally:
            child.communicate(timeout=5)
        artifacts.prune(self.root,self.now,apply=True)
        self.assertFalse(run.exists())


if __name__=='__main__':
    unittest.main()
