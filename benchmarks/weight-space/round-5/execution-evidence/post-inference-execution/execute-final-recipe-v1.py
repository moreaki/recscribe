#!/usr/bin/env python3
"""Execute the authorized frozen recipe once; preserve every result/error."""
import argparse,hashlib,json,os,signal,subprocess,sys,time
from datetime import datetime,timezone
from pathlib import Path
R=Path(__file__).resolve().parent
W=Path('/Users/moreaki/.codex/worktrees/swiss-written-corpus/recscribe')
CURRENT=None;STOP=False
def require(v,m):
    if not v:raise ValueError(m)
def sha(b):return hashlib.sha256(b).hexdigest()
def descriptor(p,expected=None,cap=64*1024**2):
    p=Path(p);before=p.stat();require(p.is_file() and not p.is_symlink() and before.st_size<=cap,'Bounded regular output/metadata required')
    h=hashlib.sha256()
    with p.open('rb') as f:
        used=0
        while used<before.st_size:
            b=f.read(min(1024**2,before.st_size-used));require(b,'Input truncated');used+=len(b);h.update(b)
    after=p.stat();identity=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    require(identity(before)==identity(after) and (expected is None or h.hexdigest()==expected),'Metadata/source/output changed')
    return {'path':str(p),'sha256':h.hexdigest(),'bytes':used}
def metadata(p,expected=None,cap=4*1024**2):
    d=descriptor(p,expected,cap);raw=Path(p).read_bytes();require(sha(raw)==d['sha256'],'Metadata changed before parse');return json.loads(raw),d
def put(p,v):
    raw=(json.dumps(v,indent=2,allow_nan=False)+'\n').encode()
    with p.open('xb') as f:f.write(raw)
    p.chmod(0o600);return {'path':str(p),'sha256':sha(raw),'bytes':len(raw)}
def terminate_owned(proc):
    if proc is None or proc.poll() is not None:return
    for sig,seconds in ((signal.SIGINT,30),(signal.SIGTERM,10),(signal.SIGKILL,5)):
        try:os.killpg(proc.pid,sig)
        except ProcessLookupError:pass
        try:proc.wait(timeout=seconds);return
        except subprocess.TimeoutExpired:continue
    raise RuntimeError('Owned recipe manager did not reap')
