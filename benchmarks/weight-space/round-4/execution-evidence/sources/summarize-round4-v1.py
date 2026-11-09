#!/usr/bin/env python3
"""Final-only retained numeric summary; never follow audio/ref/model/raw paths.

The complete 15-stage journal barrier is checked before any stage outcome opens.
Only declared JSON/JSONL metadata and pinned Python analysis source are read.
Frozen scorer, decisions and missing values remain unchanged. No inference,
rescoring, selective retry, new performance gate or default promotion occurs.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import signal
import stat
import sys
import time

R = Path(__file__).resolve().parent
VERSION = 'round4-retained-numeric-summary-v1'
FAMILY = '8058f9785929639d70da620fd6f12841b3078aa17352f6d02b542b6a7f191fe2'
ADMISSION = '1e9d6a0dbea1fd9f9df2ece06a9044e24eb4f2b37c259500cca87545e9d29153'
LANGUAGES = ('de-CH','de','fr','it','en','ar','zh','es','pt')
MODELS = ('tiny','base','small','large-v3-turbo','large-v3')
ADAPTED = {'small','large-v3-turbo'}
ROLES = ('original','rotated_f16','plain_q4','rotated_q4')
FIELDS = ('planned_cells','attempted_cells','completed_cells','failed_cells','planned_native_parent_pairs',
          'completed_native_parent_pairs','pending_native_parent_pairs','planned_assessor_derived_q4_pairs',
          'completed_assessor_derived_q4_pairs','pending_assessor_derived_q4_pairs','runtime_reference_placeholders')
MAX_JSON, MAX_SMALL, MAX_TOTAL = 64*1024**2, 4*1024**2, 512*1024**2

def require(ok, message):
    if not ok: raise ValueError(message)

def valid_sha(value): return isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None
def integer(value): return type(value) is int and value >= 0
def canonical(value): return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()

class Reader:
    def __init__(self, seconds=180):
        self.deadline=time.monotonic()+seconds; self.stopped=False; self.ledger={}
    def check(self):
        if self.stopped or (R/'cancel-summary.request').exists(): raise InterruptedError('Metadata summary canceled')
        if time.monotonic()>=self.deadline: raise TimeoutError('Metadata-only summary exceeded finite bound')
    def raw(self,path,expected=None,maximum=MAX_JSON):
        self.check(); path=Path(path)
        require(path.is_absolute() and '..' not in path.parts and path.suffix in {'.json','.jsonl','.py'}
                and not any(p.is_symlink() for p in (path,*path.parents)), 'Only explicit nonsymlink metadata/source paths may open')
        before=path.stat(); identity=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
        require(stat.S_ISREG(before.st_mode) and before.st_size<=maximum, 'Metadata/source exceeds bound')
        require(sum(x['bytes'] for k,x in self.ledger.items() if k!=str(path))+before.st_size<=MAX_TOTAL,'Metadata exceeds512MiB')
        with path.open('rb') as f: data=f.read(maximum+1)
        digest=hashlib.sha256(data).hexdigest()
        require(len(data)<=maximum and identity(path.stat())==identity(before)
                and (expected is None or valid_sha(expected) and digest==expected),'Metadata/source identity or SHA differs')
        self.ledger[str(path)]={'sha256':digest,'bytes':len(data)};self.check();return data,digest
    def read(self,path,expected=None,maximum=MAX_JSON):
        raw,digest=self.raw(path,expected,maximum);value=decode(raw)
        require(isinstance(value,dict),'Object metadata required');return value,digest
    def jsonl(self,path,expected=None):
        raw,digest=self.raw(path,expected,MAX_SMALL);values=[decode(x) for x in raw.splitlines() if x.strip()]
        require(all(isinstance(x,dict) for x in values),'Object event metadata required');return values,digest

def decode(raw):
    def fields(items):
        out={}
        for k,v in items: require(k not in out,'Duplicate JSON key');out[k]=v
        return out
    def number(value):
        out=float(value);require(math.isfinite(out),'Nonfinite JSON');return out
    return json.loads(raw,object_pairs_hook=fields,parse_float=number,
        parse_constant=lambda _:(_ for _ in ()).throw(ValueError('Nonfinite JSON')))

def source_module(reader,descriptor,name):
    path=Path(descriptor['path']);reader.raw(path,descriptor['sha256'],MAX_SMALL)
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec)
    sys.modules[name]=module;spec.loader.exec_module(module);return module

def barrier(family,events):
    """Pure chronology/count barrier; callers must invoke before outcome reads."""
    stages=family.get('stages',[])
    expected=[prefix+'-'+model for prefix in ('panel','dev-validation','heldout') for model in MODELS]
    require(family.get('schema_version')=='attention-rotation-family-pre-inference-v1'
        and len(stages)==15 and [s.get('id') for s in stages]==expected,'Exact15 frozen stages required')
    require((family.get('planned_cells'),family.get('planned_native_parent_pairs'),family.get('planned_assessor_derived_q4_pairs'),
             family.get('planned_reference_runtime_placeholders'))==(4554,2484,828,1242),'Frozen grid differs')
    require(events and events[0].get('event')=='serial_started' and events[-1].get('event')=='serial_finished'
        and sum(x.get('event')=='serial_started' for x in events)==1
        and sum(x.get('event')=='serial_finished' for x in events)==1
        and not any(x.get('event') in {'serial_stopped','owned_guard_cleanup_pending'} for x in events),
        'All4,554 terminal attempts must finish before any stage outcome is read')
    start,finish=events[0],events[-1]
    require(start.get('family_seal_sha256')==finish.get('family_seal_sha256')==FAMILY
        and start.get('coordinator_sha256')==family['tools']['coordinator']['sha256']
        and start.get('initial_attestation')==finish.get('initial_attestation')
        and isinstance(start.get('initial_attestation'),dict),'Journal source/attestation identity differs')
    assessed=[x for x in events if x.get('event')=='stage_assessed']
    launches=[x for x in events if x.get('event')=='command_start' and x.get('action')=='guarded_inference']
    ended=[x for x in events if x.get('event')=='command_finished' and x.get('action')=='guarded_inference']
    require([x.get('id') for x in assessed]==expected and [x.get('stage') for x in launches]==expected
        and [x.get('stage') for x in ended]==expected,'Every exact stage must launch/finish/assess once in order; no retry')
    for stage,event,launch,end in zip(stages,assessed,launches,ended):
        require(events.index(launch)<events.index(end)<events.index(event)
            and type(end.get('returncode')) is int and end['returncode'] in {0,1}
            and event.get('stage')==stage['stage'] and event.get('analysis_source')==family['tools']['assessor']
            and event.get('default_promotion') is False,'Stage chronology/source differs')
        require(all(valid_sha(event.get(k)) for k in ('matrix_sha256','report_sha256','assessment_sha256','guard_sha256','plan_sha256')),
                'Final stage evidence hash missing')
        require(all(integer(event.get(k)) for k in FIELDS)
            and event['attempted_cells']==event['planned_cells']==stage['planned_cells']
            and event['completed_cells']+event['failed_cells']==event['attempted_cells']
            and event['planned_native_parent_pairs']==stage['planned_native_parent_pairs']
            and event['completed_native_parent_pairs']+event['pending_native_parent_pairs']==event['planned_native_parent_pairs']
            and event['planned_assessor_derived_q4_pairs']==stage['planned_assessor_derived_q4_pairs']
            and event['completed_assessor_derived_q4_pairs']+event['pending_assessor_derived_q4_pairs']==event['planned_assessor_derived_q4_pairs']
            and end['returncode']==(1 if event['failed_cells'] else 0),'Terminal attempts/successes/failures differ')
    require(all(events.index(assessed[i])<events.index(launches[i+1]) for i in range(14)),
            'Each stage must be assessed before the next guarded launch; overlapping phases are forbidden')
    accepts=[x for x in events if x.get('event')=='heldout_family_accepted']
    require(len(accepts)==1,'One all-five held-out release required');accept=accepts[0]
    position=events.index(accept)
    require(sum(x.get('event')=='stage_assessed' for x in events[:position])==10
        and position<events.index(launches[10]) and valid_sha(accept.get('freeze_sha256'))
        and accept.get('family_seal_sha256')==FAMILY and accept.get('initial_attestation')==start['initial_attestation']
        and accept.get('analysis_source')==family['tools']['assessor'],'All10→all5 held-out release chronology differs')
    totals={k:sum(x[k] for x in assessed) for k in FIELDS}
    require(all(integer(finish.get(k)) and finish[k]==v for k,v in totals.items())
        and totals['attempted_cells']==4554 and totals['planned_native_parent_pairs']==2484
        and totals['completed_native_parent_pairs']+totals['pending_native_parent_pairs']==2484
        and totals['planned_assessor_derived_q4_pairs']==828
        and totals['completed_assessor_derived_q4_pairs']+totals['pending_assessor_derived_q4_pairs']==828
        and totals['runtime_reference_placeholders']==1242
        and finish.get('status')==('completed_with_failures' if totals['failed_cells'] else 'completed')
        and finish.get('default_promotion') is False,'Final exact coverage counters differ')
    return assessed,accept,totals

def admission(reader,path,digest,events):
    value,_=reader.read(path,digest,MAX_SMALL)
    require(digest==ADMISSION and value.get('frozen_inputs',{}) and value.get('unchanged_initial_family_seal') is True
        and value.get('candidates_or_settings_changed') is False and value.get('preflight_added_quality_cells')==0
        and value.get('default_promotion') is False,'Explicit launch admission capsule required')
    att=events[0]['initial_attestation'];observation,_=reader.read(att['path'],att['sha256'],MAX_SMALL)
    require(observation.get('recording_active') is False and observation.get('live_transcription_active') is False
        and observation.get('inspection_method')=='native-ui','Separate native idle/live-off observation required')
    pins=value['frozen_inputs']
    require(any(x.get('path')==att['path'] and x.get('sha256')==att['sha256'] for x in pins.values())
        and any(x.get('sha256')==FAMILY for x in pins.values()),'Admission capsule lost family/idle attestation pins')
    load=value['native_load_receipt'];receipt,_=reader.read(load['path'],load['sha256'],MAX_SMALL)
    require(receipt.get('status')=='passed' and receipt.get('verified_derived_artifacts')==6
        and receipt.get('recognition_performed') is False and receipt.get('quality_inference_grid_cells_added')==0,
        'Native load preflight is not a quality-grid result')
    guard=value['native_load_guard'];guards,_=reader.jsonl(guard['path'],guard['sha256']);end=guards[-1]
    require(end.get('event')=='finished' and end.get('canceled') is False and end.get('reason') is None
        and end.get('failure') is None and end.get('shutdown')=={'returncode':0,'cli_reaped':True,'owned_session_present':False,'shutdown_errors':[]},
        'Admission preflight guard did not close cleanly')
    return {'path':str(path),'sha256':digest,'initial_attestation':att,
            'native_load_receipt':value.get('native_load_receipt'),'native_load_guard':value.get('native_load_guard'),
            'independent_static_audit':value.get('independent_static_audit')}

def held_bundle(reader,family,events,accept):
    value,_=reader.read(R/'heldout-family.freeze.json',accept['freeze_sha256'],MAX_SMALL)
    require(value.get('schema_version')=='attention-rotation-heldout-family-freeze-v1'
        and value.get('original_family_seal_sha256')==FAMILY and value.get('initial_attestation')==events[0]['initial_attestation']
        and value.get('analysis_source')==family['tools']['assessor'] and value.get('budgets')==family['budgets']
        and value.get('rotation')==family['rotation'] and value.get('quantization')==family['quantization']
        and value.get('fresh_heldout_reference_content_inspected') is False
        and value.get('heldout_outcomes_used_for_selection') is False and value.get('default_promotion') is False,
        'Held-out freeze policy/source differs')
    parts=value.get('partitions',[])
    require(len(parts)==5 and [x.get('id') for x in parts]==[s['id'] for s in family['stages'][10:]]
        and accept.get('partitions')==parts,'All-five held-out descriptors differ')
    history=value.get('development_history',[]);prior=[x for x in events if x.get('event')=='stage_assessed'][:10]
    require(len(history)==10 and all(all(e.get(k)==v for k,v in h.items()) for h,e in zip(history,prior)),
            'Held-out freeze lost exact preceding terminal history')
    expected=[{k:s[k] for k in ('id','corpus_sha256','configuration_sha256','assessment_pre_freeze_plan_sha256','models')} for s in family['stages'][10:]]
    require(value.get('all_heldout_partitions')==expected,'Held-out source/preplan family differs')
    return {x['id']:x for x in parts},value

def final_plan(reader,family,stage,preplan,binding,held):
    folder=R/stage['id'];freeze,_=reader.read(folder/'freeze.json',binding['freeze_sha256'],MAX_SMALL)
    final,digest=reader.read(folder/'assessment-plan.final.json',binding['final_plan_sha256'],MAX_SMALL)
    require(all(binding.get(k)==stage[k] for k in ('corpus_sha256','configuration_sha256'))
        and binding.get('pre_freeze_plan_sha256')==stage['assessment_pre_freeze_plan_sha256']
        and freeze.get('original_family_seal_sha256')==FAMILY and freeze.get('frozen_before_held_out') is True
        and freeze.get('initial_attestation')==held['initial_attestation'] and freeze.get('analysis_source')==family['tools']['assessor']
        and freeze.get('all_heldout_partitions')==held['all_heldout_partitions']
        and freeze.get('budgets')==family['budgets'] and freeze.get('rotation')==family['rotation']
        and freeze.get('quantization')==family['quantization'],'Held-out partition freeze differs')
    require(final.get('pre_freeze_family_seal_sha256')==FAMILY
        and final.get('pre_freeze_plan_sha256')==stage['assessment_pre_freeze_plan_sha256']
        and final.get('execution',{}).get('freeze_sha256')==binding['freeze_sha256'],'Final-plan links differ')
    stripped=json.loads(json.dumps(final));stripped['execution'].pop('freeze_sha256')
    stripped.pop('pre_freeze_family_seal_sha256');stripped.pop('pre_freeze_plan_sha256')
    require(stripped==preplan,'Only three declared final-plan links may change');return final,digest

def repeat_stability(cohort,planned):
    records=cohort.get('utterance_repeats',[]);require(isinstance(records,list) and len(records)<=planned,'Repeated-source grid differs')
    out={'planned_source_groups':planned,'stable_multiple_repeats':0,'observed_varied':0,'single_repeat_observed':0,'unknown':planned-len(records)}
    for x in records:
        requested,complete,count=x.get('requested_repeats'),x.get('completed_repeats'),x.get('distinct_hypothesis_hashes')
        require(integer(requested) and integer(complete) and complete<=requested,'Repeat completeness differs')
        if x.get('transcript_variation') is True and type(count) is int and count>1: out['observed_varied']+=1
        elif complete==requested and requested>0 and count==1 and x.get('transcript_variation') is False:
            out['stable_multiple_repeats' if requested>1 else 'single_repeat_observed']+=1
        else:out['unknown']+=1
    out['scope']='Descriptive transcript-hash variation; single-repeat quality is not determinism evidence or independent speech'
    return out

def model_observations(cohorts,model,modes,per_language):
    observed=[]
    for mode in modes:
        rows=[v for v in cohorts if v["model"]==model["id"] and v["language_mode"]==mode]
        require(len(rows)==9 and {v["language"] for v in rows}==set(LANGUAGES),"Nine language cohorts required")
        by_language={v["language"]:v for v in rows};per=[];rates={"cer":[],"wer":[]}
        for language in LANGUAGES:
            v=by_language[language];q=v["quality"]
            require(q.get("planned_unique_utterances")==per_language and type(q.get("completed_unique_utterances")) is int
              and 0<=q["completed_unique_utterances"]<=per_language,"Planned/observed source count differs")
            require(v.get("model_sha256")==model["sha256"] and v.get("model_kind")==model["kind"],"Cohort artifact source differs")
            observed_bytes=v.get("artifact_metrics",{}).get("model_file_bytes")
            require(observed_bytes is None or type(observed_bytes) is int and observed_bytes==model["model_file_bytes"],"Observed artifact bytes differ")
            metrics={}
            for metric in ("cer","wer"):
                if metric=="wer" and language=="zh":
                    metrics[metric]={"status":"not_reported_chinese_whitespace_wer"};continue
                value=q[metric];scored=value["scored_unique_utterances"];errors=value["errors"];units=value["reference_units"];rate=value["corpus_weighted_rate"]
                require(type(scored) is int and 0<=scored<=per_language,"Observed scored-source count differs")
                if scored:
                    require(type(errors) is int and errors>=0 and type(units) is int and units>0 and rate is not None
                      and abs(rate-errors/units)<=1e-12*max(1,abs(rate)),"Retained count/rate mismatch")
                else:require(rate is None,"Unmeasured rate must remain null")
                complete=scored==per_language
                full=rate if complete else None;rates[metric].append(full)
                metrics[metric]={"planned_unique_sources":per_language,"scored_unique_sources":scored,"coverage_complete":complete,
                  "observed_errors":errors,"observed_reference_units":units,"observed_rate":rate,"full_planned_rate":full,
                  "interpretation":"Observed partial counts are not a full planned metric; missing remains unscored/PENDING"}
            per.append({"language":language,"task":v["task"],"planned_unique_sources":per_language,"completed_unique_sources":q["completed_unique_utterances"],
              "quality":q,"counted_metric_coverage":metrics,"timing":v["timing"],"peak_process_rss_bytes":v["peak_process_rss_bytes"],"artifact_metrics":v["artifact_metrics"],
              "sample_grouping":v.get('sample_grouping'),"repeat_stability":repeat_stability(v,per_language)})
        macros={metric:(sum(values)/len(values) if len(values)==(9 if metric=="cer" else 8) and all(v is not None for v in values) else None) for metric,values in rates.items()}
        observed.append({"language_mode":mode,"macro_cer":macros["cer"],"macro_wer":macros["wer"],
          "macro_cer_complete_languages":sum(v is not None for v in rates["cer"]),"macro_wer_complete_languages":sum(v is not None for v in rates["wer"]),"per_language":per})
    return {"id":model["id"],"kind":model["kind"],"sha256":model["sha256"],"actual_model_file_bytes":model["model_file_bytes"],"modes":observed}


def verify_macros(observations,modes,partition,equivalent):
    expected={}
    for mode in modes:
        if partition['kind']=='reference':
            m=mode['reference_metrics'];expected[(partition['model']['id'],mode['language_mode'])]=(m['macro_cer'],m['macro_wer'])
        else:
            contrasts=mode['native_parent_contrasts'];m=contrasts['rotated_f16']['macro_metrics']
            expected[(partition['arms']['original']['id'],mode['language_mode'])]=(m['baseline_macro_cer'],m['baseline_macro_wer'])
            for role in ROLES[1:]:
                m=contrasts[role]['macro_metrics'];expected[(partition['arms'][role]['id'],mode['language_mode'])]=(m['candidate_macro_cer'],m['candidate_macro_wer'])
    for model in observations:
        for mode in model['modes']:
            require(equivalent((mode['macro_cer'],mode['macro_wer']),expected[(model['id'],mode['language_mode'])]),
                    'Independently counted full macros disagree with frozen assessor')

def read_stage(reader,family,stage,event,binding,held,analyzer,terminal):
    folder=R/stage['id']
    preplan,plan_sha=reader.read(stage['assessment_pre_freeze_plan'],stage['assessment_pre_freeze_plan_sha256'],MAX_SMALL)
    plan=preplan
    if binding: plan,plan_sha=final_plan(reader,family,stage,preplan,binding,held)
    require(plan_sha==event['plan_sha256'],'Journal plan hash differs')
    for key,sha_key in (('configuration','configuration_sha256'),('corpus','corpus_sha256'),('source_snapshot','source_snapshot_sha256')):
        reader.read(stage[key],stage[sha_key],MAX_SMALL)
    runtime=plan['runtime_record'];require(runtime==family['runtime_record'],'Runtime metadata descriptor differs')
    reader.read(runtime['path'],runtime['sha256'],MAX_SMALL)
    matrix,matrix_sha=reader.read(folder/'matrix/matrix.json',event['matrix_sha256'])
    report,report_sha=reader.read(folder/'report-v1.1/report.json',event['report_sha256'])
    assessment,assessment_sha=reader.read(folder/'assessment-v1/assessment.json',event['assessment_sha256'])
    guards,_=reader.jsonl(folder/'matrix.guard.jsonl',event['guard_sha256'])
    require(guards and guards[0].get('event')=='starting' and guards[0].get('foreign_cpu_limit')==1000
        and guards[0].get('timeout_seconds')==stage['guard_timeout_seconds']
        and not any(x.get('event') in {'owned_group_signal','owned_cli_signal','cancel_requested','interrupted','cancelled'} for x in guards),
        'Capture/cancel/signal/guard policy differs')
    require(not (folder/'matrix/cancel.request').exists(),'Matrix cancellation cannot be treated as natural failure')
    failed=any(x.get('status')=='failed' for x in matrix.get('rows',[]));classification=None;ref=None
    if failed:
        classification,digest=reader.read(folder/'natural-failures.json')
        ref={'path':str(folder/'natural-failures.json'),'sha256':digest}
        require(classification.get('matrix')=={'path':str(folder/'matrix/matrix.json'),'sha256':matrix_sha}
            and classification.get('classifier')==family['tools']['failure_classifier']
            and type(classification.get('matrix_bytes')) is int
            and classification['matrix_bytes']==reader.ledger[str(folder/'matrix/matrix.json')]['bytes']
            and classification.get('classified_failure_count')==classification.get('failure_count')
            and all(classification.get(k) is False for k in ('reference_audio_model_paths_followed','text_emitted','source_bytes_modified')),
            'Forensic matrix/source binding differs')
    require(event.get('failure_classification')==ref,'Journal classification reference differs')
    counts=terminal.validate_terminal_attempts(stage,plan,matrix,guards[-1],classification)
    require(all(event.get(k)==v for k,v in counts.items()),'Journal terminal counts differ')
    expected={'report_sha256':report_sha,'matrix_sha256':matrix_sha,'plan_sha256':plan_sha,'runtime_record_sha256':runtime['sha256'],
        'analyzer_sha256':family['tools']['assessor']['sha256'],'reused_affine_helpers_sha256':family['tools']['affine_helpers']['sha256'],
        'public_reporter_sha256':family['tools']['reporter']['sha256']}
    require(assessment.get('evidence')==expected,'Frozen assessment provenance differs')
    rebuilt=analyzer.assess(report,matrix,matrix_sha,plan)
    strip=lambda x:{k:v for k,v in x.items() if k not in {'created_utc','evidence'}}
    require(analyzer.equivalent(strip(assessment),strip(rebuilt)),'Frozen assessment/gates differ on metadata rebuild')
    require(event.get('decision')==assessment['partition_assessment'],'Journal frozen decision differs')
    models={m['id']:m for m in family['models']}
    observations=[model_observations(report['cohorts'],models[m],stage['language_modes'],len(plan['cases'])//9) for m in stage['models']]
    verify_macros(observations,assessment['model_mode_assessments'],plan['partition'],analyzer.equivalent)
    metrics_complete=all(mode['macro_cer'] is not None and mode['macro_wer'] is not None for m in observations for mode in m['modes'])
    return {'id':stage['id'],'stage':stage['stage'],'partition_id':stage['partition_id'],'status':'COMPLETE_TERMINAL_ATTEMPT_EVIDENCE',
        **counts,'complete_counted_quality_coverage':metrics_complete,'partition_assessment':assessment['partition_assessment'],
        'decision':assessment['partition_assessment'],'model_mode_assessments':assessment['model_mode_assessments'],
        'artifact_observations':observations,'evidence':expected,'assessment_sha256':assessment_sha,
        'failure_classification':ref,'host_and_software_observations':report.get('host')}

def conclusions(stages):
    result=[]
    for family in ('small','large-v3-turbo'):
        groups=[x for x in stages if x['partition_id']==family];panel=next(x for x in groups if x['stage']=='panel')
        held=next(x for x in groups if x['stage']=='held_out')
        controls=all(all(v is True for v in x['gates'].values()) for x in panel['model_mode_assessments'])
        complete=all(x['complete_counted_quality_coverage'] for x in groups)
        modes={x['language_mode']:x['decision'] for x in held['model_mode_assessments']}
        decision='REJECT' if 'reject' in modes.values() else 'NUMERICAL_GATES_MET_NATIVE_PENDING' if controls and complete and all(v=='continue_no_promotion' for v in modes.values()) else 'INCONCLUSIVE_NO_PROMOTION'
        result.append({'family':family,'decision':decision,'frozen_heldout_mode_decisions':modes,'all_three_repeat_panel_controls_observed':controls,
                       'complete_counted_family_quality':complete,'development_performance_is_not_a_new_gate':True,'default_promotion':False})
    return result

def build(reader,family,events,admission_path,admission_sha):
    assessed,accept,coverage=barrier(family,events)  # MUST precede every outcome read.
    launch=admission(reader,admission_path,admission_sha,events)
    for name in ('assessor','affine_helpers','reporter','sealer'): reader.raw(family['tools'][name]['path'],family['tools'][name]['sha256'],MAX_SMALL)
    analyzer=source_module(reader,family['tools']['assessor'],'round4_summary_assessor')
    terminal=source_module(reader,family['tools']['sealer'],'round4_summary_pure_terminal')
    bindings,held=held_bundle(reader,family,events,accept)
    stages=[read_stage(reader,family,s,e,bindings.get(s['id']),held,analyzer,terminal) for s,e in zip(family['stages'],assessed)]
    require(all(coverage[k]==sum(x[k] for x in stages) for k in FIELDS),'Final independently verified totals differ')
    complete=all(x['complete_counted_quality_coverage'] for x in stages)
    return {'schema_version':VERSION,'created_utc':datetime.now(timezone.utc).isoformat(),
        'status':'COMPLETE_TERMINAL_ATTEMPTS_NO_PROMOTION' if complete else 'COMPLETE_TERMINAL_ATTEMPTS_QUALITY_INCOMPLETE_NO_PROMOTION',
        'terminal_plan_complete':True,'complete_quality_coverage':complete,'coverage':coverage,'stages':stages,
        'artifacts':family['models'],'family_conclusions':conclusions(stages),'scientific_budgets':family['budgets'],
        'frozen_family_seal_sha256':FAMILY,'admission_sha256':ADMISSION,'admission':launch,
        'rotation':family['rotation'],'quantization':family['quantization'],'tools':family['tools'],
        'heldout_family':{'sha256':accept['freeze_sha256'],'partitions':held['partitions']},
        'native_review':'PENDING','product_acceptance':'PENDING','resource_acceptance':'UNCONTROLLED / NOT EVALUATED',
        'default_promotion':False,'integrity_failures':[],'pending':['Native/v2/critical/grouping/region/script/switch/live/channel/product and controlled resources remain unresolved'],
        'preservation':{'raw_reference_audio_model_paths_followed':False,'rescoring_performed':False,'retry_performed':False,'new_gates_or_statistical_claims':False}}

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('family-seal','family-seal-sha256','journal','journal-sha256','admission-capsule','admission-capsule-sha256','expected-source-sha256','output'):
        parser.add_argument('--'+name,required=True)
    parser.add_argument('--timeout-seconds',type=int,choices=range(1,301),default=180)
    a=parser.parse_args(argv);reader=Reader(a.timeout_seconds)
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(number,lambda *_:setattr(reader,'stopped',True))
    require(Path(a.family_seal)==R/'pre-inference-family-seal.json' and a.family_seal_sha256==FAMILY
        and Path(a.journal)==R/'serial.events.jsonl' and Path(a.admission_capsule)==R/'inference-launch.freeze.v1.json'
        and a.admission_capsule_sha256==ADMISSION,'Exact frozen family/journal/admission paths required')
    _,source_sha=reader.raw(Path(__file__).resolve(),a.expected_source_sha256,MAX_SMALL)
    family,_=reader.read(a.family_seal,FAMILY,MAX_SMALL);events,journal_sha=reader.jsonl(a.journal,a.journal_sha256)
    value=build(reader,family,events,Path(a.admission_capsule),ADMISSION)
    for path,pin in list(reader.ledger.items()): reader.raw(path,pin['sha256'])
    value.update(summary_source_sha256=source_sha,journal_sha256=journal_sha,input_metadata_hashes=reader.ledger)
    output=Path(a.output)
    require(output.is_absolute() and R in output.parents and '..' not in output.parts and not output.exists()
        and not any(p.is_symlink() for p in (output,*output.parents)),'New protected summary directory required')
    data=(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n').encode()
    require(len(data)<=MAX_JSON,'Summary exceeds64MiB');reader.check();output.mkdir(mode=0o700)
    with (output/'summary.json').open('xb') as f:f.write(data)
    print(json.dumps({'status':value['status'],'output':str(output),'sha256':hashlib.sha256(data).hexdigest(),'default_promotion':False}))

if __name__=='__main__': main()
