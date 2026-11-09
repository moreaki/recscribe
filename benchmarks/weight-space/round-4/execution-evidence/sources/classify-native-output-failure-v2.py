#!/usr/bin/env python3
"""Classify unusable failed ASR output opaquely; never repair, rescore or retry."""
import argparse
import codecs
from datetime import datetime,timezone
import hashlib
import json
import math
from pathlib import Path
import re
import signal
import stat
import sys
import time

R=Path(__file__).absolute().parent
VERSION="round3-natural-case-failure-classification-v2"
MAX_MATRIX=64*1024*1024
MAX_FILE=1024*1024
MAX_TOTAL=512*1024*1024
MAX_SPANS=4096
STOP=False
DEADLINE=None
READS={}
EXPECTED_OUTER_ERROR_SHA256="b1b52723c37723fdc841ad88c7b14d8038addcc1db64d0e9a96c087115479ff6"
EXPECTED_MANIFEST_ERROR_SHA256="a1e430c71d4ca673cba76dbc866fb7fb461a4d0fa4e0dbe76a690516d1311625"
STRUCTURAL_ERRORS={
    "unsupported_transcription_scaffold":"aba8053f8d9bb5a63524d39c7729f6a148ba63fef694b53766547685c6c618d2",
    "invalid_offsets_or_speech":"e011f55264ce549d891e7ed7a763b3856ec183b054e5154e3b8c9dbb80994a05",
    "zero_duration_speech":"e6299686c73f2b8f51a96066b26f7ec022f8d74fec2710739606d4f1485e0fef",
}
MISSING=object()


class Unclassified(ValueError):pass

def require(ok,message):
    if not ok:raise Unclassified(message)

def check():
    if STOP or (R/"cancel-failure-classification.request").exists():raise InterruptedError("Failure classification canceled; sources preserved")
    if DEADLINE is not None and time.monotonic()>=DEADLINE:raise TimeoutError("Failure classification exceeded finite bound")

def sha(data):return hashlib.sha256(data).hexdigest()

def valid_sha(value):return isinstance(value,str) and re.fullmatch("[0-9a-f]{64}",value) is not None

def safe(path):
    path=Path(path)
    require(path.is_absolute() and ".." not in path.parts and not any(p.is_symlink() for p in (path,*path.parents)),"unsafe_metadata_path")
    require(stat.S_ISREG(path.stat().st_mode),"not_regular_metadata_file")
    return path

def identity(path):
    s=path.stat();return(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)

def read_bytes(path,maximum=MAX_FILE):
    check();path=safe(path);before=identity(path)
    require(before[2]<=maximum,"opaque_file_exceeds_bound")
    require(sum(v["bytes"] for k,v in READS.items() if k!=str(path))+before[2]<=MAX_TOTAL,"opaque_total_exceeds_bound")
    with path.open("rb") as f:data=f.read(maximum+1)
    require(len(data)<=maximum and identity(path)==before,"metadata_changed_during_read")
    descriptor={"path":str(path),"sha256":sha(data),"bytes":len(data)};READS[str(path)]=descriptor
    check();return data,descriptor

def pairs(values):
    out={}
    for key,value in values:
        require(key not in out,"duplicate_json_key");out[key]=value
    return out

def finite(value):
    result=float(value);require(math.isfinite(result),"nonfinite_json_number");return result

def parse(text):
    return json.loads(text,object_pairs_hook=pairs,parse_float=finite,
       parse_constant=lambda _:(_ for _ in ()).throw(Unclassified("nonfinite_json_constant")))

def json_metadata(path):
    raw,descriptor=read_bytes(path)
    value=parse(raw.decode("utf-8"))
    require(isinstance(value,dict),"metadata_root_not_object")
    return value,descriptor

def utf8_diagnostic(data):
    spans=[]
    def invalid(error):
        check();require(len(spans)<MAX_SPANS,"too_many_invalid_utf8_spans")
        spans.append({"start":error.start,"end":error.end,"reason":error.reason})
        return("\ufffd",error.end)
    name="recscribe_natural_failure_diagnostic_v1"
    codecs.register_error(name,invalid)
    text=data.decode("utf-8",errors=name)
    return text,spans

