#!/usr/bin/env python3
"""Initialize six frozen derived models, then reject our empty audio; never ASR.

The pinned CLI initializes context/state before read_audio_data(). A single
existing empty file takes its read-failure/continue/free/return11 path before
whisper_full_parallel. Printed runs are max(1,actual_count), so zero displayed
compute time and pinned control-flow evidence are retained, not invented counts.
Run only under the recording-priority guard after a fresh native idle check.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

R=Path(__file__).absolute().parent
R3=R.parent/'round-3'
CLI_SHA='e23dcdf55fdff2dfc085902b00cac93aba09e0373422e40ddd69d7c67d725f16'
SOURCE_PINS={
    'examples/cli/cli.cpp':'675b63066ed1f3364305af3cb2ea70e379396c1d6511f6358df867c163c98ff9',
    'examples/common-whisper.cpp':'852fbc77d2461322a82b9c571cf4703bac3c78c5c51d3a90e80792ce0c04e313',
    'src/whisper.cpp':'891168a838301bd2baa5e8b87422a854dafeeb7da914d40a2e4c6bf33ff448ed'}
ROLES={'permuted_f16':'conversion_control','plain_q4':'compression','permuted_q4':'combined'}
MAX_FILE=4*1024**3
MAX_METADATA=8*1024**2
MAX_LOG=8*1024**2


def require(value,message):
    if not value:raise ValueError(message)


def regular(path):
    path=Path(path)
    require(path.is_absolute() and '..' not in path.parts and not any(p.is_symlink() for p in (path,*path.parents)),
        'Absolute nonsymlink input required')
    require(stat.S_ISREG(path.stat().st_mode),'Regular input required');return path


def identity(path):
    s=Path(path).lstat();require(stat.S_ISREG(s.st_mode),'Input ceased to be regular')
    return s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns


def record(path,check=lambda:None,maximum=MAX_FILE):
    path=regular(path);before=identity(path);require(before[2]<=maximum,'Input exceeds bound')
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        while True:
            check();block=stream.read(256*1024)
            if not block:break
            digest.update(block)
    require(identity(path)==before,'Input changed during bounded hash')
    return {'path':str(path),'sha256':digest.hexdigest(),'bytes':before[2]}


def read(path,expected,check):
    d=record(path,check,MAX_METADATA);require(d['sha256']==expected,'Explicit metadata pin differs')
    before=identity(path)
    with Path(path).open('rb') as stream:raw=stream.read(MAX_METADATA+1)
    require(len(raw)<=MAX_METADATA and identity(path)==before and hashlib.sha256(raw).hexdigest()==expected,'Metadata changed')
    def fields(items):
        value={}
        for key,item in items:require(key not in value,'Duplicate JSON key');value[key]=item
        return value
    def number(value):
        result=float(value);require(math.isfinite(result),'Nonfinite JSON number');return result
    value=json.loads(raw,object_pairs_hook=fields,parse_float=number,
        parse_constant=lambda _:(_ for _ in ()).throw(ValueError('Nonfinite JSON constant')))
    require(isinstance(value,dict),'Object metadata required');return value,d


def write_new(path,value):
    data=(json.dumps(value,indent=2,allow_nan=False)+'\n').encode();require(len(data)<=MAX_METADATA,'Receipt exceeds bound')
    with Path(path).open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())


def validate_inputs(artifact,inventory):
    require(artifact.get('schema_version')=='round5-artifact-family-v1' and artifact.get('state')=='completed'
        and artifact.get('quality_inference_executed') is False and artifact.get('default_promotion') is False,
        'Complete unexposed artifact family required')
    require(inventory.get('schema_version')=='round5-pre-execution-inventory-v1' and inventory.get('verified_model_files')==11
        and inventory.get('quality_inference_executed') is False and inventory.get('installed_app_changed') is False,
        'Exact pre-execution inventory required')
    native=inventory.get('native_files');models=inventory.get('models');families=artifact.get('families')
    require(isinstance(native,list) and len(native)==11 and len({d['path'] for d in native})==11
        and Path(native[0]['path']).name=='whisper-cli' and native[0]['sha256']==CLI_SHA,'Pinned eleven-file native inventory required')
    require(isinstance(models,list) and len(models)==11 and len({d['id'] for d in models})==11
        and len({d['path'] for d in models})==11,'Exact eleven distinct models required')
    require(isinstance(families,dict) and set(families)=={'small','large-v3-turbo'}
        and artifact.get('original_models')==inventory.get('original_models'),'Original/family lineage differs')
    indexed={d['id']:d for d in models};selected=[]
    for family in ('small','large-v3-turbo'):
        arms=families[family];parent=inventory['original_models'][family]
        require(set(arms)=={'original',*ROLES},'Four fixed arms required')
        for role,kind in ROLES.items():
            arm=arms[role];identifier=family+'-'+role.replace('_','-');row=indexed.get(identifier,{})
            require(arm.get('id')==identifier and arm.get('kind')==kind and arm.get('parent_original_id')==family
                and arm.get('parent_original_sha256')==parent['sha256'] and row.get('kind')==kind
                and row.get('role')==role and row.get('family')==family
                and all(row.get(k)==arm.get(k) for k in ('path','sha256'))
                and type(arm.get('model_file_bytes')) is int and row.get('bytes')==arm['model_file_bytes']>0,
                'Derived model role/lineage/inventory differs')
            selected.append({'id':identifier,'family':family,'role':role,'path':arm['path'],'sha256':arm['sha256'],'bytes':arm['model_file_bytes']})
    require(len({d['path'] for d in (*native,*selected)})==17,'Native/model paths must be distinct')
    require(all(type(d.get('bytes')) is int and 0<d['bytes']<=MAX_FILE
        and isinstance(d.get('sha256'),str) and re.fullmatch('[0-9a-f]{64}',d['sha256']) for d in (*native,*selected)),'Bound positive file pins required')
    require(sum(d['bytes'] for d in (*native,*selected))<=16*1024**3,'Load-check inputs exceed16GiB')
    return native,selected


def validate_log(data,returncode,fixture):
    require(type(returncode) is int and returncode==11,'Only pinned read-failure exit11 is admissible')
    require(0<len(data)<=MAX_LOG,'Bounded nonempty native log required')
    text=data.decode('utf-8');lines=text.splitlines()
    expected_read="error: failed to read audio file '"+str(fixture)+"'"
    require(lines.count(expected_read)==1 and lines.count('error: 1 input file(s) failed')==1,
        'Exactly one expected input read failure required')
    require([line for line in lines if line.startswith('error:')]==[expected_read,'error: 1 input file(s) failed'],
        'Unexpected native error prevents load acceptance')
    allowed_failed={'read_audio_data: failed to read audio data','read_audio_data: failed to ffmpeg decode',expected_read,'error: 1 input file(s) failed'}
    require(not any(('failed' in line.lower() and line not in allowed_failed) or re.search(r'\b(?:assert|abort|exception|fatal)\b',line,re.I)
        for line in lines),'Unexpected initialization/runtime failure in native log')
    def one(pattern):
        found=re.findall(pattern,text,re.M);require(len(found)==1,'Missing/duplicate native witness: '+pattern);return found[0]
    require(one(r'^whisper_init_with_params_no_state: use gpu\s*= (\d+)$')=='1'
        and one(r'^whisper_init_with_params_no_state: flash attn\s*= (\d+)$')=='1','Requested GPU/FA not active')
    backend=one(r'^whisper_backend_init_gpu: using (MTL\d+) backend$')
    for name in ('conv','encode','cross','decode'):
        amount=one(r'^whisper_init_state: compute buffer \('+name+r'\)\s*=\s*([0-9.]+) MB$')
        require(math.isfinite(float(amount)) and float(amount)>0,'State allocator did not complete')
    require(one(r'^whisper_print_timings:\s+fallbacks =\s*(\d+) p /\s*(\d+) h$')==('0','0'),'Fallbacks imply unexpected inference')
    require(float(one(r'^whisper_print_timings:\s+mel time =\s*([0-9.]+) ms$'))==0,'Unexpected mel processing')
    displayed={}
    for label in ('sample','encode','decode','batchd','prompt'):
        elapsed,runs,per=one(r'^whisper_print_timings:\s+'+label+r' time =\s*([0-9.]+) ms /\s*(\d+) runs \(\s*([0-9.]+) ms per run\)$')
        require(float(elapsed)==float(per)==0 and runs=='1','Unexpected inference timing; display clamps runs to one')
        displayed[label]={'milliseconds':float(elapsed),'displayed_runs':int(runs),'milliseconds_per_displayed_run':float(per)}
    require(not re.search(r'^main: processing|^\[\d\d:\d\d|^whisper_full',text,re.M),'Unexpected transcription path')
    return {'native_context_and_state_initialization':'observed','actual_selected_gpu_backend':backend,
        'use_gpu':True,'flash_attention':True,'threads_argument':2,'empty_input_read_failures':1,
        'inference_calls_from_pinned_control_flow':0,'actual_internal_run_counts_observable':False,
        'printed_runs_note':'Pinned whisper_print_timings uses max(1,n); displayed1 is not an actual call count',
        'displayed_compute_timings':displayed,'quality_or_performance_measured':False}


def members(group,session):
    require(type(group) is int and group>1 and group!=os.getpgrp(),'Invalid owned PGID')
    result=subprocess.run(['/bin/ps','-axo','pid,pgid'],stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=.5)
    require(result.returncode==0 and len(result.stdout)<=1024**2,'Owned child inventory unavailable')
    found=[]
    for line in result.stdout.splitlines()[1:]:
        row=line.split();require(len(row)==2 and all(v.isdigit() for v in row),'Invalid process inventory')
        pid,pgid=map(int,row)
        if pgid!=group:continue
        try:
            require(os.getsid(pid)==session and os.getpgid(pid)==group,'Owned process group identity changed');found.append(pid)
        except ProcessLookupError:pass
    return found


def cleanup(child,group,session):
    errors=[];signals=[]
    for number,grace in ((signal.SIGINT,.5),(signal.SIGTERM,.5),(signal.SIGKILL,1)):
        try:
            owned=members(group,session)
            if not owned:break
            require(all(os.getsid(pid)==session and os.getpgid(pid)==group for pid in owned),'Group ownership changed before signal')
            os.killpg(group,number);signals.append(int(number));end=time.monotonic()+grace
            while time.monotonic()<end:
                child.poll()
                if not members(group,session):break
                time.sleep(.025)
        except ProcessLookupError:continue
        except (ValueError,OSError,subprocess.TimeoutExpired) as error:errors.append(type(error).__name__+': '+str(error));break
    if child.poll() is None:
        try:child.kill()
        except ProcessLookupError:pass
    try:child.wait(timeout=.5)
    except subprocess.TimeoutExpired:errors.append('Owned direct child did not reap')
    try:remaining=members(group,session)
    except (ValueError,OSError,subprocess.TimeoutExpired) as error:remaining=None;errors.append(type(error).__name__+': '+str(error))
    return {'pid':child.pid,'pgid':group,'sid':session,'returncode':child.returncode,'cli_reaped':child.poll() is not None,
        'owned_group_present':None if remaining is None else bool(remaining),'signals':signals,'errors':errors}


def run_child(command,log,check,timeout=60):
    require(0<timeout<=60,'Per-load cap must not exceed60seconds')
    child=None;shutdown=None;session=os.getsid(0);deadline=time.monotonic()+timeout
    try:
        with log.open('xb') as target:
            check();child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=target,stderr=subprocess.STDOUT,process_group=0)
            while True:
                check();require(log.stat().st_size<=MAX_LOG,'Native log exceeds8MiB')
                if time.monotonic()>=deadline:raise TimeoutError('Native load exceeded60second cap')
                if child.poll() is not None:break
                time.sleep(.05)
        require(not members(child.pid,session),'Native child left an owned descendant')
        shutdown={'pid':child.pid,'pgid':child.pid,'sid':session,'returncode':child.returncode,'cli_reaped':True,
            'owned_group_present':False,'signals':[],'errors':[]}
        return shutdown
    finally:
        if child is not None and shutdown is None:
            shutdown=cleanup(child,child.pid,session)
            require(shutdown['cli_reaped'] is True and shutdown['owned_group_present'] is False and not shutdown['errors'],
                'Owned native cleanup uncertain: '+json.dumps(shutdown))


def run_check(artifact_path,artifact_sha,inventory_path,inventory_sha,expected_source_sha,output,timeout=600,cancel_file=None):
    require(type(timeout) is int and 1<=timeout<=600,'Finite total cap≤600required')
    output=Path(output)
    require(output.is_absolute() and '..' not in output.parts and output.parent.is_dir() and not output.exists()
        and not any(p.is_symlink() for p in (output,*output.parents)),'New protected absolute output required')
    require(not any((p/'.git').exists() for p in (output,*output.parents)),'Native load artifacts must stay outside checkout')
    if cancel_file is not None:
        cancel_file=Path(cancel_file);require(cancel_file.is_absolute() and '..' not in cancel_file.parts,'Absolute cancel marker required')
    previous={};requested=False;deadline=time.monotonic()+timeout;created=False
    def stop(*_):
        nonlocal requested
        requested=True
    def check():
        if requested or (output/'cancel.request').exists() or (cancel_file is not None and cancel_file.exists()):
            raise InterruptedError('Native load check canceled; no transcription attempted')
        if time.monotonic()>=deadline:raise TimeoutError('Native load check exceeded total bound')
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):previous[number]=signal.signal(number,stop)
    receipt={'schema_version':'round5-native-load-only-v1','status':'preparing','created_utc':datetime.now(timezone.utc).isoformat(),
        'recognition_performed':False,'quality_or_resource_acceptance_measured':False,'quality_inference_grid_cells_added':0,
        'installed_app_changed':False,'default_promotion':False,'results':[],'timeout_seconds':timeout,'per_load_timeout_seconds':60}
    try:
        own=record(Path(__file__),check,MAX_METADATA);require(own['sha256']==expected_source_sha,'Explicit native-load source pin differs')
        artifact,artifact_d=read(artifact_path,artifact_sha,check);inventory,inventory_d=read(inventory_path,inventory_sha,check)
        require(inventory.get('artifact_family')==artifact_d,'Inventory does not bind the exact artifact receipt')
        native,selected=validate_inputs(artifact,inventory);bindings=(*native,*selected)
        snapshots={}
        for d in bindings:
            actual=record(d['path'],check);require(all(actual[k]==d[k] for k in ('path','sha256','bytes')),'Frozen model/native payload differs')
            snapshots[d['path']]=identity(d['path'])
        sources=[]
        for relative,sha in SOURCE_PINS.items():
            d=record(R3/'native/whisper.cpp'/relative,check,MAX_METADATA);require(d['sha256']==sha,'Pinned native control-flow source differs');sources.append(d)
        output.mkdir(mode=0o700);created=True;fixture=output/'empty-invalid-audio.bin'
        with fixture.open('xb'):pass
        fixture.chmod(0o400);fixture_identity=identity(fixture)
        receipt.update(status='running',source=own,artifact_family=artifact_d,inventory=inventory_d,native_control_flow_sources=sources,
            native_files=native,selected_models=selected,invalid_fixture=record(fixture,check),
            method='existing-empty-file; context/state init then expected read failure/continue/free/return11 before whisper_full_parallel')
        write_new(output/'started.json',receipt)
        for index,model in enumerate(selected):
            check();require(all(identity(p)==v for p,v in snapshots.items()),'Frozen input identity changed between loads')
            require(identity(fixture)==fixture_identity and fixture.stat().st_size==0,'Owned empty fixture changed')
            command=[native[0]['path'],'-m',model['path'],'-f',str(fixture),'-t','2','-l','auto','-fa']
            log=output/(str(index+1)+'-'+model['id']+'.log');shutdown=run_child(command,log,check)
            witness=validate_log(log.read_bytes(),shutdown['returncode'],fixture)
            result={'model':model,'command':command,'log':record(log,check,MAX_LOG),'shutdown':shutdown,'witness':witness}
            receipt['results'].append(result);write_new(output/(str(index+1)+'-load-result.json'),result)
        for d in bindings:
            actual=record(d['path'],check);require(all(actual[k]==d[k] for k in ('path','sha256','bytes'))
                and identity(d['path'])==snapshots[d['path']],'Frozen model/native changed during load checks')
        require(record(Path(__file__),check,MAX_METADATA)==own and read(artifact_path,artifact_sha,check)[1]==artifact_d
            and read(inventory_path,inventory_sha,check)[1]==inventory_d,'Source/input receipts changed')
        for source in sources:require(record(source['path'],check,MAX_METADATA)==source,'Native control-flow source changed')
        check();receipt.update(status='passed',verified_derived_artifacts=6,all_model_native_hashes_preserved=True,
            full_asr_operator_compatibility='PENDING_CANONICAL_GRID',actual_internal_run_counts='UNOBSERVABLE; pinned branch proves no inference calls')
        write_new(output/'receipt.json',receipt);return receipt
    except BaseException as error:
        receipt.update(status='canceled' if isinstance(error,(InterruptedError,KeyboardInterrupt,TimeoutError)) else 'failed',
            error_type=type(error).__name__,error=str(error))
        if created:write_new(output/'failure.json',receipt)
        raise
    finally:
        for number,handler in previous.items():signal.signal(number,handler)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact-family',type=Path,required=True);parser.add_argument('--artifact-family-sha256',required=True)
    parser.add_argument('--native-inventory',type=Path,required=True);parser.add_argument('--native-inventory-sha256',required=True)
    parser.add_argument('--expected-source-sha256',required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--timeout',type=int,default=600);parser.add_argument('--cancel-file',type=Path)
    args=parser.parse_args(argv)
    value=run_check(args.artifact_family,args.artifact_family_sha256,args.native_inventory,args.native_inventory_sha256,
        args.expected_source_sha256,args.output,args.timeout,args.cancel_file)
    print(json.dumps({'status':value['status'],'verified_derived_artifacts':value['verified_derived_artifacts'],'recognition_performed':False}))


if __name__=='__main__':
    try:main()
    except (ValueError,OSError,InterruptedError,TimeoutError) as error:
        print(type(error).__name__+': '+str(error),file=sys.stderr);raise SystemExit(1)
