#!/usr/bin/env python3
"""Post-terminal opaque hashes of frozen inputs and all retained matrix files.

No model execution, source/reference decoding, scoring, output repair or cleanup.
Run under the exact recording-priority guard with a new protected --output.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import re
from pathlib import Path
import signal
import stat
import time

R=Path(__file__).absolute().parent
FAMILY_SHA=None  # Mandatory explicit runtime CLI pin
INTEGRITY_SHA=None  # Mandatory explicit runtime CLI pin
ADMISSION_SHA=None  # Mandatory explicit runtime CLI pin
MAX_INPUT_FILES=2048
MAX_OUTPUT_FILES=100000
MAX_FILE_BYTES=4*1024**3
MAX_OUTPUT_FILE_BYTES=64*1024**2
MAX_TOTAL_BYTES=32*1024**3
MAX_METADATA_BYTES=64*1024**2

def require(ok,message):
    if not ok: raise ValueError(message)

def decode(raw):
    def fields(items):
        out={}
        for key,value in items:
            require(key not in out,"Duplicate metadata key");out[key]=value
        return out
    def number(value):
        result=float(value);require(math.isfinite(result),"Nonfinite metadata number");return result
    return json.loads(raw,object_pairs_hook=fields,parse_float=number,
        parse_constant=lambda _:(_ for _ in ()).throw(ValueError("Nonfinite metadata constant")))

class Audit:
    def __init__(self,output,seconds=600):
        self.output=Path(output);self.deadline=time.monotonic()+seconds;self.stopped=False
        self.total_bytes=0;self.files={}
    def check(self):
        if self.stopped or (self.output/"cancel.request").exists() or (R/"cancel-preservation.request").exists():
            raise InterruptedError("Opaque post-run audit canceled; originals and outputs retained")
        if time.monotonic()>=self.deadline: raise TimeoutError("Opaque post-run audit exceeded600seconds")
    def regular(self,path):
        path=Path(path)
        require(path.is_absolute() and ".." not in path.parts and not any(p.is_symlink() for p in (path,*path.parents)),"Absolute nonsymlink file required")
        require(stat.S_ISREG(path.lstat().st_mode),"Regular file required");return path
    @staticmethod
    def identity(path):
        s=path.lstat();return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    def digest(self,path,expected=None,maximum=MAX_FILE_BYTES):
        self.check();path=self.regular(path);before=self.identity(path)
        require(0<=before[2]<=maximum,"File exceeds declared bound")
        if str(path) in self.files:
            item=self.files[str(path)]
            require(before==tuple(item["identity"]) and (expected is None or item["sha256"]==expected),"Previously hashed file changed/conflicting pin")
            return item
        require(self.total_bytes+before[2]<=MAX_TOTAL_BYTES,"Total opaque read volume exceeds32GiB")
        digest=hashlib.sha256();consumed=0
        with path.open("rb") as source:
            while consumed<before[2]:
                self.check();block=source.read(min(256*1024,before[2]-consumed));require(block,'Input truncated during bounded hash')
                consumed+=len(block)
                self.total_bytes+=len(block)
                require(consumed<=before[2] and consumed<=maximum,"File grew beyond its initial/per-file bound")
                digest.update(block)
                require(self.total_bytes<=MAX_TOTAL_BYTES,"Actual opaque reads exceed32GiB")
        self.check();require(self.identity(path)==before and (expected is None or digest.hexdigest()==expected),"File changed or frozen SHA differs")
        item={"path":str(path),"sha256":digest.hexdigest(),"bytes":before[2],"identity":list(before)}
        self.files[str(path)]=item;return item
    def raw_metadata(self,path,expected,maximum=MAX_METADATA_BYTES):
        item=self.digest(path,expected,maximum)
        require(self.total_bytes+item['bytes']<=MAX_TOTAL_BYTES,'Bounded metadata reread exceeds32GiB before IO')
        parts=[];used=0
        with Path(path).open('rb') as source:
            while used<item['bytes']:
                self.check();part=source.read(min(256*1024,item['bytes']-used,MAX_TOTAL_BYTES-self.total_bytes));require(part,'Metadata truncated during bounded reread')
                used+=len(part);self.total_bytes+=len(part);parts.append(part)
        raw=b''.join(parts);self.check()
        require(self.total_bytes<=MAX_TOTAL_BYTES and len(raw)<=maximum and hashlib.sha256(raw).hexdigest()==item["sha256"]
            and self.identity(Path(path))==tuple(item["identity"]),"Metadata changed/read volume exceeded")
        return raw
    def metadata(self,path,expected,maximum=MAX_METADATA_BYTES):
        return decode(self.raw_metadata(path,expected,maximum))

FAMILIES=('tiny','base','small','large-v3-turbo','large-v3')
IDS=[prefix+family for prefix in ('panel-','dev-validation-','heldout-') for family in FAMILIES]
FIELDS=('planned_cells','attempted_cells','completed_cells','failed_cells','planned_native_parent_pairs','completed_native_parent_pairs','pending_native_parent_pairs','planned_assessor_derived_q4_pairs','completed_assessor_derived_q4_pairs','pending_assessor_derived_q4_pairs','runtime_reference_placeholders')
def valid_sha(value):return isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None
def integer(value):return type(value) is int and value>=0

def validate_paths(family):
    keys={'stage_directory','matrix_directory','matrix_json','matrix_cancel','guard_receipt','report_directory','report_json',
          'assessment_directory','assessment_json','classification_receipt','freeze','final_plan'}
    for s in family['stages']:
        p=s.get('paths');require(isinstance(p,dict) and set(p)==keys,'Exact sealed stage.paths keys required')
        require(p['stage_directory']==str(R/s['id']),'Sealed stage directory differs')
        for key,value in p.items():
            if value is None:require(key in {'freeze','final_plan'} and s['stage']!='held_out','Unexpected null stage path');continue
            require(isinstance(value,str) and Path(value).is_absolute() and R in Path(value).parents and '..' not in Path(value).parts,'Protected mapped path required')
        require(Path(p['matrix_json']).parent==Path(p['matrix_cancel']).parent==Path(p['matrix_directory'])
          and Path(p['report_json']).parent==Path(p['report_directory']) and Path(p['assessment_json']).parent==Path(p['assessment_directory'])
          and Path(p['classification_receipt']).name=='natural-failures.attempted-v2.json','Mapped producer/reader path contract differs')

def barrier(family,events):
    require(family.get('schema_version')=='mlp-permutation-family-pre-inference-v1' and [s['id'] for s in family['stages']]==IDS,'Frozen family schema/order differs')
    require((family['planned_cells'],family['planned_native_parent_pairs'],family['planned_assessor_derived_q4_pairs'],family['planned_reference_runtime_placeholders'])==(4554,2484,828,1242),'Frozen planned totals differ')
    require(events and events[0].get('event')=='serial_started' and events[-1].get('event')=='serial_finished'
        and sum(e.get('event')=='serial_started' for e in events)==sum(e.get('event')=='serial_finished' for e in events)==1
        and not any(e.get('event') in {'serial_stopped','owned_guard_cleanup_pending'} for e in events),'All15 terminal barrier not satisfied; no outcome reads')
    start,end=events[0],events[-1]
    require(start.get('family_seal_sha256')==end.get('family_seal_sha256')==FAMILY_SHA
        and start.get('coordinator_sha256')==family['tools']['coordinator']['sha256']
        and start.get('initial_attestation')==end.get('initial_attestation'),'Final source/admission identities differ')
    assessed=[e for e in events if e.get('event')=='stage_assessed']
    launches=[e for e in events if e.get('event')=='command_start' and e.get('action')=='guarded_inference']
    ends=[e for e in events if e.get('event')=='command_finished' and e.get('action')=='guarded_inference']
    require([e.get('id') for e in assessed]==[e.get('stage') for e in launches]==[e.get('stage') for e in ends]==IDS,'All15 unique launch/end/assessment grid required')
    previous=0
    for s,e,launch,finish in zip(family['stages'],assessed,launches,ends):
        require(previous<events.index(launch)<events.index(finish)<events.index(e),'Serial launch/end/assessment chronology differs');previous=events.index(e)
        require(e.get('stage')==s['stage'] and e.get('analysis_source')==family['tools']['assessor'] and e.get('default_promotion') is False,'Stage source decision binding differs')
        require(all(valid_sha(e.get(k)) for k in ('matrix_sha256','report_sha256','assessment_sha256','guard_sha256','plan_sha256')),'Stage digest absent')
        require(all(integer(e.get(k)) for k in FIELDS) and e['planned_cells']==e['attempted_cells']==s['planned_cells']
            and e['completed_cells']+e['failed_cells']==s['planned_cells']
            and type(finish.get('returncode')) is int and finish['returncode']==int(e['failed_cells']>0),'Terminal attempts/return code differs')
    accepts=[e for e in events if e.get('event')=='heldout_family_accepted'];require(len(accepts)==1,'All-five release missing/duplicated');accept=accepts[0]
    require(events.index(assessed[9])<events.index(accept)<events.index(launches[10]) and valid_sha(accept.get('freeze_sha256'))
        and accept.get('family_seal_sha256')==FAMILY_SHA and accept.get('analysis_source')==family['tools']['assessor']
        and accept.get('initial_attestation')==start['initial_attestation'],'All10 before all5 frozen chronology differs')
    totals={k:sum(e[k] for e in assessed) for k in FIELDS}
    require(all(integer(end.get(k)) and end[k]==v for k,v in totals.items()) and totals['attempted_cells']==4554
        and totals['planned_native_parent_pairs']==totals['completed_native_parent_pairs']+totals['pending_native_parent_pairs']==2484
        and totals['planned_assessor_derived_q4_pairs']==totals['completed_assessor_derived_q4_pairs']+totals['pending_assessor_derived_q4_pairs']==828
        and totals['runtime_reference_placeholders']==1242 and end.get('default_promotion') is False
        and end.get('status')==('completed_with_failures' if totals['failed_cells'] else 'completed'),'Final exact totals differ')
    return assessed,accept,totals

def publish(audit,output,data):
    """Exclusive partial publication; cancellation retains the partial evidence."""
    require(not output.exists() and output.parent.is_dir(),"New audit output required")
    audit.check();output.mkdir(mode=0o700)
    partial=output/"preservation.partial.json";final=output/"preservation.json"
    fd=os.open(partial,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    owned=os.fstat(fd);owner=(owned.st_dev,owned.st_ino)
    with os.fdopen(fd,"wb") as target:target.write(data);target.flush();os.fsync(target.fileno())
    audit.check();actual=partial.lstat()
    require(stat.S_ISREG(actual.st_mode) and (actual.st_dev,actual.st_ino)==owner and actual.st_size==len(data),"Owned partial changed")
    os.link(partial,final,follow_symlinks=False)
    actual=final.lstat();require((actual.st_dev,actual.st_ino)==owner,"Published audit inode changed")
    partial.unlink();audit.check()

def main(argv=None):
    global R,FAMILY_SHA,INTEGRITY_SHA,ADMISSION_SHA
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--journal-sha256",required=True);parser.add_argument("--expected-source-sha256",required=True)
    for name in ('family-seal','family-seal-sha256','journal','admission-capsule','admission-capsule-sha256',
                 'integrity','integrity-sha256','operation-freeze','operation-freeze-sha256'):
        parser.add_argument('--'+name,required=True)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args(argv);output=args.output;R=Path(args.family_seal).absolute().parent
    require(all(isinstance(getattr(args,name),str) and re.fullmatch('[0-9a-f]{64}',getattr(args,name)) for name in
      ('journal_sha256','expected_source_sha256','family_seal_sha256','admission_capsule_sha256','integrity_sha256','operation_freeze_sha256')),'Every runtime source/input SHA required')
    FAMILY_SHA=args.family_seal_sha256;INTEGRITY_SHA=args.integrity_sha256;ADMISSION_SHA=args.admission_capsule_sha256
    require(output.is_absolute() and output.parent==R and not output.exists() and ".." not in output.parts
        and not any(p.is_symlink() for p in (output,*output.parents)),"New protected audit output required")
    audit=Audit(output)
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(number,lambda *_:setattr(audit,"stopped",True))
    own=audit.digest(Path(__file__),args.expected_source_sha256,1024**2)
    family=audit.metadata(Path(args.family_seal),FAMILY_SHA,4*1024**2)
    require(family.get('schema_version')=='mlp-permutation-family-pre-inference-v1' and family['paths']['journal']==args.journal,'Exact sealed R5 journal/path schema required')
    raw=audit.raw_metadata(Path(args.journal),args.journal_sha256,4*1024**2)
    events=[decode(v) for v in raw.splitlines() if v.strip()];assessed,accept,totals=barrier(family,events)
    validate_paths(family)
    # No model/audio/reference/output file opens before the terminal barrier.
    operation=audit.metadata(Path(args.operation_freeze),args.operation_freeze_sha256,4*1024**2)
    require(operation.get('schema_version')=='round5-postrun-preservation-freeze-v1' and operation.get('source',{}).get('sha256')==args.expected_source_sha256
      and operation.get('dynamic_cli_pins') is True and operation.get('mandatory_all15_terminal_barrier') is True
      and operation.get('campaign_outcomes_read') is False and operation.get('default_promotion') is False,'Prospective opaque authority source/policy differs')
    first=next(e for e in events if e.get('event')=='command_start' and e.get('action')=='guarded_inference')
    frozen=datetime.fromisoformat(operation['created_utc'].replace('Z','+00:00'));launched=datetime.fromisoformat(first['created_utc'].replace('Z','+00:00'))
    require(frozen.tzinfo is not None and launched.tzinfo is not None and frozen<launched,'Preservation source must freeze before ANY quality launch')
    inputs={}
    def pin(item):
        path=item["path"];expected=item["sha256"]
        require(path not in inputs or inputs[path]==expected,"Conflicting frozen input descriptors")
        inputs[path]=expected;require(len(inputs)<=MAX_INPUT_FILES,"Frozen input file count exceeds2048")
    def pins(value,depth=0):
        require(depth<=64,'Descriptor nesting bound exceeded')
        if isinstance(value,dict):
            if isinstance(value.get('path'),str) and valid_sha(value.get('sha256')):pin(value)
            else:
                for v in value.values():pins(v,depth+1)
        elif isinstance(value,list):
            require(len(value)<=100000,'Descriptor list bound exceeded')
            for v in value:pins(v,depth+1)
    for item in family["immutable_files"]:pin(item)
    for path,digest in ((args.family_seal,FAMILY_SHA),(args.integrity,INTEGRITY_SHA),(args.admission_capsule,ADMISSION_SHA),
                        (args.operation_freeze,args.operation_freeze_sha256)):
        pin({'path':path,'sha256':digest})
    pin({k:own[k] for k in ('path','sha256')})
    integrity_item=family["inputs"]["integrity"]
    require(integrity_item["sha256"]==INTEGRITY_SHA and integrity_item['path']==args.integrity,"Opaque corpus integrity source differs")
    integrity=audit.metadata(integrity_item["path"],INTEGRITY_SHA)
    require(integrity.get('schema_version')=='round5-completed-corpus-opaque-integrity-v1' and integrity["case_count"]==216
      and integrity['reference_semantic_inspection'] is False and integrity['reference_bytes_decoded_to_text'] is False,'Fresh opaque corpus receipt differs')
    for item in integrity['published_source_metadata']:pin(item)
    pin(integrity['swiss_archive_prefix']);pin(integrity['source'])
    require(len(integrity['case_receipts'])==216 and len({c['id'] for c in integrity['case_receipts']})==216,'Full216 fresh-source inventory required')
    for case in integrity['case_receipts']:
        for item in case["opaque_inputs"]:pin(item)
        pin(case['provenance'])
    pins(integrity['lineage'])
    admission=audit.metadata(Path(args.admission_capsule),ADMISSION_SHA,4*1024**2)
    require(any(v.get('sha256')==FAMILY_SHA for v in admission['frozen_inputs'].values())
      and any(v.get('path')==events[0]['initial_attestation']['path'] and v.get('sha256')==events[0]['initial_attestation']['sha256'] for v in admission['frozen_inputs'].values()),'Admission family/idle source differs')
    for item in admission["frozen_inputs"].values():pin(item)
    for key in ("native_load_receipt","native_load_guard","native_load_launch","independent_static_audit"):pin(admission[key])
    pins(admission)
    panel_pin=admission.get('source_payload_inventory');require(isinstance(panel_pin,dict),'Explicit panel9 supplement required')
    require(any(v.get('path')==panel_pin['path'] and v.get('sha256')==panel_pin['sha256'] for v in admission['frozen_inputs'].values()),'Panel supplement must be bound in admission')
    panel=audit.metadata(panel_pin['path'],panel_pin['sha256'])
    require(panel.get('schema_version')=='round5-panel-source-payload-inventory-v1' and panel.get('status') in
      {'PASSED_PANEL9_OPAQUE_PAYLOAD_INVENTORY','PENDING_PANEL9_PAYLOAD_EVIDENCE'} and panel.get('case_count')==len(panel.get('cases',[]))==9
      and panel.get('reference_or_audio_semantic_decode') is False and panel.get('recognition_performed') is False
      and panel.get('input_bytes_modified') is False and panel.get('default_promotion') is False,'Panel opaque supplement policy differs')
    panel_ids={c['id'] for c in panel['cases']};fresh_ids={c['id'] for c in integrity['case_receipts']}
    require(len(panel_ids)==9 and not(panel_ids&fresh_ids) and isinstance(panel.get('pending'),list),'Exact225 source coverage/pending metadata required')
    pins(panel)
    for path,expected in inputs.items():audit.digest(path,expected)
    for stage,event in zip(family["stages"],assessed):
        paths=stage['paths']
        for path_key,key in (('matrix_json','matrix_sha256'),('guard_receipt','guard_sha256'),('report_json','report_sha256'),('assessment_json','assessment_sha256')):
            audit.digest(Path(paths[path_key]),event[key],MAX_OUTPUT_FILE_BYTES)
        classification=event.get('failure_classification')
        if classification is not None:
            require(classification['path']==paths['classification_receipt'],'Classifier path must use sealed exactattempted-v2 filename');audit.digest(classification['path'],classification['sha256'],MAX_OUTPUT_FILE_BYTES)
    outputs=[];entries=0;directories_seen={}
    for stage in family["stages"]:
        root=Path(stage['paths']['matrix_directory']);audit.check()
        require(root.is_dir() and not root.is_symlink(),"Retained matrix folder missing/unsafe")
        def failed_walk(error):raise error
        for parent,directories,files in os.walk(root,followlinks=False,onerror=failed_walk):
            audit.check();entries+=len(directories)+len(files)
            require(entries<=150000,"Retained directory entry bound exceeded")
            parent=Path(parent)
            require(stat.S_ISDIR(parent.lstat().st_mode) and not parent.is_symlink(),"Retained directory changed")
            directories.sort();files.sort()
            directories_seen[str(parent)]={"identity":audit.identity(parent),"entries":tuple(sorted(directories+files))}
            for name in directories:require(not (Path(parent)/name).is_symlink(),"Retained matrix contains directory symlink")
            for name in files:
                require(len(outputs)<MAX_OUTPUT_FILES,"Retained output file count exceeds100000")
                item=audit.digest(Path(parent)/name,maximum=MAX_OUTPUT_FILE_BYTES)
                outputs.append({"stage":stage["id"],**{k:item[k] for k in ("path","sha256","bytes")}})
    for path,item in audit.files.items():audit.check();require(audit.identity(Path(path))==tuple(item["identity"]),"Earlier audited file changed")
    for path,snapshot in directories_seen.items():
        audit.check();names=[]
        with os.scandir(path) as scan:
            for entry in scan:
                audit.check();names.append(entry.name)
                require(len(names)<=150000,"Retained directory grew beyond entry bound")
        require(tuple(sorted(names))==snapshot["entries"] and audit.identity(Path(path))==snapshot["identity"],
            "Retained directory entries changed during inventory")
    value={"schema_version":"round5-postrun-opaque-preservation-v1","created_utc":datetime.now(timezone.utc).isoformat(),"status":"PASS_OPAQUE_INPUT_AND_RETAINED_OUTPUT_HASHES",
        "source":{k:own[k] for k in ("path","sha256","bytes")},"family_seal_sha256":FAMILY_SHA,"admission_sha256":ADMISSION_SHA,"fresh_integrity_sha256":INTEGRITY_SHA,"operation_freeze_sha256":args.operation_freeze_sha256,"final_journal_sha256":args.journal_sha256,
        "frozen_input_count":len(inputs),"retained_output_count":len(outputs),"actual_bytes_read":audit.total_bytes,
        'source_case_coverage':{'fresh_cases':216,'panel_cases':9,'distinct_source_cases':225,'panel_inventory_sha256':panel_pin['sha256'],
          'panel_pending':panel['pending'],'complete_panel_payload_evidence':not panel['pending']},
        "limits":{"input_files":MAX_INPUT_FILES,"output_files":MAX_OUTPUT_FILES,"output_entries":150000,"input_file_bytes":MAX_FILE_BYTES,"output_file_bytes":MAX_OUTPUT_FILE_BYTES,"total_read_bytes":MAX_TOTAL_BYTES,"seconds":600},
        "frozen_inputs":[{k:audit.files[p][k] for k in ("path","sha256","bytes")} for p in inputs],"retained_outputs":outputs,
        "training":False,"recognition":False,"rescoring":False,"reference_or_transcript_semantic_decode":False,"input_or_output_bytes_modified":False,
        "native_review":"PENDING","controlled_resource_acceptance":"NOT_EVALUATED","default_promotion":False}
    data=(json.dumps(value,indent=2,allow_nan=False)+"\n").encode()
    require(len(data)<=MAX_METADATA_BYTES,"Preservation inventory exceeds64MiB");publish(audit,output,data)
    print(json.dumps({"status":value["status"],"sha256":hashlib.sha256(data).hexdigest(),"frozen_inputs":len(inputs),"retained_outputs":len(outputs)}))

if __name__=="__main__":main()