def raw_structure(data):
    diagnostic,spans=utf8_diagnostic(data)
    require(bool(spans),"raw_json_utf8_is_valid")
    # The pinned writer does not emit Unicode escapes. Reject this conservative
    # pattern even when double-escaped; Latin-1 JSON decoding could otherwise
    # turn valid escaped U+0080..00FF into invented malformed payload bytes.
    require(bytes([92,117]) not in data,"unicode_escape_diagnostic_unsupported")
    value=parse(diagnostic)
    require(isinstance(value,dict),"asr_json_root_not_object")
    entries=value.get("transcription")
    require(isinstance(entries,list) and entries and len(entries)<=4096,"missing_asr_segments")
    for entry in entries:
        require(isinstance(entry,dict) and isinstance(entry.get("text"),str) and isinstance(entry.get("offsets"),dict),"invalid_asr_segment_scaffold")
        start,end=entry["offsets"].get("from"),entry["offsets"].get("to")
        require(type(start) is int and type(end) is int and 0<=start<end,"invalid_asr_segment_timing")
    # The pinned native writer emits bytes with quote/backslash escaping, not
    # Unicode escapes. A Latin-1 diagnostic view preserves each byte value.
    # Unsupported escaped Unicode is rejected rather than guessed or repaired.
    byte_view=parse(data.decode("latin-1"))
    fields=[]
    def walk(node,path="$",depth=0):
        check();require(depth<=128,"diagnostic_nesting_exceeds_bound")
        if isinstance(node,dict):
            for key,child in node.items():
                require(isinstance(key,str) and key.isascii(),"non_ascii_json_field_name")
                walk(child,path+"."+key,depth+1)
        elif isinstance(node,list):
            for i,child in enumerate(node):walk(child,path+"["+str(i)+"]",depth+1)
        elif isinstance(node,str):
            try:payload=node.encode("latin-1")
            except UnicodeEncodeError:raise Unclassified("unsupported_unicode_escape_diagnostic")
            _,bad=utf8_diagnostic(payload)
            if bad:
                require(len(fields)<MAX_SPANS,"too_many_invalid_text_fields")
                fields.append({"path":path,"payload_bytes":len(payload),"invalid_utf8_spans":bad})
    walk(byte_view)
    paths=[f["path"] for f in fields]
    canonical=lambda p:re.fullmatch(r"\$\.transcription\[\d+\]\.text",p) is not None
    allowed=lambda p:canonical(p) or re.fullmatch(r"\$\.transcription\[\d+\]\.tokens\[\d+\]\.text",p) is not None
    require(bool(paths),"invalid_utf8_field_paths_missing")
    require(all(allowed(p) for p in paths),"invalid_utf8_outside_asr_text_fields")
    return {"invalid_byte_spans":spans,"replacement_field_paths":paths,"field_diagnostics":fields,
      "canonical_segment_text_invalid":any(canonical(p) for p in paths),"segment_count":len(entries),
      "diagnostic_only":"In-memory replacement/Latin-1 views locate invalid fields only; no text emitted or accepted"}

def int64(value):return type(value) is int and -(2**63)<=value<2**63

def json_type(value):
    if value is MISSING:return "missing"
    if value is None:return "null"
    if type(value) is bool:return "bool"
    if type(value) is int:return "integer"
    if type(value) is float:return "number"
    if isinstance(value,str):return "string"
    if isinstance(value,list):return "array"
    if isinstance(value,dict):return "object"
    raise Unclassified("unsupported_json_value_type")

def unmistakably_nonblank_nonmarker(text):
    # A letter/digit is never removed by Foundation whitespace trimming.
    # Ignore all non-alphanumerics for marker exclusion, conservatively rejecting
    # even punctuation/Unicode-edge variations instead of guessing trim parity.
    skeleton="".join(c.lower() for c in text if c.isalnum())
    return bool(skeleton) and skeleton not in ("blankaudio","silence","nospeech")

