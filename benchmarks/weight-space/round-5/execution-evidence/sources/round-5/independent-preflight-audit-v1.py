#!/usr/bin/env python3
"""Independent R5 static/metadata audit; no Whisper initialization or ASR.

Run under unchanged7697. All11 whole-file hashes, fixed neuron orders, exact
F16 permutations and official Q4 containers/row proofs are independently checked.
Reconstruction diagnostics never select a recipe or establish speech quality.
"""
import os
for _key in ('OPENBLAS_NUM_THREADS','OMP_NUM_THREADS','VECLIB_MAXIMUM_THREADS','MKL_NUM_THREADS','NUMEXPR_NUM_THREADS','BLIS_NUM_THREADS'):
    os.environ[_key]='1'
import argparse
from collections import Counter
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import signal
import stat
import struct
import sys
import time

VERSION='round5-independent-pre-inference-audit-v1'
STATUS='PASSED_STATIC_PROVENANCE_ONLY_NO_QUALITY_CLAIM'
OPERATOR='0a33ffab0c343b88e1cffa3e571619b414148d4b88673b69fa77386124087122'
EXPORTER='eca16247e3855bd5948e01378a4d56fe08c3b2613c824cc2fa17f1f25766e9f4'
PARSER='11c0c7ddda3d81a90c47b58a4b82415f9764f51eed7b2c5302fdc0784c34e4c3'
CORE='bf3f2ef5e00a4c06ef7fd4912c46dd2a0d50f7a381d45fff7cef6c5fae93c4e0'
QUANTIZER='2efffddc246a52e7ba9a81145926d07e7f1c5fc7ba56a95586602a12ec5e00bd'
GUARD='7697f60e8a2c0aa150b598afe2e8c552435e1d8a4cb2f99489c9fa10de0dc56c'
LANGUAGES=('de-CH','de','fr','it','en','ar','zh','es','pt')
GEOMETRIES={'small':(768,12,12,12,80,51865),'large-v3-turbo':(1280,20,32,4,128,51866)}
PLAIN={'small':('f6099c17a4305c6d173ef90ab6f15150dcbb85332b7831313bf36a378d7c5a85',145458015),
       'large-v3-turbo':('2ceb779ca61ce46ed6e9aa43c4a0f8a89a37f683df3c0ba3119238fcd5852155',473992235)}
ORDERING={'key':'original_mlp2_column_max_abs_f64','direction':'ascending','ties':'original_hidden_index',
          'index_semantics':'new_position_to_original_hidden_index','index_encoding':'u32-le'}
MAX_READ=32*1024**3
MAX_FILE=4*1024**3
MAX_JSON=8*1024**2

def require(value,message):
    if not value:raise ValueError(message)

def sha(data):return hashlib.sha256(data).hexdigest()
def identity(s):return(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)

def decode(raw):
    def fields(pairs):
        value={}
        for key,item in pairs:require(key not in value,'Duplicate JSON field');value[key]=item
        return value
    def number(value):
        result=float(value);require(math.isfinite(result),'Nonfinite JSON number');return result
    return json.loads(raw,object_pairs_hook=fields,parse_float=number,
        parse_constant=lambda _:(_ for _ in ()).throw(ValueError('Nonfinite JSON value')))

