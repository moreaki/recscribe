#!/usr/bin/env python3
"""Verified logical event projection; both raw journals and the stop stay intact."""
import argparse,hashlib,json,re,signal,stat,time
from datetime import datetime,timezone
from pathlib import Path

R=Path(__file__).absolute().parent.parent
FAMILY='8058f9785929639d70da620fd6f12841b3078aa17352f6d02b542b6a7f191fe2'
ADMISSION='1e9d6a0dbea1fd9f9df2ece06a9044e24eb4f2b37c259500cca87545e9d29153'
ORIGINAL='72a096b9b51912569c9b37ddc8c4ac7098b4040eea1be96e337335c4b13196e5'
MODELS=('tiny','base','small','large-v3-turbo','large-v3')
IDS=[p+m for p in ('panel-','dev-validation-','heldout-') for m in MODELS]
FIELDS=('planned_cells','attempted_cells','completed_cells','failed_cells','planned_native_parent_pairs','completed_native_parent_pairs','pending_native_parent_pairs','planned_assessor_derived_q4_pairs','completed_assessor_derived_q4_pairs','pending_assessor_derived_q4_pairs','runtime_reference_placeholders')
LOGICAL=R/'logical-serial-continuation-v1.events.jsonl'
RECEIPT=R/'logical-serial-continuation-v1.receipt.json'
STOP=False;DEADLINE=None
def need(ok,msg):
    if not ok:raise ValueError(msg)
def valid(v):return isinstance(v,str) and re.fullmatch('[0-9a-f]{64}',v) is not None
def integer(v):return type(v) is int and v>=0
def digest(b):return hashlib.sha256(b).hexdigest()
def check():
    if STOP or (R/'cancel-journal-projection.request').exists():raise InterruptedError('Projection canceled')
    if DEADLINE is not None and time.monotonic()>DEADLINE:raise TimeoutError('Projection time bound exceeded')
def decode(b):
    def pairs(items):
        d={}
        for k,v in items:need(k not in d,'Duplicate metadata key');d[k]=v
        return d
    return json.loads(b,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('Nonfinite metadata')))
def read(path,sha,callback=check):
    callback();p=Path(path)
    need(valid(sha) and p.is_absolute() and R in p.parents and '..' not in p.parts and p.suffix in {'.json','.jsonl','.py'}
        and not any(x.is_symlink() for x in (p,*p.parents)),'Explicit protected metadata/source required')
    a=p.stat();need(stat.S_ISREG(a.st_mode) and a.st_size<=4*1024**2,'Metadata bound exceeded')
    with p.open('rb') as f:b=f.read(4*1024**2+1)
    z=p.stat();identity=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    need(len(b)<=4*1024**2 and identity(a)==identity(z) and digest(b)==sha,'Metadata identity/SHA differs');callback();return b
def events(b):
    e=[decode(line) for line in b.splitlines() if line.strip()];need(all(isinstance(x,dict) for x in e),'Object events required');return e
def canonical_lines(es):return b''.join((json.dumps(e,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)+'\n').encode() for e in es)
def descriptor(path,sha):return {'path':str(path),'sha256':sha}
def same_pin(a,b):
    return isinstance(a,dict) and isinstance(b,dict) and all(a.get(k)==b.get(k) for k in ('path','sha256'))