def main():
    global CURRENT,STOP
    Path(os.environ['RECSCRIBE_RUN_DIR'],'.pin').touch(exist_ok=True)
    parser=argparse.ArgumentParser();parser.add_argument('--recipe',type=Path,required=True);parser.add_argument('--recipe-sha256',required=True)
    parser.add_argument('--asr-exit-code',type=int,required=True);parser.add_argument('--root-authorized',action='store_true');a=parser.parse_args()
    require(a.root_authorized and a.asr_exit_code==0,'Explicit root authorization and actual ASR exit0 required')
    def stop(*_):
        global STOP
        STOP=True
        if CURRENT is not None and CURRENT.poll() is None:
            try:os.killpg(CURRENT.pid,signal.SIGINT)
            except ProcessLookupError:pass
    for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,stop)
    recipe,rd=metadata(a.recipe,a.recipe_sha256)
    require(recipe['schema_version']=='round5-final-execution-recipe-v1' and [s['id'] for s in recipe['steps']]==['postrun','summary','projection','numeric'],'Exact frozen four-step recipe required')
    for d in recipe['metadata_inputs']:descriptor(d['path'],d['sha256'],4*1024**2)
    first=recipe['steps'][0]['source_argv'];journal=Path(first[first.index('--journal')+1])
    jd=descriptor(journal,cap=4*1024**2);raw=journal.read_bytes();require(sha(raw)==jd['sha256'],'Final journal changed')
    events=[json.loads(line) for line in raw.splitlines() if line.strip()]
    require(events and events[-1].get('event')=='serial_finished' and len([e for e in events if e.get('event')=='stage_assessed'])==15,'All15 terminal barrier required')
    require(not any(e.get('event') in ('serial_stopped','owned_guard_cleanup_pending') for e in events),'Stopped campaign may not execute final recipe')
    for step in recipe['steps']:require(not Path(step['output']).exists() and not Path(step['guard_receipt']).exists(),'New-only output/log required; no retry or overwrite')
    run=R/'final-execution.v1';run.mkdir(mode=0o700,exist_ok=False)
    tokens={'<FINAL_SERIAL_JOURNAL_SHA256>':jd['sha256']};results=[];failure=None
    for step in recipe['steps']:
        name=step['id'];command=[tokens.get(arg,arg) for arg in step['managed_guarded_argv']]
        require(not any(arg.startswith('<') and arg.endswith('>') for arg in command),'Unresolved predecessor SHA token')
        if STOP:failure={'step':name,'kind':'root_or_user_canceled'};break
        print(json.dumps({'event':'step_start','step':name,'journal_sha256':jd['sha256']}),flush=True)
        console=run/(name+'.console.log');begin=time.monotonic();item={'step':name,'command':command,'started_utc':datetime.now(timezone.utc).isoformat()}
        try:
            with console.open('xb') as out:
                CURRENT=subprocess.Popen(command,cwd=W,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
                try:code=CURRENT.wait(timeout=step['seconds']+90)
                except BaseException:
                    terminate_owned(CURRENT);raise
            item.update(returncode=code,elapsed_seconds=time.monotonic()-begin,console=descriptor(console))
            require(not STOP and code==0,'Guarded step returned nonzero/canceled')
            gd=descriptor(step['guard_receipt'],cap=4*1024**2);guard=[json.loads(x) for x in Path(step['guard_receipt']).read_bytes().splitlines()];last=guard[-1];shutdown=last.get('shutdown',{})
            require(last.get('event')=='finished' and last.get('canceled') is False and last.get('reason') is None and last.get('failure') is None
              and shutdown.get('returncode')==0 and type(shutdown.get('returncode')) is int and shutdown.get('cli_reaped') is True
              and shutdown.get('owned_session_present') is False and shutdown.get('shutdown_errors')==[]
              and not any(e.get('event') in ('owned_group_signal','owned_cli_signal','cancel_requested','interrupted','cancelled') for e in guard),'Guard did not close naturally/reap cleanly')
            target=Path(step['output'])/{'postrun':'preservation.json','summary':'summary.json','projection':'audit.json','numeric':'receipt.json'}[name]
            od=descriptor(target);item.update(status='PASSED_GUARDED_EXECUTION',receipt=od,guard=gd)
            if name=='postrun':tokens.update({'<POSTRUN_PRESERVATION_SHA256>':od['sha256'],'<POSTRUN_CLOSED_GUARD_SHA256>':gd['sha256']})
            elif name=='summary':tokens['<SUMMARY_SHA256>']=od['sha256']
            elif name=='projection':tokens['<PROJECTION_AUDIT_SHA256>']=od['sha256']
        except BaseException as error:
            item.update(status='FAILED_STOPPED_NO_RETRY',error_type=type(error).__name__,error=str(error),elapsed_seconds=time.monotonic()-begin)
            if console.exists():item['console']=descriptor(console)
            failure={'step':name,'kind':type(error).__name__};results.append(item)
            sd=put(run/(name+'.execution.json'),item)
            print(json.dumps({'event':'step_finished','step':name,'status':item['status'],'execution_receipt':sd,'failure':failure}),flush=True);break
        finally:CURRENT=None
        results.append(item);sd=put(run/(name+'.execution.json'),item)
        print(json.dumps({'event':'step_finished','step':name,'status':item['status'],'receipt':item['receipt'],'guard':item['guard'],'execution_receipt':sd,'elapsed_seconds':item['elapsed_seconds']}),flush=True)
    passed=failure is None and len(results)==4 and all(x['status']=='PASSED_GUARDED_EXECUTION' for x in results)
    value={'schema_version':'round5-final-recipe-actual-execution-v1','created_utc':datetime.now(timezone.utc).isoformat(),
      'status':'ALL_FOUR_GUARDED_STEPS_PASSED' if passed else 'STOPPED_RETAINED_NO_RETRY','source':descriptor(Path(__file__).resolve()),
      'recipe':rd,'final_journal':jd,'actual_asr_exit_code_attested_by_root':a.asr_exit_code,'ordered_terminal_stage_count':15,
      'final_operational_counts':{k:events[-1].get(k) for k in ('planned_cells','attempted_cells','completed_cells','failed_cells','planned_native_parent_pairs','completed_native_parent_pairs','pending_native_parent_pairs','planned_assessor_derived_q4_pairs','completed_assessor_derived_q4_pairs','runtime_reference_placeholders')},
      'resolved_hashes':tokens,'steps':results,'failure':failure,'inference_or_scoring_retries':False,'source_or_gates_or_checkout_modified':False,
      'quality_findings_released_before_independent_audit_pass':False,'default_promotion':False}
    final=put(run/'execution.receipt.json',value);print(json.dumps({'event':'recipe_finished','status':value['status'],'receipt':final}),flush=True)
    return 0 if passed else 1
if __name__=='__main__':raise SystemExit(main())
