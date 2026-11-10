#!/usr/bin/env python3
"""Freeze and run the six fixed R5 byte-only exports; never initialize ASR.

The immutable command graph precedes every model payload read. Typed SHA slots
can only refer to completed, hash-bound predecessors; no recipe choice exists.
All model reads/edits/quantization and final payload inventory run under7697.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import time

R = Path(__file__).resolve().parent
W = Path('/Users/moreaki/.codex/worktrees/swiss-written-corpus/recscribe')
R4 = R.parent / 'round-4'
R3 = R.parent / 'round-3'
OPERATOR_SHA = '0a33ffab0c343b88e1cffa3e571619b414148d4b88673b69fa77386124087122'
EXPORTER_SHA = 'eca16247e3855bd5948e01378a4d56fe08c3b2613c824cc2fa17f1f25766e9f4'
CORE_SHA = 'bf3f2ef5e00a4c06ef7fd4912c46dd2a0d50f7a381d45fff7cef6c5fae93c4e0'
PARSER_SHA = '11c0c7ddda3d81a90c47b58a4b82415f9764f51eed7b2c5302fdc0784c34e4c3'
GUARD_SHA = '7697f60e8a2c0aa150b598afe2e8c552435e1d8a4cb2f99489c9fa10de0dc56c'
QUANTIZER_SHA = '2efffddc246a52e7ba9a81145926d07e7f1c5fc7ba56a95586602a12ec5e00bd'
RETAINED_SEAL_SHA = '8058f9785929639d70da620fd6f12841b3078aa17352f6d02b542b6a7f191fe2'
FAMILIES = ('small', 'large-v3-turbo')
ROLES = ('permuted_f16', 'plain_q4', 'permuted_q4')
KINDS = {'original':'pretrained', 'permuted_f16':'conversion_control', 'plain_q4':'compression', 'permuted_q4':'combined'}
PLAIN_CONTROLS = {
    'small': {'sha256':'f6099c17a4305c6d173ef90ab6f15150dcbb85332b7831313bf36a378d7c5a85','bytes':145458015},
    'large-v3-turbo': {'sha256':'2ceb779ca61ce46ed6e9aa43c4a0f8a89a37f683df3c0ba3119238fcd5852155','bytes':473992235}}
MAX_MODEL = 4 * 1024**3
MAX_METADATA = 8 * 1024**2
FREE_SPACE = 10 * 1024**3
ENVIRONMENT = {k:'1' for k in ('OPENBLAS_NUM_THREADS','OMP_NUM_THREADS','VECLIB_MAXIMUM_THREADS','MKL_NUM_THREADS','NUMEXPR_NUM_THREADS','BLIS_NUM_THREADS')}
STOP = False
DEADLINE = None

def require(value, message):
    if not value: raise ValueError(message)

def valid_sha(value):
    return isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None

def check():
    if STOP or (R/'cancel-artifacts.request').exists(): raise InterruptedError('Generation canceled; no retries, owned guard cleanup required')
    if DEADLINE is not None and time.monotonic() >= DEADLINE: raise TimeoutError('Generation exceeded its fixed overall bound')

def identity(s): return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)

def regular(path):
    path=Path(path)
    require(path.is_absolute() and '..' not in path.parts and not any(p.is_symlink() for p in (path,*path.parents)), 'Absolute nonsymlink file required')
    require(stat.S_ISREG(path.lstat().st_mode),'Regular file required')
    return path

def descriptor(path, expected=None, maximum=64*1024**2, byte_counter=None):
    path=regular(path);before=path.stat();require(0<=before.st_size<=maximum,'Input exceeds fixed byte bound')
    h=hashlib.sha256();consumed=0
    with path.open('rb') as f:
        require(identity(os.fstat(f.fileno()))==identity(before),'Input replaced before read')
        while True:
            check();block=f.read(min(256*1024,before.st_size-consumed+1))
            if not block:break
            consumed+=len(block)
            if byte_counter is not None:
                byte_counter[0]+=len(block);require(byte_counter[0]<=16*1024**3,'Inventory exceeds16GiB physical read bound')
            require(consumed<=before.st_size,'Input grew while reading');h.update(block)
        require(consumed==before.st_size and identity(os.fstat(f.fileno()))==identity(before),'Input changed while reading')
    require(identity(path.lstat())==identity(before),'Input path changed while reading')
    value={'path':str(path),'sha256':h.hexdigest(),'bytes':consumed}
    require(expected is None or value['sha256']==expected,'Frozen hash differs: '+str(path))
    return value

def read(path, expected=None):
    pin=descriptor(path,expected,MAX_METADATA);path=Path(path);before=path.stat()
    with path.open('rb') as f:data=f.read(MAX_METADATA+1)
    require(len(data)<=MAX_METADATA and len(data)==pin['bytes'] and hashlib.sha256(data).hexdigest()==pin['sha256']
            and identity(path.lstat())==identity(before),'Metadata changed before parsing')
    return json.loads(data)

def write(path,value):
    data=(json.dumps(value,indent=2,allow_nan=False)+'\n').encode();require(len(data)<=MAX_METADATA,'Output metadata exceeds8MiB')
    with Path(path).open('xb') as f:f.write(data);f.flush();os.fsync(f.fileno())
    Path(path).chmod(0o600)

def copy_source(source,destination,expected):
    pin=descriptor(source,expected,MAX_METADATA);destination.parent.mkdir(parents=True,exist_ok=True)
    with Path(source).open('rb') as f:data=f.read(MAX_METADATA+1)
    require(len(data)==pin['bytes'] and hashlib.sha256(data).hexdigest()==expected,'Source changed before archival')
    with destination.open('xb') as f:f.write(data);f.flush();os.fsync(f.fileno())
    destination.chmod(0o400)
    return descriptor(destination,expected,MAX_METADATA)

def template_steps(original,tools,python,output):
    result=[]
    for family in FAMILIES:
        parent=original[family]
        for role in ROLES:
            folder=output/(family+'-'+role)
            if role=='permuted_f16':
                command=[python,'-B',tools['operator']['path'],'apply',parent['path'],'--model-id',family,
                    '--sha256',parent['sha256'],'--output',str(folder),'--timeout','600']
            else:
                source=parent['path'] if role=='plain_q4' else str(output/(family+'-permuted_f16')/'model.bin')
                source_sha=parent['sha256'] if role=='plain_q4' else '${'+family+'.permuted_f16.sha256}'
                command=[python,'-B',tools['exporter']['path'],'--model',source,'--sha256',source_sha,'--model-id',family,
                    '--role',role,'--parent',parent['path'],'--parent-sha256',parent['sha256'],'--output',str(folder),'--timeout','600']
                if role=='permuted_q4':
                    for option,predecessor,filename,key in (
                        ('permutation-plan','permuted_f16','permutation-plan.json','plan_sha256'),
                        ('permutation-audit','permuted_f16','permutation-audit.json','audit_sha256'),
                        ('plain-control','plain_q4','export-audit.json','audit_sha256')):
                        command += ['--'+option,str(output/(family+'-'+predecessor)/filename),
                                    '--'+option+'-sha256','${'+family+'.'+predecessor+'.'+key+'}']
            result.append({'id':family+'-'+role,'family':family,'role':role,'output':str(folder),
                'guard_log':str(R/(folder.name+'.guard.jsonl')),'timeout_seconds':600,'command_template':command})
    return result

def resolve_command(template,results):
    command=[]
    for value in template:
        if value.startswith('${'):
            match=re.fullmatch(r'\$\{(small|large-v3-turbo)\.(permuted_f16|plain_q4)\.(sha256|audit_sha256|plan_sha256)\}',value)
            require(match is not None,'Unknown command dependency')
            family,role,key=match.groups();value=results[family][role][key]
            require(valid_sha(value),'Predecessor hash missing')
        command.append(value)
    return command

def verify_sources(freeze):
    check()
    for pin in freeze['source_files']+freeze['native_files']+[freeze['tools']['quantizer'],freeze['tools']['python'],freeze['runner'],freeze['baseline_control']]:
        actual=descriptor(pin['path'],pin['sha256']);require(actual['bytes']==pin['bytes'],'Frozen file size changed')
    require(descriptor(Path(__file__))==freeze['coordinator'],'Generation coordinator changed')
    for name,pin in freeze['original_models'].items():
        p=regular(pin['path']);require(p.stat().st_size==pin['bytes'],'Original model size changed: '+name)

def freeze_package(args):
    require(args.output==R/'artifacts' and not args.output.exists() and not args.freeze.exists(),'New canonical generation outputs required')
    require(shutil.disk_usage(R).free>=FREE_SPACE,'Need10GiB available protected external space')
    head=subprocess.run(['git','rev-parse','HEAD'],cwd=W,capture_output=True,text=True,timeout=5,check=True).stdout.strip()
    require(head==args.source_revision and valid_sha(args.exporter_sha256) and args.exporter_sha256==EXPORTER_SHA,'Final reviewed source revision/exporter required')
    retained=R4/'pre-inference-family-seal.json';old=read(retained,RETAINED_SEAL_SHA)
    package=R/'generation-source-v1';require(not package.exists(),'Source package must be new');package.mkdir(mode=0o700)
    sources={'operator':('scripts/quality/mlp-permute.py',OPERATOR_SHA),
        'exporter':('scripts/quality/quantize-mlp-permutation.py',EXPORTER_SHA),
        'reused_q4_core':('scripts/quality/quantize-attention-rotation.py',CORE_SHA),
        'parser':('scripts/quality/ggml_weights.py',PARSER_SHA)}
    tools={key:copy_source(W/relative,package/relative,pin) for key,(relative,pin) in sources.items()}
    protocol_path=W/'benchmarks/weight-space-round5-protocol.md';protocol_pin=descriptor(protocol_path)
    protocol=copy_source(protocol_path,package/'benchmarks/weight-space-round5-protocol.md',protocol_pin['sha256'])
    tools['guard']=copy_source(R3/'attempted-v1/run-guard.py',package/'run-guard.py',GUARD_SHA)
    tools['quantizer']=descriptor(Path('/opt/homebrew/bin/whisper-quantize').resolve(strict=True),QUANTIZER_SHA)
    tools['python']=descriptor(Path(sys.executable).resolve(strict=True))
    native=[descriptor(p['path'],p['sha256']) for p in old['native_files']]
    require(len(native)==11,'Exactly11 pinned native files required')
    original=old['original_models'];require(set(original)=={'tiny','base','small','large-v3-turbo','large-v3'},'All5 original controls required')
    for value in original.values():require(valid_sha(value['sha256']) and type(value['bytes']) is int and 0<value['bytes']<=MAX_MODEL,'Invalid original pin')
    source_files=[tools[k] for k in sources]+[tools['guard'],protocol]
    python=tools['python']['path']
    value={'schema_version':'round5-artifact-generation-freeze-v1','created_utc':datetime.now(timezone.utc).isoformat(),
        'coordinator':descriptor(Path(__file__)),'source_revision':head,'source_repository':str(W),'source_archive':str(package),
        'source_files':source_files,'tools':tools,'native_files':native,'protocol':protocol,
        'retained_original_inventory':descriptor(retained,RETAINED_SEAL_SHA),'original_models':original,'prior_plain_q4_controls':PLAIN_CONTROLS,
        'runner':old['runner'],'baseline_control':old['baseline_control'],'output':str(args.output),
        'steps':template_steps(original,tools,python,args.output),'permutation_version':'whisper-mlp-permutation-v1',
        'recipe_sha256':OPERATOR_SHA,'quantization':{'format':'q4_0','file_header_ftype':2002,'tensor_type':2,'quantizer_sha256':QUANTIZER_SHA},
        'dependency_rule':'Only typed predecessor SHA slots are resolved from completed hash-bound audit outputs; no command or recipe selection',
        'minimum_available_bytes_before_each_stage':FREE_SPACE,'observed_available_bytes_before_freeze':shutil.disk_usage(R).free,
        'maximum_model_bytes':MAX_MODEL,'artifact_timeout_seconds':600,'guard_supervisor_seconds':660,'interrupt_cleanup_seconds':60,
        'generation_timeout_seconds':4800,'inventory_maximum_payload_read_bytes':16*1024**3,
        'inventory_output':str(R/'generation-inventory-v1'),'inventory_request':str(R/'generation-inventory.request.v1.json'),
        'numeric_workers':1,'numeric_environment':ENVIRONMENT,'host':{'platform':platform.platform(),'uname':list(platform.uname()),'python':sys.version,'numpy':importlib.metadata.version('numpy')},
        'training_used':False,'fitting_used':False,'recipe_search':False,'quality_inference_executed':False,
        'native_model_initialization_executed':False,'native_idle_admission_required_before':'later model initialization or ASR; byte-only work uses capture guard',
        'default_promotion':False}
    verify_sources(value);write(args.freeze,value)
    print(json.dumps({'freeze':descriptor(args.freeze),'steps':6,'source_revision':head,'model_payloads_read':False}),flush=True)

def load_freeze(args):
    require(valid_sha(args.freeze_sha256),'Explicit freeze SHA required')
    value=read(args.freeze,args.freeze_sha256)
    require(value['schema_version']=='round5-artifact-generation-freeze-v1' and args.output==Path(value['output']),'Wrong generation freeze/output')
    require(value['steps']==template_steps(value['original_models'],value['tools'],value['tools']['python']['path'],args.output),'Fixed6 command graph differs')
    verify_sources(value);return value

def guard_command(freeze,output,log,command):
    require(command.count('--output')==1 and command[command.index('--output')+1]==str(output),'Guard/worker output contract differs')
    return [freeze['tools']['python']['path'],'-B',freeze['tools']['guard']['path'],'--output',str(output),'--log',str(log),
        '--timeout','600','--poll-seconds','1','--probe-timeout','2','--foreign-cpu-limit','1000','--',*command]

def closed_guard(path,command):
    pin=descriptor(path,maximum=MAX_METADATA)
    with Path(path).open('rb') as f:data=f.read(MAX_METADATA+1)
    require(len(data)<=MAX_METADATA and hashlib.sha256(data).hexdigest()==pin['sha256'],'Guard log changed or exceeded bound')
    events=[json.loads(line) for line in data.splitlines() if line.strip()]
    require(events and events[0].get('event')=='starting' and events[0].get('command')==command
            and events[0].get('foreign_cpu_limit')==1000,'Actual guard command/settings differ')
    final=events[-1];s=final.get('shutdown',{})
    require(final.get('event')=='finished' and final.get('reason') is None and final.get('failure') is None and final.get('canceled') is False
            and type(s.get('returncode')) is int and s['returncode']==0 and s.get('cli_reaped') is True and s.get('owned_session_present') is False and s.get('shutdown_errors')==[], 'Guard failed/canceled/uncertain')
    require(not any(e.get('event') in ('cancel_requested','owned_group_signal','owned_cli_signal','interrupted','cancelled') for e in events),'Guard cancellation veto')
    return descriptor(path,maximum=MAX_METADATA)

def supervise_guard(command):
    child=subprocess.Popen(command,stdin=subprocess.DEVNULL,env={**os.environ,**ENVIRONMENT},start_new_session=True)
    try:
        end=time.monotonic()+660
        check()  # Includes a request delivered inside Popen.
        while child.poll() is None:
            check()
            if time.monotonic()>=end:raise TimeoutError('Owned generation guard exceeded660s')
            try:child.wait(timeout=.25)
            except subprocess.TimeoutExpired:pass
        check();require(child.returncode==0,'Guarded byte export failed; no later stage or retry')
    except BaseException:
        if child.poll() is None:child.send_signal(signal.SIGINT)
        try:child.wait(timeout=60)
        except subprocess.TimeoutExpired:raise RuntimeError('Owned guard cleanup uncertain; stop without foreign-process killing')
        raise

def artifact_metadata(step,parent):
    folder=Path(step['output']);role=step['role'];audit_path=folder/('permutation-audit.json' if role=='permuted_f16' else 'export-audit.json')
    audit=read(audit_path);require(audit.get('state')=='completed' and valid_sha(audit.get('derived_sha256')),'Artifact audit incomplete')
    if role=='permuted_f16':
        require(audit.get('schema_version')=='whisper-mlp-permutation-v1' and audit.get('source_sha256')==parent['sha256']
                and audit.get('generator_sha256')==OPERATOR_SHA,'Permutation provenance differs')
        size=audit['file_bytes']
    else:
        require(audit.get('schema_version')=='mlp-permutation-official-q4-v1' and audit.get('role')==role
                and audit.get('parent_original_sha256')==parent['sha256'] and audit.get('quantizer_sha256')==QUANTIZER_SHA,'Q4 provenance differs')
        size=audit['model_file_bytes']
    path=regular(folder/'model.bin');require(path.stat().st_size==size,'Published artifact size differs')
    result={'id':step['family']+'-'+role.replace('_','-'),'path':str(path),'sha256':audit['derived_sha256'],'bytes':size,'model_file_bytes':size,
        'kind':KINDS[role],'parent_original_id':step['family'],'parent_original_sha256':parent['sha256'],
        'audit':descriptor(audit_path,maximum=MAX_METADATA),'audit_sha256':descriptor(audit_path,maximum=MAX_METADATA)['sha256'],
        'post_guard_file_identity':list(identity(path.stat()))}
    if role=='permuted_f16':
        result['permutation_plan']=descriptor(folder/'permutation-plan.json',maximum=MAX_METADATA)
        result['plan_sha256']=result['permutation_plan']['sha256'];require(result['plan_sha256']==audit['permutation_plan_sha256'],'Permutation plan hash differs')
    if role=='plain_q4':require({'sha256':result['sha256'],'bytes':size}==PLAIN_CONTROLS[step['family']],'Official unchanged plain-Q4 reproduction differs')
    if role=='permuted_q4':result['weight_error_diagnostics']=audit['plain_control_comparison']['weight_error_diagnostics']
    return result

def run_generation(args,freeze):
    global DEADLINE
    DEADLINE=time.monotonic()+4800
    os.setpriority(os.PRIO_PROCESS,0,10)
    preflight_path=R/'generation-preflight.launch.v1.json';pre=read(preflight_path)
    require(pre['freeze']=={'path':str(args.freeze),'sha256':args.freeze_sha256},'Matching packaged preflight required')
    expected_preflight=[freeze['tools']['python']['path'],'-B',freeze['coordinator']['path'],'preflight',
        '--output',str(args.output),'--freeze',str(args.freeze),'--freeze-sha256',args.freeze_sha256]
    require(pre['worker_command']==expected_preflight,'Exact model-free packaged preflight command required')
    closed_guard(R/'generation-preflight.guard.v1.jsonl',pre['worker_command'])
    require(not args.output.exists(),'Artifacts output must be exclusive');args.output.mkdir(mode=0o700)
    results={family:{} for family in FAMILIES}
    for step in freeze['steps']:
        verify_sources(freeze);require(descriptor(args.freeze)['sha256']==args.freeze_sha256,'Generation freeze changed')
        require(shutil.disk_usage(R).free>=FREE_SPACE,'Need10GiB available before each export')
        command=resolve_command(step['command_template'],results)
        guarded=guard_command(freeze,Path(step['output']),Path(step['guard_log']),command)
        launch=R/(step['id']+'.launch.json')
        write(launch,{'freeze':{'path':str(args.freeze),'sha256':args.freeze_sha256},'step':step,'command':guarded,
            'observed_available_bytes':shutil.disk_usage(R).free,'nice':10,'no_inference':True})
        print(json.dumps({'event':'export_starting','id':step['id'],'launch':descriptor(launch)}),flush=True)
        supervise_guard(guarded);verify_sources(freeze)
        guard=closed_guard(step['guard_log'],command)
        value=artifact_metadata(step,freeze['original_models'][step['family']]);value['guard']=guard
        results[step['family']][step['role']]=value
        write(R/(step['id']+'.completed.json'),value)
        print(json.dumps({'event':'export_completed','id':step['id'],'sha256':value['sha256'],'bytes':value['bytes']}),flush=True)
    models=[]
    for name,p in freeze['original_models'].items():models.append({**p,'id':name,'model_file_bytes':p['bytes'],'kind':'pretrained','parent_original_id':name,'parent_original_sha256':p['sha256']})
    for family in FAMILIES:
        results[family]['original']=next(p for p in models if p['id']==family)
        models += [results[family][role] for role in ROLES]
    request=Path(freeze['inventory_request']);write(request,{'freeze_sha256':args.freeze_sha256,'models':models,'families':results})
    inventory_out=Path(freeze['inventory_output']);inventory_log=R/'generation-inventory.guard.v1.jsonl'
    command=[freeze['tools']['python']['path'],'-B',str(Path(__file__)),'inventory','--output',str(inventory_out),
        '--freeze',str(args.freeze),'--freeze-sha256',args.freeze_sha256,'--request',str(request),'--request-sha256',descriptor(request)['sha256']]
    guarded=guard_command(freeze,inventory_out,inventory_log,command)
    write(R/'generation-inventory.launch.v1.json',{'freeze_sha256':args.freeze_sha256,'command':guarded})
    supervise_guard(guarded);guard=closed_guard(inventory_log,command);verify_sources(freeze)
    inventory=descriptor(inventory_out/'inventory.json',maximum=MAX_METADATA)
    require(read(inventory['path'],inventory['sha256'])['state']=='completed','Actual11-model/native inventory incomplete')
    receipt={'schema_version':'round5-artifact-family-v1','state':'completed','generation_freeze':descriptor(args.freeze),
        'source_revision':freeze['source_revision'],'permutation_version':'whisper-mlp-permutation-v1','recipe_sha256':OPERATOR_SHA,
        'families':results,'models':models,'original_models':freeze['original_models'],'tools':freeze['tools'],
        'inventory':inventory,'inventory_guard':guard,'quality':'UNMEASURED','native_compatibility':'PENDING',
        'resource_gate':'NOT_EVALUATED','quality_inference_executed':False,'native_model_initialization_executed':False,
        'heldout_reference_text_inspected':False,'default_promotion':False}
    write(R/'artifact-family.receipt.json',receipt)
    print(json.dumps({'state':'completed','receipt':descriptor(R/'artifact-family.receipt.json'),'exports':6,'verified_models':11}),flush=True)

def inventory_worker(args):
    global DEADLINE
    DEADLINE=time.monotonic()+600
    freeze=read(args.freeze,args.freeze_sha256);verify_sources(freeze)
    require(args.output==Path(freeze['inventory_output']) and not args.output.exists(),'New frozen inventory output required')
    require(args.request==Path(freeze['inventory_request']),'Only the frozen inventory request path is allowed')
    request=read(args.request,args.request_sha256);require(request['freeze_sha256']==args.freeze_sha256,'Inventory request/freeze differs')
    canonical=[];families={family:{} for family in FAMILIES}
    for name,p in freeze['original_models'].items():
        canonical.append({**p,'id':name,'model_file_bytes':p['bytes'],'kind':'pretrained','parent_original_id':name,'parent_original_sha256':p['sha256']})
    for step in freeze['steps']:
        command=resolve_command(step['command_template'],families)
        actual=artifact_metadata(step,freeze['original_models'][step['family']])
        actual['guard']=closed_guard(step['guard_log'],command)
        require(read(R/(step['id']+'.completed.json'))==actual,'Completed artifact metadata differs before inventory')
        families[step['family']][step['role']]=actual
    for family in FAMILIES:
        families[family]['original']=next(p for p in canonical if p['id']==family)
        canonical += [families[family][role] for role in ROLES]
    require(request['models']==canonical and request['families']==families,'Inventory request differs from all6 completed guarded artifacts')
    models=request['models'];expected=set(freeze['original_models'])|{family+'-'+role.replace('_','-') for family in FAMILIES for role in ROLES}
    require(len(models)==11 and {m['id'] for m in models}==expected,'Exact11 models required')
    counter=[0];records=[]
    for item in models:
        pin=descriptor(item['path'],item['sha256'],MAX_MODEL,counter);require(pin['bytes']==item['bytes'],'Inventory model size differs')
        records.append({**pin,'id':item['id'],'kind':item['kind'],'parent_original_id':item['parent_original_id'],
            'parent_original_sha256':item['parent_original_sha256'],'file_identity':list(identity(Path(pin['path']).stat()))})
    verify_sources(freeze)
    for item in records:require(list(identity(Path(item['path']).lstat()))==item['file_identity'],'Earlier inventoried model changed')
    args.output.mkdir(mode=0o700)
    write(args.output/'inventory.json',{'schema_version':'round5-generation-payload-inventory-v1','state':'completed',
        'freeze_sha256':args.freeze_sha256,'request':descriptor(args.request,args.request_sha256),'models':records,
        'verified_model_files':11,'native_files':freeze['native_files'],'payload_bytes_read':counter[0],
        'source_revision':freeze['source_revision'],'originals_unchanged':True,'quality_inference_executed':False,'native_model_initialization_executed':False})

def main(argv=None):
    global STOP,DEADLINE
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=('freeze','preflight','run','inventory'))
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--freeze',type=Path,required=True)
    parser.add_argument('--freeze-sha256');parser.add_argument('--source-revision');parser.add_argument('--exporter-sha256')
    parser.add_argument('--request',type=Path);parser.add_argument('--request-sha256')
    args=parser.parse_args(argv)
    STOP=False
    DEADLINE=time.monotonic()+(4800 if args.mode=='run' else 600 if args.mode=='inventory' else 180)
    Path(os.environ['RECSCRIBE_RUN_DIR'],'.pin').touch(exist_ok=True)
    def stop(*_):
        global STOP
        STOP=True
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(number,stop)
    if args.mode=='freeze':freeze_package(args)
    elif args.mode=='inventory':inventory_worker(args)
    else:
        freeze=load_freeze(args)
        if args.mode=='preflight':
            require(not args.output.exists(),'Preflight must precede artifact output')
            print(json.dumps({'state':'preflight_passed','model_payloads_read':False,'native_model_initialization_executed':False,
                'fixed_export_commands':6,'freeze_sha256':args.freeze_sha256}),flush=True)
        else:run_generation(args,freeze)
    return 0

if __name__=='__main__':
    raise SystemExit(main())