def structural_failure(data,branch):
    require(branch in STRUCTURAL_ERRORS,"unsupported_structural_branch")
    # The pinned writer emits literal Unicode. Keep escaped-Unicode ambiguities
    # unsupported, just as for the byte-preserving UTF-8 diagnostic path.
    require(bytes([92,117]) not in data,"unicode_escape_structural_diagnostic_unsupported")
    value=parse(data.decode("utf-8",errors="strict"))
    entries=value.get("transcription",MISSING) if isinstance(value,dict) else MISSING
    violations=[]
    def violation(path,reason,start=MISSING,end=MISSING,nonblank=None,types=None):
        require(len(violations)<4096,"too_many_native_validation_violations")
        violations.append({"path":path,"reason":reason,
          "from_ms":start if int64(start) else None,"to_ms":end if int64(end) else None,
          "offset_types":types or [json_type(start),json_type(end)],"nonblank_nonmarker":nonblank})
    if branch=="unsupported_transcription_scaffold":
        require(not isinstance(entries,list),"transcription_array_is_supported")
        violation("$.transcription","transcription_missing_or_not_array",types=["not_applicable","not_applicable"])
        segment_count=None
    else:
        require(isinstance(entries,list) and 1<=len(entries)<=4096,"bounded_asr_segments_required")
        segment_count=len(entries)
        for i,entry in enumerate(entries):
            check();base="$.transcription["+str(i)+"]"
            def first_failure(kind,path,reason,start=MISSING,end=MISSING,nonblank=None):
                require(branch==kind,"earlier_native_validation_branch_conflicts_with_error_metadata")
                violation(path,reason,start,end,nonblank)
            if not isinstance(entry,dict):
                first_failure("invalid_offsets_or_speech",base,"segment_not_object");break
            offsets=entry.get("offsets",MISSING);text=entry.get("text",MISSING)
            if not isinstance(offsets,dict):
                first_failure("invalid_offsets_or_speech",base+".offsets","offsets_not_object");break
            start,end=offsets.get("from",MISSING),offsets.get("to",MISSING)
            # Any definite failure in the compound reader guard proves branch114.
            # A float alone is ambiguous: Swift may decode an integral JSON float
            # as Int64. Never advance past an ambiguous earlier entry.
            if not int64(start) and type(start) is not float:
                first_failure("invalid_offsets_or_speech",base+".offsets.from","offset_not_supported_int64",start,end);break
            if not int64(end) and type(end) is not float:
                first_failure("invalid_offsets_or_speech",base+".offsets.to","offset_not_supported_int64",start,end);break
            if not isinstance(text,str):
                first_failure("invalid_offsets_or_speech",base+".text","speech_not_string",start,end);break
            require(int64(start) and int64(end),"earlier_numeric_decoding_is_ambiguous")
            if start<0 or end<start:
                first_failure("invalid_offsets_or_speech",base+".offsets","negative_start_or_reversed_interval",start,end);break
            if start==end:
                ascii_trimmed=text.strip(" \t\r\n\v\f")
                if not ascii_trimmed or ascii_trimmed.lower() in ("[blank_audio]","[silence]","[no_speech]"):continue
                require(unmistakably_nonblank_nonmarker(text),"earlier_zero_duration_text_is_ambiguous")
                first_failure("zero_duration_speech",base,"zero_duration_nonblank_nonmarker",start,end,True);break
        require(bool(violations),"native_validation_predicate_not_demonstrated")
    return {"valid_utf8":True,"strict_json":True,"invalid_byte_spans":[],"replacement_field_paths":[],
      "field_diagnostics":[],"canonical_segment_text_invalid":False,"segment_count":segment_count,
      "native_validation":{"contract":"native-whisper-read-structural-rejection-v1","branch":branch,
        "error_message_sha256":STRUCTURAL_ERRORS[branch],"violations":violations,"text_emitted":False},
      "diagnostic_only":"Structural validation proof only; no transcript text emitted, timing repaired or output accepted"}

