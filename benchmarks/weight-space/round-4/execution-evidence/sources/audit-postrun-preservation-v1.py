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
from pathlib import Path
import signal
import stat
import time

R=Path(__file__).absolute().parent
FAMILY_SHA="8058f9785929639d70da620fd6f12841b3078aa17352f6d02b542b6a7f191fe2"
INTEGRITY_SHA="557a1cbbd409c1bbe000d5a1f5584195112ae259537329046dbab5e89b4013ae"
ADMISSION_SHA="1e9d6a0dbea1fd9f9df2ece06a9044e24eb4f2b37c259500cca87545e9d29153"
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
            while True:
                self.check();block=source.read(min(256*1024,before[2]-consumed+1))
                if not block:break
                consumed+=len(block)
                self.total_bytes+=len(block)
                require(consumed<=before[2] and consumed<=maximum,"File grew beyond its initial/per-file bound")
                digest.update(block)
                require(self.total_bytes<=MAX_TOTAL_BYTES,"Actual opaque reads exceed32GiB")
        require(self.identity(path)==before and (expected is None or digest.hexdigest()==expected),"File changed or frozen SHA differs")
        item={"path":str(path),"sha256":digest.hexdigest(),"bytes":before[2],"identity":list(before)}
        self.files[str(path)]=item;return item
    def metadata(self,path,expected,maximum=MAX_METADATA_BYTES):
        item=self.digest(path,expected,maximum)
        with Path(path).open("rb") as source:raw=source.read(maximum+1)
        self.total_bytes+=len(raw);self.check()
        require(self.total_bytes<=MAX_TOTAL_BYTES and len(raw)<=maximum and hashlib.sha256(raw).hexdigest()==item["sha256"]
            and self.identity(Path(path))==tuple(item["identity"]),"Metadata changed/read volume exceeded")
        return decode(raw)

