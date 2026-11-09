#!/usr/bin/env python3
"""Execute only the sealed 15-stage round-4 family, serially and cancellably.

No retry/resume or outcome-based selection. Each inference launch is owned by
the frozen guard; cancellation signals/awaits that supervisor, never kills it
and orphans its separate CLI session. Importing this module opens nothing.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

R = Path(__file__).resolve().parent


def require(value, message):
    if not value: raise ValueError(message)


def digest(path):
    path=Path(path)
    require(path.is_absolute() and '..' not in path.parts and not any(p.is_symlink() for p in (path,*path.parents)),
            'Bootstrap source/metadata path must be absolute and nonsymlink')
    before=path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_size<=4*1024*1024,'Bootstrap source/metadata exceeds its 4 MiB bound')
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""): h.update(block)
    after=path.lstat()
    require((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)==
            (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns),'Bootstrap file changed during hashing')
    return h.hexdigest()


class Coordinator:
    def __init__(self, family_path, family_sha, expected_source_sha, initial_attestation, signal_requested=lambda: False):
        require(re.fullmatch(r"[0-9a-f]{64}", expected_source_sha or "") and digest(__file__) == expected_source_sha,
                "Coordinator source differs from explicit CLI SHA256 lock")
        self.signal_requested = signal_requested; self.cancel = R / "cancel-serial.request"
        self.current = None; self.interrupted = False; self.journal = None; self.heldout_sha = None; self.heldout = None
        family_path = Path(family_path)
        require(family_path == R / "pre-inference-family-seal.json" and re.fullmatch(r"[0-9a-f]{64}", family_sha or ""), "Explicit exact family path/SHA256 required")
        require(digest(family_path) == family_sha, "Initial family seal differs from CLI lock")
        # Read only this hash-locked metadata to locate the separately pinned
        # sealer/common verifier. Its import has no experiment-input side effect.
        with family_path.open("rb") as stream: raw = stream.read(4 * 1024 * 1024 + 1)
        require(len(raw) <= 4 * 1024 * 1024, "Initial family metadata exceeds its bound")
        value = json.loads(raw)
        sealer = value.get("tools", {}).get("sealer", {})
        require(sealer.get("path") == str(R / "seal-heldout.py") and re.fullmatch(r"[0-9a-f]{64}", sealer.get("sha256", "")) and
                digest(sealer["path"]) == sealer["sha256"], "Sealer source differs from initial family lock")
        specification = importlib.util.spec_from_file_location("round4_sealer", sealer["path"])
        self.common = importlib.util.module_from_spec(specification); sys.modules[specification.name] = self.common
        specification.loader.exec_module(self.common)
        self.family = self.common.Family(family_path, family_sha, self.check)
        self.family.bind_initial_attestation(initial_attestation)
        require(self.family.value["tools"]["coordinator"]["path"] == str(Path(__file__).resolve()) and
                self.family.value["tools"]["coordinator"]["sha256"] == expected_source_sha, "Family coordinator pin differs from CLI lock")

    def check(self):
        if self.interrupted or self.signal_requested() or self.cancel.exists():
            raise InterruptedError("Serial research cancellation requested; partial evidence retained")

    def note(self, event, **fields):
        require(self.journal is not None, "Journal is not open")
        value = {"created_utc": datetime.now(timezone.utc).isoformat(), "event": event, **fields}
        line = json.dumps(value, ensure_ascii=False, allow_nan=False)
        self.journal.write(line + "\n"); self.journal.flush(); os.fsync(self.journal.fileno())
        print(line, flush=True)

    def signal_child(self, child):
        self.interrupted = True
        if child.poll() is None:
            try: child.send_signal(signal.SIGINT)
            except ProcessLookupError: pass

    def await_owned_child(self, child, guarded):
        if child.poll() is None: self.signal_child(child)
        # The frozen guard performs its own bounded signal escalation for every
        # process group in the CLI's owned session. Killing the guard here could
        # orphan that session, so an exceptional unresolved cleanup stays pending.
        try: child.wait(timeout=60 if guarded else 15)
        except subprocess.TimeoutExpired:
            if guarded:
                self.note("owned_guard_cleanup_pending", pid=child.pid, default_promotion=False)
                raise RuntimeError("Owned guard did not finish within60 seconds; supervisor retained to complete cleanup")
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=5)
        require(child.poll() is not None, "Owned command could not be reaped")

    def command(self, argv, stage, action, *, guarded=False, timeout=180):
        self.check(); self.family.verify_step()
        self.note("command_start", stage=stage, action=action, command=argv)
        child = subprocess.Popen(argv, cwd=R, stdin=subprocess.DEVNULL)
        self.current = child; failure = None
        deadline = time.monotonic() + timeout
        try:
            # Required post-Popen check closes cancellation arriving after the
            # precheck but before the parent owns the returned Popen handle.
            if self.signal_requested() or self.cancel.exists(): self.signal_child(child)
            while child.poll() is None:
                if self.interrupted or self.signal_requested() or self.cancel.exists():
                    self.signal_child(child); break
                if time.monotonic() >= deadline:
                    self.signal_child(child); raise TimeoutError("Owned command exceeded its finite bound")
                try: child.wait(timeout=.25)
                except subprocess.TimeoutExpired: pass
            self.await_owned_child(child, guarded)
            self.note("command_finished", stage=stage, action=action, returncode=child.returncode)
            self.check()
            require(child.returncode in ({0,1} if guarded else {0}), stage + "/" + action + " failed; later inference not started")
            self.family.verify_step(); return child.returncode
        except BaseException as error:
            failure = error; raise
        finally:
            try:
                self.await_owned_child(child, guarded)
            except BaseException as cleanup:
                if failure is None: raise
                if hasattr(failure, "add_note"): failure.add_note("Owned cleanup: " + str(cleanup))
            finally:
                if child.poll() is not None: self.current = None

    def heldout_bindings(self):
        require(self.heldout_sha is not None and self.heldout is not None,'All-five held-out seal is not accepted')
        current,_=self.common.read(R/'heldout-family.freeze.json',self.heldout_sha,self.check)
        require(current==self.heldout and current.get('original_family_seal_sha256')==self.family.expected_sha
            and current.get('schema_version')=='attention-rotation-heldout-family-freeze-v1'
            and current.get('initial_attestation')==self.family.attestation
            and current.get('rotation')==self.family.value['rotation'] and current.get('quantization')==self.family.value['quantization']
            and current.get('analysis_source')==self.family.tools['assessor'],'All-five held-out receipt differs')
        records=current.get('partitions',[])
        require(len(records)==5 and {x.get('id') for x in records}=={s['id'] for s in self.family.value['stages'][10:]},
            'Held-out receipt must bind all five partitions')
        return {x['id']:x for x in records}

    def verify_heldout_plan(self,stage,binding):
        folder=Path(stage['configuration']).parent; original=self.family.plans[stage['id']]
        freeze,_=self.common.read(stage['freeze'],binding['freeze_sha256'],self.check)
        final,_=self.common.read(folder/'assessment-plan.final.json',binding['final_plan_sha256'],self.check)
        require(all(binding.get(k)==stage[k] for k in ('corpus_sha256','configuration_sha256'))
            and binding.get('pre_freeze_plan_sha256')==stage['assessment_pre_freeze_plan_sha256'],'Held-out input pins differ')
        require(freeze.get('schema_version')=='1.0' and freeze.get('original_family_seal_sha256')==self.family.expected_sha
            and freeze.get('frozen_before_held_out') is True and freeze.get('initial_attestation')==self.family.attestation
            and freeze.get('corpus_sha256')==stage['corpus_sha256'] and freeze.get('experiment_sha256')==stage['configuration_sha256']
            and freeze.get('budgets')==self.family.value['budgets'] and freeze.get('all_heldout_partitions')==self.heldout['all_heldout_partitions']
            and freeze.get('profiles')=={'current-defaults':self.family.value['profile']['sha256']}
            and freeze.get('rotation')==self.family.value['rotation'] and freeze.get('quantization')==self.family.value['quantization']
            and freeze.get('analysis_source')==self.family.tools['assessor']
            and freeze.get('runner_sha256')==original['execution']['runner_sha256']
            and freeze.get('whisper_binary_sha256')==original['execution']['whisper_binary_sha256'], 'Held-out partition freeze differs')
        require(final.get('pre_freeze_plan_sha256')==stage['assessment_pre_freeze_plan_sha256']
            and final.get('pre_freeze_family_seal_sha256')==self.family.expected_sha
            and final.get('execution',{}).get('freeze_sha256')==binding['freeze_sha256'],'Final-plan links differ')
        stripped=json.loads(json.dumps(final)); stripped['execution'].pop('freeze_sha256')
        stripped.pop('pre_freeze_plan_sha256'); stripped.pop('pre_freeze_family_seal_sha256')
        require(stripped==original,'Final plan changes more than the three allowed links')

    def stage_run(self,stage):
        self.family.verify_step(); self.check(); held=stage['stage']=='held_out'; binding=None
        if held:
            bindings=self.heldout_bindings()
            for item in self.family.value['stages'][10:]: self.verify_heldout_plan(item,bindings[item['id']])
            binding=bindings[stage['id']]
        folder=Path(stage['configuration']).parent; matrix=folder/'matrix'
        require(not any((folder/name).exists() for name in ('matrix','matrix.guard.jsonl','report-v1.1','assessment-v1','natural-failures.json')),
            'Stage outcome exists; no retry or resume')
        tools=self.family.tools; limit=stage['guard_timeout_seconds']
        rc=self.command([sys.executable,tools['guard']['path'],'--output',str(matrix),'--timeout',str(limit),'--foreign-cpu-limit','1000','--',
            self.family.value['runner']['path'],'benchmark',stage['corpus'],'--experiment',stage['configuration'],'--output',str(matrix)],
            stage['id'],'guarded_inference',guarded=True,timeout=limit+60)
        if rc==1:
            require(not (matrix/'cancel.request').exists(),'Campaign cancellation cannot enter forensic continuation')
            events,_=self.family.guard_metadata(folder/'matrix.guard.jsonl')
            attempted,_=self.common.read(matrix/'matrix.json',check=self.check)
            self.common.validate_attempted_cells(stage,self.family.plans[stage['id']],attempted,events[-1])
            self.command([sys.executable,tools['failure_classifier']['path'],'--matrix',str(matrix/'matrix.json'),
                '--output',str(folder/'natural-failures.json'),'--expected-source-sha256',tools['failure_classifier']['sha256']],
                stage['id'],'classify_finite_native_output_failure')
        self.family.terminal(stage)
        report=folder/'report-v1.1'; argv=[sys.executable,tools['reporter']['path'],str(matrix),'--output',str(report)]
        if held: argv.append('--allow-held-out')
        self.command(argv,stage['id'],'retained_metric_report')
        plan=folder/'assessment-plan.final.json' if held else Path(stage['assessment_pre_freeze_plan'])
        self.command([sys.executable,tools['assessor']['path'],str(report/'report.json'),'--matrix',str(matrix/'matrix.json'),
            '--plan',str(plan),'--output',str(folder/'assessment-v1')],stage['id'],'frozen_assessment')
        evidence=self.family.stage_evidence(stage,binding); self.note('stage_assessed',**evidence); return evidence

    def execute(self):
        journal_path=R/'serial.events.jsonl'; require(not journal_path.exists(),'Serial journal exists; no undocumented resume')
        with journal_path.open('x',buffering=1) as journal:
            self.journal=journal
            try:
                require(self.family.attestation is not None,'Separate native idle attestation missing')
                self.family.verify_all()
                for s in self.family.value['stages']:
                    folder=Path(s['configuration']).parent
                    require(not any((folder/name).exists() for name in ('matrix','matrix.guard.jsonl','report-v1.1','assessment-v1',
                        'natural-failures.json','freeze.json','assessment-plan.final.json')),'Prior stage outcome/freeze forbids new run')
                require(not (R/'heldout-family.freeze.json').exists(),'Held-out family already released')
                self.note('serial_started',pid=os.getpid(),family_seal_sha256=self.family.expected_sha,
                    coordinator_sha256=digest(__file__),initial_attestation=self.family.attestation,
                    planned_cells=4554,planned_native_parent_pairs=2484,planned_assessor_derived_q4_pairs=828,
                    planned_reference_runtime_placeholders=1242,cancel_marker=str(self.cancel),default_promotion=False)
                evidence=[self.stage_run(s) for s in self.family.value['stages'][:10]]
                tools=self.family.tools; attestation=self.family.attestation
                self.command([sys.executable,tools['sealer']['path'],'--family-seal',str(self.family.path),
                    '--family-seal-sha256',self.family.expected_sha,'--expected-source-sha256',tools['sealer']['sha256'],
                    '--initial-attestation',attestation['path'],'--initial-attestation-sha256',attestation['sha256'],
                    '--output',str(R/'heldout-family.freeze.json')],'all-heldout','all_ten_terminal_then_all_five_freeze',timeout=300)
                self.heldout,self.heldout_sha=self.common.read(R/'heldout-family.freeze.json',check=self.check)
                self.heldout_bindings(); self.note('heldout_family_accepted',freeze_sha256=self.heldout_sha,
                    partitions=self.heldout['partitions'],family_seal_sha256=self.family.expected_sha,
                    initial_attestation=self.family.attestation,analysis_source=tools['assessor'],default_promotion=False)
                evidence += [self.stage_run(s) for s in self.family.value['stages'][10:]]
                self.family.verify_all(); bindings=self.heldout_bindings()
                final=[self.family.stage_evidence(s,bindings[s['id']] if s['stage']=='held_out' else None) for s in self.family.value['stages']]
                require(final==evidence,'Completed evidence changed before final journal publication')
                keys=('attempted_cells','completed_cells','failed_cells','planned_native_parent_pairs','completed_native_parent_pairs',
                    'pending_native_parent_pairs','planned_assessor_derived_q4_pairs','completed_assessor_derived_q4_pairs',
                    'pending_assessor_derived_q4_pairs','runtime_reference_placeholders')
                totals={k:sum(x[k] for x in final) for k in keys}
                require(totals['attempted_cells']==totals['completed_cells']+totals['failed_cells']==4554
                    and totals['planned_native_parent_pairs']==totals['completed_native_parent_pairs']+totals['pending_native_parent_pairs']==2484
                    and totals['planned_assessor_derived_q4_pairs']==totals['completed_assessor_derived_q4_pairs']+totals['pending_assessor_derived_q4_pairs']==828
                    and totals['runtime_reference_placeholders']==1242,'All15 exact attempt/pair/placeholder grids must be accounted')
                self.check(); self.note('serial_finished',status='completed_with_failures' if totals['failed_cells'] else 'completed',
                    planned_cells=4554,observed_rows=4554,**totals,complete_quality_coverage=not totals['failed_cells'],
                    family_seal_sha256=self.family.expected_sha,initial_attestation=self.family.attestation,
                    unique_source_cases_by_stage={'panel':9,'development':72,'held_out':144},language_count=9,artifacts=11,stage_count=15,
                    default_promotion=False,native_approval='PENDING',resource_acceptance='NOT EVALUATED')
                return 0
            except BaseException as error:
                if self.current is not None:
                    try: self.await_owned_child(self.current,True)
                    except BaseException as cleanup:
                        if hasattr(error,'add_note'): error.add_note('Final owned guard cleanup: '+str(cleanup))
                self.note('serial_stopped',error_type=type(error).__name__,error=str(error),default_promotion=False,
                    native_approval='PENDING',resource_acceptance='NOT EVALUATED')
                return 130 if isinstance(error,(InterruptedError,KeyboardInterrupt)) else 1
            finally: self.journal=None


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--family-seal',type=Path,required=True); parser.add_argument('--family-seal-sha256',required=True)
    parser.add_argument('--expected-source-sha256',required=True)
    parser.add_argument('--initial-attestation',type=Path,required=True); parser.add_argument('--initial-attestation-sha256',required=True)
    args=parser.parse_args(argv); requested={'stop':False}
    def stop(_number,_frame): requested['stop']=True
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP): signal.signal(number,stop)
    return Coordinator(args.family_seal,args.family_seal_sha256,args.expected_source_sha256,
        {'path':str(args.initial_attestation),'sha256':args.initial_attestation_sha256},lambda:requested['stop']).execute()


if __name__=='__main__':
    try: raise SystemExit(main())
    except (ValueError,OSError,InterruptedError) as error:
        print(type(error).__name__+': '+str(error),file=sys.stderr); raise SystemExit(1)

