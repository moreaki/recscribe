#!/usr/bin/env python3
"""Use the unchanged frozen numeric builder on a verified logical journal.

This is an explicitly different entry point, not execution of the original main.
Both immutable raw journals, the real stop and the metadata-only recovery remain
in execution_context. No stage outcome opens until the projector proves all15.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import stat
import sys

R=Path(__file__).absolute().parent.parent
BUILDER='9638db9ee4cf02b15dafc854bdcbfce74c523de04757115ba5eb358226ddd870'
FAMILY='8058f9785929639d70da620fd6f12841b3078aa17352f6d02b542b6a7f191fe2'
ADMISSION='1e9d6a0dbea1fd9f9df2ece06a9044e24eb4f2b37c259500cca87545e9d29153'
MAX_SOURCE=4*1024**2


def need(value,message):
    if not value:raise ValueError(message)


def source_bytes(path,expected):
    path=Path(path)
    need(path.is_absolute() and R in path.parents and '..' not in path.parts
        and not any(p.is_symlink() for p in (path,*path.parents)),'Protected metadata/source required')
    before=path.stat();need(stat.S_ISREG(before.st_mode) and before.st_size<=MAX_SOURCE,'Bootstrap input exceeds4MiB')
    with path.open('rb') as stream:data=stream.read(MAX_SOURCE+1)
    after=path.stat();identity=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    need(len(data)<=MAX_SOURCE and identity(before)==identity(after) and hashlib.sha256(data).hexdigest()==expected,
        'Bootstrap metadata/source SHA differs')
    return data


def decoded(data):
    def fields(items):
        value={}
        for key,child in items:need(key not in value,'Duplicate JSON key');value[key]=child
        return value
    def finite(value):
        value=float(value);need(math.isfinite(value),'Nonfinite metadata');return value
    return json.loads(data,object_pairs_hook=fields,parse_float=finite,
        parse_constant=lambda _:(_ for _ in ()).throw(ValueError('Nonfinite metadata')))


def module(path,expected,name):
    source_bytes(path,expected)
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec)
    sys.modules[name]=value;spec.loader.exec_module(value);return value


def build_verified(builder,reader,family,projector,args,own_sha):
    """Projector admission precedes the unchanged builder and all outcome reads."""
    chain=projector.validate_chain(Path(args.continuation_freeze),args.continuation_freeze_sha256,
        Path(args.journal_projection),args.journal_projection_sha256,args.journal_sha256,reader.check)
    need(chain.get('no_inference_retry') is True and chain.get('no_scoring_or_gate_change') is True
        and chain.get('default_promotion') is False,'Recovery cannot retry inference or change scientific policy')
    value=builder.build(reader,family,chain['events'],R/'inference-launch.freeze.v1.json',ADMISSION)
    context={k:v for k,v in chain.items() if k!='events'}
    context.update(executing_adapter_sha256=own_sha,frozen_builder_source={'path':str(R/'summarize-round4-v1.py'),'sha256':BUILDER},
        frozen_builder_api='build(reader,family,verified_logical_events,admission_path,admission_sha256)',
        original_builder_main_executed=False,
        logical_journal_is_raw=False,original_serial_stop_retained=True)
    value.update(summary_source_sha256=BUILDER,executing_adapter_sha256=own_sha,
        journal_sha256=args.journal_sha256,execution_context=context)
    # The projector follows only declared metadata. Recheck its whole raw chain
    # as well as the numeric reader's immutable input hashes before publishing.
    again=projector.validate_chain(Path(args.continuation_freeze),args.continuation_freeze_sha256,
        Path(args.journal_projection),args.journal_projection_sha256,args.journal_sha256,reader.check)
    need(again==chain,'Verified recovery chain changed during numeric construction')
    for path,pin in list(reader.ledger.items()):reader.raw(path,pin['sha256'])
    value['input_metadata_hashes']=reader.ledger
    return value


def publish(reader,output,value):
    output=Path(output)
    need(output.is_absolute() and R in output.parents and '..' not in output.parts and not output.exists()
        and not any(p.is_symlink() for p in (output,*output.parents)),'New protected summary output required')
    data=(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n').encode()
    need(len(data)<=64*1024**2,'Summary exceeds64MiB');reader.check();output.mkdir(mode=0o700)
    partial=output/'summary.partial.json';final=output/'summary.json'
    fd=os.open(partial,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600);owned=os.fstat(fd)
    with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
    reader.check();actual=partial.lstat()
    need(stat.S_ISREG(actual.st_mode) and (actual.st_dev,actual.st_ino)==(owned.st_dev,owned.st_ino)
        and actual.st_size==len(data),'Owned summary partial changed')
    os.link(partial,final,follow_symlinks=False)
    actual=final.lstat();need((actual.st_dev,actual.st_ino)==(owned.st_dev,owned.st_ino),'Published summary inode changed')
    partial.unlink();reader.check();return hashlib.sha256(data).hexdigest()


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('continuation-freeze','continuation-freeze-sha256','journal-projection','journal-projection-sha256',
                 'journal-sha256','expected-source-sha256','output'):p.add_argument('--'+name,required=True)
    p.add_argument('--timeout-seconds',type=int,choices=range(1,301),default=180)
    args=p.parse_args(argv)
    need(Path(args.continuation_freeze)==R/'continuation.freeze.v1.json'
        and Path(args.journal_projection)==R/'logical-serial-continuation-v1.receipt.json','Exact continuation/projection metadata required')
    source_bytes(Path(__file__).absolute(),args.expected_source_sha256)
    builder=module(R/'summarize-round4-v1.py',BUILDER,'r4_unchanged_numeric_builder_for_continuation')
    reader=builder.Reader(args.timeout_seconds)
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(number,lambda *_:setattr(reader,'stopped',True))
    cap,_=reader.read(Path(args.continuation_freeze),args.continuation_freeze_sha256,builder.MAX_SMALL)
    need(cap.get('schema_version')=='round4-metadata-filename-continuation-v1','Frozen continuation capsule required')
    source=cap['sources']['journal_projector']
    need(source.get('path')==str(R/'continuation-v1/project-journal.py'),'Exact journal projector source required')
    reader.raw(source['path'],source['sha256'],builder.MAX_SMALL)
    projector=module(Path(source['path']),source['sha256'],'r4_verified_journal_projector_for_summary')
    family,_=reader.read(R/'pre-inference-family-seal.json',FAMILY,builder.MAX_SMALL)
    value=build_verified(builder,reader,family,projector,args,args.expected_source_sha256)
    source_bytes(R/'summarize-round4-v1.py',BUILDER)
    source_bytes(Path(__file__).absolute(),args.expected_source_sha256)
    digest=publish(reader,Path(args.output),value)
    print(json.dumps({'status':value['status'],'summary_sha256':digest,'executing_adapter_sha256':args.expected_source_sha256,
        'frozen_builder_source_sha256':BUILDER,'original_builder_main_executed':False,'default_promotion':False}))


if __name__=='__main__':main()
