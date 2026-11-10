#!/usr/bin/env python3
"""Enrich a NEW labelled toy before sealing; actual R5 metadata schemas only.

No real audio/reference/model or stage outcome is opened. Template JSON files
contain descriptors, source hashes and static evidence, not utterance text.
"""
import copy,hashlib,json,time
from datetime import datetime,timezone
from pathlib import Path
R=Path(__file__).resolve().parent
def now():return datetime.now(timezone.utc).isoformat()
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def actual(p):
    p=Path(p)
    with p.open('rb') as f:b=f.read(4*1024**2+1)
    if p.suffix!='.json' or len(b)>4*1024**2:raise ValueError('Only bounded metadata blueprint JSON allowed')
    return json.loads(b)
def desc(p):return{'path':str(p),'sha256':sha(p)}
def enrich(f):
    root=f.root;counter=[0];leafmap={}
    def file(name,value):return f.file('audit-toy/'+name,value)
    def clean(v):
        if isinstance(v,dict):
            if isinstance(v.get('path'),str) and isinstance(v.get('sha256'),str):
                key=(v['path'],v['sha256'])
                if key not in leafmap:
                    counter[0]+=1;suffix=Path(v['path']).suffix or '.opaque'
                    leafmap[key]=file('blueprint-leaf-'+str(counter[0])+suffix,b'Explicitly synthetic opaque stand-in; no real payload opened.\n')
                d={k:clean(x) for k,x in v.items() if k not in ('path','sha256','bytes','identity')};d.update(leafmap[key]);return d
            return {k:clean(x) for k,x in v.items()}
        if isinstance(v,list):return[clean(x) for x in v]
        if isinstance(v,str) and v.startswith('/'):return str(root/'synthetic-blueprint-paths'/hashlib.sha256(v.encode()).hexdigest()[:16])
        return copy.deepcopy(v)
    actual_sources=actual(R/'corpus-source-receipt.json')
    templates={key:actual(actual_sources[key]['path']) for key in ('acquisition_freeze','acquisition_stop','completion_freeze','completion_receipt','assembly_receipt','integrity')}
    by_stage={}
    for stage in ('panel','development','held_out'):
        s=next(x for x in f.family['stages'] if x['stage']==stage);by_stage[stage]=actual(s['corpus'])
    source_records=[];panel_records=[]
    for stage in ('panel','development','held_out'):
        for c in by_stage[stage]['cases']:
            original=file('original-'+c['id']+'.opaque',('synthetic original '+c['id']).encode())
            provenance=file('provenance-'+c['id']+'.json',{'synthetic_only':True,'original_audio_sha256':original['sha256'],
              'derived_audio_sha256':c['sha256'],'reference_sha256':c['reference_sha256'],'conversion_command':['synthetic-no-execution','-i',original['path']]})
            prepared={'path':c['audio'],'sha256':c['sha256']};reference={'path':c['reference'],'sha256':c['reference_sha256']}
            record={'id':c['id'],'language':c['language'],'split':'held_out' if stage=='held_out' else 'development',
              'opaque_inputs':[original,prepared,reference],'provenance':provenance}
            if stage=='panel':panel_records.append(record)
            else:source_records.append(record)
    corpus={}
    for stage,v in by_stage.items():corpus[stage]=file(stage+'-corpus.json',v)
    history={}
    for key in ('acquisition_freeze','completion_freeze','acquisition_stop','completion_receipt'):
        v=clean(templates[key]);v['synthetic_only']=True
        if key in ('acquisition_freeze','completion_freeze'):v['created_utc']=now()
        history[key]=file(key+'.json',v)
    initial_acq=file('initial-acquisition.json',{'synthetic_only':True,'errors':[{'error':'synthetic initial cap stop'}]})
    initial_guard=file('initial-guard.jsonl',b'{"event":"finished","synthetic_only":true}\n')
    completion_guard=file('completion-guard.jsonl',b'{"event":"finished","synthetic_only":true}\n')
    prefix=file('swiss-prefix.opaque',b'synthetic retained prefix; not actual Swiss data')
    source_meta=[file('published-meta-'+str(i)+'.opaque',('synthetic metadata '+str(i)).encode()) for i in range(16)]
    lineage={'initial_freeze':history['acquisition_freeze'],'initial_stop':history['acquisition_stop'],'initial_acquisition':initial_acq,
      'initial_guard':initial_guard,'completion_freeze':history['completion_freeze'],'completion_receipt':history['completion_receipt'],
      'completion_guard':completion_guard,'source_manifests':[corpus['development'],corpus['held_out']]}
    omit=lambda value,keys:{k:v for k,v in value.items() if k not in keys}
    integrity=clean(omit(templates['integrity'],{'lineage','case_receipts','source','manifests','published_source_metadata','swiss_archive_prefix'}));integrity.update(synthetic_only=True,lineage=lineage,case_receipts=source_records,
      source=file('synthetic-assembler.py',b'# synthetic metadata stand-in, never executed\n'),manifests=[corpus['development'],corpus['held_out']],
      published_source_metadata=source_meta,swiss_archive_prefix=prefix)
    integrity_d=file('integrity.json',integrity)
    assembly=clean(omit(templates['assembly_receipt'],{'lineage','integrity','manifests','source'}));assembly.update(synthetic_only=True,lineage=lineage,integrity=integrity_d,source=integrity['source'],
      manifests=[corpus['development'],corpus['held_out']]);history['assembly_receipt']=file('assembly.json',assembly)
    source_map=clean(omit(actual_sources,{'panel','development','held_out','integrity',*history}));source_map.update(synthetic_only=True,panel=corpus['panel'],development=corpus['development'],held_out=corpus['held_out'],integrity=integrity_d,**history)
    source_d=file('corpus-source-receipt.json',source_map)
    epoch=time.time();corpus_guard=file('corpus-integrity.guard.jsonl',(''.join(json.dumps(x)+'\n' for x in [
      {'event':'starting','time':epoch,'synthetic_only':True,'command':['synthetic-metadata-assembler']},
      {'event':'finished','time':epoch,'synthetic_only':True,'reason':None,'failure':None,'canceled':False,
       'shutdown':{'returncode':0,'cli_reaped':True,'owned_session_present':False,'shutdown_errors':[]}}])).encode())
    kinds={'original':'pretrained','permuted_f16':'conversion_control','plain_q4':'compression','permuted_q4':'combined'}
    artifacts={family:{role:copy.deepcopy(next(x for x in f.family['models'] if x['parent_original_id']==family and x['kind']==kind))
      for role,kind in kinds.items()} for family in ('small','large-v3-turbo')}
    actual_artifact=actual(R/'artifact-family.receipt.json')
    for family,arms in artifacts.items():
        for role,arm in arms.items():
            if role=='original':continue
            blueprint=actual_artifact['families'][family][role]
            for key in ('audit','guard','permutation_plan'):
                if key not in blueprint:continue
                original=Path(blueprint[key]['path'])
                if key=='guard':raw=(json.dumps({'event':'starting','synthetic_only':True})+'\n'+json.dumps({'event':'finished','synthetic_only':True,'canceled':False,'reason':None,'failure':None,'shutdown':{'returncode':0,'cli_reaped':True,'owned_session_present':False,'shutdown_errors':[]}})+'\n').encode()
                else:raw=clean(actual(original))
                arm[key]=file('export-'+arm['id']+'-'+key+original.suffix,raw)
    originals={x['id']:{**x,'bytes':x['model_file_bytes']} for x in f.family['models'] if x['kind']=='pretrained'}
    artifact=clean(omit(actual_artifact,{'families','models','original_models'}));artifact.update(synthetic_only=True,families=artifacts,models=f.family['models'],original_models=originals)
    artifact_d=file('artifact-family.receipt.json',artifact)
    inventory=clean(omit(actual(R/'pre-execution-identities.json'),{'models','original_models','native_files','runner','baseline_control'}));inventory.update(synthetic_only=True,models=f.family['models'],original_models=originals,native_files=f.family['native_files'],runner=f.family['runner'],baseline_control=f.family['baseline_control'])
    inventory_d=file('pre-execution-identities.json',inventory)
    f.family.update(created_utc=now(),artifacts=artifacts,artifact_family_receipt=artifact_d,original_models=originals,fresh_integrity_sha256=integrity_d['sha256'],
      inputs={'corpus_sources':source_d,'panel_corpus':corpus['panel'],'development_corpus':corpus['development'],'held_out_corpus':corpus['held_out'],
        'integrity':integrity_d,'artifact_family_receipt':artifact_d,'inventory':inventory_d,'corpus_integrity_guard':corpus_guard,**history})
    actual_family=actual(R/'pre-inference-family-seal.json');sources={}
    for key,d in actual_family['inputs'].items():
        if key not in f.family['inputs']:f.family['inputs'][key]=clean(d)
    for key,value in actual_family.items():
        if key not in f.family and key not in {'immutable_files','sources','source_sha256','full_quality_protocol_sha256'}:f.family[key]=clean(value)
    f.family['guard']=f.family['tools']['guard']
    for relative,d in actual_family['sources'].items():
        p=Path(d['path'])
        with p.open('rb') as stream:raw=stream.read(8*1024**2+1)
        if len(raw)>8*1024**2 or hashlib.sha256(raw).hexdigest()!=d['sha256']:raise ValueError('Bounded frozen source blueprint differs')
        sources[relative]=f.file('quality/'+relative,raw)
    f.family.update(sources=sources,source_sha256={k:v['sha256'] for k,v in sources.items()},full_quality_protocol_sha256=sources['benchmarks/weight-space-round5-protocol.md']['sha256'])
    for stage in f.family['stages']:
        value={'schema_version':'mlp-permutation-stage-source-v1','stage':stage['stage'],'partition_id':stage['partition_id'],
          'inputs':f.family['inputs'],'sources':sources,'runner':f.family['runner'],'baseline_control':f.family['baseline_control'],'tools':f.family['tools'],
          'fresh_heldout_reference_content_inspected':False,'native_v2_grouping_approval':False,'synthetic_only':True}
        d=f.file(str(Path(stage['source_snapshot']).relative_to(root)),value);stage['source_snapshot_sha256']=d['sha256']
    panel_payloads=[{'role':'panel_manifest',**corpus['panel']}];panel_cases=[]
    for c in panel_records:
        sources_for_case={'original_audio':c['opaque_inputs'][0],'prepared_audio':c['opaque_inputs'][1],'reference':c['opaque_inputs'][2],'provenance':c['provenance']}
        panel_cases.append({'id':c['id'],'language':c['language'],'source_channel':0,'sources':sources_for_case,'original_hash_binding':'captured_provenance'})
        for role,d in sources_for_case.items():panel_payloads.append({'id':c['id'],'role':role,**d})
    panel_template=actual(R/'panel-source-payloads-v1/inventory.json')
    panel_value=clean(omit(panel_template,{'cases','payloads','panel_manifest'}));panel_value.update(synthetic_only=True,panel_manifest=corpus['panel'],
      status='PASSED_PANEL9_OPAQUE_PAYLOAD_INVENTORY',case_count=9,cases=panel_cases,payloads=panel_payloads,pending=[])
    panel_inventory=file('panel-source-payload-inventory.json',panel_value)
    flags={'dynamic_cli_pins':True,'mandatory_all15_terminal_barrier':True,'campaign_outcomes_read':False,'default_promotion':False,'synthetic_only':True,'created_utc':now()}
    reporting=desc(R/'final-reporting-tools.freeze.v1.json')
    for name in ('summarize-round5-v1.py','project-round5-report-v1.py'):
        f.file(name,(R/name).read_bytes())
    post_source=desc(R/'audit-postrun-preservation-v1.py');numeric_source=desc(R/'audit-final-numeric-gates-v1.py')
    operation=file('postrun-preservation.freeze.json',{'schema_version':'round5-postrun-preservation-freeze-v1','source':post_source,**flags})
    audit_freeze=file('independent-audit.freeze.json',{'schema_version':'round5-independent-final-audit-tools-freeze-v1','source':numeric_source,
      'reporting_tools_freeze_sha256':reporting['sha256'],'preservation_tools_freeze_sha256':operation['sha256'],**flags})
    f._audit_enrichment={'file':file,'clean':clean,'source_map':source_d,'integrity':integrity_d,'reporting_freeze':reporting,
      'operation_freeze':operation,'audit_freeze':audit_freeze,'panel_inventory':panel_inventory,'postrun_source':post_source,'numeric_source':numeric_source}

