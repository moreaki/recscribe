#!/usr/bin/env python3
"""Plan exact source publication; never copy or read speech/model payloads.

This prepares protected metadata only. It does not publish, copy sources, open
campaign outcomes or claim completion. Future evidence must be supplied after
the independent all15 terminal barrier and approved separately.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import stat

R=Path(__file__).resolve().parent
REPOSITORY=Path('/Users/moreaki/.codex/worktrees/swiss-written-corpus/recscribe')
ALLOWED={'.py','.md','.json'}
MAX_FILE=8*1024**2
MAX_TOTAL=64*1024**2
ANCHORS={
 'pre-inference-family-seal.json':('ca33f8896168838829dc36151de6b7a206f329db28ac0fcb610152d49bdeb60e','PROSPECTIVE_BEFORE_ANY_QUALITY_INFERENCE'),
 'artifact-generation.freeze.v1.json':('ddfbcf7fe06028af11c8d4b302d602d512b21c43bc3b6bf1e3721a8328f902d8','PROSPECTIVE_BEFORE_ACTUAL_BYTE_EXPORTS'),
 'independent-preflight-audit.freeze.v1.json':('baa9a4bccdc58d4b28fa17a12e6e4f90a8c00bd7107975f587afe975ca59a720','PROSPECTIVE_BEFORE_ACTUAL_STATIC_AUDIT'),
 'independent-preflight-completion.receipt.v1.json':('15f5713bd1eb28b2b30f632942d600edc211ca84152de4c1e3f9c5349bde8de7','POST_STATIC_AUDIT_CLOSED_GUARD_EVIDENCE'),
 'final-reporting-tools.freeze.v1.json':('1322966de1b7b8a7b963bf81d6830ee3d28fe93ad63f91cd84db31a939c9d662','PROSPECTIVE_BEFORE_ANY_QUALITY_INFERENCE'),
 'native-load-tools.freeze.v1.json':('4c8f824de05f7a016838f8e020169942c9b55b57bb6d0478b0d4a9c738951b59','PROSPECTIVE_BEFORE_NATIVE_MODEL_INITIALIZATION'),
 'postrun-preservation.freeze.v1.json':('f0ffd6b79e228c9e7924a7c6ac9fb1116b59e6f529ea0b5d797894a4959eb4be','PROSPECTIVE_BEFORE_ANY_QUALITY_INFERENCE'),
 'independent-final-audit-tools.freeze.v1.json':('d3da8987dffca7e99ce5ebe4c4f710ca9904106973ced6f64a566985a90b24b6','PROSPECTIVE_BEFORE_ANY_QUALITY_INFERENCE'),
 'independent-analysis-source-peer.v2.json':('a522c90128df46b2c130516b49da8787f32beacdb2453077bf70ecc0bec3530d','SOURCE_REVIEW_BEFORE_ANY_QUALITY_INFERENCE_CLI_PROOF_THEN_PENDING'),
 'independent-static-completion-peer-v1.json':('7a320ebe5d722462c57148756dd9be5006b3f121eba049c23fb6929cf3bb5fee','INDEPENDENT_POST_STATIC_AUDIT_CLOSURE_PEER'),
}
HISTORY={
 'generation-admissions.receipt.v1.json':('0db73dde9e79e3bf2b1a976e259abc00485907598896bde74fab94e5c9792c55','PRE_EXPORT_ADMISSION_HISTORY_INCLUDING_NOT_STARTED_ATTEMPT'),
 'independent-preflight-admission.v1.json':('a6c014a7cbe8e48936d02f6c28d24682628341163477a2c5d7e9e22dee01cf7f','PRE_STATIC_AUDIT_ADMISSION_AND_PRIOR_METADATA_VERIFIER_FAILURE'),
 'independent-preflight-admission-verifier.executed-inline-v1.py':('ae8bc670161f50563be5ebccdbb7aca16df6df048a22a19559d2e9cf270c3289','POST_LAUNCH_AND_POST_COMPLETION_ARCHIVE_NOT_PROSPECTIVELY_FROZEN'),
 'independent-preflight-validation.v1.json':('71896694fc110ca8035bc210ae0c0af94508178a74ae5e57a049740fadcada92','SYNTHETIC_CONTRACT_EVIDENCE_BEFORE_STATIC_AUDIT'),
 'independent-preflight-smoke-v1/audit.json':('3bfdd8f20b9e2c5b50125e12199a6d4631c6c61baff1ddf2f65677dc1fcbd0cb','ACTUAL_METADATA_CLI_MODEL_OPENS_DENIED_NOT_INFERENCE'),
 'independent-preflight-audit-v1/audit.json':('809fa23bb9ec04cdc8841fb9eec7f24a1891898c8d852df5beec25c4f88cb7a2','ACTUAL_STATIC_WEIGHT_PROVENANCE_ONLY_NOT_SPEECH_QUALITY'),
}

def require(ok,message):
    if not ok:raise ValueError(message)

def digest(raw):return hashlib.sha256(raw).hexdigest()
def identity(s):return(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)

class Planner:
    def __init__(self):self.total=0;self.entries={};self.references={};self.read_identities={};self.documents={}
    def read(self,path,expected=None):
        p=Path(path)
        require(p.is_absolute() and '..' not in p.parts and p.suffix in ALLOWED and not any(x.is_symlink() for x in (p,*p.parents)),'Explicit regular source/metadata path required')
        before=p.lstat();require(stat.S_ISREG(before.st_mode) and before.st_size<=MAX_FILE and self.total+before.st_size<=MAX_TOTAL,'Bounded source/metadata read required')
        with p.open('rb') as f:
            require(identity(os.fstat(f.fileno()))==identity(before),'Source changed before open')
            raw=f.read(before.st_size)
        self.total+=len(raw)
        require(len(raw)==before.st_size and identity(p.lstat())==identity(before) and (expected is None or digest(raw)==expected),'Frozen source/metadata hash or identity differs')
        self.read_identities[str(p)]=identity(before)
        return raw
    def entry(self,pin,role,phase,binding):
        require(isinstance(pin,dict) and isinstance(pin.get('path'),str) and isinstance(pin.get('sha256'),str) and len(pin['sha256'])==64,'Explicit descriptor required')
        p=Path(pin['path'])
        if p.suffix not in ALLOWED:
            key=(str(p),pin['sha256'])
            self.references.setdefault(key,{'original_path':str(p),'sha256':pin['sha256'],'bytes_from_descriptor':pin.get('bytes'),
              'disposition':'REFERENCE_ONLY_NOT_OPENED_OR_COPIED','reason':'Outside explicit .py/.md/.json source scope','bindings':[]})['bindings'].append(binding)
            return None
        require(R in p.parents,'Only explicitly selected protected round5 source/metadata copies may be archived')
        raw=self.read(p,pin['sha256'])
        relative='round-5/'+p.relative_to(R).as_posix()
        key=str(p);value=self.entries.get(key)
        if value is None:
            value={'original_path':key,'sha256':digest(raw),'bytes':len(raw),'archive_relative_path':relative,
              'copy_exact_bytes_after_final_barrier':True,'content_rewrite_authorized':False,'roles':[],'phase_claims':[],'bindings':[]}
            self.entries[key]=value
        require(value['sha256']==pin['sha256'],'Conflicting source hash')
        for field,item in (('roles',role),('phase_claims',phase),('bindings',binding)):
            if item not in value[field]:value[field].append(item)
        if p.suffix=='.json':self.documents[key]=json.loads(raw)
        return self.documents.get(key)
    def descriptors(self,value,role,phase,binding):
        if isinstance(value,dict):
            if isinstance(value.get('path'),str) and isinstance(value.get('sha256'),str):self.entry(value,role,phase,binding)
            else:
                for key,item in value.items():self.descriptors(item,role,phase,binding+'/'+key)
        elif isinstance(value,list):
            for index,item in enumerate(value):self.descriptors(item,role,phase,binding+'/'+str(index))
    def finish(self):
        for p,before in self.read_identities.items():require(identity(Path(p).lstat())==before,'Earlier source changed while preparing manifest')
        require(len(self.entries)<=512 and len({e['archive_relative_path'] for e in self.entries.values()})==len(self.entries),'Bounded unique archive layout required')

def write(path,value):
    raw=(json.dumps(value,indent=2,allow_nan=False)+'\n').encode()
    with path.open('xb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
    return {'path':str(path),'sha256':digest(raw),'bytes':len(raw)}

def main():
    Path(os.environ['RECSCRIBE_RUN_DIR'],'.pin').touch(exist_ok=True)
    planner=Planner();anchors={}
    for name,(expected,phase) in ANCHORS.items():
        pin={'path':str(R/name),'sha256':expected};anchors[name]=planner.entry(pin,'frozen_anchor_or_peer',phase,name)
    family=anchors['pre-inference-family-seal.json']
    for key in ('tools','sources','runtime_record','profile'):
        planner.descriptors(family[key],'family_'+key,'FAMILY_BOUND_BEFORE_ANY_QUALITY_INFERENCE','pre-inference-family-seal.json/'+key)
    for stage in family['stages']:
        for path_key,sha_key in (('configuration','configuration_sha256'),('assessment_pre_freeze_plan','assessment_pre_freeze_plan_sha256'),('source_snapshot','source_snapshot_sha256')):
            planner.entry({'path':stage[path_key],'sha256':stage[sha_key]},'frozen_stage_'+path_key,'BEFORE_ANY_QUALITY_INFERENCE','family/stages/'+stage['id']+'/'+path_key)
    for name in ('artifact-generation.freeze.v1.json','independent-preflight-audit.freeze.v1.json','final-reporting-tools.freeze.v1.json','native-load-tools.freeze.v1.json','postrun-preservation.freeze.v1.json','independent-final-audit-tools.freeze.v1.json'):
        value=anchors[name];phase=ANCHORS[name][1]
        for key in ('coordinator','source_files','tools','protocol','source','test_source','model_denial_smoke_launcher','sources','preservation_source'):
            if key in value:planner.descriptors(value[key],'frozen_executed_or_validation_source',phase,name+'/'+key)
        if isinstance(value.get('validation'),dict):
            validation=value['validation']
            if 'sources' in validation:planner.descriptors(validation['sources'],'synthetic_validation_source',phase,name+'/validation/sources')
            for key in ('actual_packaged_reporting_main_write_smoke','actual_model_free_all_main_write_proof','real_metadata_api_only_proof'):
                if key in validation:planner.entry(validation[key],'explicitly_synthetic_or_metadata_validation_receipt','VALIDATION_ONLY_NOT_ACTUAL_SPEECH_QUALITY',name+'/validation/'+key)
        if 'retained_setup_failures' in value:planner.descriptors(value['retained_setup_failures'],'retained_failed_metadata_cli_history','FAILED_SYNTHETIC_SETUP_NO_ACTUAL_QUALITY_INFERENCE',name+'/retained_setup_failures')
    for name,(expected,phase) in HISTORY.items():planner.entry({'path':str(R/name),'sha256':expected},'explicit_prequality_execution_history',phase,name)
    for name in ('generation-preflight.not-started.attempt1.launch.json','generation-preflight.not-started.attempt1.receipt.json'):
        p=R/name;raw=planner.read(p)
        planner.entry({'path':str(p),'sha256':digest(raw)},'retained_not_started_history','OPERATIONAL_ADMISSION_NOT_STARTED_NO_EXPORT_WORKER',name)
    closure=anchors['independent-preflight-completion.receipt.v1.json']
    for key in ('actual_guard','original_metadata_only_failure'):planner.descriptors(closure[key],'external_closed_guard_or_failed_console','STATIC_AUDIT_OPERATIONAL_HISTORY_ONLY','closure/'+key)
    # Capture references inside the failed admission metadata, without opening
    # console/guard/payload files or traversing arbitrary JSON data manifests.
    admission=planner.documents[str(R/'independent-preflight-admission.v1.json')]
    planner.descriptors(admission['prior_admission_verifier_packaging_failure'],'external_failed_admission_console','BEFORE_PAYLOAD_AUDIT_WORKER_LAUNCH','admission/prior_failure')
    own=planner.read(Path(__file__).resolve());planner.entry({'path':str(Path(__file__).resolve()),'sha256':digest(own)},'publication_plan_generator','CURRENT_PLAN_PREPARATION_NOT_PART_OF_FROZEN_SCIENTIFIC_EXECUTION','self')
    planner.finish();created=datetime.now(timezone.utc).isoformat()
    manifest={'schema_version':'round5-exact-source-publication-manifest-plan-v1','created_utc':created,'status':'PLANNED_ONLY_NOT_PUBLISHED_NOT_EVALUATION_COMPLETE',
      'anchors':{name:{'path':str(R/name),'sha256':expected,'phase_claim':phase} for name,(expected,phase) in ANCHORS.items()},
      'entries':sorted(planner.entries.values(),key=lambda v:v['archive_relative_path']),
      'external_reference_only':sorted(planner.references.values(),key=lambda v:(v['original_path'],v['sha256'])),
      'source_bytes_verified_now':planner.total,'metadata_or_source_files_selected':len(planner.entries),
      'physical_file_copy_or_publication_performed':False,'quality_outcomes_read':False,'model_audio_reference_transcript_payloads_read':False,
      'numeric_csvs_read_or_copied':False,'postlaunch_archive_label':'POST_LAUNCH_AND_POST_COMPLETION_ARCHIVE_NOT_PROSPECTIVELY_FROZEN',
      'source_layout':'Retain round-5 relative layout, exact bytes, original absolute path and SHA. No portability or relocation equivalence claim.',
      'frozen_inputs_unchanged':True,'future_actual_evidence':'PENDING_ALL15_TERMINAL_AND_ROOT_SUPPLIED_EXPLICIT_DESCRIPTORS'}
    mp=write(R/'source-publication-archive.manifest.v1.json',manifest)
    plan={'schema_version':'round5-source-publication-plan-v1','created_utc':created,'status':'PREPARED_NOT_PUBLISHED','manifest':mp,
      'archive_destination':'PENDING_ROOT_REVIEW_NO_REPOSITORY_WRITE_AUTHORIZED_HERE','exact_source_bytes_required':True,
      'source_tree_revision':family['workspace_source_revision'],'actual_code_aliases_and_failed_histories_preserved':True,
      'postlaunch_verifier_prospective_freeze_claim':False,'scope_extensions_require_new_plan':True,
      'blocked_until':['All15 stage_assessed records and exactly one final serial_finished verified from the actual campaign','Root supplies finished actual summary/projection/independent numeric and opaque-preservation evidence descriptors','Archive targets and hashes reviewed; each copied source checked again; publication performed separately'],
      'excluded':['Model and native binary payloads','Original/prepared audio and audio fixtures','Reference and transcript payloads','Corpus manifests and raw source data','Synthetic or actual numeric CSVs','Current or future campaign outcome files not explicitly supplied after completion','Unselected file types including Swift and requirements.txt; frozen hashes remain reference-only'],
      'claims':'Source/provenance preparation only. No quality, latency, native compatibility, controlled resources or product/default acceptance.',
      'repository_writes_performed':False,'source_or_evidence_bytes_rewritten':False,'recognition_or_model_initialization':False}
    pp=write(R/'source-publication-plan.v1.json',plan)
    print(json.dumps({'plan':pp,'manifest':mp,'selected_source_metadata_files':len(planner.entries),'reference_only':len(planner.references),'bounded_source_metadata_bytes_read':planner.total}),flush=True)

if __name__=='__main__':main()
