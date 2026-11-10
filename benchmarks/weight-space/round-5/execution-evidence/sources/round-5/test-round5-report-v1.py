"""Synthetic final-barrier/count/null/resource contracts; no campaign reads."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

R=Path(__file__).resolve().parent
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,R/file);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
S=module('round5_summary_test','summarize-round5-v1.py')
P=module('round5_projection_test','project-round5-report-v1.py')
def sha(x):return hashlib.sha256(x.encode()).hexdigest()

def family_events():
    tools={'coordinator':{'path':'/synthetic/controller.py','sha256':sha('controller')},
           'assessor':{'path':'/synthetic/assessor.py','sha256':sha('assessor')}}
    att={'path':'/synthetic/idle.json','sha256':sha('idle')}
    f={'schema_version':'mlp-permutation-family-pre-inference-v1','planned_cells':4554,'planned_native_parent_pairs':2484,
       'planned_assessor_derived_q4_pairs':828,'planned_reference_runtime_placeholders':1242,'tools':tools,'stages':[]}
    e=[{'event':'serial_started','family_seal_sha256':S.FAMILY,'coordinator_sha256':tools['coordinator']['sha256'],'initial_attestation':att}]
    totals={k:0 for k in S.FIELDS}
    for phase,prefix,n,modes,repeats in [('panel','panel',9,['known','auto'],3),('development','dev-validation',72,['known'],1),('held_out','heldout',144,['known','auto'],1)]:
        for model in S.MODELS:
            adapted=model in S.ADAPTED;units=n*len(modes)*repeats
            st={'id':prefix+'-'+model,'stage':phase,'planned_cells':units*(4 if adapted else 1),
                'planned_native_parent_pairs':units*3 if adapted else 0,'planned_assessor_derived_q4_pairs':units if adapted else 0}
            if len(f['stages'])==10:
                e.append({'event':'heldout_family_accepted','family_seal_sha256':S.FAMILY,'initial_attestation':att,
                          'analysis_source':tools['assessor'],'freeze_sha256':sha('held')})
            f['stages'].append(st)
            e += [{'event':'command_start','stage':st['id'],'action':'guarded_inference'},
                  {'event':'command_finished','stage':st['id'],'action':'guarded_inference','returncode':0}]
            counts={'planned_cells':st['planned_cells'],'attempted_cells':st['planned_cells'],'completed_cells':st['planned_cells'],'failed_cells':0,
                    'planned_native_parent_pairs':st['planned_native_parent_pairs'],'completed_native_parent_pairs':st['planned_native_parent_pairs'],'pending_native_parent_pairs':0,
                    'planned_assessor_derived_q4_pairs':st['planned_assessor_derived_q4_pairs'],'completed_assessor_derived_q4_pairs':st['planned_assessor_derived_q4_pairs'],
                    'pending_assessor_derived_q4_pairs':0,'runtime_reference_placeholders':0 if adapted else units}
            event={'event':'stage_assessed','id':st['id'],'stage':phase,'analysis_source':tools['assessor'],'default_promotion':False,**counts,
                   **{key:sha(st['id']+key) for key in ['matrix_sha256','report_sha256','assessment_sha256','guard_sha256','plan_sha256']}}
            e.append(event)
            for key in totals:totals[key]+=counts[key]
    e.append({'event':'serial_finished','family_seal_sha256':S.FAMILY,'initial_attestation':att,'status':'completed','default_promotion':False,**totals})
    return f,e

def summary_fixture():
    models=[{'id':name,'kind':kind,'sha256':sha(name),'model_file_bytes':1000 if kind in {'pretrained','conversion_control'} else 350} for name,kind in P.MODEL_KINDS.items()]
    stages=[]
    for phase,prefix,planned,modes,repeats in [('panel','panel',1,['known','auto'],3),('development','dev-validation',8,['known'],1),('held_out','heldout',16,['known','auto'],1)]:
        for family in S.MODELS:
            selected=[m for m in models if m['id']==family or family in S.ADAPTED and m['id'].startswith(family+'-')]
            observations=[]
            for model in selected:
                cohorts=[]
                for mode in modes:
                    for language in S.LANGUAGES:
                        metric={'scored_unique_utterances':planned,'errors':planned,'reference_units':100*planned,'corpus_weighted_rate':.01,
                                'insertions':0,'deletions':0,'substitutions':planned}
                        dist=lambda count,value:{'measured_count':count,'minimum':value,'median':value,'maximum':value}
                        load={**dist(planned*repeats,.1),'native_invocations_recorded':planned*repeats,'parser_versions':['synthetic']}
                        cohorts.append({'model':model['id'],'model_kind':model['kind'],'model_sha256':model['sha256'],'language_mode':mode,'language':language,
                            'task':'standard_rendering' if language=='de-CH' else 'transcription',
                            'quality':{'planned_unique_utterances':planned,'completed_unique_utterances':planned,'cer':copy.deepcopy(metric),'wer':copy.deepcopy(metric)},
                            'timing':{'completed_cells':planned*repeats,'wall_seconds_per_utterance_invocation':dist(planned*repeats,1.),
                                      'complete_workload_real_time_factor':dist(repeats,.5),'model_load_seconds_per_native_invocation':load},
                            'peak_process_rss_bytes':dist(planned*repeats,1048576.),'artifact_metrics':{'model_file_bytes':model['model_file_bytes']}})
                observations.append(S.model_observations(cohorts,model,modes,planned))
            cells=planned*9*len(modes)*repeats*len(selected)
            stages.append({'id':prefix+'-'+family,'stage':phase,'status':'COMPLETE_TERMINAL_ATTEMPT_EVIDENCE','planned_cells':cells,'attempted_cells':cells,
                           'completed_cells':cells,'failed_cells':0,'artifact_observations':observations})
    return {'schema_version':S.VERSION,'summary_source_sha256':P.FORMATTER,'frozen_family_seal_sha256':S.FAMILY,'admission_sha256':S.ADMISSION,
            'terminal_plan_complete':True,'integrity_failures':[],'default_promotion':False,'resource_acceptance':'UNCONTROLLED / NOT EVALUATED',
            'native_review':'PENDING','product_acceptance':'PENDING','preservation':{'raw_reference_audio_model_paths_followed':False},
            'complete_quality_coverage':True,'artifacts':models,'stages':stages,
            'coverage':{'planned_cells':4554,'attempted_cells':4554,'completed_cells':4554,'failed_cells':0},'status':'SYNTHETIC','family_conclusions':[]}

class ReportContracts(unittest.TestCase):
    def test_all15_counts_and_release_barrier(self):
        f,e=family_events();stages,accepted,total=S.barrier(f,e)
        self.assertEqual(len(stages),15);self.assertEqual(total['attempted_cells'],4554)
        self.assertEqual(total['planned_native_parent_pairs'],2484);self.assertEqual(total['planned_assessor_derived_q4_pairs'],828)
        self.assertEqual(total['runtime_reference_placeholders'],1242)
    def test_incomplete_stop_duplicate_retry_and_early_held_release_fail_before_any_outcome_read(self):
        class Forbidden:
            def __getattr__(self,name):raise AssertionError('Outcome read attempted: '+name)
        f,e=family_events()
        cases=[e[:-1],e+[e[-1]],e[:4]+[e[1]]+e[4:]]
        early=copy.deepcopy(e);release=next(x for x in early if x['event']=='heldout_family_accepted');early.remove(release);early.insert(1,release);cases.append(early)
        overlap=copy.deepcopy(e);first=next(x for x in overlap if x.get('event')=='stage_assessed')
        overlap.remove(first);next_launch=next(i for i,x in enumerate(overlap) if x.get('event')=='command_start' and x.get('stage')=='panel-base')
        overlap.insert(next_launch+1,first);cases.append(overlap)
        stopped=copy.deepcopy(e);stopped[-1]['event']='serial_stopped';cases.append(stopped)
        bad=copy.deepcopy(e);bad[-1]['attempted_cells']=True;cases.append(bad)
        for events in cases:
            with self.subTest(events=len(events)),self.assertRaises(ValueError):S.build(Forbidden(),f,events,None,None)
    def test_failed_counts_require_pending_and_natural1_not_false(self):
        f,e=family_events();bad=copy.deepcopy(e);bad[2]['returncode']=False
        with self.assertRaises(ValueError):S.barrier(f,bad)
        bad=copy.deepcopy(e);row=next(x for x in bad if x.get('event')=='stage_assessed' and x['id']=='panel-small')
        row['failed_cells']=1;row['completed_cells']-=1
        with self.assertRaises(ValueError):S.barrier(f,bad)
    def test_no_raw_path_extension_can_be_opened(self):
        reader=S.Reader()
        for name in ['reference.txt','audio.wav','model.bin','native.log']:
            with self.assertRaises(ValueError):reader.raw(Path('/synthetic')/name)
    def test_exact495_cohorts55_macros9cer8wer_and_load_scope(self):
        value=summary_fixture();quality,resources,macros,cohorts=P.project(value)
        self.assertEqual((len(quality),len(resources),len(macros),len(cohorts)),(495,495,55,495))
        self.assertTrue(all(x['cer_planned_languages']==9 and x['wer_planned_languages']==8 for x in macros))
        chinese=next(x for x in quality if x['language']=='zh');self.assertIsNone(chinese['wer_full_rate'])
        self.assertEqual(resources[0]['model_load_seconds_median'],.1);self.assertIn('not full initialization',resources[0]['model_load_scope'])
    def test_null_counted_quality_does_not_become_complete_from_zero_failed_cells(self):
        value=summary_fixture();stage=value['stages'][7];model=stage['artifact_observations'][0];mode=model['modes'][0]
        row=next(x for x in mode['per_language'] if x['language']=='de');metric=row['counted_metric_coverage']['cer']
        metric.update(scored_unique_sources=7,coverage_complete=False,observed_errors=7,observed_reference_units=700,observed_rate=.01,full_planned_rate=None)
        row['quality']['cer'].update(scored_unique_utterances=7,errors=7,reference_units=700,substitutions=7)
        mode.update(macro_cer=None,macro_cer_complete_languages=8)
        with self.assertRaisesRegex(ValueError,'completeness'):P.project(value)
        value['complete_quality_coverage']=False
        quality,_,macros,_=P.project(value)
        projected=next(x for x in quality if x['stage']==stage['id'] and x['model']==model['id'] and x['language']=='de')
        self.assertIsNone(projected['cer_full_rate']);self.assertEqual(projected['cer_scored'],7)
    def test_count_rate_resource_identity_and_macro_corruptions_fail(self):
        base=summary_fixture()
        for change in ['rate','macro','resource','identity']:
            value=copy.deepcopy(base);mode=value['stages'][0]['artifact_observations'][0]['modes'][0];row=mode['per_language'][0]
            if change=='rate':row['counted_metric_coverage']['cer']['observed_rate']=0
            if change=='macro':mode['macro_cer']=0
            if change=='resource':row['timing']['wall_seconds_per_utterance_invocation']['median']=-1
            if change=='identity':value['stages'][0]['artifact_observations'][0]['sha256']=sha('wrong')
            with self.subTest(change=change),self.assertRaises(ValueError):P.project(value)
    def test_later_panel_repeat_failure_does_not_erase_complete_repeat_one_quality(self):
        value=summary_fixture();stage=value['stages'][0];row=stage['artifact_observations'][0]['modes'][0]['per_language'][0]
        stage['completed_cells']-=1;stage['failed_cells']=1
        value['coverage']['completed_cells']-=1;value['coverage']['failed_cells']=1
        row['timing']['completed_cells']-=1
        for d in [row['timing']['wall_seconds_per_utterance_invocation'],row['timing']['complete_workload_real_time_factor'],
                  row['timing']['model_load_seconds_per_native_invocation'],row['peak_process_rss_bytes']]:d['measured_count']-=1
        row['timing']['model_load_seconds_per_native_invocation']['native_invocations_recorded']-=1
        quality,resources,macros,_=P.project(value)
        self.assertTrue(value['complete_quality_coverage'])
        self.assertTrue(all(x['cer_full_rate'] is not None for x in quality))
        self.assertEqual(len(macros),55)
    def test_single_repeat_is_not_determinism_and_missing_is_not_stable(self):
        one={'utterance_repeats':[{'requested_repeats':1,'completed_repeats':1,'distinct_hypothesis_hashes':1,'transcript_variation':False}]}
        self.assertEqual(S.repeat_stability(one,1)['single_repeat_observed'],1)
        one['utterance_repeats'][0]['completed_repeats']=0
        self.assertEqual(S.repeat_stability(one,1)['unknown'],1)

if __name__=='__main__':unittest.main()