def finalize(f,attestation):
    """Post-family metadata includes the FINALhash without changing any bindings."""
    state=f._audit_enrichment;file=state['file'];clean=state['clean'];family=desc(f.path)
    template=actual(R/'independent-preflight-audit-v1/audit.json');static=clean(template)
    static.update(synthetic_only=True,family=family,status='PASSED_STATIC_PROVENANCE_ONLY_NO_QUALITY_CLAIM')
    static_d=file('native-static-audit.json',static)
    load=file('native-load.json',{'synthetic_only':True,'status':'passed','verified_derived_artifacts':6,'recognition_performed':False,'quality_inference_grid_cells_added':0})
    guard=file('native-load.guard.jsonl',(json.dumps({'event':'finished','synthetic_only':True,'canceled':False,'reason':None,'failure':None,
      'shutdown':{'returncode':0,'cli_reaped':True,'owned_session_present':False,'shutdown_errors':[]}})+'\n').encode())
    launch=file('native-load.launch.json',{'synthetic_only':True,'recognition_performed':False})
    frozen_inputs={'family':family,'idle':attestation,'independent_static_audit':static_d,'source_payload_inventory':state['panel_inventory']}
    if isinstance(static.get('audit_source'),dict):frozen_inputs['independent_static_audit_source']=static['audit_source']
    admission=f.file('inference-launch.freeze.v1.json',{'synthetic_only':True,'created_utc':now(),'frozen_inputs':frozen_inputs,
      'unchanged_initial_family_seal':True,'candidates_or_settings_changed':False,'preflight_added_quality_cells':0,'default_promotion':False,
      'native_load_receipt':load,'native_load_guard':guard,'native_load_launch':launch,'independent_static_audit':static_d,
      'source_payload_inventory':state['panel_inventory']})
    return {k:v for k,v in state.items() if isinstance(v,dict)}|{'family':family,'admission':admission,'synthetic_only':True}