class Reader:
    def __init__(self,root,seconds=600):
        require(type(seconds) is int and 0<seconds<=600,'Finite audit bound required')
        self.root=Path(root);self.deadline=time.monotonic()+seconds;self.stopped=False
        self.debited=0;self.direct=0;self.helper_upper=0;self.ledger={}
    def check(self):
        if self.stopped or (self.root/'cancel-independent-preflight-audit.request').exists():raise InterruptedError('Independent audit canceled; all inputs retained')
        if time.monotonic()>=self.deadline:raise TimeoutError('Independent audit exceeded600s')
    def debit(self,count,helper=False):
        self.check();require(type(count) is int and count>=0 and self.debited+count<=MAX_READ,'Protected input read budget exceeds32GiB')
        self.debited+=count
        if helper:self.helper_upper+=count
        else:self.direct+=count
    def path(self,path):
        path=Path(path)
        require(path.is_absolute() and '..' not in path.parts and not any(p.is_symlink() for p in (path,*path.parents)),'Absolute nonsymlink input required')
        require(stat.S_ISREG(path.lstat().st_mode),'Regular input required')
        return path
    def raw(self,path,expected=None,maximum=MAX_JSON):
        path=self.path(path);before=path.stat();require(before.st_size<=maximum,'Metadata/source bound exceeded')
        self.check()
        limit=min(before.st_size+1,maximum+1)
        require(self.debited+limit<=MAX_READ,'Metadata read exceeds remaining protected input budget')
        with path.open('rb') as stream:
            require(identity(os.fstat(stream.fileno()))==identity(before),'Input replaced before read')
            data=stream.read(limit)
        self.debit(len(data));require(len(data)<=maximum and identity(path.lstat())==identity(before),'Metadata changed/grown')
        digest=sha(data);require(expected is None or digest==expected,'Pinned metadata/source hash differs')
        self.ledger[str(path)]={'path':str(path),'sha256':digest,'bytes':len(data),'identity':identity(before)}
        return data
    def document(self,pin):return decode(self.raw(pin['path'],pin['sha256']))
    def digest(self,path,expected,maximum=MAX_FILE):
        path=self.path(path);before=path.stat();require(before.st_size<=maximum,'Input file bound exceeded')
        value=hashlib.sha256();count=0
        with path.open('rb') as stream:
            require(identity(os.fstat(stream.fileno()))==identity(before),'Input replaced before hashing')
            while True:
                self.check();limit=min(256*1024,before.st_size-count+1,MAX_READ-self.debited)
                require(limit>0,'Read budget exhausted before EOF')
                data=stream.read(limit);self.debit(len(data))
                if not data:break
                count+=len(data);require(count<=before.st_size,'Input grew during hash');value.update(data)
            require(identity(os.fstat(stream.fileno()))==identity(before),'Input changed during hash')
        require(count==before.st_size and identity(path.lstat())==identity(before) and value.hexdigest()==expected,'Actual input hash/identity differs')
        self.ledger[str(path)]={'path':str(path),'sha256':expected,'bytes':count,'identity':identity(before)}
        return self.ledger[str(path)]
    def block(self,stream,offset,count):
        self.check();require(type(count) is int and 0<=count<=1024*1024 and self.debited+count<=MAX_READ,'Bounded read tile required')
        stream.seek(offset);value=stream.read(count);self.debit(len(value));require(len(value)==count,'Truncated selected tensor');return value
    def final(self):
        for value in self.ledger.values():require(identity(self.path(value['path']).stat())==tuple(value['identity']),'Earlier audited input changed')
        self.check()

def source_module(reader,pin,name):
    reader.raw(pin['path'],pin['sha256']);spec=importlib.util.spec_from_file_location(name,pin['path'])
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module);return module

def epoch(value):
    result=datetime.fromisoformat(value.replace('Z','+00:00'));require(result.tzinfo is not None,'Timezone-aware provenance required');return result.timestamp()

def closed_events(reader,pin,allow_initial_budget_stop=False):
    events=[decode(v) for v in reader.raw(pin['path'],pin['sha256']).splitlines() if v.strip()]
    require(events and events[0].get('event')=='starting' and events[-1].get('event')=='finished','Closed guard required')
    end=events[-1];shutdown=end.get('shutdown',{})
    require(type(shutdown.get('returncode')) is int and shutdown['returncode'] in ({0,1} if allow_initial_budget_stop else {0})
        and end.get('reason') is None and end.get('failure') is None and end.get('canceled') is False
        and shutdown.get('cli_reaped') is True and shutdown.get('owned_session_present') is False and shutdown.get('shutdown_errors')==[]
        and not any(e.get('event') in ('cancel_requested','owned_group_signal','owned_cli_signal','interrupted','cancelled') for e in events),'Guard failure/cancellation/cleanup uncertainty')
    require(all(type(e.get('time')) in (int,float) and math.isfinite(e['time']) for e in events),'Finite guard chronology required')
    return events