def project(cap,old,new,cap_pin,old_pin,new_pin,source_pin):
    """Pure exact-grid admission. No stage outcome paths are opened here."""
    need(cap.get('schema_version')=='round4-metadata-filename-continuation-v1'
        and cap.get('original_family',{}).get('sha256')==FAMILY and cap.get('original_admission',{}).get('sha256')==ADMISSION
        and same_pin(cap.get('original_journal'),old_pin) and same_pin(old_pin,descriptor(R/'serial.events.jsonl',ORIGINAL)),'Frozen original chain differs')
    expected={'reused_attempted_cells':738,'reused_completed_cells':737,'reused_failed_cells':1,'remaining_inference_cells':3816,
        'planned_cells':4554,'planned_native_parent_pairs':2484,'planned_assessor_derived_q4_pairs':828,'planned_reference_runtime_placeholders':1242}
    need(all(type(cap.get(k)) is int and cap[k]==v for k,v in expected.items()),'Prospective exact counts differ')
    need(cap.get('sources',{}).get('journal_projector')==source_pin,'Projector source not frozen in continuation capsule')
    need(all(cap.get(k) is False for k in ('allow_inference_retries','model_settings_changed','scorer_changed','quality_gates_changed')),
        'Continuation cannot change retry/settings/scorer/gates')
    need(isinstance(cap.get('base_stop_proof'),dict) and valid(cap['base_stop_proof'].get('sha256')),'Frozen basename-only stop proof required')
    need(old and old[0].get('event')=='serial_started' and old[-1].get('event')=='serial_stopped'
        and sum(e.get('event')=='serial_stopped' for e in old)==1
        and not any(e.get('event') in {'serial_finished','heldout_family_accepted'} for e in old),'Original stop chronology differs')
    stop=old[-1]
    need(stop.get('error_type')=='ValueError' and stop.get('error')=='dev-validation-base/classify_finite_native_output_failure failed; later inference not started'
        and stop.get('default_promotion') is False,'Only exact metadata-filename stop admitted')
    need(old[0].get('family_seal_sha256')==FAMILY and old[0].get('initial_attestation')==cap.get('initial_attestation')
        and old[0].get('coordinator_sha256')==cap['sources']['original_coordinator']['sha256'],'Original coordinator/attestation differs')
    starts=[e for e in old if e.get('event')=='command_start' and e.get('action')=='guarded_inference']
    ends=[e for e in old if e.get('event')=='command_finished' and e.get('action')=='guarded_inference']
    before=[e for e in old if e.get('event')=='stage_assessed']
    need([e.get('stage') for e in starts]==[e.get('stage') for e in ends]==IDS[:7] and [e.get('id') for e in before]==IDS[:6]
        and all(type(e.get('returncode')) is int and e['returncode']==int(i==6) for i,e in enumerate(ends)),'Original exact seven launches/six assessments differs')
    retained=cap.get('retained_stages',[])
    need(len(retained)==7 and [s.get('id') for s in retained]==IDS[:7],'Seven retained stages required')
    for i,s in enumerate(retained):
        need(all(isinstance(s.get(k),dict) and valid(s[k].get('sha256')) for k in ('matrix','guard')),'Retained matrix/guard pin missing')
        if i<6:
            need(all(isinstance(s.get(k),dict) and valid(s[k].get('sha256')) for k in ('report','assessment')),'Retained report/assessment pin missing')
            for field,key in (('matrix','matrix_sha256'),('guard','guard_sha256'),('report','report_sha256'),('assessment','assessment_sha256')):
                need(s[field]['sha256']==before[i].get(key),'Retained assessment evidence changed')
        else:need(s.get('report') is None and s.get('assessment') is None,'Base postprocessing cannot pretend already assessed')
    badstart,badend=old[-3:-1]
    need(badstart.get('event')=='command_start' and badstart.get('stage')=='dev-validation-base' and badstart.get('action')=='classify_finite_native_output_failure'
        and badend.get('event')=='command_finished' and badend.get('returncode')==1,'Wrong-name classifier attempt not retained')
    cmd=badstart.get('command',[])
    need(len(cmd)==8 and cmd[1]==cap['sources']['classifier']['path'] and cmd[2:]==['--matrix',str(R/'dev-validation-base/matrix/matrix.json'),'--output',str(R/'dev-validation-base/natural-failures.json'),'--expected-source-sha256',cap['sources']['classifier']['sha256']],'Original stop was not exact wrong output basename')
    need(new and new[0].get('event')=='continuation_started' and new[-1].get('event')=='continuation_finished'
        and sum(e.get('event')=='continuation_started' for e in new)==sum(e.get('event')=='continuation_finished' for e in new)==1
        and not any(e.get('event') in {'serial_stopped','continuation_stopped','serial_finished'} for e in new),'All remaining attempts must finish before projection')
    start,finish=new[0],new[-1]
    need(start.get('original_family_seal_sha256')==FAMILY and finish.get('family_seal_sha256')==FAMILY
        and all(type(start.get(k)) is int and start[k]==expected[k] for k in ('reused_attempted_cells','reused_completed_cells','reused_failed_cells','remaining_inference_cells')),'Continuation actual launch scope differs')
    for e in (start,finish):
        need(e.get('continuation_capsule_sha256')==cap_pin['sha256'] and same_pin(e.get('original_journal'),old_pin)
            and same_pin(e.get('original_admission'),cap['original_admission']) and e.get('initial_attestation')==cap['initial_attestation']
            and e.get('default_promotion') is False,'Continuation capsule/raw/attestation chain differs')
    need(start.get('controller_sha256')==cap['sources']['controller']['sha256'],'Actual continuation controller differs')
    revalidated=[e for e in new if e.get('event')=='retained_stage_revalidated']
    need([e.get('id') for e in revalidated]==IDS[:7],'All seven retained attempts must be revalidated')
    for s,e in zip(retained,revalidated):
        need(e.get('matrix_sha256')==s['matrix']['sha256'] and e.get('guard_sha256')==s['guard']['sha256'],'Retained matrix/guard revalidation differs')
        for field in ('report','assessment'):
            if s[field]:need(e.get(field+'_sha256')==s[field]['sha256'],'Old assessed evidence changed')
    aliases=[e for e in new if e.get('event')=='classifier_receipt_alias_created']
    need(aliases,'Base filename compatibility alias missing')
    seen_alias=set()
    for e in aliases:
        stage=e.get('stage');need(stage in IDS[6:] and stage not in seen_alias,'Unplanned/duplicate classifier alias');seen_alias.add(stage)
        need(e.get('byte_identical') is True and e.get('classification_source')==cap['sources']['classifier']
            and e.get('versioned_receipt',{}).get('path')==str(R/stage/'natural-failures.attempted-v2.json')
            and e.get('canonical_receipt',{}).get('path')==str(R/stage/'natural-failures.json')
            and valid(e['versioned_receipt'].get('sha256')) and e['canonical_receipt'].get('sha256')==e['versioned_receipt']['sha256'],'Only byte-identical metadata receipt aliases admitted')
        if stage==IDS[6]:need(same_pin(e['versioned_receipt'],cap['base_classification']),'Frozen Base classification changed')
    need(IDS[6] in seen_alias,'Base compatibility receipt alias is mandatory')
    after=[e for e in new if e.get('event')=='stage_assessed']
    launches=[e for e in new if e.get('event')=='command_start' and e.get('action')=='guarded_inference']
    ended=[e for e in new if e.get('event')=='command_finished' and e.get('action')=='guarded_inference']
    need([e.get('id') for e in after]==IDS[6:] and [e.get('stage') for e in launches]==[e.get('stage') for e in ended]==IDS[7:],'Continuation may run only eight untouched stages; no retry')
    need(all(new.index(e)<new.index(after[0]) for e in revalidated)
        and all(new.index(e)<new.index(next(a for a in after if a['id']==e['stage'])) for e in aliases),'Retained validation and classifier aliases must precede assessment')
    combined=before+after;totals={k:sum(e.get(k,-10**9) for e in combined) for k in FIELDS}
    need(all(all(integer(e.get(k)) for k in FIELDS) for e in combined)
        and all(all(valid(e.get(k)) for k in ('matrix_sha256','guard_sha256','report_sha256','assessment_sha256','plan_sha256')) and e.get('default_promotion') is False for e in combined)
        and all(type(finish.get(k)) is int and finish[k]==v for k,v in totals.items())
        and totals['planned_cells']==totals['attempted_cells']==4554 and totals['completed_cells']+totals['failed_cells']==4554
        and totals['planned_native_parent_pairs']==totals['completed_native_parent_pairs']+totals['pending_native_parent_pairs']==2484
        and totals['planned_assessor_derived_q4_pairs']==totals['completed_assessor_derived_q4_pairs']+totals['pending_assessor_derived_q4_pairs']==828
        and totals['runtime_reference_placeholders']==1242,'Final unique attempt/pair/placeholder accounting differs')
    need(finish.get('status')=='completed_with_failures' and type(finish.get('observed_rows')) is int and finish['observed_rows']==4554,'Retained failed cell or attempted row count cannot disappear from completion status')
    need(after[0]['attempted_cells']==72 and after[0]['completed_cells']==71 and after[0]['failed_cells']==1
        and sum(e['attempted_cells'] for e in combined[:7])==738,'Retained Base failure cannot be retried or recovered')
    logical=list(old[:-1])+[{'event':'verified_prior_serial_stop','created_utc':stop['created_utc'],'original_event':stop,
        'original_journal':old_pin,'continuation_capsule':cap_pin,'interpretation':'Actual stopped raw journal retained unchanged; metadata-filename-only continuation, no inference retry'}]+list(new)
    final={**finish,'event':'serial_finished','family_seal_sha256':FAMILY,'status':'completed_with_failures' if totals['failed_cells'] else 'completed',
        'logical_projection':{'derived_from_actual_event':'continuation_finished','original_journal':old_pin,'continuation_journal':new_pin,'continuation_capsule':cap_pin,'actual_stop_retained_as':'verified_prior_serial_stop'}}
    logical.append(final)
    # Independently prove serial chronology expected by frozen report/gate code.
    ls=[e for e in logical if e.get('event')=='command_start' and e.get('action')=='guarded_inference']
    le=[e for e in logical if e.get('event')=='command_finished' and e.get('action')=='guarded_inference']
    la=[e for e in logical if e.get('event')=='stage_assessed']
    need([e.get('stage') for e in ls]==[e.get('stage') for e in le]==[e.get('id') for e in la]==IDS,'Logical unique full grid differs')
    previous=0
    for a,b,c in zip(ls,le,la):
        need(previous<logical.index(a)<logical.index(b)<logical.index(c),'Cross-stage overlap/retry in logical chronology');previous=logical.index(c)
    releases=[e for e in logical if e.get('event')=='heldout_family_accepted'];need(len(releases)==1,'Exactly one held release required')
    need(logical.index(la[9])<logical.index(releases[0])<logical.index(ls[10]),'All10 before all5 release required')
    return logical,{'original_journal':old_pin,'continuation_journal':new_pin,'continuation_capsule':cap_pin,'projector_source':source_pin,
        'stop_provenance':{'original_stop_event':stop,'original_stop_preserved':True,'logical_marker':'verified_prior_serial_stop','cause':'classifier output basename API mismatch before postprocessing'},
        'coverage':totals,'retained_attempted_cells':738,'new_inference_cells':3816,'no_inference_retry':True,'no_scoring_or_gate_change':True,'default_promotion':False}

