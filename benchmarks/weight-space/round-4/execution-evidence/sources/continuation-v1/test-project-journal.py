#!/usr/bin/env python3
"""Synthetic raw-chain contracts. No actual campaign journals are opened."""
import copy,importlib.util,unittest
from pathlib import Path
HERE=Path(__file__).absolute().parent
def module(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
P=module('synthetic_continuation_projector',HERE/'project-journal.py')
T=module('synthetic_original_fixture',HERE.parent/'test-final-numeric-audit-v1.py')
def fixture():
    _,full=T.fixture();full=copy.deepcopy(full)
    for e in full:e['created_utc']='2026-01-01T00:00:00+00:00'
    base_index=next(i for i,e in enumerate(full) if e.get('event')=='stage_assessed' and e.get('id')==P.IDS[6])
    base=full[base_index];base['completed_cells']=71;base['failed_cells']=1
    full[base_index-1]['returncode']=1
    sources={k:{'path':str(P.R/('continuation-v1/project-journal.py' if k=='journal_projector' else k+'.py')),'sha256':('b' if k=='original_coordinator' else 'a')*64}
        for k in ('original_coordinator','sealer','classifier','guard','controller','journal_projector')}
    old=copy.deepcopy(full[:base_index])
    wrong={'event':'command_start','stage':P.IDS[6],'action':'classify_finite_native_output_failure','command':['/synthetic/python',sources['classifier']['path'],'--matrix',str(P.R/P.IDS[6]/'matrix/matrix.json'),'--output',str(P.R/P.IDS[6]/'natural-failures.json'),'--expected-source-sha256',sources['classifier']['sha256']]}
    stop={'created_utc':'2026-01-01T00:00:01+00:00','event':'serial_stopped','error_type':'ValueError','error':'dev-validation-base/classify_finite_native_output_failure failed; later inference not started','default_promotion':False}
    old.extend([wrong,{'event':'command_finished','stage':P.IDS[6],'action':'classify_finite_native_output_failure','returncode':1},stop])
    oldpin=P.descriptor(P.R/'serial.events.jsonl',P.ORIGINAL);newpin=P.descriptor(P.R/'serial-continuation-v1.events.jsonl','f'*64);cappin=P.descriptor(P.R/'continuation.freeze.v1.json','d'*64)
    retained=[]
    before=[e for e in full if e.get('event')=='stage_assessed'][:7]
    for i,e in enumerate(before):
        retained.append({'id':e['id'],'matrix':P.descriptor(P.R/e['id']/'matrix/matrix.json',e['matrix_sha256']),
            'guard':P.descriptor(P.R/e['id']/'matrix.guard.jsonl',e['guard_sha256']),
            'report':P.descriptor(P.R/e['id']/'report-v1.1/report.json',e['report_sha256']) if i<6 else None,
            'assessment':P.descriptor(P.R/e['id']/'assessment-v1/assessment.json',e['assessment_sha256']) if i<6 else None})
    cap={'schema_version':'round4-metadata-filename-continuation-v1','original_family':{'sha256':P.FAMILY},'original_admission':{'sha256':P.ADMISSION},
        'allow_inference_retries':False,'model_settings_changed':False,'scorer_changed':False,'quality_gates_changed':False,
        'original_journal':oldpin,'initial_attestation':old[0]['initial_attestation'],'sources':sources,'retained_stages':retained,
        'base_stop_proof':P.descriptor(P.R/'synthetic-stop-proof.json','a'*64),'base_classification':P.descriptor(P.R/P.IDS[6]/'natural-failures.attempted-v2.json','c'*64),
        'reused_attempted_cells':738,'reused_completed_cells':737,'reused_failed_cells':1,'remaining_inference_cells':3816,
        'planned_cells':4554,'planned_native_parent_pairs':2484,'planned_assessor_derived_q4_pairs':828,'planned_reference_runtime_placeholders':1242}
    start={'event':'continuation_started','continuation_capsule_sha256':cappin['sha256'],'original_family_seal_sha256':P.FAMILY,'original_journal':oldpin,
        'original_admission':cap['original_admission'],'initial_attestation':cap['initial_attestation'],'controller_sha256':sources['controller']['sha256'],'default_promotion':False,
        **{k:cap[k] for k in ('reused_attempted_cells','reused_completed_cells','reused_failed_cells','remaining_inference_cells')}}
    new=[start]
    for e in before:new.append({**copy.deepcopy(e),'event':'retained_stage_revalidated'})
    new.append({'event':'classifier_receipt_alias_created','stage':P.IDS[6],'versioned_receipt':cap['base_classification'],
        'canonical_receipt':P.descriptor(P.R/P.IDS[6]/'natural-failures.json','c'*64),'byte_identical':True,'classification_source':sources['classifier']})
    new.extend(copy.deepcopy(full[base_index:-1]));finish=copy.deepcopy(full[-1]);finish.update(event='continuation_finished',status='completed_with_failures',
        continuation_capsule_sha256=cappin['sha256'],original_journal=oldpin,original_admission=cap['original_admission'],initial_attestation=cap['initial_attestation'],
        completed_cells=4553,failed_cells=1,observed_rows=4554)
    new.append(finish)
    return cap,old,new,cappin,oldpin,newpin,sources['journal_projector']

class Contracts(unittest.TestCase):
    def test_preserves_stop_and_exact_attempts(self):
        args=fixture();unchanged=copy.deepcopy(args);events,proof=P.project(*args)
        self.assertEqual(args,unchanged);self.assertEqual(proof['coverage']['attempted_cells'],4554)
        self.assertEqual(proof['coverage']['failed_cells'],1);self.assertEqual(sum(e.get('event')=='verified_prior_serial_stop' for e in events),1)
        self.assertEqual(events[-1]['logical_projection']['actual_stop_retained_as'],'verified_prior_serial_stop')
        self.assertEqual(len([e for e in events if e.get('event')=='command_start' and e.get('action')=='guarded_inference']),15)
    def test_no_base_retry(self):
        args=list(fixture());args[2].insert(1,{'event':'command_start','action':'guarded_inference','stage':P.IDS[6]})
        with self.assertRaises(ValueError):P.project(*args)
    def test_unknown_stop_veto(self):
        args=list(fixture());args[1][-1]['error']='capture canceled'
        with self.assertRaises(ValueError):P.project(*args)
    def test_no_failed_cell_recovery(self):
        args=list(fixture());next(e for e in args[2] if e.get('event')=='stage_assessed')['completed_cells']=72
        with self.assertRaises(ValueError):P.project(*args)
    def test_alias_not_byte_identical_veto(self):
        args=list(fixture());next(e for e in args[2] if e.get('event')=='classifier_receipt_alias_created')['byte_identical']=False
        with self.assertRaises(ValueError):P.project(*args)
    def test_missing_retained_stage_veto(self):
        args=list(fixture());args[0]['retained_stages'].pop()
        with self.assertRaises(ValueError):P.project(*args)
    def test_missing_final_barrier_veto(self):
        args=list(fixture());args[2].pop()
        with self.assertRaises(ValueError):P.project(*args)
    def test_early_held_release_veto(self):
        args=list(fixture());new=args[2];e=new.pop(next(i for i,e in enumerate(new) if e.get('event')=='heldout_family_accepted'));new.insert(1,e)
        with self.assertRaises(ValueError):P.project(*args)
    def test_first_raw_bytes_are_not_rewritten(self):
        cap,old,new,*pins=fixture();e,proof=P.project(cap,old,new,*pins)
        self.assertEqual(e[:len(old)-1],old[:-1]);self.assertEqual(e[len(old)]['event'],'continuation_started')
    def test_boolean_counts_rejected(self):
        args=list(fixture());args[0]['reused_failed_cells']=True
        with self.assertRaises(ValueError):P.project(*args)
    def test_optional_descriptor_bytes_compatible(self):
        args=list(fixture());args[0]['original_journal']={**args[0]['original_journal'],'bytes':123}
        args[0]['base_classification']={**args[0]['base_classification'],'bytes':321}
        self.assertEqual(P.project(*args)[1]['coverage']['attempted_cells'],4554)
    def test_missing_base_alias_rejected(self):
        args=list(fixture());alias=next(e for e in args[2] if e.get('event')=='classifier_receipt_alias_created');alias.update(stage=P.IDS[7],versioned_receipt=P.descriptor(P.R/P.IDS[7]/'natural-failures.attempted-v2.json','c'*64),canonical_receipt=P.descriptor(P.R/P.IDS[7]/'natural-failures.json','c'*64))
        with self.assertRaises(ValueError):P.project(*args)
    def test_observed_rows_bool_rejected(self):
        args=list(fixture());args[2][-1]['observed_rows']=True
        with self.assertRaises(ValueError):P.project(*args)
if __name__=='__main__':unittest.main()