def barrier(family,events):
    expected=[s["id"] for s in family["stages"]]
    require(len(expected)==15 and len(set(expected))==15,"Exact15 frozen stages required")
    require(events and events[0].get("event")=="serial_started" and events[-1].get("event")=="serial_finished"
        and not any(x.get("event") in {"serial_stopped","owned_guard_cleanup_pending"} for x in events),"Post-run audit requires final terminal journal")
    assessed=[x for x in events if x.get("event")=="stage_assessed"]
    require([x.get("id") for x in assessed]==expected and events[0].get("family_seal_sha256")==events[-1].get("family_seal_sha256")==FAMILY_SHA,
        "Final ordered stage/source evidence differs")
    finish=events[-1]
    fields=("planned_cells","attempted_cells","completed_cells","failed_cells","planned_native_parent_pairs",
        "completed_native_parent_pairs","pending_native_parent_pairs","planned_assessor_derived_q4_pairs",
        "completed_assessor_derived_q4_pairs","pending_assessor_derived_q4_pairs","runtime_reference_placeholders")
    require(all(type(finish.get(k)) is int and finish[k]>=0 for k in fields),"Typed nonnegative final counters required")
    for stage,event in zip(family["stages"],assessed):
        require(all(type(event.get(k)) is int and event[k]>=0 for k in fields)
            and event["planned_cells"]==event["attempted_cells"]==stage["planned_cells"]
            and event["completed_cells"]+event["failed_cells"]==event["attempted_cells"],"Typed exact stage attempts required")
    require(all(finish[k]==sum(x[k] for x in assessed) for k in fields),"Final/stage counters differ")
    require(finish.get("attempted_cells")==4554 and finish.get("completed_cells",0)+finish.get("failed_cells",0)==4554
        and finish.get("planned_native_parent_pairs")==2484 and finish.get("completed_native_parent_pairs",0)+finish.get("pending_native_parent_pairs",0)==2484
        and finish.get("planned_assessor_derived_q4_pairs")==828 and finish.get("completed_assessor_derived_q4_pairs",0)+finish.get("pending_assessor_derived_q4_pairs",0)==828
        and finish.get("runtime_reference_placeholders")==1242 and finish.get("default_promotion") is False,"Final grid accounting differs")
    return assessed

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
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--journal-sha256",required=True);parser.add_argument("--expected-source-sha256",required=True)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args(argv);output=args.output
    require(output.is_absolute() and output.parent==R and not output.exists() and ".." not in output.parts
        and not any(p.is_symlink() for p in (output,*output.parents)),"New protected audit output required")
    audit=Audit(output)
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(number,lambda *_:setattr(audit,"stopped",True))
    own=audit.digest(Path(__file__),args.expected_source_sha256,1024**2)
    family=audit.metadata(R/"pre-inference-family-seal.json",FAMILY_SHA,4*1024**2)
    journal_item=audit.digest(R/"serial.events.jsonl",args.journal_sha256,4*1024**2)
    with (R/"serial.events.jsonl").open("rb") as source:raw=source.read(4*1024**2+1)
    audit.total_bytes+=len(raw);require(hashlib.sha256(raw).hexdigest()==journal_item["sha256"],"Journal changed")
    events=[decode(v) for v in raw.splitlines() if v.strip()];assessed=barrier(family,events)
    # No model/audio/reference/output file opens before the terminal barrier.
    inputs={}
    def pin(item):
        path=item["path"];expected=item["sha256"]
        require(path not in inputs or inputs[path]==expected,"Conflicting frozen input descriptors")
        inputs[path]=expected;require(len(inputs)<=MAX_INPUT_FILES,"Frozen input file count exceeds2048")
    for item in family["immutable_files"]:pin(item)
    integrity_item=family["inputs"]["integrity"]
    require(integrity_item["sha256"]==INTEGRITY_SHA,"Opaque corpus integrity source differs")
    integrity=audit.metadata(integrity_item["path"],INTEGRITY_SHA)
    require(integrity["case_count"]==216 and integrity["raw_reference_semantic_inspection"] is False,"Fresh opaque corpus receipt differs")
    for item in integrity["input_metadata_and_hashes"]:pin(item)
    for case in integrity["opaque_case_evidence"]:
        for item in case["opaque_inputs"]:pin(item)
    admission=audit.metadata(R/"inference-launch.freeze.v1.json",ADMISSION_SHA,4*1024**2)
    for item in admission["frozen_inputs"].values():pin(item)
    for key in ("native_load_receipt","native_load_guard","native_load_launch","independent_static_audit"):pin(admission[key])
    for path,expected in inputs.items():audit.digest(path,expected)
    for stage,event in zip(family["stages"],assessed):
        folder=R/stage["id"]
        for relative,key in (("matrix/matrix.json","matrix_sha256"),("matrix.guard.jsonl","guard_sha256"),
            ("report-v1.1/report.json","report_sha256"),("assessment-v1/assessment.json","assessment_sha256")):
            audit.digest(folder/relative,event[key],MAX_OUTPUT_FILE_BYTES)
    outputs=[];entries=0;directories_seen={}
    for stage in family["stages"]:
        root=R/stage["id"]/"matrix";audit.check()
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
    value={"schema_version":"round4-postrun-opaque-preservation-v1","created_utc":datetime.now(timezone.utc).isoformat(),"status":"PASS_OPAQUE_INPUT_AND_RETAINED_OUTPUT_HASHES",
        "source":{k:own[k] for k in ("path","sha256","bytes")},"family_seal_sha256":FAMILY_SHA,"final_journal_sha256":args.journal_sha256,
        "frozen_input_count":len(inputs),"retained_output_count":len(outputs),"actual_bytes_read":audit.total_bytes,
        "limits":{"input_files":MAX_INPUT_FILES,"output_files":MAX_OUTPUT_FILES,"output_entries":150000,"input_file_bytes":MAX_FILE_BYTES,"output_file_bytes":MAX_OUTPUT_FILE_BYTES,"total_read_bytes":MAX_TOTAL_BYTES,"seconds":600},
        "frozen_inputs":[{k:audit.files[p][k] for k in ("path","sha256","bytes")} for p in inputs],"retained_outputs":outputs,
        "training":False,"recognition":False,"rescoring":False,"reference_or_transcript_semantic_decode":False,"input_or_output_bytes_modified":False,
        "native_review":"PENDING","controlled_resource_acceptance":"NOT_EVALUATED","default_promotion":False}
    data=(json.dumps(value,indent=2,allow_nan=False)+"\n").encode()
    require(len(data)<=MAX_METADATA_BYTES,"Preservation inventory exceeds64MiB");publish(audit,output,data)
    print(json.dumps({"status":value["status"],"sha256":hashlib.sha256(data).hexdigest(),"frozen_inputs":len(inputs),"retained_outputs":len(outputs)}))

if __name__=="__main__":main()