def inputs(capsule_path,capsule_sha,new_sha,callback=check):
    need(Path(capsule_path)==R/'continuation.freeze.v1.json','Exact continuation capsule required')
    cap=decode(read(capsule_path,capsule_sha,callback));source=cap['sources']['journal_projector']
    need(source['path']==str(Path(__file__).absolute()),'Projector path differs');read(source['path'],source['sha256'],callback)
    oldpin=descriptor(R/'serial.events.jsonl',ORIGINAL);newpin=descriptor(R/'serial-continuation-v1.events.jsonl',new_sha)
    old=events(read(oldpin['path'],oldpin['sha256'],callback));new=events(read(newpin['path'],newpin['sha256'],callback))
    logical,proof=project(cap,old,new,descriptor(capsule_path,capsule_sha),oldpin,newpin,source)
    read(cap['base_stop_proof']['path'],cap['base_stop_proof']['sha256'],callback)
    classification=decode(read(cap['base_classification']['path'],cap['base_classification']['sha256'],callback))
    need(classification.get('all_failures_classified') is True and classification.get('failure_count')==1
        and classification.get('unclassified_cells')==[] and all(classification.get(k) is False for k in ('recognition_performed','rescoring_performed','retry_performed')),'Frozen Base classification not admissible')
    for alias in (e for e in new if e.get('event')=='classifier_receipt_alias_created'):
        for key in ('versioned_receipt','canonical_receipt'):read(alias[key]['path'],alias[key]['sha256'],callback)
    return logical,{**proof,'base_stop_proof':cap['base_stop_proof'],'base_classification':cap['base_classification']}