def source_sets(cases):
    values={k:set() for k in ('id','source_id','audio','reference','speaker','session')}
    for c in cases:
        for k in ('id','source_id'):
            if c.get(k):values[k].add(c[k])
        values['audio'].update(c[k] for k in ('sha256','original_audio_sha256') if c.get(k))
        if c.get('reference_sha256'):values['reference'].add(c['reference_sha256'])
        values['speaker'].update(c.get('speaker_ids') or [])
        if c.get('session_id'):values['session'].add(c['session_id'])
    return values

def corpus_proof(reader,family):
    source=reader.document(family['inputs']['corpus_sources']);integrity=reader.document(family['inputs']['integrity'])
    require(source.get('schema_version')=='round5-corpus-source-receipt-v1' and source.get('state')=='completed'
        and source.get('opaque') is True and source.get('reference_text_semantically_inspected') is False,'Fresh opaque source map differs')
    require(integrity.get('schema_version')=='round5-completed-corpus-opaque-integrity-v1'
        and integrity.get('status')=='PASSED_OPAQUE_BYTE_METADATA_INTEGRITY_EXPLORATORY_ONLY'
        and integrity.get('case_count')==integrity.get('source_id_count')==integrity.get('reference_hash_count')==216
        and integrity.get('original_prepared_hash_count')==432 and integrity.get('final_vs_prior9_disjoint') is True
        and integrity.get('swiss_completion_vs_all11_disjoint') is True
        and all(integrity.get(k) is False for k in ('reference_bytes_decoded_to_text','reference_semantic_inspection','recognition_performed',
            'original_case_objects_changed','audio_reference_copies_or_links_created','native_human_approval','approved_v2_corpus')),'Complete216 opaque corpus evidence differs')
    dev=reader.document(source['development'])['cases'];held=reader.document(source['held_out'])['cases']
    require(Counter(c['language'] for c in dev)==Counter({k:8 for k in LANGUAGES}) and Counter(c['language'] for c in held)==Counter({k:16 for k in LANGUAGES}),'Every language needs8DEV/16held')
    cases=dev+held;fresh=source_sets(cases)
    acquisition=reader.document(source['acquisition_freeze']);completion=reader.document(source['completion_freeze'])
    require(len(acquisition['exclusion_manifests'])==9 and len(completion['exclusion_manifests'])==11,'Exact9/11 consumed manifest ledgers required')
    prior_cases=[]
    for pin in acquisition['exclusion_manifests']:prior_cases+=reader.document(pin)['cases']
    prior=source_sets(prior_cases)
    require(len(prior_cases)==648 and len(prior['speaker'])==70 and all(not(prior[k]&fresh[k]) for k in prior),'Prior9 source/speaker/hash leakage')
    require(len(fresh['id'])==len(fresh['source_id'])==len(fresh['reference'])==216 and len(fresh['audio'])==432
        and len(fresh['speaker'])==24 and sum(not c.get('speaker_ids') for c in cases)==192 and sum(not c.get('session_id') for c in cases)==216,'Fresh identity/grouping count differs')
    require(all(c.get('task')==('standard_rendering' if c['language']=='de-CH' else 'transcription') and type(c.get('source_channel')) is int and c['source_channel']==0 and c.get('reviewed') is False for c in cases),'Swiss rendering/channel/unreviewed scope differs')
    lineage=integrity['lineage'];initial_guard=closed_events(reader,lineage['initial_guard'],True);completion_guard=closed_events(reader,lineage['completion_guard'])
    corpus_guard=closed_events(reader,family['inputs']['corpus_integrity_guard'])
    require(epoch(acquisition['created_utc'])<=initial_guard[0]['time']<initial_guard[-1]['time']
        <=epoch(completion['created_utc'])<=completion_guard[0]['time']<completion_guard[-1]['time']
        <=corpus_guard[0]['time']<corpus_guard[-1]['time']<=epoch(family['created_utc']),'Prospective data completion/family chronology differs')
    initial=reader.document(lineage['initial_acquisition']);require(initial['errors'] and sum(p['cases'] for p in initial['manifests'])==192,'Original192-case budget stop must remain visible')
    expected={c['id']:c for c in cases}
    for pin in lineage['source_manifests']:
        for c in reader.document(pin)['cases']:require(expected.get(c['id'])==c,'Accepted source case object changed during completion')
    return {'cases':216,'per_language_development':8,'per_language_heldout':16,'prior_manifests':9,'completion_exclusion_manifests':11,
        'prior_swiss_speakers':70,'new_swiss_speakers':24,'unknown_fleurs_speakers':192,'unknown_sessions':216,
        'initial192_budget_stop_preserved':True,'actual_guard_chronology_verified':True,'raw_audio_or_reference_payloads_opened_here':False}

