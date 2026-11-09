#!/usr/bin/env python3
"""Actual CLI-write smoke of the independent audit's new authority branch.

Uses synthetic nonexistent model/output payload descriptors. It does not run
the complete scientific audit main, any scorer, recognition or real outcome.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import time

REAL=Path(__file__).absolute().parent.parent
def sha(data):return hashlib.sha256(data).hexdigest()
def encoded(value):return (json.dumps(value,indent=2,allow_nan=False)+'\n').encode()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--expected-audit-source-sha256',required=True);a=parser.parse_args()
    source=REAL/'continuation-v1/audit-final-numeric-gates.py';source_bytes=source.read_bytes()
    if len(source_bytes)>1024*1024 or sha(source_bytes)!=a.expected_audit_source_sha256:raise ValueError('Audit source lock differs')
    spec=importlib.util.spec_from_file_location('synthetic_preservation_branch_audit',source);A=importlib.util.module_from_spec(spec);spec.loader.exec_module(A)
    root=Path(os.environ['RECSCRIBE_RUN_DIR'])/'synthetic-authority-root';root.mkdir(mode=0o700)
    A.R=root;A.DEADLINE=time.monotonic()+30
    def save(path,value,jsonl=False):
        path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        data=b''.join(encoded(v).replace(b'\n',b'')+b'\n' for v in value) if jsonl else encoded(value)
        with path.open('xb') as f:f.write(data)
        return sha(data)
    model={'id':'synthetic','path':str(root/'NEVER-OPEN-model.bin'),'sha256':'a'*64,'model_file_bytes':123}
    family={'models':[model],'immutable_files':[{'path':model['path'],'sha256':model['sha256']}]}
    helper=b'# Synthetic source bytes only; never executed.\n';(root/'continuation-v1').mkdir();(root/'continuation-v1/audit-postrun-preservation.py').write_bytes(helper)
    A.PRESERVATION_SOURCE_SHA=sha(helper)
    frozen={'schema_version':'round4-postrun-preservation-continuation-freeze-v1','created_utc':'2026-01-01T00:00:00+00:00',
        'source':{'sha256':A.PRESERVATION_SOURCE_SHA},'original_family':{'sha256':A.FAMILY_SHA},
        'original_admission':{'sha256':A.ADMISSION_SHA},'default_promotion':False,**{k:False for k in ('opaque_preservation_algorithm_changed','scorer_changed','quality_gates_changed','allow_inference_retries')}}
    A.PRESERVATION_FREEZE_SHA=save(root/'postrun-preservation-continuation.freeze.v1.json',frozen)
    events=[{'event':'command_start','action':'guarded_inference','stage':A.IDS[10],'created_utc':'2026-02-01T00:00:00+00:00'}]
    events.extend({'event':'stage_assessed','id':identifier,'matrix_sha256':'b'*64} for identifier in A.IDS)
    events.append({'event':'serial_finished','created_utc':'2026-02-02T00:00:00+00:00'})
    value={'schema_version':'round4-postrun-opaque-preservation-v1','created_utc':'2026-02-02T00:01:00+00:00',
        'status':'PASS_OPAQUE_INPUT_AND_RETAINED_OUTPUT_HASHES','source':{'sha256':A.PRESERVATION_SOURCE_SHA},
        'family_seal_sha256':A.FAMILY_SHA,'final_journal_sha256':'c'*64,'native_review':'PENDING','controlled_resource_acceptance':'NOT_EVALUATED','default_promotion':False,
        **{k:False for k in ('training','recognition','rescoring','reference_or_transcript_semantic_decode','input_or_output_bytes_modified')},
        'frozen_input_count':1,'retained_output_count':15,'frozen_inputs':[{'path':model['path'],'sha256':model['sha256'],'bytes':123}],
        'retained_outputs':[{'path':str(root/i/'matrix/matrix.json'),'sha256':'b'*64,'bytes':456} for i in A.IDS]}
    receipt_sha=save(root/'postrun-preservation-continuation-v1/preservation.json',value)
    guard=[{'event':'starting','foreign_cpu_limit':1000},{'event':'finished','canceled':False,'reason':None,'failure':None,'guard_observation':None,
        'shutdown':{'returncode':0,'cli_reaped':True,'owned_session_present':False,'shutdown_errors':[]}}]
    guard_sha=save(root/'postrun-preservation-continuation-v1.guard.jsonl',guard,True)
    result=A.preservation_provenance(family,events,'c'*64,receipt_sha,guard_sha)
    failures=[]
    for name,change in [('wrong_journal',lambda:(family,events,'d'*64,receipt_sha,guard_sha)),
                        ('wrong_model_hash',lambda:({**family,'models':[{**model,'sha256':'d'*64}]},events,'c'*64,receipt_sha,guard_sha))]:
        try:A.preservation_provenance(*change())
        except ValueError:failures.append(name)
        else:raise ValueError('Synthetic corruption admitted: '+name)
    bad=list(guard);bad[-1]={**bad[-1],'canceled':True}
    original=(root/'postrun-preservation-continuation-v1.guard.jsonl').read_bytes()
    (root/'postrun-preservation-continuation-v1.guard.jsonl').unlink();bad_sha=save(root/'postrun-preservation-continuation-v1.guard.jsonl',bad,True)
    try:A.preservation_provenance(family,events,'c'*64,receipt_sha,bad_sha)
    except ValueError:failures.append('canceled_guard')
    else:raise ValueError('Canceled synthetic guard admitted')
    if Path(model['path']).exists() or any(Path(v['path']).exists() for v in value['retained_outputs']):raise ValueError('Synthetic payload unexpectedly exists')
    A.R=REAL
    output={'schema_version':'round4-independent-audit-authority-cli-smoke-v1','created_utc':datetime.now(timezone.utc).isoformat(),
        'status':'PASS_SYNTHETIC_NEW_AUTHORITY_BRANCH_AND_EXCLUSIVE_CLI_WRITE','audit_source_sha256':sha(source_bytes),
        'smoke_source_sha256':sha(Path(__file__).read_bytes()),'synthetic_result':result,'rejected_corruptions':failures,
        'payload_descriptors_nonexistent':True,'actual_campaign_journal_or_outcomes_read':False,'recognition_or_rescoring_performed':False,
        'scope':'Actual CLI invokes new preservation_provenance and final publish_files. Full scientific audit main remains unexecuted until final15 barrier.',
        'default_promotion':False}
    data=encoded(output);A.publish_files(a.output,{'receipt.json':data})
    try:A.publish_files(a.output,{'receipt.json':b'overwrite'})
    except ValueError:pass
    else:raise ValueError('Exclusive publication allowed overwrite')
    if (a.output/'receipt.json').read_bytes()!=data or stat.S_IMODE((a.output/'receipt.json').stat().st_mode)!=0o600:raise ValueError('Published synthetic receipt changed or permissions differ')
    print(json.dumps({'status':output['status'],'output':str(a.output),'receipt_sha256':sha(data),'default_promotion':False}))
if __name__=='__main__':main()
