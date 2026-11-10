#!/usr/bin/env python3
"""Full fifteen-stage synthetic CLI-write campaign. Never runs NN or a quantizer.

Only guarded_inference is intercepted to write invented, labelled toy metadata.
The unchanged forensic classifier and actual reporter/assessor/sealer CLI entry
points execute as separate bounded processes. No real corpus/model is opened.
"""
import argparse
import hashlib
import importlib.util
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

R=Path(__file__).resolve().parent
OUTER='Local speech process exited with status 1; inspect its retained job log'
INNER='Speech has no duration; raw output retained for timing review'


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec)
    sys.modules[name]=value;spec.loader.exec_module(value);return value


def write(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('x') as stream:json.dump(value,stream,ensure_ascii=False,allow_nan=False);stream.write('\n')


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pending(row,original,comparison):
    fields=('id','task','repeat','language_mode','path','source_channel','language','conditions','coverage_role')
    result={k:row.get(k) for k in fields}
    identity_fields=('id','language','language_mode','path','source_sha256','reference_sha256','scoring_policy','task')
    result.update(identity='|'.join(row[k] for k in identity_fields)+'|'+str(row['source_channel'])+'|'+str(row['repeat']),
        candidate_profile=row['profile'],candidate_model=row['model'],candidate_model_sha256=row['model_sha256'],
        baseline_model=original['id'],baseline_profile=row['profile'] if comparison else None,
        comparison_id=comparison,intervention=row['model_kind'] if comparison else 'runtime',
        intervention_id=row.get('intervention_id'),pairing_contract_version='model-lineage-v2',status='pending_pair')
    return result


def failed_evidence(matrix,row,index):
    cell=matrix/('cell-'+str(index));job=cell/row['id'];job.mkdir(parents=True)
    write(cell/'results.json',{'results':[{'id':row['id'],'task':row['task'],'status':'failed','error':OUTER}]})
    write(job/'manifest.json',{'state':'failed','error':{'type':'failed','message':INNER}})
    write(job/'asr-channel-0.json',{'transcription':[{'offsets':{'from':0,'to':0},'text':'synthetic failed speech'}]})
    write(job/'asr-channel-0.profile.json',{})
    for path in (cell/(row['id']+'.log'),job/'asr-channel-0.log',job/'asr-channel-0.version.log',job/'audio-report.json'):
        path.write_bytes(b'Synthetic fixture evidence only; no ASR\n')
    (job/'cancel.request').touch()  # Existing per-cell failure cleanup, never a matrix cancel.


def synthetic_matrix(family,stage,binding=None,fail=False,guarded_command=None):
    workspace=Path(os.environ['RECSCRIBE_SOURCE_ROOT'])
    test=module('round5_actual_assessor_fixture',workspace/'scripts/tests/test_quality_mlp_assessment.py')
    helper=test.QualityMLPAssessmentTests();helper.root=family.root/'_synthetic-writer'/stage['id'];helper.root.mkdir(parents=True)
    reference=stage['partition_id'] if stage['partition_kind']=='reference' else False
    sample,matrix=helper.fixture(stage['stage'],reference=reference,family=stage['partition_id'])
    plan_path=Path(stage['paths']['final_plan']) if binding else Path(stage['assessment_pre_freeze_plan'])
    plan=json.loads(plan_path.read_text());execution=plan['execution']
    before_arms=sample['partition']['arms'] if not reference else {'original':sample['partition']['model']}
    arms=plan['partition']['arms'] if not reference else {'original':plan['partition']['model']}
    roles={value['id']:role for role,value in before_arms.items()}
    target_by_language={language:[v for v in plan['cases'] if v['language']==language] for language in test.permutation.LANGUAGES}
    source_by_id={}
    for language in test.permutation.LANGUAGES:
        old_cases=[v for v in sample['cases'] if v['language']==language]
        source_by_id.update({a['id']:b for a,b in zip(old_cases,target_by_language[language])})
    for row in matrix['rows']:
        role=roles[row['model']];arm=arms[role];case=source_by_id[row['id']]
        row.update(case);row.update(model=arm['id'],model_sha256=arm['sha256'],model_kind=test.permutation.ARM_KINDS[role],
            baseline_model_id=arms['original']['id'],baseline_model_sha256=arms['original']['sha256'],
            intervention_id=None if role=='original' else arm['id'],profile_sha256=execution['profile_sha256'],
            runtime_settings_sha256=execution['runtime_settings_sha256'],effective_profile_sha256=execution['runtime_settings_sha256'],
            transcription_runner_sha256=execution['runner_sha256'],whisper_binary_sha256=execution['whisper_binary_sha256'])
        row['artifact_metrics']={'model_file_bytes':arm['model_file_bytes']}
        measurement=row['measurement'];measurement.update(source_sha256=case['source_sha256'],reference_sha256=case['reference_sha256'],
            artifact_metrics=dict(row['artifact_metrics']))
        for native in measurement['engine_passes']:
            native.update(binary_sha256=execution['whisper_binary_sha256'],model_sha256=arm['sha256'])
            native['decoding']['profile_sha256']=execution['runtime_settings_sha256']
    for key in ('runner_sha256','whisper_binary_sha256','corpus_sha256','configuration_sha256'):
        matrix[key]=execution[key]
    if binding:matrix['freeze_sha256']=execution['freeze_sha256']
    if fail:
        row=next(v for v in matrix['rows'] if v['model']==arms['original']['id'] and v['language']=='de' and v['repeat']==1)
        row.update(status='failed',measurement=None)
    # Generate actual planned pair records, then expand pending records to the
    # pinned Swift writer's exact canonical fields before any terminal verifier.
    helper.materialize(plan,matrix)
    rows={(r['id'],r['model'],r['language_mode'],r['repeat']):r for r in matrix['rows']}
    pairs=[]
    for old in matrix['paired_comparisons']:
        row=rows[(old['id'],old['candidate_model'],old['language_mode'],old['repeat'])]
        value=pending(row,arms['original'],old['comparison_id'])
        if old['status']=='paired_exploratory':value.update(old)
        pairs.append(value)
    matrix['paired_comparisons']=pairs
    folder=Path(stage['paths']['matrix_directory']);folder.mkdir()
    for i,row in enumerate(matrix['rows']):
        row['evidence_directory']='cell-'+str(i)
        if row['status']=='failed':failed_evidence(folder,row,i)
    write(stage['paths']['matrix_json'],matrix)
    for source,destination in ((stage['corpus'],'corpus.original.json'),(stage['configuration'],'experiment.original.json')):
        shutil.copyfile(source,folder/destination)
    if binding:shutil.copyfile(stage['paths']['freeze'],folder/'freeze.original.json')
    code=1 if fail else 0
    command=guarded_command[guarded_command.index('--')+1:] if guarded_command else ['synthetic guarded-inference replacement']
    events=[{'event':'starting','command':command,'foreign_cpu_limit':1000,'timeout_seconds':stage['guard_timeout_seconds'],
             'poll_seconds':1,'probe_timeout_seconds':2,'interrupt_grace':8,'terminate_grace':3,'kill_grace':2},
        {'event':'finished','reason':None,'failure':None,'guard_observation':None,'canceled':False,
         'shutdown':{'returncode':code,'cli_reaped':True,'owned_session_present':False,'shutdown_errors':[]}}]
    Path(stage['paths']['guard_receipt']).write_text(''.join(json.dumps(v)+'\n' for v in events))
    return code


def drive(root,family_sha,attestation):
    serial=module('round5_packaged_actual_controller',root/'run-remaining.py')
    class Simulated(serial.Coordinator):
        def note(self,event,**fields):super().note(event,synthetic_model_free_fixture=True,**fields)
        def command(self,argv,stage,action,*,guarded=False,timeout=180):
            if not guarded:return super().command(argv,stage,action,guarded=guarded,timeout=timeout)
            self.check();self.family.verify_step()
            selected=next(s for s in self.family.value['stages'] if s['id']==stage)
            binding=self.heldout_bindings()[stage] if selected['stage']=='held_out' else None
            self.note('command_start',stage=stage,action=action,command=argv)
            code=synthetic_matrix(self.family,selected,binding,fail=stage in {'dev-validation-base','dev-validation-small'},guarded_command=argv)
            self.note('command_finished',stage=stage,action=action,returncode=code)
            self.check();self.family.verify_step();return code
    coordinator=Simulated(root/'pre-inference-family-seal.json',family_sha,sha(root/'run-remaining.py'),attestation)
    result=coordinator.execute()
    if result:raise RuntimeError('Synthetic actual controller stopped with code '+str(result))


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    root=a.output;assert root.is_absolute() and not root.exists();root.mkdir(mode=0o700)
    test=module('round5_orchestration_fixture_factory',R/'test-orchestration.py')
    fixture=test.Fixture(root)
    family=fixture.verified();attestation=family.attestation
    # The real controller's initial veto expects no outcomes. Input files and
    # source hashes are already complete and verified; only synthetic guarded
    # inference is substituted in drive(). All downstream CLIs remain actual.
    drive(root,fixture.sha,attestation)
    events=[json.loads(line) for line in (root/'serial.events.jsonl').read_text().splitlines()]
    finish=events[-1]
    assert finish['event']=='serial_finished' and finish['attempted_cells']==4554 and finish['completed_cells']==4552 and finish['failed_cells']==2
    assert finish['all_native_cells_successful'] is False and 'complete_quality_coverage' not in finish
    assert finish['completed_native_parent_pairs']==2481 and finish['pending_native_parent_pairs']==3
    assert finish['completed_assessor_derived_q4_pairs']==828 and finish['runtime_reference_placeholders']==1242
    assert sum(e['event']=='stage_assessed' for e in events)==15
    receipt={'schema_version':'round5-packaged-model-free-cli-write-smoke-v1','status':'passed',
        'fixture_root':str(root),'synthetic_only':True,'recognition_or_model_initialization_or_quantization_executed':False,
        'actual_unmodified_classifier_reporter_assessor_sealer_cli_executed':True,'classifier_receipt_aliases_created':False,
        'terminal_counts':{k:finish[k] for k in ('attempted_cells','completed_cells','failed_cells','completed_native_parent_pairs',
            'pending_native_parent_pairs','completed_assessor_derived_q4_pairs','runtime_reference_placeholders')},
        'classifier_case_types':['family-original-failed','reference-failed'],'stage_count':15,
        'source_files':{n:sha(R/n) for n in ('run-remaining.py','seal-heldout.py','test-orchestration.py','smoke-packaged-orchestration.py')},
        'journal_sha256':sha(root/'serial.events.jsonl'),'family_sha256':fixture.sha,
        'native_idle_is_synthetic_fixture_only_not_actual_admission':True}
    write(root/'packaged-smoke.receipt.json',receipt)
    print(json.dumps(receipt),flush=True)


if __name__=='__main__':main()