def tensor_bytes_proof(reader,original,candidate,site,record,edits,np):
    hidden=record['hidden_channels'];order=record['permutation'];inverse=np.argsort(order);results=[]
    with original.path.open('rb') as a,candidate.path.open('rb') as b:
        for suffix,operation in (('.0.weight','rows'),('.0.bias','bias'),('.2.weight','columns')):
            t=original.tensor(site+suffix);before=hashlib.sha256();after=hashlib.sha256();undo=hashlib.sha256();changed=0
            width=4 if operation=='bias' else 2;dtype='<u4' if width==4 else '<u2'
            if operation=='rows':
                row_bytes=t.shape[0]*width
                for new,old in enumerate(order):
                    source=reader.block(a,t.offset+old*row_bytes,row_bytes);baseline=reader.block(a,t.offset+new*row_bytes,row_bytes)
                    result=reader.block(b,t.offset+new*row_bytes,row_bytes)
                    require(source==result and bool(np.isfinite(np.frombuffer(baseline,dtype='<f2')).all()),'Exact finite MLP1 row permutation differs')
                    before.update(baseline);after.update(result);changed+=int(np.count_nonzero(np.frombuffer(baseline,dtype=dtype)!=np.frombuffer(result,dtype=dtype)))
                for new in inverse:undo.update(reader.block(b,t.offset+int(new)*row_bytes,row_bytes))
            else:
                rows=1 if operation=='bias' else t.shape[1];columns=hidden;row_bytes=columns*width
                for row in range(rows):
                    source=reader.block(a,t.offset+row*row_bytes,row_bytes);result=reader.block(b,t.offset+row*row_bytes,row_bytes)
                    values=np.frombuffer(source,dtype=dtype)
                    require(values[order].tobytes()==result,'Exact MLP bias/down-projection permutation differs')
                    before.update(source);after.update(result);undo.update(np.frombuffer(result,dtype=dtype)[inverse].tobytes())
                    changed+=int(np.count_nonzero(values!=np.frombuffer(result,dtype=dtype)))
                    require(bool(np.isfinite(np.frombuffer(source,dtype='<f4' if width==4 else '<f2')).all()),'Selected original has nonfinite values')
            edit=edits[t.name]
            require(edit['before_sha256']==before.hexdigest()==undo.hexdigest()==edit['inverse_permutation_sha256']
                and edit['after_sha256']==after.hexdigest() and edit['inverse_permutation_equal'] is True
                and type(edit['changed_elements']) is int and edit['changed_elements']==changed
                and edit['selected_elements']==t.elements and edit['operation']==operation,'Actual selected/inverse bytes differ from bound audit')
            results.append((t.offset,t.offset+t.bytes));
    return results