def classify(row,index,matrix_folder):
    key={k:row.get(k) for k in ("id","model","language_mode","path","source_channel","repeat")}
    require(all(isinstance(key[k],str) and re.fullmatch("[A-Za-z0-9_-]{1,200}",key[k]) for k in ("id","model")),"unsafe_failed_cell_identity")
    require(key["language_mode"] in ("known","auto") and key["path"]=="final" and type(key["source_channel"]) is int
       and key["source_channel"]==0 and type(key["repeat"]) is int and 1<=key["repeat"]<=10,"unsupported_failed_cell_mode")
    require(row.get("evidence_directory")=="cell-"+str(index),"failed_evidence_directory_not_canonical")
    cell=matrix_folder/row["evidence_directory"];job=cell/key["id"]
    require(not (job/"transcript.json").exists() and not (job/"transcript.raw.json").exists(),"canonical_transcript_already_present")
    result,result_descriptor=json_metadata(cell/"results.json")
    outcomes=result.get("results")
    require(isinstance(outcomes,list) and len(outcomes)==1 and outcomes[0].get("id")==key["id"]
      and outcomes[0].get("status")=="failed" and outcomes[0].get("task")==row.get("task"),"outer_case_not_single_failed_attempt")
    manifest,manifest_descriptor=json_metadata(job/"manifest.json")
    require(manifest.get("state")=="failed" and manifest.get("error",{}).get("type")=="failed","job_not_natural_failed_state")
    outer_error=outcomes[0].get("error");inner_error=manifest["error"].get("message")
    require(isinstance(outer_error,str) and sha(outer_error.encode())==EXPECTED_OUTER_ERROR_SHA256
      and isinstance(inner_error,str),"failure_error_metadata_not_pinned_native_output_contract")
    inner_hash=sha(inner_error.encode())
    branch=next((kind for kind,digest in STRUCTURAL_ERRORS.items() if digest==inner_hash),None)
    require(inner_hash==EXPECTED_MANIFEST_ERROR_SHA256 or branch is not None,
      "failure_error_metadata_not_pinned_native_output_contract")
    raw,raw_descriptor=read_bytes(job/"asr-channel-0.json")
    structure=structural_failure(raw,branch) if branch else raw_structure(raw)
    _,profile=json_metadata(job/"asr-channel-0.profile.json")
    evidence={"outer_results":result_descriptor,"manifest":manifest_descriptor,"profile_metadata":profile}
    for label,path in (("outer_log",cell/(key["id"]+".log")),("native_log",job/"asr-channel-0.log"),
      ("native_version_metadata",job/"asr-channel-0.version.log"),("audio_metadata",job/"audio-report.json")):
        _,evidence[label]=read_bytes(path)
    time_path=cell/(key["id"]+".time.txt")
    if time_path.is_file():_,evidence["source_time_metadata"]=read_bytes(time_path)
    kind=branch or ("invalid_utf8_canonical_asr_segment" if structure["canonical_segment_text_invalid"] else "invalid_utf8_asr_token_text_only")
    return {"key":key,"evidence_directory":row["evidence_directory"],"classification":kind,
      "status":"classified_unscored_failed","raw_json":{**raw_descriptor,**structure},"evidence":evidence,
      "cause_provenance":{"contract":"pinned-native-output-validation-failure-metadata-v2","outer_error_sha256":sha(outer_error.encode()),
        "manifest_error_message_sha256":sha(inner_error.encode()),"sole_cause_proven":False,
        "interpretation":"Matching frozen-code failure metadata plus structurally unusable ASR bytes; no recovered text or causal repair claim"},
      "scores_recovered":False,"source_bytes_modified":False,
      "note":"Cell cancel.request is created by generic benchmark failure cleanup; campaign cancellation is checked separately by controller"}