def validate_chain(capsule_path,capsule_sha256,projection_path,projection_sha256,logical_journal_sha256,check=lambda:None):
    need(Path(projection_path)==RECEIPT,'Exact projection receipt required')
    receipt=decode(read(projection_path,projection_sha256,check))
    need(receipt.get('schema_version')=='round4-verified-logical-journal-projection-v1','Projection version differs')
    logical,proof=inputs(capsule_path,capsule_sha256,receipt['continuation_journal']['sha256'],check)
    data=canonical_lines(logical);actual=read(LOGICAL,logical_journal_sha256,check)
    need(data==actual and receipt.get('logical_journal')==descriptor(LOGICAL,logical_journal_sha256)
        and all(receipt.get(k)==v for k,v in proof.items()),'Logical projection/recovery chain differs from both immutable raw journals')
    return {**proof,'events':logical,'logical_journal':descriptor(LOGICAL,logical_journal_sha256),'projection_receipt':descriptor(projection_path,projection_sha256)}

def main():
    global DEADLINE,STOP
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('continuation-freeze','continuation-freeze-sha256','continuation-journal-sha256','expected-source-sha256'):p.add_argument('--'+name,required=True)
    a=p.parse_args();DEADLINE=time.monotonic()+45
    for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,lambda *_:globals().__setitem__('STOP',True))
    read(Path(__file__).absolute(),a.expected_source_sha256)
    logical,proof=inputs(Path(a.continuation_freeze),a.continuation_freeze_sha256,a.continuation_journal_sha256)
    need(proof['projector_source']['sha256']==a.expected_source_sha256,'Explicit source lock differs')
    need(not LOGICAL.exists() and not RECEIPT.exists(),'New-only projection outputs required')
    data=canonical_lines(logical);receipt={'schema_version':'round4-verified-logical-journal-projection-v1','created_utc':datetime.now(timezone.utc).isoformat(),
        **proof,'logical_journal':descriptor(LOGICAL,digest(data)),'status':'PASS_VERIFIED_RAW_CHAIN_LOGICAL_PROJECTION_NOT_A_RAW_JOURNAL',
        'recognition_performed':False,'rescoring_performed':False,'payload_paths_followed':False}
    encoded=(json.dumps(receipt,indent=2,allow_nan=False)+'\n').encode();need(len(data)+len(encoded)<=8*1024**2,'Output bound exceeded')
    for path,b in ((LOGICAL,data),(RECEIPT,encoded)):
        check()
        with path.open('xb') as f:f.write(b)
        path.chmod(0o600)
    print(json.dumps({'logical_journal':receipt['logical_journal'],'projection_receipt':descriptor(RECEIPT,digest(encoded)),'default_promotion':False}))
if __name__=='__main__':main()
