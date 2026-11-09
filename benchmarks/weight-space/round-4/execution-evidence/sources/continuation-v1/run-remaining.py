#!/usr/bin/env python3
"""Prospective filename-only continuation; never repeat retained inference.

The original8058/c0fc/cf975/b5 tools, data, settings, models and journal remain
immutable. The classifier receives its required versioned filename; only after
the same finite, unscored terminal proof passes is an exclusive byte-identical
canonical metadata alias created for the unchanged sealer. No text recovery.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys

ROOT=Path(__file__).resolve().parent.parent
FAMILY_SHA='8058f9785929639d70da620fd6f12841b3078aa17352f6d02b542b6a7f191fe2'
ADMISSION_SHA='1e9d6a0dbea1fd9f9df2ece06a9044e24eb4f2b37c259500cca87545e9d29153'
OLD_JOURNAL_SHA='72a096b9b51912569c9b37ddc8c4ac7098b4040eea1be96e337335c4b13196e5'
ORIGINAL_SHA='c0fc46a4e51895b8c1587ccf61c9e28f9c7b86ad67e2d3bdee0b9fccea1a6cc4'
SEALER_SHA='cf97523a03e6843fb8fcb4fec2151b41db4f6c08fddf69e65c77fddc20346dad'
CLASSIFIER_SHA='b5fa141cab70dce2401d095aacc3f4d192b92e157878afddfb72a4a4608bc353'
GUARD_SHA='7697f60e8a2c0aa150b598afe2e8c552435e1d8a4cb2f99489c9fa10de0dc56c'
FIELDS=('attempted_cells','completed_cells','failed_cells','planned_native_parent_pairs','completed_native_parent_pairs',
        'pending_native_parent_pairs','planned_assessor_derived_q4_pairs','completed_assessor_derived_q4_pairs',
        'pending_assessor_derived_q4_pairs','runtime_reference_placeholders')

def require(ok,message):
    if not ok:raise ValueError(message)
def valid_sha(value):return isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None
def raw(path,expected=None,maximum=64*1024**2):
    path=Path(path);require(path.is_absolute() and '..' not in path.parts and path.suffix in {'.json','.jsonl','.py'}
        and not any(p.is_symlink() for p in (path,*path.parents)),'Only explicit nonsymlink metadata/source files may open')
    before=path.stat();identity=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    require(stat.S_ISREG(before.st_mode) and before.st_size<=maximum,'Metadata/source exceeds bound')
    with path.open('rb') as f:data=f.read(maximum+1)
    digest=hashlib.sha256(data).hexdigest()
    require(len(data)<=maximum and identity(path.stat())==identity(before)
        and (expected is None or valid_sha(expected) and digest==expected),'Metadata/source changed or SHA differs')
    return data,digest
def fields(items):
    out={}
    for k,v in items:require(k not in out,'Duplicate JSON key');out[k]=v
    return out
def decode(data):
    return json.loads(data,object_pairs_hook=fields,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('Nonfinite JSON')))
def read(path,expected=None):
    b,h=raw(path,expected);v=decode(b);require(isinstance(v,dict),'Object metadata required');return v,h
def events(path,expected=None):
    b,h=raw(path,expected,4*1024**2);v=[decode(x) for x in b.splitlines() if x.strip()]
    require(all(isinstance(x,dict) for x in v),'Object events required');return v,h
def descriptor(path):
    _,digest=raw(path);return {'path':str(path),'sha256':digest}
def source_module(path,expected,name):
    raw(path,expected,4*1024**2);s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s)
    sys.modules[name]=m;s.loader.exec_module(m);return m

ORIGINAL=source_module(ROOT/'run-remaining.py',ORIGINAL_SHA,'round4_immutable_original_controller')

def validate_original_prefix(family,old,capsule):
    stages=family['stages'];first=[s['id'] for s in stages[:7]]
    require(old and old[0].get('event')=='serial_started' and old[-1].get('event')=='serial_stopped'
        and old[0].get('family_seal_sha256')==FAMILY_SHA and old[0].get('coordinator_sha256')==ORIGINAL_SHA
        and old[0].get('initial_attestation')==capsule['initial_attestation']
        and not any(e.get('event') in {'heldout_family_accepted','serial_finished','owned_guard_cleanup_pending'} for e in old),
        'Original stop is not the exact pre-held-out metadata-only boundary')
    assessed=[e for e in old if e.get('event')=='stage_assessed']
    launches=[e for e in old if e.get('event')=='command_start' and e.get('action')=='guarded_inference']
    ends=[e for e in old if e.get('event')=='command_finished' and e.get('action')=='guarded_inference']
    require([e.get('id') for e in assessed]==first[:6] and [e.get('stage') for e in launches]==first
        and [(e.get('stage'),e.get('returncode')) for e in ends]==[(x,0 if i<6 else 1) for i,x in enumerate(first)]
        and all(type(e.get('returncode')) is int for e in ends),'Exactly six assessed/seven once-only inference grids required')
    for i,(launch,end) in enumerate(zip(launches,ends)):
        require(old.index(launch)<old.index(end) and (i==0 or old.index(assessed[i-1])<old.index(launch)),
                'Original retained inference order differs')
        if i<6:require(old.index(end)<old.index(assessed[i]),'Original assessment precedes its inference completion')
    base=ROOT/'dev-validation-base';action='classify_finite_native_output_failure'
    wrong=[e for e in old if e.get('event')=='command_start' and e.get('action')==action]
    require(len(wrong)==1 and wrong[0].get('stage')==stages[6]['id'],'One exact filename-contract failure required')
    argv=wrong[0].get('command',[])
    require(isinstance(argv,list) and len(argv)==8 and argv[1:]==[family['tools']['failure_classifier']['path'],
        '--matrix',str(base/'matrix/matrix.json'),'--output',str(base/'natural-failures.json'),
        '--expected-source-sha256',CLASSIFIER_SHA],'Original classifier failure command differs')
    require(old[-3] is wrong[0] and old[-2].get('event')=='command_finished' and old[-2].get('stage')==stages[6]['id']
        and old[-2].get('action')==action and type(old[-2].get('returncode')) is int and old[-2]['returncode']==1
        and old[-1].get('error_type')=='ValueError'
        and old[-1].get('error')=='dev-validation-base/classify_finite_native_output_failure failed; later inference not started'
        and old[-1].get('default_promotion') is False,'Stop cause is not solely the frozen classifier filename contract')
    return assessed

def classification_proof(family,stage,versioned,expected_sha=None):
    family.check();folder=Path(stage['configuration']).parent
    require(Path(versioned)==folder/'natural-failures.attempted-v2.json','Classifier must keep its unchanged exact versioned filename')
    canonical=folder/'natural-failures.json'
    require(not canonical.exists() and not canonical.is_symlink() and not (folder/'matrix/cancel.request').exists(),
            'Canonical alias must be new and campaign must not be canceled')
    data,digest=raw(versioned,expected_sha);value=decode(data)
    matrix,matrix_sha=family.tool_common.read(folder/'matrix/matrix.json',check=family.check)
    guard,_=family.guard_metadata(folder/'matrix.guard.jsonl')
    require(isinstance(value,dict) and value.get('classifier')==family.tools['failure_classifier']
        and value.get('matrix')=={'path':str(folder/'matrix/matrix.json'),'sha256':matrix_sha}
        and type(value.get('matrix_bytes')) is int and value['matrix_bytes']==(folder/'matrix/matrix.json').stat().st_size
        and value.get('classified_failure_count')==value.get('failure_count')
        and all(value.get(k) is False for k in ('reference_audio_model_paths_followed','text_emitted','source_bytes_modified')),
        'Versioned receipt does not preserve the exact frozen matrix/classifier/unscored scope')
    counts=family.tool_common.validate_terminal_attempts(stage,family.plans[stage['id']],matrix,guard[-1],value)
    require(counts['failed_cells']>0,'A metadata alias cannot manufacture a successful-grid failure')
    family.check();return data,digest,counts

def alias_classification(family,stage,versioned,expected_sha=None,note=lambda *_a,**_k:None):
    data,digest,counts=classification_proof(family,stage,versioned,expected_sha)
    canonical=Path(stage['configuration']).parent/'natural-failures.json'
    family.check();fd=os.open(canonical,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as target:target.write(data);target.flush();os.fsync(target.fileno())
    family.check();require(raw(canonical)[0]==data and raw(versioned,digest)[0]==data,'Classifier alias bytes changed')
    note('classifier_receipt_alias_created',stage=stage['id'],versioned_receipt={'path':str(versioned),'sha256':digest},
         canonical_receipt={'path':str(canonical),'sha256':digest},byte_identical=True,
         classification_source=family.tools['failure_classifier'],default_promotion=False)
    return counts

class Continued(ORIGINAL.Coordinator):
    def __init__(self,capsule_path,capsule_sha,expected_source_sha,signal_requested=lambda:False):
        require(Path(capsule_path)==ROOT/'continuation.freeze.v1.json' and valid_sha(capsule_sha)
            and valid_sha(expected_source_sha),'Explicit exact continuation path/source/SHA required')
        raw(Path(__file__).resolve(),expected_source_sha,4*1024**2)
        capsule,_=read(capsule_path,capsule_sha);self.capsule=capsule;self.capsule_path=Path(capsule_path);self.capsule_sha=capsule_sha
        self.controller_sha=expected_source_sha
        expected={'reused_attempted_cells':738,'reused_completed_cells':737,'reused_failed_cells':1,'remaining_inference_cells':3816,
            'planned_cells':4554,'planned_native_parent_pairs':2484,'planned_assessor_derived_q4_pairs':828,'planned_reference_runtime_placeholders':1242}
        require(capsule.get('schema_version')=='round4-metadata-filename-continuation-v1'
            and all(type(capsule.get(k)) is int and capsule[k]==v for k,v in expected.items())
            and capsule.get('reason_class')=='classifier_output_filename_contract_mismatch'
            and capsule.get('classifier_filename_adapter_only') is True and capsule.get('byte_identical_receipt_alias_only') is True
            and all(capsule.get(k) is False for k in ('allow_inference_retries','model_settings_changed','scorer_changed','quality_gates_changed','default_promotion')),
            'Continuation changes more than the prospective metadata filename adapter')
        require(capsule.get('original_family')=={'path':str(ROOT/'pre-inference-family-seal.json'),'sha256':FAMILY_SHA}
            and capsule.get('original_admission')=={'path':str(ROOT/'inference-launch.freeze.v1.json'),'sha256':ADMISSION_SHA}
            and capsule.get('original_journal')=={'path':str(ROOT/'serial.events.jsonl'),'sha256':OLD_JOURNAL_SHA}
            and capsule.get('continuation_journal')==str(ROOT/'serial-continuation-v1.events.jsonl')
            and capsule.get('logical_journal')==str(ROOT/'logical-serial-continuation-v1.events.jsonl'),
            'Immutable original campaign/journal/admission or new output paths differ')
        sources=capsule.get('sources',{});require(set(sources)=={'original_coordinator','sealer','classifier','guard','controller','journal_projector'},'Exact continuation sources required')
        expected_sources={'original_coordinator':(ROOT/'run-remaining.py',ORIGINAL_SHA),'sealer':(ROOT/'seal-heldout.py',SEALER_SHA),
            'classifier':(ROOT/'classify-native-output-failure-v2.py',CLASSIFIER_SHA),'guard':(ROOT/'run-guard.py',GUARD_SHA),
            'controller':(Path(__file__).resolve(),expected_source_sha)}
        for key,(path,digest) in expected_sources.items():require(sources[key]=={'path':str(path),'sha256':digest},'Continuation source differs: '+key)
        require(sources['journal_projector']['path']==str(ROOT/'continuation-v1/project-journal.py') and valid_sha(sources['journal_projector'].get('sha256')),
            'Explicit logical journal projection source required')
        for value in (*sources.values(),capsule['original_admission'],capsule['base_stop_proof']):raw(value['path'],value['sha256'])
        super().__init__(ROOT/'pre-inference-family-seal.json',FAMILY_SHA,ORIGINAL_SHA,capsule['initial_attestation'],signal_requested)
        self.family.tool_common=self.common
        self.old,_=events(ROOT/'serial.events.jsonl',OLD_JOURNAL_SHA)
        self.old_assessed=validate_original_prefix(self.family.value,self.old,capsule)
        retained=capsule.get('retained_stages',[])
        require(len(retained)==7 and [x.get('id') for x in retained]==[s['id'] for s in self.family.value['stages'][:7]],'Exact seven retained grids required')
        for i,(item,stage) in enumerate(zip(retained,self.family.value['stages'])):
            folder=ROOT/stage['id']
            for key,path in [('matrix',folder/'matrix/matrix.json'),('guard',folder/'matrix.guard.jsonl')]:
                require(item[key]['path']==str(path),'Retained path differs');raw(path,item[key]['sha256'])
            for key,path in [('report',folder/'report-v1.1/report.json'),('assessment',folder/'assessment-v1/assessment.json')]:
                if i<6:
                    require(item[key]=={'path':str(path),'sha256':self.old_assessed[i][key+'_sha256']},'Retained assessed metadata differs')
                    raw(path,item[key]['sha256'])
                else:require(item.get(key) is None and not path.parent.exists(),'Base metadata must remain unexecuted until continuation')
        base=capsule['base_classification'];require(base['path']==str(ROOT/'dev-validation-base/natural-failures.attempted-v2.json'),
            'Exact Base versioned finite classification required');raw(base['path'],base['sha256'])

    def check(self):
        if (ROOT/'cancel-continuation-v1.request').exists():raise InterruptedError('Filename continuation canceled')
        super().check()

    def verify_recovery(self):
        self.check();raw(self.capsule_path,self.capsule_sha);raw(ROOT/'serial.events.jsonl',OLD_JOURNAL_SHA)
        for d in self.capsule['sources'].values():raw(d['path'],d['sha256'],4*1024**2)
        self.family.verify_step();self.check()

    def preflight(self):
        """Read-only proof: no journal, alias, report, assessment or NN launch."""
        self.family.verify_all();self.verify_recovery()
        proof=[]
        for i,stage in enumerate(self.family.value['stages'][:7]):
            if i<6:
                evidence=self.family.stage_evidence(stage)
                require(all(self.old_assessed[i].get(k)==v for k,v in evidence.items()),'Retained first-six body/evidence changed')
                proof.append(evidence)
            else:
                d=self.capsule['base_classification']
                _,_,counts=classification_proof(self.family,stage,Path(d['path']),d['sha256'])
                proof.append(counts)
        require(sum(x['attempted_cells'] for x in proof)==738 and sum(x['completed_cells'] for x in proof)==737
            and sum(x['failed_cells'] for x in proof)==1,'Read-only retained prefix count differs')
        require(not (ROOT/'heldout-family.freeze.json').exists(),'Held-out release already exists')
        for stage in self.family.value['stages'][7:]:
            folder=ROOT/stage['id']
            require(not any((folder/x).exists() for x in ('matrix','matrix.guard.jsonl','report-v1.1','assessment-v1','natural-failures.json',
                'natural-failures.attempted-v2.json','freeze.json','assessment-plan.final.json')),'Unexecuted stage already has outcome')
        self.check();return {'status':'passed_read_only_recovery_preflight','retained_attempted_cells':738,
            'retained_completed_cells':737,'retained_failed_cells':1,'remaining_inference_cells':3816,
            'continuation_capsule_sha256':self.capsule_sha,'original_journal':self.capsule['original_journal'],
            'canonical_receipt_alias_created':False,'recognition_or_retry_performed':False}

    def command(self,argv,stage,action,*,guarded=False,timeout=180):
        self.verify_recovery();selected=next((s for s in self.family.value['stages'] if s['id']==stage),None)
        if action=='classify_finite_native_output_failure':
            require(not guarded and selected is not None,'Only a metadata classifier command may be adapted')
            argv=list(argv);folder=Path(selected['configuration']).parent
            require(argv.count('--output')==1 and argv[argv.index('--output')+1]==str(folder/'natural-failures.json'),
                'Unexpected original classifier output argument')
            argv[argv.index('--output')+1]=str(folder/'natural-failures.attempted-v2.json')
        result=super().command(argv,stage,action,guarded=guarded,timeout=timeout)
        if action=='classify_finite_native_output_failure':
            alias_classification(self.family,selected,Path(selected['configuration']).parent/'natural-failures.attempted-v2.json',note=self.note)
        self.verify_recovery();return result

    def execute(self):
        journal=Path(self.capsule['continuation_journal']);require(not journal.exists(),'No continuation retry or resume')
        with journal.open('x',buffering=1) as stream:
            self.journal=stream
            try:
                self.family.verify_all();self.verify_recovery()
                require(not (ROOT/'heldout-family.freeze.json').exists(),'Held-out release already exists')
                for stage in self.family.value['stages'][7:]:
                    folder=ROOT/stage['id']
                    require(not any((folder/x).exists() for x in ('matrix','matrix.guard.jsonl','report-v1.1','assessment-v1','natural-failures.json',
                        'natural-failures.attempted-v2.json','freeze.json','assessment-plan.final.json')),'Unexecuted fixed stage already has outcome; no retry')
                self.note('continuation_started',continuation_capsule_sha256=self.capsule_sha,original_family_seal_sha256=FAMILY_SHA,
                    original_journal=self.capsule['original_journal'],original_admission=self.capsule['original_admission'],initial_attestation=self.family.attestation,
                    controller_sha256=self.controller_sha,reused_attempted_cells=738,reused_completed_cells=737,reused_failed_cells=1,remaining_inference_cells=3816,default_promotion=False)
                base=self.family.value['stages'][6];d=self.capsule['base_classification']
                alias_classification(self.family,base,Path(d['path']),d['sha256'],self.note)
                prior=[];retained_counts=[]
                for i,stage in enumerate(self.family.value['stages'][:7]):
                    _,counts=self.family.terminal(stage)
                    retained_counts.append(counts)
                    if i<6:
                        evidence=self.family.stage_evidence(stage)
                        require(all(self.old_assessed[i].get(k)==v for k,v in evidence.items()),'Retained first-six frozen assessment body/evidence changed')
                        prior.append(evidence)
                    self.note('retained_stage_revalidated',id=stage['id'],stage=stage['stage'],**counts,
                        report_sha256=self.old_assessed[i]['report_sha256'] if i<6 else None,
                        assessment_sha256=self.old_assessed[i]['assessment_sha256'] if i<6 else None,default_promotion=False)
                require(sum(x['planned_cells'] for x in self.family.value['stages'][:7])==738
                    and sum(x['attempted_cells'] for x in retained_counts)==738
                    and sum(x['completed_cells'] for x in retained_counts)==737
                    and sum(x['failed_cells'] for x in retained_counts)==1,'Retained exact attempted/successful/failed grid differs')
                folder=Path(base['configuration']).parent;tools=self.family.tools
                self.command([sys.executable,tools['reporter']['path'],str(folder/'matrix'),'--output',str(folder/'report-v1.1')],base['id'],'retained_metric_report')
                self.command([sys.executable,tools['assessor']['path'],str(folder/'report-v1.1/report.json'),'--matrix',str(folder/'matrix/matrix.json'),
                    '--plan',base['assessment_pre_freeze_plan'],'--output',str(folder/'assessment-v1')],base['id'],'frozen_assessment')
                evidence=self.family.stage_evidence(base);prior.append(evidence);self.note('stage_assessed',**evidence)
                prior += [self.stage_run(s) for s in self.family.value['stages'][7:10]]
                self.command([sys.executable,tools['sealer']['path'],'--family-seal',str(self.family.path),'--family-seal-sha256',FAMILY_SHA,
                    '--expected-source-sha256',tools['sealer']['sha256'],'--initial-attestation',self.family.attestation['path'],
                    '--initial-attestation-sha256',self.family.attestation['sha256'],'--output',str(ROOT/'heldout-family.freeze.json')],
                    'all-heldout','all_ten_terminal_then_all_five_freeze',timeout=300)
                self.heldout,self.heldout_sha=self.common.read(ROOT/'heldout-family.freeze.json',check=self.check)
                self.heldout_bindings();self.note('heldout_family_accepted',freeze_sha256=self.heldout_sha,partitions=self.heldout['partitions'],
                    family_seal_sha256=FAMILY_SHA,initial_attestation=self.family.attestation,analysis_source=tools['assessor'],default_promotion=False)
                prior += [self.stage_run(s) for s in self.family.value['stages'][10:]]
                self.family.verify_all();self.verify_recovery();bindings=self.heldout_bindings()
                final=[self.family.stage_evidence(s,bindings[s['id']] if s['stage']=='held_out' else None) for s in self.family.value['stages']]
                require(final==prior,'Final retained/new evidence changed')
                totals={k:sum(x[k] for x in final) for k in FIELDS}
                require(totals['attempted_cells']==totals['completed_cells']+totals['failed_cells']==4554
                    and totals['planned_native_parent_pairs']==totals['completed_native_parent_pairs']+totals['pending_native_parent_pairs']==2484
                    and totals['planned_assessor_derived_q4_pairs']==totals['completed_assessor_derived_q4_pairs']+totals['pending_assessor_derived_q4_pairs']==828
                    and totals['runtime_reference_placeholders']==1242,'Final exact retained-plus-new grids differ')
                self.check();self.note('continuation_finished',status='completed_with_failures' if totals['failed_cells'] else 'completed',
                    planned_cells=4554,observed_rows=4554,**totals,family_seal_sha256=FAMILY_SHA,continuation_capsule_sha256=self.capsule_sha,
                    original_journal=self.capsule['original_journal'],original_admission=self.capsule['original_admission'],initial_attestation=self.family.attestation,
                    default_promotion=False,native_approval='PENDING',resource_acceptance='NOT EVALUATED')
                return 0
            except BaseException as error:
                if self.current is not None:
                    try:self.await_owned_child(self.current,True)
                    except BaseException as cleanup:
                        if hasattr(error,'add_note'):error.add_note('Owned guard cleanup: '+str(cleanup))
                self.note('continuation_stopped',error_type=type(error).__name__,error=str(error),default_promotion=False)
                return 130 if isinstance(error,(InterruptedError,KeyboardInterrupt)) else 1
            finally:self.journal=None

def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--continuation-freeze',type=Path,required=True);p.add_argument('--continuation-freeze-sha256',required=True)
    p.add_argument('--expected-source-sha256',required=True);p.add_argument('--preflight-only',action='store_true')
    a=p.parse_args(argv);requested={'stop':False}
    def stop(*_):requested['stop']=True
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(number,stop)
    controller=Continued(a.continuation_freeze,a.continuation_freeze_sha256,a.expected_source_sha256,lambda:requested['stop'])
    if a.preflight_only:print(json.dumps(controller.preflight()));return 0
    return controller.execute()

if __name__=='__main__':raise SystemExit(main())