def main(argv=None):
    global STOP,DEADLINE
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix",type=Path,required=True);parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--expected-source-sha256",required=True)
    args=parser.parse_args(argv);STOP=False;DEADLINE=time.monotonic()+180;READS.clear()
    def stop(_number,_frame):
        global STOP
        STOP=True
    for n in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(n,stop)
    own,tool=read_bytes(Path(__file__))
    require(valid_sha(args.expected_source_sha256) and tool["sha256"]==args.expected_source_sha256,"classifier_source_hash_mismatch")
    matrix_path=safe(args.matrix);stage=matrix_path.parent.parent
    require(matrix_path.name=="matrix.json" and matrix_path.parent.name=="matrix" and stage.parent==R,"explicit_protected_stage_matrix_required")
    require(args.output==stage/"natural-failures.attempted-v2.json"
      and not args.output.exists(),"new_exact_stage_failure_receipt_required")
    raw,matrix_descriptor=read_bytes(matrix_path,MAX_MATRIX);matrix=parse(raw.decode("utf-8"))
    rows=matrix.get("rows")
    require(isinstance(rows,list) and 1<=len(rows)<=20000 and all(isinstance(r,dict) for r in rows),"bounded_matrix_rows_required")
    failed=[];unknown=[]
    for index,row in enumerate(rows):
        check()
        if row.get("status")!="failed":continue
        try:failed.append(classify(row,index,matrix_path.parent))
        except (ValueError,OSError,KeyError,TypeError) as error:
            if isinstance(error,(InterruptedError,TimeoutError)):raise
            unknown.append({"key":{k:row.get(k) for k in ("id","model","language_mode","path","source_channel","repeat")},
              "evidence_directory":row.get("evidence_directory"),"classification":"unclassified","reason_code":str(error) if isinstance(error,Unclassified) else type(error).__name__})
    count=sum(r.get("status")=="failed" for r in rows)
    require(len(failed)+len(unknown)==count,"failed_classification_coverage_disagrees")
    receipt={"schema_version":VERSION,"created_utc":datetime.now(timezone.utc).isoformat(),
      "classifier":{"path":tool["path"],"sha256":tool["sha256"]},"matrix":{"path":matrix_descriptor["path"],"sha256":matrix_descriptor["sha256"]},"matrix_bytes":matrix_descriptor["bytes"],
      "failure_count":count,"classified_failure_count":len(failed),"failed_cells":failed,"unclassified_cells":unknown,
      "all_failures_classified":count>0 and not unknown,"recognition_performed":False,"rescoring_performed":False,"retry_performed":False,
      "reference_audio_model_paths_followed":False,"text_emitted":False,"source_bytes_modified":False,
      "scope":"Only failed ASR text encoding or finite NativeWhisperEngine.read structural rejection branches. Does not attest guard shutdown, attempted grid, settings/hashes or capture state.",
      "bounds":{"per_raw_or_evidence_file_bytes":MAX_FILE,"matrix_bytes":MAX_MATRIX,"total_input_bytes":MAX_TOTAL,"timeout_seconds":180},
      "input_hashes":list(READS.values())}
    encoded=(json.dumps(receipt,ensure_ascii=True,indent=2,allow_nan=False)+"\n").encode()
    require(len(encoded)<=MAX_MATRIX,"classification_receipt_exceeds_bound")
    check()
    with args.output.open("xb") as f:f.write(encoded)
    args.output.chmod(0o600)
    print(json.dumps({"output":str(args.output),"sha256":sha(encoded),"failure_count":count,
      "classified_failure_count":len(failed),"unclassified_failure_count":len(unknown),"all_failures_classified":receipt["all_failures_classified"],"text_emitted":False}))
    return 0 if receipt["all_failures_classified"] else 1

if __name__=="__main__":
    try:raise SystemExit(main())
    except InterruptedError as error:print(type(error).__name__+": "+str(error),file=sys.stderr);raise SystemExit(130)
    except (ValueError,OSError,KeyError,TypeError) as error:print(type(error).__name__+": "+str(error),file=sys.stderr);raise SystemExit(1)

