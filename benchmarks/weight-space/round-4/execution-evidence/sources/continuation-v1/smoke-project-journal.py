#!/usr/bin/env python3
"""Actual projector CLI+validate_chain in a synthetic namespace, no real journals."""
import hashlib,importlib.util,json,os,subprocess,sys
from pathlib import Path
H=Path(__file__).absolute().parent
def load(name,p):
    s=importlib.util.spec_from_file_location(name,p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def sha(b):return hashlib.sha256(b).hexdigest()
def encode(x):return (json.dumps(x,indent=2,allow_nan=False)+'\n').encode()
def main():
    t=load('synthetic_projector_fixture',H/'test-project-journal.py');p=t.P
    root=Path(os.environ['RECSCRIBE_RUN_DIR'])/'synthetic-root';(root/'continuation-v1').mkdir(parents=True,mode=0o700)
    p.R=root
    args=list(t.fixture());cap,old,new,cappin,oldpin,newpin,sourcepin=args
    oldbytes=p.canonical_lines(old);oldsha=sha(oldbytes);oldpin['sha256']=oldsha
    actual=(H/'project-journal.py').read_bytes();copied=actual.replace(p.ORIGINAL.encode(),oldsha.encode())
    # Only fixture root and original-journal hash differ; production source stays untouched.
    source=root/'continuation-v1/project-journal.py';source.write_bytes(copied)
    sourcepin.update(path=str(source),sha256=sha(copied))
    cap['base_stop_proof']['sha256']=sha(encode({'synthetic_stop_proof':True}))
    Path(cap['base_stop_proof']['path']).write_bytes(encode({'synthetic_stop_proof':True}))
    classification={'all_failures_classified':True,'failure_count':1,'unclassified_cells':[],
        'recognition_performed':False,'rescoring_performed':False,'retry_performed':False}
    b=encode(classification);cap['base_classification']['sha256']=sha(b)
    folder=root/p.IDS[6];folder.mkdir(exist_ok=True)
    (folder/'natural-failures.attempted-v2.json').write_bytes(b);(folder/'natural-failures.json').write_bytes(b)
    alias=next(e for e in new if e.get('event')=='classifier_receipt_alias_created');alias['canonical_receipt']['sha256']=sha(b)
    capbytes=encode(cap);capsha=sha(capbytes)
    new[0]['continuation_capsule_sha256']=new[-1]['continuation_capsule_sha256']=capsha
    newbytes=p.canonical_lines(new);newsha=sha(newbytes)
    (root/'serial.events.jsonl').write_bytes(oldbytes);(root/'serial-continuation-v1.events.jsonl').write_bytes(newbytes);(root/'continuation.freeze.v1.json').write_bytes(capbytes)
    command=[sys.executable,str(source),'--continuation-freeze',str(root/'continuation.freeze.v1.json'),'--continuation-freeze-sha256',capsha,
        '--continuation-journal-sha256',newsha,'--expected-source-sha256',sha(copied)]
    first=subprocess.run(command,capture_output=True,text=True,timeout=15)
    if first.returncode:raise ValueError('Synthetic actual CLI failed: '+first.stderr)
    logical=root/'logical-serial-continuation-v1.events.jsonl';receipt=root/'logical-serial-continuation-v1.receipt.json'
    q=load('synthetic_chain_validator_actual_cli',source)
    result=q.validate_chain(root/'continuation.freeze.v1.json',capsha,receipt,sha(receipt.read_bytes()),sha(logical.read_bytes()))
    if result['coverage']['attempted_cells']!=4554 or result['coverage']['failed_cells']!=1:raise ValueError('Coverage differs')
    original=sha(oldbytes);before=sha(logical.read_bytes());again=subprocess.run(command,capture_output=True,text=True,timeout=15)
    if again.returncode==0 or sha(logical.read_bytes())!=before or sha((root/'serial.events.jsonl').read_bytes())!=original:raise ValueError('Exclusive/raw preservation failed')
    value={'schema_version':'round4-continuation-projector-synthetic-cli-v1','status':'PASS_ACTUAL_CLI_AND_VALIDATE_CHAIN',
        'production_source_sha256':sha(actual),'synthetic_copy_sha256':sha(copied),'copy_change':'Only ORIGINAL journal hash constant and namespace differ; frozen production source unchanged',
        'first_cli_exitcode':first.returncode,'second_cli_rejected_existing_outputs':again.returncode!=0,
        'validated_attempts':4554,'validated_failed_cells':1,'prior_stop_marker_preserved':True,
        'actual_campaign_journal_outcomes_or_payloads_read':False,'recognition_or_rescoring_performed':False,'default_promotion':False}
    out=H.parent/'projector-continuation-cli-smoke-v3.receipt.json';data=encode(value)
    with out.open('xb') as f:f.write(data)
    out.chmod(0o600)
    print(json.dumps({'receipt':str(out),'sha256':sha(data),'status':value['status']}))
if __name__=='__main__':main()
