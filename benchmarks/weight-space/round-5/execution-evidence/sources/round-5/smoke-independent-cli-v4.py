#!/usr/bin/env python3
"""Actual four new MAIN writers over the labelled, completed rich model-free toy."""
import argparse,hashlib,json,os,subprocess,sys,time
from pathlib import Path
R=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
    Path(os.environ['RECSCRIBE_RUN_DIR'],'.pin').touch(exist_ok=True)
    p=argparse.ArgumentParser();p.add_argument('--fixture',type=Path,required=True);a=p.parse_args();f=a.fixture.resolve()
    s=json.loads((f/'packaged-smoke-v7.receipt.json').read_bytes());c=s['rich_context']
    if s.get('synthetic_only') is not True:raise ValueError('Only completed labelled toy may open')
    family=c['family'];admission=c['admission'];journal=f/'serial.events.jsonl'
    post=f/'independent-postrun-cli-v1';post_guard=f/'independent-postrun-cli-v1.guard.jsonl';summary=f/'independent-reporting-summary-v1';projection=f/'independent-reporting-projection-v1';numeric=f/'independent-numeric-cli-v1'
    reporting=json.loads(Path(c['reporting_freeze']['path']).read_bytes());ss=reporting['sources']['summarize-round5-v1.py'];ps=reporting['sources']['project-round5-report-v1.py']
    ss={**ss,'path':str(f/'summarize-round5-v1.py')};ps={**ps,'path':str(f/'project-round5-report-v1.py')}
    if sha(ss['path'])!=ss['sha256'] or sha(ps['path'])!=ps['sha256']:raise ValueError('Canonical packaged source bytes differ')
    common=['--family-seal',family['path'],'--family-seal-sha256',family['sha256'],'--journal',str(journal),'--journal-sha256',sha(journal),
      '--admission-capsule',admission['path'],'--admission-capsule-sha256',admission['sha256']]
    commands=[];results=[]
    post_cmd=[sys.executable,'-B',c['postrun_source']['path'],*common,'--integrity',c['integrity']['path'],'--integrity-sha256',c['integrity']['sha256'],
      '--operation-freeze',c['operation_freeze']['path'],'--operation-freeze-sha256',c['operation_freeze']['sha256'],
      '--expected-source-sha256',c['postrun_source']['sha256'],'--output',str(post)]
    guard=R.parent/'round-3/attempted-v1/run-guard.py'
    commands.append(('postrun',[sys.executable,'-B',str(guard),'--output',str(post),'--log',str(post_guard),'--timeout','600','--poll-seconds','1','--probe-timeout','2','--foreign-cpu-limit','1000','--',*post_cmd]))
    commands.append(('summary',[sys.executable,'-B',ss['path'],*common,'--expected-source-sha256',ss['sha256'],'--output',str(summary)]))
    status='FAILED_ACTUAL_INDEPENDENT_CLI_SMOKE_SYNTHETIC_ONLY'
    def run(name,command):
        print('Executing actual model-free MAIN: '+name,flush=True)
        begin=time.monotonic();r=subprocess.run(command,capture_output=True,text=True,timeout=660 if name=='postrun' else 120)
        results.append({'name':name,'command':command,'returncode':r.returncode,'elapsed_seconds':time.monotonic()-begin,'stdout':r.stdout,'stderr':r.stderr})
        print(json.dumps({'step':name,'returncode':r.returncode}),flush=True)
        return r.returncode==0
    okay=True
    for name,command in commands:
        if not run(name,command):okay=False;break
    if okay:
        okay=run('projector',[sys.executable,'-B',ps['path'],'--summary',str(summary/'summary.json'),'--summary-sha256',sha(summary/'summary.json'),
          '--family-seal-sha256',family['sha256'],'--admission-capsule-sha256',admission['sha256'],'--expected-source-sha256',ps['sha256'],'--output',str(projection)])
    if okay:
        args={'family-seal':family['path'],'family-seal-sha256':family['sha256'],'journal':str(journal),'journal-sha256':sha(journal),
          'admission-capsule':admission['path'],'admission-capsule-sha256':admission['sha256'],
          'summary':str(summary/'summary.json'),'summary-sha256':sha(summary/'summary.json'),'projection-audit':str(projection/'audit.json'),'projection-audit-sha256':sha(projection/'audit.json'),
          'summary-source':ss['path'],'summary-source-sha256':ss['sha256'],'projector-source':ps['path'],'projector-source-sha256':ps['sha256'],
          'reporting-freeze':c['reporting_freeze']['path'],'reporting-freeze-sha256':c['reporting_freeze']['sha256'],
          'audit-freeze':c['audit_freeze']['path'],'audit-freeze-sha256':c['audit_freeze']['sha256'],
          'preservation-source':c['postrun_source']['path'],'preservation-source-sha256':c['postrun_source']['sha256'],
          'preservation-freeze':c['operation_freeze']['path'],'preservation-freeze-sha256':c['operation_freeze']['sha256'],
          'preservation-receipt':str(post/'preservation.json'),'preservation-sha256':sha(post/'preservation.json'),
          'preservation-guard':str(post_guard),'preservation-guard-sha256':sha(post_guard),
          'expected-source-sha256':c['numeric_source']['sha256'],'output':str(numeric)}
        command=[sys.executable,'-B',c['numeric_source']['path']]
        for k,v in args.items():command+=['--'+k,v]
        okay=run('numeric',command)
    if okay:
        v=json.loads((numeric/'receipt.json').read_bytes());assert v['counts']=={'attempted':4554,'completed':4552,'failed':2}
        assert v['quality_coverage_complete'] is False and v['checks']['quality_cohorts']==495 and v['checks']['macro_rows']==55
        assert v['completed_opaque_preservation_authority']['source_case_coverage']['distinct_source_cases']==225
        status='PASSED_ACTUAL_POSTRUN_SUMMARY_PROJECTOR_NUMERIC_MAIN_SYNTHETIC_ONLY'
    receipt={'schema_version':'round5-independent-all-main-cli-smoke-v1','status':status,'synthetic_only':True,
      'actual_postrun_summary_projector_numeric_mains_executed':True,'model_initialization_recognition_quantization_or_rescoring_performed':False,
      'fixture_receipt':{'path':str(f/'packaged-smoke-v7.receipt.json'),'sha256':sha(f/'packaged-smoke-v7.receipt.json')},'results':results}
    output=f/'independent-all-main-cli-smoke-v4.receipt.json';b=(json.dumps(receipt,indent=2)+'\n').encode()
    with output.open('xb') as stream:stream.write(b)
    print(json.dumps({'status':status,'receipt':str(output),'sha256':hashlib.sha256(b).hexdigest()}),flush=True)
    return 0 if okay else 1
if __name__=='__main__':raise SystemExit(main())