def permutation_proof(reader,original,candidate,model_id,plan,audit,np):
    state=original.architecture['n_text_state'];enc=original.architecture['n_audio_layer'];dec=original.architecture['n_text_layer'];hidden=4*state
    expected=[f'{side}.blocks.{i}.mlp' for side,n in (('encoder',enc),('decoder',dec)) for i in range(n)]
    require(plan['schema_version']=='whisper-mlp-permutation-v1' and plan['model_id']==audit['model_id']==model_id
        and plan['source_sha256']==audit['source_sha256']==original.source_sha256
        and plan['ordering']==ORDERING and [v['site'] for v in plan['sites']]==expected,'Exact fixed MLP model/source/recipe/sites required')
    edits={v['tensor']:v for v in audit['edits']};require(len(edits)==len(audit['edits'])==3*len(expected),'Exact selected tensor inventory required')
    ranges=[]
    with original.path.open('rb') as stream:
        for record in plan['sites']:
            site=record['site'];t=original.tensor(site+'.2.weight');maxima=np.zeros(hidden,dtype=np.float64)
            for first in range(0,state,16):
                count=min(16,state-first);raw=reader.block(stream,t.offset+first*hidden*2,count*hidden*2)
                values=np.frombuffer(raw,dtype='<f2').astype(np.float64).reshape(count,hidden)
                require(bool(np.isfinite(values).all()),'Nonfinite original MLP2');maxima=np.maximum(maxima,np.abs(values).max(axis=0))
            order=sorted(range(hidden),key=lambda i:(float(maxima[i]),i));vector=struct.pack('<'+'I'*hidden,*order)
            require(record['hidden_channels']==hidden and all(type(v) is int for v in record['permutation']) and record['permutation']==order
                and record['permutation_sha256']==sha(vector) and record['nonidentity_positions']==sum(i!=v for i,v in enumerate(order))
                and record['column_max_abs_min']==float(maxima.min()) and record['column_max_abs_max']==float(maxima.max())
                and record['zero_scale_channels']==int(np.count_nonzero(maxima==0)),'Original-weight maxabs/tie order differs')
            ranges+=tensor_bytes_proof(reader,original,candidate,site,record,edits,np)
    selected=sum(original.tensor(site+suffix).elements for site in expected for suffix in ('.0.weight','.0.bias','.2.weight'))
    require(type(audit['selected_elements']) is int and audit['selected_elements']==selected
        and audit['selected_tensor_count']==len(ranges) and audit['changed_elements']==sum(v['changed_elements'] for v in edits.values())
        and audit['no_op'] is (audit['changed_elements']==0),'Actual permutation count/no-op differs')
    # Bound exact equality outside all selected ranges independently of claims.
    digest=hashlib.sha256();position=0
    with original.path.open('rb') as a,candidate.path.open('rb') as b:
        for start,end in sorted(ranges)+[(original.bytes,original.bytes)]:
            while position<start:
                count=min(256*1024,start-position);left=reader.block(a,position,count);right=reader.block(b,position,count)
                require(left==right,'Unselected F16 bytes changed');digest.update(left);position+=count
            position=end
    require(digest.hexdigest()==audit['unchanged_regions_sha256'],'Outside-range hash differs')
    return {'sites':len(expected),'selected_tensors':len(ranges),'selected_elements':audit['selected_elements'],
        'actual_original_weight_order_recomputed':True,'actual_selected_and_inverse_bytes_verified':True,'outside_declared_changed_bytes':0}

def q4_rows(reader,original,plain_path,candidate_path,plain,candidate,plan,np):
    left={v['name']:v for v in plain['tensors']};right={v['name']:v for v in candidate['tensors']}
    targets={v['site']+s for v in plan['sites'] for s in ('.0.weight','.0.bias','.2.weight')}
    require(set(left)==set(right) and plain['model_file_bytes']==candidate['model_file_bytes'],'Q4 layout/size differs')
    for name in left:
        require(all(left[name][k]==right[name][k] for k in ('shape','type_id','offset','payload_bytes','quantized')),'Q4 tensor layout differs')
        if name not in targets:require(left[name]['payload_sha256']==right[name]['payload_sha256'],'Unselected Q4 tensor changed')
    with Path(plain_path).open('rb') as a,Path(candidate_path).open('rb') as b:
        for site in plan['sites']:
            order=site['permutation'];t=left[site['site']+'.0.weight'];row_bytes=t['shape'][0]//32*18
            for new,old in enumerate(order):require(reader.block(a,t['offset']+old*row_bytes,row_bytes)==reader.block(b,t['offset']+new*row_bytes,row_bytes),'Q4 first rows are not the exact plain-control permutation')
            t=left[site['site']+'.0.bias'];source=reader.block(a,t['offset'],t['payload_bytes']);result=reader.block(b,t['offset'],t['payload_bytes'])
            require(result==b''.join(source[i*4:i*4+4] for i in order),'Q4 F32 bias permutation differs')
    return len(left)-len(targets)

