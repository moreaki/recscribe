#!/usr/bin/env python3
"""Synthetic arithmetic/barrier contracts only; no campaign input opens."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).absolute().parent
SPEC=importlib.util.spec_from_file_location('independent_audit_synthetic_only',ROOT/'audit-final-numeric-gates-v1.py')
A=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(A)
A.FAMILY_SHA='f'*64

def counted_row(errors=2,units=10):
    return {'status':'completed','measurement':{'status':'completed','cer':errors/units,
        'character_errors':errors,'reference_characters':units,'character_insertions':errors,
        'character_deletions':0,'character_substitutions':0,'hypothesis_sha256':'f'*64}}

def native_row(label='de'):
    row=counted_row();row['measurement']['engine_passes']=[{'engine':'whisper.cpp','asr_language':'auto',
        'language_policy':{'effective_argument':'auto','recognizer_language':label}}]
    return row

def fixture():
    family={'schema_version':'mlp-permutation-family-pre-inference-v1','planned_cells':4554,
        'planned_native_parent_pairs':2484,'planned_assessor_derived_q4_pairs':828,'planned_reference_runtime_placeholders':1242,
        'tools':{'assessor':{'path':'/synthetic-only/assessor.py','sha256':'a'*64},'coordinator':{'sha256':'b'*64}},'stages':[]}
    att={'path':'/synthetic-only/idle.json','sha256':'c'*64}
    events=[{'event':'serial_started','family_seal_sha256':A.FAMILY_SHA,'coordinator_sha256':'b'*64,'initial_attestation':att}]
    totals={k:0 for k in A.FIELDS}
    for index,identifier in enumerate(A.IDS):
        phase=('panel','development','held_out')[index//5];adapted=identifier.split('-',1)[1] in A.ADAPTED if index<5 else any(identifier.endswith('-'+x) for x in A.ADAPTED)
        if phase=='panel':cells=216 if adapted else 54;pairs=162 if adapted else 0;sibling=54 if adapted else 0
        elif phase=='development':cells=288 if adapted else 72;pairs=216 if adapted else 0;sibling=72 if adapted else 0
        else:cells=1152 if adapted else 288;pairs=864 if adapted else 0;sibling=288 if adapted else 0
        stage={'id':identifier,'stage':phase,'planned_cells':cells};family['stages'].append(stage)
        if index==10:events.append({'event':'heldout_family_accepted','freeze_sha256':'d'*64,'family_seal_sha256':A.FAMILY_SHA,'initial_attestation':att,'analysis_source':family['tools']['assessor']})
        events.extend([{'event':'command_start','action':'guarded_inference','stage':identifier},
            {'event':'command_finished','action':'guarded_inference','stage':identifier,'returncode':0}])
        row={'event':'stage_assessed','id':identifier,'stage':phase,'analysis_source':family['tools']['assessor'],'default_promotion':False,
            **{k:'e'*64 for k in ('matrix_sha256','report_sha256','assessment_sha256','guard_sha256','plan_sha256')},
            'planned_cells':cells,'attempted_cells':cells,'completed_cells':cells,'failed_cells':0,'planned_native_parent_pairs':pairs,
            'completed_native_parent_pairs':pairs,'pending_native_parent_pairs':0,'planned_assessor_derived_q4_pairs':sibling,
            'completed_assessor_derived_q4_pairs':sibling,'pending_assessor_derived_q4_pairs':0,'runtime_reference_placeholders':cells if not adapted else 0}
        events.append(row)
        for k in totals:totals[k]+=row[k]
    events.append({'event':'serial_finished','family_seal_sha256':A.FAMILY_SHA,'initial_attestation':att,
        'status':'completed','default_promotion':False,**totals})
    return family,events

class Contracts(unittest.TestCase):
    def test_actual_plan_arms_omit_kind(self):
        arms={role:{'id':role,'sha256':'f'*64,'model_file_bytes':10} for role in A.KINDS}
        _,models=A.planned_arm_models({'kind':'family','arms':arms})
        self.assertEqual({key:value[2] for key,value in models.items()},A.KINDS)
        self.assertTrue(all('kind' not in value for value in arms.values()))
        original={'id':'tiny','sha256':'a'*64,'model_file_bytes':100}
        self.assertEqual(A.planned_arm_models({'kind':'reference','model':original})[1]['tiny'],('original',original,'pretrained'))
    def test_counted_weighted_not_utterance_average(self):
        c=A.counted([counted_row(1,2),counted_row(1,10)],'cer')
        self.assertEqual(c['errors'],2);self.assertEqual(c['reference_units'],12)
        self.assertAlmostEqual(c['corpus_weighted_rate'],1/6);self.assertAlmostEqual(c['macro_utterance_rate'],.3)
    def test_missing_never_full_counted_metric(self):
        c=A.assessment_counted([counted_row()],2,'cer')
        self.assertEqual(c['observed_scored_utterances'],1);self.assertEqual(c['observed_errors'],2)
        for k in ('rate','errors','reference_units','insertions','deletions','substitutions'):self.assertIsNone(c[k])
    def test_failed_no_quality_recovery(self):
        c=A.assessment_counted([{'status':'failed','measurement':None}],1,'cer')
        self.assertIsNone(c['rate']);self.assertEqual(c['observed_scored_utterances'],0)
    def test_bad_edit_arithmetic_rejected(self):
        row=counted_row();row['measurement']['character_deletions']=1
        with self.assertRaises(ValueError):A.counted([row],'cer')
    def test_boolean_count_rejected(self):
        row=counted_row();row['measurement']['character_errors']=True
        self.assertEqual(A.counted([row],'cer')['scored_unique_utterances'],0)
    def test_structured_auto_only(self):
        self.assertEqual(A.automatic(native_row()),('de',None))
        for label in ('DE',' und','auto','und','mul','zxx','zh_Hans',''):
            self.assertEqual(A.automatic(native_row(label)),(None,'no_structured_nonempty_speech_label'))
        self.assertEqual(A.automatic(native_row('zh-Hans')),('zh',None))
    def test_raw_detected_label_not_used(self):
        row=native_row(None);row['measurement']['engine_passes'][0]['detected_language']='de'
        self.assertIsNone(A.automatic(row)[0])
        row['measurement']['engine_passes'][0]['language_policy']['recognizer_language']='de'
        row['measurement']['hypothesis_sha256']=A.sha(b'')
        self.assertEqual(A.automatic(row),(None,'exact_empty_hypothesis_hash'))
    def test_ambiguous_multiple_passes_unknown(self):
        row=native_row();row['measurement']['engine_passes']*=2
        self.assertEqual(A.automatic(row),(None,'ambiguous_multiple_engine_passes'))
    def test_thresholds_are_rates_not_percent_units(self):
        self.assertTrue(A.threshold(.10,.10,'min'));self.assertFalse(A.threshold(.099,.10,'min'))
        self.assertTrue(A.threshold(.01,.01,'max'));self.assertFalse(A.threshold(.0101,.01,'max'))
        self.assertTrue(A.threshold(.65,.65,'min'));self.assertIsNone(A.threshold(None,.65,'min'))
    def test_panel_requires_all_three_repeats(self):
        plan={'stage':'panel','repetitions':3,'cases':[{'id':'synthetic'}]}
        v={'required_repeats':[1,2,3],'hypothesis_identity':[{'id':'synthetic','repeat':n,'identical_hypothesis_hash':True} for n in (1,2,3)],
            'identical_required_hypothesis_hashes':True,'observed_different_hypothesis_pairs':0,'unknown_hypothesis_pairs':0,'unknown_hypothesis_cases':0,
            'planned_hypothesis_pairs':3,'auto_label_identity':[],'identical_required_auto_labels':'not_applicable_explicit_mode',
            'planned_auto_label_pairs':0,'status':'observed_match_no_promotion'}
        self.assertEqual(A.float_control(v,plan,'known'),(True,True))
        v['hypothesis_identity'][2]['identical_hypothesis_hash']=False;v.update(identical_required_hypothesis_hashes=None,observed_different_hypothesis_pairs=1,status='inconclusive_no_promotion')
        self.assertEqual(A.float_control(v,plan,'known'),(False,True));self.assertIsNone(v['identical_required_hypothesis_hashes'])
        v['hypothesis_identity']=v['hypothesis_identity'][:1]
        with self.assertRaises(ValueError):A.float_control(v,plan,'known')
    def test_terminal_complete_barrier(self):
        f,e=fixture();self.assertEqual(A.barrier(f,e)[2]['attempted_cells'],4554)
    def test_incomplete_and_early_finish_rejected(self):
        f,e=fixture()
        with self.assertRaises(ValueError):A.barrier(f,e[:-1])
        e.insert(1,e.pop())
        with self.assertRaises(ValueError):A.barrier(f,e)
    def test_crossstage_launch_before_prior_assessment_rejected(self):
        f,e=fixture();first=next(i for i,x in enumerate(e) if x.get('event')=='stage_assessed');next_launch=e.pop(first+1);e.insert(first,next_launch)
        with self.assertRaises(ValueError):A.barrier(f,e)
    def test_missing_digest_rejected(self):
        f,e=fixture();next(x for x in e if x.get('event')=='stage_assessed')['matrix_sha256']=None
        with self.assertRaises(ValueError):A.barrier(f,e)
    def test_bool_count_rejected(self):
        f,e=fixture();e[-1]['failed_cells']=False
        with self.assertRaises(ValueError):A.barrier(f,e)
    def test_release_before_all10_rejected(self):
        f,e=fixture();accept=e.pop(next(i for i,x in enumerate(e) if x.get('event')=='heldout_family_accepted'));e.insert(1,accept)
        with self.assertRaises(ValueError):A.barrier(f,e)
    def test_pooled_distribution_uses_native_observations(self):
        self.assertEqual(A.dist([1,2,3,100]),{'measured_count':4,'median':2.5,'minimum':1.,'maximum':100.})
    def test_metadata_decoder_duplicate_nonfinite_rejected(self):
        for data in (b'{"x":1,"x":2}',b'{"x":NaN}',b'{"x":1e999}'):
            with self.assertRaises(ValueError):A.decode(data)

if __name__=='__main__':unittest.main()