def artifact_proofs(reader,family,weights,core,np):
    proofs=[]
    for name,arms in family['artifacts'].items():
        require(name in GEOMETRIES and set(arms)=={'original','permuted_f16','plain_q4','permuted_q4'},'Exactly fixed2families/4arms required')
        original,permuted=arms['original'],arms['permuted_f16'];models=[]
        for value in (original,permuted):
            # Pinned inspector reads at most one parse pass plus one whole hash.
            reader.debit(2*value['model_file_bytes'],helper=True)
            model=weights.inspect_model(value['path'],weights.Limits(model_bytes=MAX_FILE),reader.check)
            require(model.source_sha256==value['sha256'] and model.bytes==value['model_file_bytes'],'Actual F16 model identity differs');models.append(model)
        a,b=models;require(a.architecture==b.architecture and a.tensors==b.tensors and a.vocabulary_sha256==b.vocabulary_sha256,'F16 headers/layout/vocabulary differ')
        state,heads,enc,dec,mels,vocab=GEOMETRIES[name]
        expected={'n_audio_state':state,'n_text_state':state,'n_audio_head':heads,'n_text_head':heads,'n_audio_layer':enc,'n_text_layer':dec,'n_mels':mels,'n_vocab':vocab,'ftype':1,'n_audio_ctx':1500,'n_text_ctx':448}
        require(a.architecture==expected,'Pinned multilingual geometry differs')
        audit=reader.document(permuted['audit']);plan=reader.document(permuted['permutation_plan'])
        require(audit['state']=='completed' and audit['source_sha256']==original['sha256'] and audit['derived_sha256']==permuted['sha256']
            and audit['generator_sha256']==OPERATOR and audit['parser_sha256']==PARSER
            and audit['permutation_plan_sha256']==permuted['permutation_plan']['sha256']
            and all(audit[k] is False for k in ('training_used','fitting_used','seed_search_used','inference_or_quantization_executed')),'F16 method/source/lineage differs')
        proof=permutation_proof(reader,a,b,name,plan,audit,np);actual={};exports={}
        for role,source in (('plain_q4',a),('permuted_q4',b)):
            arm=arms[role];q=reader.document(arm['audit']);exports[role]=q
            require(q['state']=='completed' and q['role']==role and q['derived_sha256']==arm['sha256'] and q['input_sha256']==source.source_sha256
                and q['parent_original_sha256']==q['original_after_sha256']==original['sha256'] and q['intermediate_after_sha256']==source.source_sha256
                and q['generator_sha256']==EXPORTER and q['quantizer_sha256']==q['quantizer_after_sha256']==QUANTIZER
                and q['quantization']=={'format':'q4_0','ftype':2,'file_header_ftype':2002}
                and q['recognition_or_model_initialization_executed'] is False and q['default_promotion'] is False,'Official Q4 lineage/source/policy differs')
            # Pinned bf3 parser visits each Q4 byte once and a subset of F16 once.
            reader.debit(source.bytes+arm['model_file_bytes'],helper=True)
            static=core.audit_q4(source,arm['path'],reader.check)
            require(all(q['static_validation'].get(k)==v for k,v in static.items() if k!='file_identity'),'Actual Q4 container/payload hashes differ')
            actual[role]=static
        require((arms['plain_q4']['sha256'],arms['plain_q4']['model_file_bytes'])==PLAIN[name],'Unchanged conventional Q4 control did not reproduce')
        untouched=q4_rows(reader,a,arms['plain_q4']['path'],arms['permuted_q4']['path'],actual['plain_q4'],actual['permuted_q4'],plan,np)
        combined=exports['permuted_q4'];validation=combined['permutation_validation'];comparison=combined['plain_control_comparison']
        require(validation['parent_sha256']==original['sha256'] and validation['intermediate_sha256']==permuted['sha256']
            and validation['permutation_plan_sha256']==permuted['permutation_plan']['sha256'] and validation['exact_selected_and_inverse_bytes_verified'] is True
            and comparison['same_file_bytes'] is True and comparison['unmodified_tensors_byte_identical'] is True
            and comparison['unmodified_tensor_count']==untouched and comparison['exact_q4_mlp1_row_and_f32_bias_permutation'] is True,'Bound Q4 permutation proof differs')
        diagnostics=comparison['weight_error_diagnostics'];require(diagnostics['descriptive_only'] is True and diagnostics['selection_or_quality_gate'] is False
            and len(diagnostics['layers'])==enc+dec,'Weight SSE must remain complete and descriptive')
        proofs.append({'family':name,**proof,'q4_file_bytes':arms['plain_q4']['model_file_bytes'],'plain_permuted_equal_byte_lengths':True,
            'unmodified_q4_tensors':untouched,'actual_official_q4_containers_verified':2,'q4_first_rows_and_bias_bytes_verified':True,
            'weight_error_diagnostics':diagnostics,'weight_sse_recomputed_here':False,'weight_sse_scope':'Descriptive export diagnostics bound to actual source/output hashes; never a quality or selection gate'})
    require({p['family'] for p in proofs}==set(GEOMETRIES),'Both fixed families required');return proofs

def publish(reader,output,value):
    require(output.is_absolute() and output.parent==reader.root and not output.exists() and '..' not in output.parts
        and not any(p.is_symlink() for p in (output,*output.parents)),'New protected audit output required')
    raw=(json.dumps(value,indent=2,allow_nan=False)+'\n').encode();require(len(raw)<=MAX_JSON,'Audit output exceeds8MiB')
    reader.check();output.mkdir(mode=0o700);partial=output/'audit.partial.json';final=output/'audit.json'
    with partial.open('xb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
    owner=identity(partial.stat())[:2];reader.final();os.link(partial,final,follow_symlinks=False)
    require(identity(final.lstat())[:2]==owner,'Published audit inode changed');partial.unlink();reader.check()
    return {'path':str(final),'sha256':sha(raw),'bytes':len(raw)}

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('family-seal','family-seal-sha256','expected-source-sha256','output'):parser.add_argument('--'+name,required=True)
    parser.add_argument('--preflight-only',action='store_true');a=parser.parse_args(argv)
    root=Path(a.family_seal).resolve().parent;reader=Reader(root)
    Path(os.environ['RECSCRIBE_RUN_DIR'],'.pin').touch(exist_ok=True)
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(number,lambda *_:setattr(reader,'stopped',True))
    reader.raw(Path(__file__).resolve(),a.expected_source_sha256);family_pin={'path':a.family_seal,'sha256':a.family_seal_sha256};f=reader.document(family_pin)
    require(Path(a.family_seal)==root/'pre-inference-family-seal.json' and f.get('permutation')=={'version':'whisper-mlp-permutation-v1','recipe_sha256':OPERATOR}
        and f['tools']['guard']['sha256']==GUARD and f['quantization']=={'format':'q4_0','ftype':2,'quantizer_sha256':QUANTIZER},'Exact frozen method/family required')
    # A conservative metadata allowance covers the reused constructor/import reads;
    # it opens no model payload. Actual protected payload reads are below.
    reader.debit(512*1024**2,helper=True)
    sealer=source_module(reader,f['tools']['sealer'],'round5_independent_static_sealer')
    family=sealer.Family(Path(a.family_seal),a.family_seal_sha256,reader.check)
    assessor=family.tool('assessor');require(Path(assessor.__file__).parents[2]==root/'quality','Deep packaged assessor boundary differs')
    for stage in f['stages']:
        require(not any(p.exists() for p in sealer.output_paths(stage)),'Quality output already exists before pre-inference audit')
        if stage['stage']!='held_out':assessor.validate_plan(family.plans[stage['id']])
        snapshot=reader.document({'path':stage['source_snapshot'],'sha256':stage['source_snapshot_sha256']})
        require(snapshot['tools']==f['tools'] and snapshot['inputs']==f['inputs'] and snapshot['runner']==f['runner'],'Stage source snapshot differs')
    require(len(family.plans)==15 and len(f['models'])==11,'Exact15plans/11models required')
    base={'schema_version':VERSION,'created_utc':datetime.now(timezone.utc).isoformat(),'audit_source':{k:v for k,v in reader.ledger[str(Path(__file__).resolve())].items() if k!='identity'},
        'family':family_pin,'sealer':f['tools']['sealer'],'stage_preplans_verified':15,'nonheld_assessor_plans_validated':10,
        'held_preplans_intentionally_without_final_freeze_links':5,'recognition_or_model_initialization_executed':False,
        'held_reference_semantically_inspected':False,'model_source_or_payload_writes':False,'default_promotion':False}
    if a.preflight_only:
        base.update(status='PREFLIGHT_METADATA_ONLY_NO_MODEL_PAYLOAD',models_verified=0,model_payloads_opened=False)
    else:
        models={m['path'] for m in f['models']}
        for path,expected in family.bindings.items():reader.digest(path,expected)
        for m in f['models']:require(reader.ledger[m['path']]['bytes']==m['model_file_bytes'],'Exact actual model bytes differ')
        corpus=corpus_proof(reader,f)
        weights=source_module(reader,f['tools']['ggml_parser'],'round5_independent_static_ggml')
        generation=reader.document(f['inputs']['artifact_family_receipt'])
        freeze=reader.document(generation['generation_freeze'])
        require(freeze['tools']['operator']['sha256']==OPERATOR and freeze['tools']['exporter']['sha256']==EXPORTER
            and freeze['tools']['reused_q4_core']['sha256']==CORE and freeze['tools']['parser']['sha256']==PARSER,'Generation source family differs')
        core=source_module(reader,freeze['tools']['reused_q4_core'],'round5_independent_static_q4')
        import numpy as np
        proofs=artifact_proofs(reader,f,weights,core,np)
        inventory=reader.document(f['inputs']['inventory']);require(inventory['verified_model_files']==11 and len(inventory['native_files'])==11,'Exact native/control inventory differs')
        base.update(status=STATUS,models_verified=11,new_exports_verified=6,native_files_verified=11,all_bound_hashes_verified=True,
            bound_files=len(family.bindings),models=f['models'],artifact_proofs=proofs,fresh_corpus=corpus,
            actual_model_whole_file_hashes_verified=True,model_payloads_opened=True,
            model_transform_and_q4_proof_scope='Independent original-weight ordering, selected/inverse F16 bytes, unchanged ranges, Q4 containers/row equivariance. Stored SSE is descriptive and hash-bound, not recomputed here.',
            quality_acceptance='PENDING',native_compatibility='PENDING_ACTUAL_NN',product_acceptance='PENDING',resource_acceptance='NOT EVALUATED',
            guard_used=True,guard_source_sha256=GUARD)
    reader.final();base.update(direct_protected_bytes_read=reader.direct,conservative_helper_read_budget_debit=reader.helper_upper,
        total_read_budget_debit_bytes=reader.debited,limits={'protected_read_bytes':MAX_READ,'seconds':600,'input_file_bytes':MAX_FILE,'metadata_bytes':MAX_JSON},
        read_budget_scope='Direct protected reads plus conservative upper bounds for pinned parser/constructor reads; system interpreter/library paging excluded',
        input_metadata=[{k:v for k,v in x.items() if k!='identity'} for x in reader.ledger.values()])
    result=publish(reader,Path(a.output),base);print(json.dumps({'receipt':result,'status':base['status']}),flush=True)
    return 0

if __name__=='__main__':raise SystemExit(main())
