#!/usr/bin/env python3
"""Independent counted-metadata audit; no scorer imports or raw payload opens."""
import argparse, collections, csv, hashlib, io, itertools, json, math, os, re, signal, statistics, stat, time
from datetime import datetime, timezone
from pathlib import Path

R=Path(__file__).absolute().parent
FAMILY_SHA=None  # Mandatory explicit runtime CLI pin
ADMISSION_SHA=None  # Mandatory explicit runtime CLI pin
VERSION='round5-independent-numeric-gate-provenance-audit-v1'
FORMATTER_SHA=None  # Mandatory explicit runtime CLI pin
PROJECTOR_SHA=None  # Mandatory explicit runtime CLI pin
REPORTING_FREEZE_SHA=None  # Mandatory explicit runtime CLI pin
PRESERVATION_SOURCE_SHA=None  # Mandatory explicit runtime CLI pin
PRESERVATION_FREEZE_SHA=None  # Mandatory explicit runtime CLI pin
LANGS=('de-CH','de','fr','it','en','ar','zh','es','pt')
FAMILIES=('tiny','base','small','large-v3-turbo','large-v3')
ADAPTED=('small','large-v3-turbo')
KINDS={'original':'pretrained','permuted_f16':'conversion_control','plain_q4':'compression','permuted_q4':'combined'}
FIELDS=('planned_cells','attempted_cells','completed_cells','failed_cells','planned_native_parent_pairs','completed_native_parent_pairs','pending_native_parent_pairs','planned_assessor_derived_q4_pairs','completed_assessor_derived_q4_pairs','pending_assessor_derived_q4_pairs','runtime_reference_placeholders')
IDS=[prefix+family for prefix in ('panel-','dev-validation-','heldout-') for family in FAMILIES]
POLICY='swift-nfc-casefold-alphanumeric-v1'
GOOD={'completed','completed_with_review'}
STOP=False
DEADLINE=None
INPUTS={}
CHECKS=collections.Counter()
VERSIONS=collections.defaultdict(set)
REFERENCE_UNITS={}
PLANNED_CASES={}
OPTIONS=None
EXTERNAL_PINS={}
PHYSICAL_READ_BYTES=0

def require(value,message):
    if not value: raise ValueError(message)

def check():
    if STOP or (R/'cancel-final-audit.request').exists(): raise InterruptedError('Audit canceled; retained inputs untouched')
    if DEADLINE is not None and time.monotonic()>DEADLINE: raise TimeoutError('Finite metadata audit time bound exceeded')

def stop(_a,_b):
    global STOP
    STOP=True
for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP): signal.signal(sig,stop)

def sha(data): return hashlib.sha256(data).hexdigest()

def read(path,digest=None,limit=64*1024*1024):
    global PHYSICAL_READ_BYTES
    check();path=Path(path)
    require(path.is_absolute() and (R in path.parents or EXTERNAL_PINS.get(str(path))==digest) and '..' not in path.parts and path.suffix in {'.json','.jsonl','.csv','.md','.py'}
        and not any(p.is_symlink() for p in (path,*path.parents)),'Protected explicit metadata/source input required')
    before=path.stat();require(stat.S_ISREG(before.st_mode) and before.st_size<=limit,'Bounded regular metadata input required')
    require(sum(v['bytes'] for k,v in INPUTS.items() if k!=str(path))+before.st_size<=512*1024*1024,'Total metadata read budget exceeded')
    chunks=[];length=0
    with path.open('rb') as f:
        while length<before.st_size:
            check();remaining=2*1024**3-PHYSICAL_READ_BYTES;require(remaining>0,'Physical metadata read cap2GiB exhausted')
            part=f.read(min(65536,before.st_size-length,remaining));require(part,'Metadata truncated during read')
            PHYSICAL_READ_BYTES+=len(part);chunks.append(part);length+=len(part);require(length<=limit,'Metadata exceeds bound')
    data=b''.join(chunks)
    after=path.stat();ident=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    require(len(data)<=limit and ident(before)==ident(after),'Metadata changed during read')
    observed=sha(data);require(valid_sha(digest) and observed==digest,'Metadata SHA mismatch: '+path.name)
    INPUTS[str(path)]={'path':str(path),'sha256':observed,'bytes':len(data)};check();return data

def valid_sha(value): return isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None
def fields(items):
    result={}
    for key,value in items:
        require(key not in result,'Duplicate metadata key');result[key]=value
    return result
def decode(data):
    def finite(text):
        value=float(text);require(math.isfinite(value),'Nonfinite JSON number');return value
    return json.loads(data,object_pairs_hook=fields,parse_float=finite,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('Nonfinite JSON')))
def load(path,digest): return decode(read(path,digest))
def jsonl(path,digest): return [decode(line) for line in read(path,digest,4*1024*1024).splitlines() if line.strip()]
def need(value,message): require(value,message)
def equal(a,b,label): same(a,b,label)
LANG=LANGS
def numeric(v): return type(v) in (int,float) and math.isfinite(v)
def integer(v): return type(v) is int and v>=0
def near(a,b): return numeric(a) and numeric(b) and math.isclose(a,b,rel_tol=1e-12,abs_tol=1e-12)

def register_pin(item):
    require(isinstance(item,dict) and isinstance(item.get('path'),str) and valid_sha(item.get('sha256')),'Explicit metadata descriptor required')
    p=item['path'];require(p not in EXTERNAL_PINS or EXTERNAL_PINS[p]==item['sha256'],'Conflicting metadata/source pin')
    EXTERNAL_PINS[p]=item['sha256']

def validate_paths(family):
    keys={'stage_directory','matrix_directory','matrix_json','matrix_cancel','guard_receipt','report_directory','report_json','assessment_directory','assessment_json','classification_receipt','freeze','final_plan'}
    for s in family['stages']:
        p=s.get('paths');require(isinstance(p,dict) and set(p)==keys and p['stage_directory']==str(R/s['id']),'Exact sealed stage.paths required')
        for key,value in p.items():
            if value is None:require(key in {'freeze','final_plan'} and s['stage']!='held_out','Unexpected null mapped path');continue
            require(isinstance(value,str) and Path(value).is_absolute() and R in Path(value).parents and '..' not in Path(value).parts,'Protected mapped path required')
        require(Path(p['matrix_json']).parent==Path(p['matrix_cancel']).parent==Path(p['matrix_directory']) and Path(p['report_json']).parent==Path(p['report_directory'])
          and Path(p['assessment_json']).parent==Path(p['assessment_directory']) and Path(p['classification_receipt']).name=='natural-failures.attempted-v2.json','Mapped writer/reader contract differs')

def same(a,b,label):
    if isinstance(b,dict):
        require(isinstance(a,dict) and set(a)==set(b),label+' dictionary shape')
        for k in b:same(a[k],b[k],label+'.'+k)
    elif isinstance(b,list):
        require(isinstance(a,list) and len(a)==len(b),label+' list shape')
        for x,y in zip(a,b):same(x,y,label)
    elif type(b) is float:require(near(a,b),label+' float value')
    else:require(type(a) is type(b) and a==b,label+' exact value')

def dist(values):
    values=sorted(float(v) for v in values if numeric(v) and v>=0)
    return {'measured_count':len(values),'median':statistics.median(values) if values else None,
            'minimum':values[0] if values else None,'maximum':values[-1] if values else None}

def good(row): return row.get('status') in GOOD and isinstance(row.get('measurement'),dict) and row['measurement'].get('status',row['status']) in GOOD
def case(row): return tuple(row[k] for k in ('id','source_sha256','reference_sha256','source_channel'))
def cohort(row): return tuple(row[k] for k in ('model','language_mode','language','task'))

def counted(rows,metric):
    prefix,unit=('character','reference_characters') if metric=='cer' else ('word','reference_words')
    values=[]
    for row in rows:
        m=row['measurement'];rate,errors,units=m.get(metric),m.get(prefix+'_errors'),m.get(unit)
        if not (numeric(rate) and rate>=0 and integer(errors) and type(units) is int and units>0):continue
        require(near(rate,errors/units),'Native counted rate mismatch')
        components=[m[prefix+'_'+op] for op in ('insertions','deletions','substitutions')]
        require(all(integer(v) for v in components) and sum(components)==errors,'Native edit-component sum mismatch')
        values.append((m,rate,errors,units));CHECKS['native_counted_rates']+=1
    return {'scored_unique_utterances':len(values),'errors':sum(v[2] for v in values) if values else None,
            'reference_units':sum(v[3] for v in values) if values else None,
            'corpus_weighted_rate':sum(v[2] for v in values)/sum(v[3] for v in values) if values else None,
            'macro_utterance_rate':statistics.mean(v[1] for v in values) if values else None,
            **{op:sum(v[0][prefix+'_'+op] for v in values) if values else None for op in ('insertions','deletions','substitutions')}}

def csv_rows(path,digest): return list(csv.DictReader(io.StringIO(read(path,digest).decode())))
def csv_same(actual,expected,label):
    require(set(actual)==set(expected),label+' columns differ')
    for key,value in expected.items():
        if value is None:require(actual[key]=='',label+' missing value replaced')
        elif type(value) is float:require(near(float(actual[key]),value),label+' rate/resource value differs')
        else:require(actual[key]==str(value),label+' exact field differs: '+key)

def csv_bytes(rows):
    s=io.StringIO(newline='');w=csv.DictWriter(s,fieldnames=list(rows[0]),lineterminator='\n');w.writeheader();w.writerows(rows);return s.getvalue().encode()


def threshold(v,limit,direction):
 if v is None:return None
 need(numeric(v),"Nonfinite threshold operand")
 return v+1e-12>=limit if direction=="min" else v<=limit+1e-12
def gate_counted(value,quota):
 need(value["planned_utterances"]==quota,"Counted planned quota differs")
 n=value["observed_scored_utterances"];need(type(n) is int and 0<=n<=quota,"Invalid scored denominator")
 if n==quota:
  e,u=value["errors"],value["reference_units"]
  need(type(e) is int and e>=0 and type(u) is int and u>0,"Invalid complete error/unit counts")
  equal(value["observed_errors"],e,"Complete observed errors")
  equal(value["observed_reference_units"],u,"Complete observed units")
  need(value["status"]=="complete_counted_rate","Complete status differs")
  ops=[value[x] for x in ("insertions","deletions","substitutions")]
  if all(type(x) is int for x in ops):need(all(x>=0 for x in ops) and sum(ops)==e,"Operation count arithmetic")
  rate=e/u;equal(value["rate"],rate,"Counted rate")
  return rate
 need(value["status"]=="inconclusive_missing_or_unscored_cases","Incomplete status differs")
 for key in ("rate","errors","reference_units","insertions","deletions","substitutions"):need(value[key] is None,"Missing planned data must remain null")
 return None
def contrast(value,plan,mode,baseline,candidate):
 cases=plan["cases"];quota=len(cases)//9
 equal(value["baseline_model"],baseline,"Contrast baseline lineage")
 equal(value["candidate_model"],candidate,"Contrast candidate lineage")
 per=value["per_language"]
 need(len(per)==9 and {p["language"] for p in per}==set(LANG),"Nine contrast languages required")
 per={p["language"]:p for p in per};rates={side:{"cer":[],"wer":[]} for side in ("baseline","candidate")}
 for lang in LANG:
  x=per[lang]
  for metric in ("cer","wer"):
   if lang=="zh" and metric=="wer":
    need(x["baseline"]["wer"] is None and x["candidate"]["wer"] is None,"Chinese whitespace WER must be absent")
    expected=None
   else:
    a,b=[gate_counted(x[side][metric],quota) for side in ("baseline","candidate")]
    rates["baseline"][metric].append(a);rates["candidate"][metric].append(b)
    expected=b-a if a is not None and b is not None else None
   equal(x[metric+"_delta"],expected,"Per-language delta")
 macros={}
 for metric,n in (("cer",9),("wer",8)):
  for side in ("baseline","candidate"):
   vals=rates[side][metric];need(len(vals)==n,"Macro language denominator")
   macros[side+"_macro_"+metric]=sum(vals)/n if all(v is not None for v in vals) else None
  a,b=macros["baseline_macro_"+metric],macros["candidate_macro_"+metric]
  macros[metric+"_relative_gain"]=(a-b)/a if a is not None and b is not None and a>0 else None
  macros["macro_"+metric+"_delta"]=b-a if a is not None and b is not None else None
 equal(value["macro_metrics"],macros,"Contrast macro arithmetic")
 labels=value["auto_labels"];entries=labels["cases"]
 need(labels["planned_cases"]==(len(cases) if mode=="auto" else 0),"Auto planned count")
 need(len(entries)==(len(cases) if mode=="auto" else 0),"Auto labels count")
 if mode=="auto":
  by={c["id"]:c for c in cases};need({e["id"] for e in entries}==set(by),"Auto case grid")
  for e in entries:
   lang=by[e["id"]]["language"];base=lang.split("-")[0];a,b=e["baseline"],e["candidate"]
   need(e["language"]==lang and e["expected_base"]==base,"Auto source/base label")
   need(all(x is None or isinstance(x,str) for x in (a,b)),"Auto observed label type")
   equal(e["newly_wrong"],a==base and b is not None and b!=base,"New wrong auto")
   equal(e["changed_already_wrong"],a is not None and b is not None and a!=base and b!=base and a!=b,"Already wrong auto")
 unknown=sum(e["baseline"] is None or e["candidate"] is None for e in entries)
 wrong=sum(e["newly_wrong"] for e in entries)
 equal(labels["unknown_cases"],unknown,"Unknown label count")
 equal(labels["newly_wrong_cases"],wrong,"New wrong count")
 equal(labels["changed_already_wrong_cases"],sum(e["changed_already_wrong"] for e in entries),"Changed wrong count")
 gate=(False if wrong else None if unknown else True) if mode=="auto" else True
 equal(value["no_new_wrong_auto_labels"],gate,"Auto tri-state gate")
 return macros,per,gate
def float_control(value,plan,mode):
 repeats=list(range(1,plan["repetitions"]+1)) if plan["stage"]=="panel" else [1]
 need(value["required_repeats"]==repeats,"Panel repeats")
 expected=set(itertools.product((c["id"] for c in plan["cases"]),repeats))
 entries=value["hypothesis_identity"]
 need(len(entries)==len(expected) and {(e["id"],e["repeat"]) for e in entries}==expected,"All required numerical hash pairs")
 need(all(e["identical_hypothesis_hash"] is None or type(e["identical_hypothesis_hash"]) is bool for e in entries),"Numerical tri-state flags")
 same=all(e["identical_hypothesis_hash"] is True for e in entries)
 equal(value["identical_required_hypothesis_hashes"],True if same else None,"Numerical hash identity")
 equal(value["observed_different_hypothesis_pairs"],sum(e["identical_hypothesis_hash"] is False for e in entries),"Different hash count")
 equal(value["unknown_hypothesis_pairs"],sum(e["identical_hypothesis_hash"] is None for e in entries),"Unknown hash count")
 equal(value["unknown_hypothesis_cases"],len({e["id"] for e in entries if e["identical_hypothesis_hash"] is None}),"Unknown hash cases")
 equal(value["planned_hypothesis_pairs"],len(expected),"Hash denominator")
 labels=value["auto_label_identity"]
 if mode=="auto":
  need(len(labels)==len(expected) and {(e["id"],e["repeat"]) for e in labels}==expected,"Panel all-repeat auto-label grid")
  for e in labels:equal(e["identical_observed_labels"],e["baseline"]==e["candidate"] if e["baseline"] is not None and e["candidate"] is not None else None,"Panel label identity")
  sl=all(e["identical_observed_labels"] is True for e in labels)
  equal(value["identical_required_auto_labels"],True if sl else None,"Panel auto identity")
 else:
  need(not labels and value["identical_required_auto_labels"]=="not_applicable_explicit_mode","Explicit panel labels not evidence")
  sl=True
 equal(value["planned_auto_label_pairs"],len(labels),"Panel label denominator")
 equal(value["status"],"observed_match_no_promotion" if same and sl else "inconclusive_no_promotion","Panel status")
 return same,sl
def mode_audit(m,plan):
 arms=plan["partition"].get("arms") or {"original":plan["partition"]["model"]}
 mode=m["language_mode"];c=m["coverage"];n=len(plan["cases"])*plan["repetitions"];family=plan["partition"]["kind"]=="family"
 need(c["planned_inference_cells"]==n*len(arms) and c["planned_native_parent_pair_cells"]==(n*3 if family else 0),"Planned cell/pair quotas")
 need(type(c["completed_inference_cells"]) is int and 0<=c["completed_inference_cells"]<=c["planned_inference_cells"],"Completed cell range")
 need(type(c["completed_native_parent_pair_cells"]) is int and 0<=c["completed_native_parent_pair_cells"]<=c["planned_native_parent_pair_cells"],"Completed pair range")
 byte_complete=True
 for role,arm in arms.items():
  b=m["artifact_bytes"][role]
  need(b["id"]==arm["id"] and b["sha256"]==arm["sha256"] and b["frozen_model_file_bytes"]==arm["model_file_bytes"] and b["planned_cells"]==n,"Arm bytes/identity")
  k=b["measured_byte_cells"];need(type(k) is int and 0<=k<=n,"Byte evidence denominator")
  equal(b["observed_model_file_bytes"],arm["model_file_bytes"] if k==n else None,"Observed size cannot be invented")
  byte_complete=byte_complete and k==n
 gates={"complete_planned_inference_grid":True if c["completed_inference_cells"]==c["planned_inference_cells"] else None,
 "complete_native_parent_pair_grid":True if c["completed_native_parent_pair_cells"]==c["planned_native_parent_pair_cells"] else None,
 "complete_artifact_byte_evidence":True if byte_complete else None}
 if not family:
  need(c["legacy_unpaired_reference_placeholders"]==n,"Reference placeholder denominator")
  ref=m["reference_metrics"];per={p["language"]:p for p in ref["per_language"]}
  for metric,langs in (("cer",LANG),("wer",tuple(l for l in LANG if l!="zh"))):
   vals=[gate_counted(per[l][metric],len(plan["cases"])//9) for l in langs]
   expected=sum(vals)/len(langs) if all(v is not None for v in vals) else None
   equal(ref["macro_"+metric],expected,"Reference macro")
  decision="reference_observed_no_promotion" if all(v is True for v in gates.values()) else "inconclusive_no_promotion"
  equal(m["gates"],gates,"Reference gates");equal(m["decision"],decision,"Reference decision")
  return gates,None
 native={}
 for role in ("permuted_f16","plain_q4","permuted_q4"):
  v=m["native_parent_contrasts"][role]
  need(v["baseline_arm"]=="original" and v["candidate_arm"]==role and v["baseline_model_kind"]=="pretrained" and v["candidate_model_kind"]==KINDS[role],"Native original-parent kinds")
  native[role]=contrast(v,plan,mode,arms["original"],arms[role])
 direct=m["permuted_q4_vs_plain_q4"]
 need(direct["baseline_arm"]=="plain_q4" and direct["candidate_arm"]=="permuted_q4" and direct["baseline_model_kind"]=="compression" and direct["candidate_model_kind"]=="combined","Q4 direct contrast must never claim untouched")
 d=contrast(direct,plan,mode,arms["plain_q4"],arms["permuted_q4"])
 for lang in LANG:
  for role in ("plain_q4","permuted_q4"):
   equal(native[role][1][lang]["candidate"],d[1][lang]["baseline" if role=="plain_q4" else "candidate"],"Direct/native counted identity")
  for role in ("plain_q4","permuted_q4"):
   equal(native[role][1][lang]["baseline"],native["permuted_f16"][1][lang]["baseline"],"Original counts invariant")
 hs,ls=float_control(m["permuted_f16_control"],plan,mode)
 ob,qb=[m["artifact_bytes"][role]["observed_model_file_bytes"] for role in ("original","permuted_q4")]
 saving=1-qb/ob if ob is not None and qb is not None else None
 equal(m["model_file_saving_vs_original"],saving,"Physical byte saving")
 if plan["stage"]=="panel":
  gates["permuted_f16_identical_required_hypothesis_hashes"]=True if hs else None
  if mode=="auto":gates["permuted_f16_identical_required_auto_labels"]=True if ls else None
  decision="continue_no_promotion" if all(v is True for v in gates.values()) else "inconclusive_no_promotion"
 else:
  gates.update(ai_macro_cer_gain_at_least_10_percent=threshold(d[0]["cer_relative_gain"],.10,"min"),
   ai_macro_wer_gain_at_least_5_percent=threshold(d[0]["wer_relative_gain"],.05,"min"),
   original_macro_cer_increase_at_most_0_0025=threshold(native["permuted_q4"][0]["macro_cer_delta"],.0025,"max"),
   original_macro_wer_increase_at_most_0_005=threshold(native["permuted_q4"][0]["macro_wer_delta"],.005,"max"),
   model_file_saving_at_least_65_percent=threshold(saving,.65,"min"))
  for name,v in (("original",native["permuted_q4"]),("plain_q4",d)):
   gates[name+"_no_new_wrong_auto_base_labels"]=v[2]
   for lang in LANG:
    gates[name+"_"+lang+"_cer_increase_at_most_0_01"]=threshold(v[1][lang]["cer_delta"],.01,"max")
    if lang!="zh":gates[name+"_"+lang+"_wer_increase_at_most_0_02"]=threshold(v[1][lang]["wer_delta"],.02,"max")
  decision="reject" if any(v is False for v in gates.values()) else "inconclusive_no_promotion" if any(v is None for v in gates.values()) else "continue_no_promotion"
 equal(m["gates"],gates,"Frozen gate keyset/tri-state")
 equal(m["decision"],decision,"Mode decision")
 return gates,{"model_family":plan["partition"]["id"],"stage":plan["stage"],"language_mode":mode,"decision":decision,
  "direct_q4_relative_cer_gain":d[0]["cer_relative_gain"],"direct_q4_relative_wer_gain":d[0]["wer_relative_gain"],
  "original_f16_macro_cer_delta":native["permuted_q4"][0]["macro_cer_delta"],"original_f16_macro_wer_delta":native["permuted_q4"][0]["macro_wer_delta"],
  "plain_q4_vs_original_relative_cer_gain":native["plain_q4"][0]["cer_relative_gain"],"plain_q4_vs_original_relative_wer_gain":native["plain_q4"][0]["wer_relative_gain"],
  "permuted_f16_vs_original_macro_cer_delta":native["permuted_f16"][0]["macro_cer_delta"],"permuted_f16_vs_original_macro_wer_delta":native["permuted_f16"][0]["macro_wer_delta"],
  "model_file_saving_vs_original":saving,"false_gates":[k for k,v in gates.items() if v is False],
  "unknown_gates":[k for k,v in gates.items() if v is None],"numerical_control_required_repeats":m["permuted_f16_control"]["required_repeats"],"numerical_control_scope":m["permuted_f16_control"]["scope"],"numerical_control_hash_match":hs,"numerical_control_label_match":ls,
  "frozen_numerical_control_status":m["permuted_f16_control"]["status"],
  "observed_different_hypothesis_pairs":m["permuted_f16_control"]["observed_different_hypothesis_pairs"],
  "unknown_hypothesis_pairs":m["permuted_f16_control"]["unknown_hypothesis_pairs"],
  "observed_different_auto_label_pairs":sum(e["identical_observed_labels"] is False for e in m["permuted_f16_control"]["auto_label_identity"]),
  "unknown_auto_label_pairs":sum(e["identical_observed_labels"] is None for e in m["permuted_f16_control"]["auto_label_identity"]),
  "numerical_control_observation_classification":"observed_match" if hs and ls else "observed_difference" if m["permuted_f16_control"]["observed_different_hypothesis_pairs"] or any(e["identical_observed_labels"] is False for e in m["permuted_f16_control"]["auto_label_identity"]) else "unknown_evidence"}

# CONTEXT_AND_BINDINGS

def automatic(row):
    if row is None or not good(row):return None,'missing_or_failed_repeat_1'
    m=row['measurement']
    if m.get('hypothesis_sha256')==sha(b''):return None,'exact_empty_hypothesis_hash'
    passes=m.get('engine_passes')
    if not isinstance(passes,list) or not passes:return None,'missing_native_pass'
    if len(passes)!=1:return None,'ambiguous_multiple_engine_passes'
    p=passes[0]
    if not isinstance(p,dict) or p.get('engine')!='whisper.cpp':return None,'not_a_direct_native_pass'
    if 'channel_regions' in p:return None,'ambiguous_region_invocations'
    policy=p.get('language_policy')
    if not isinstance(policy,dict):return None,'missing_structured_language_policy'
    if p.get('asr_language')!='auto' or policy.get('effective_argument')!='auto':return None,'not_an_automatic_native_invocation'
    label=policy.get('recognizer_language')
    base=label.split('-',1)[0] if isinstance(label,str) and re.fullmatch(r'[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*',label) else None
    if base in {'auto','und','mul','zxx'}:base=None
    if base is None:return None,'no_structured_nonempty_speech_label'
    return base,None

def assessment_counted(rows,quota,metric):
    c=counted([r for r in rows if good(r)],metric);complete=c['scored_unique_utterances']==quota
    return {'planned_utterances':quota,'observed_scored_utterances':c['scored_unique_utterances'],
        'rate':c['corpus_weighted_rate'] if complete else None,
        **{k:c[k] if complete else None for k in ('errors','reference_units','insertions','deletions','substitutions')},
        'observed_errors':c['errors'],'observed_reference_units':c['reference_units'],
        'status':'complete_counted_rate' if complete else 'inconclusive_missing_or_unscored_cases'}

def bind_gate_inputs(assessment,plan,matrix):
    """Tie every gate operand to canonical native rows, never retained prose."""
    rows={(r['id'],r['model'],r['language_mode'],r['repeat']):r for r in matrix['rows']}
    def per_language(observed,baseline,candidate=None):
        require(len(observed)==9 and {v['language'] for v in observed}==set(LANGS),'Gate nine-language operands')
        for entry in observed:
            lang=entry['language'];selected=[c for c in plan['cases'] if c['language']==lang]
            for side,model in [('baseline',baseline),('candidate',candidate)] if candidate else [(None,baseline)]:
                actual=entry[side] if side else entry
                cells=[rows[(c['id'],model['id'],mode,1)] for c in selected]
                for metric in ('cer','wer'):
                    same(actual[metric],None if lang=='zh' and metric=='wer' else assessment_counted(cells,len(selected),metric),'Gate native counted operand')
    for value in assessment['model_mode_assessments']:
        mode=value['language_mode'];arms=plan['partition'].get('arms') or {'original':plan['partition']['model']}
        selected=[r for r in matrix['rows'] if r['language_mode']==mode];coverage=value['coverage']
        require(coverage['planned_inference_cells']==len(selected) and coverage['completed_inference_cells']==sum(good(r) for r in selected),'Mode native success denominator differs')
        native_pairs=[p for p in matrix['paired_comparisons'] if p['language_mode']==mode]
        is_family=plan['partition']['kind']=='family'
        require(coverage['planned_native_parent_pair_cells']==(len(native_pairs) if is_family else 0)
            and coverage['completed_native_parent_pair_cells']==sum(p['status']=='paired_exploratory' for p in native_pairs),'Mode native pair denominator differs')
        for role,model in arms.items():
            observed=0
            for r in selected:
                if r['model']!=model['id']:continue
                sizes=[x.get('model_file_bytes') for x in (r.get('artifact_metrics'),(r.get('measurement') or {}).get('artifact_metrics')) if isinstance(x,dict) and x.get('model_file_bytes') is not None]
                require(all(type(x) is int and x==model['model_file_bytes'] and x>0 for x in sizes),'Actual measured file-byte observation differs')
                observed+=bool(sizes)
            require(value['artifact_bytes'][role]['measured_byte_cells']==observed,'Measured artifact byte-cell denominator differs')
        contrasts=list(value.get('native_parent_contrasts',{}).values())
        if 'permuted_q4_vs_plain_q4' in value:contrasts.append(value['permuted_q4_vs_plain_q4'])
        if not contrasts:
            per_language(value['reference_metrics']['per_language'],arms['original'])
            automatic_entries=value['reference_metrics']['automatic_labels']
            require(len(automatic_entries)==(len(plan['cases']) if mode=='auto' else 0),'Reference automatic label denominator differs')
            if mode=='auto':
                indexed={e['id']:e for e in automatic_entries};require(len(indexed)==len(automatic_entries) and set(indexed)=={c['id'] for c in plan['cases']},'Reference automatic case grid differs')
                for c in plan['cases']:
                    label,reason=automatic(rows[(c['id'],arms['original']['id'],mode,1)])
                    same(indexed[c['id']],{'id':c['id'],'language':c['language'],'expected_base':c['language'].split('-')[0],'observed':label,'unknown_reason':reason},'Reference native automatic evidence')
        for contrast_value in contrasts:
            before,after=contrast_value['baseline_model'],contrast_value['candidate_model']
            per_language(contrast_value['per_language'],before,after)
            expected_pairs=sum(good(rows[(c['id'],before['id'],mode,r)]) and good(rows[(c['id'],after['id'],mode,r)]) for c in plan['cases'] for r in range(1,plan['repetitions']+1))
            same(contrast_value['canonical_row_pairs'],{'planned_pair_cells':len(plan['cases'])*plan['repetitions'],'completed_pair_cells':expected_pairs,'quality_unique_pairs_planned':len(plan['cases']),'quality_repeat':1},'Canonical pair coverage')
            if contrast_value is value.get('permuted_q4_vs_plain_q4'):
                require(coverage['planned_assessor_derived_q4_pair_cells']==len(plan['cases'])*plan['repetitions']
                    and coverage['completed_assessor_derived_q4_pair_cells']==expected_pairs,'Mode sibling Q4 contrast denominator differs')
            hashes={e['id']:e for e in contrast_value['hypothesis_identity']}
            require(len(hashes)==len(contrast_value['hypothesis_identity']),'Duplicate contrast hypothesis evidence')
            require(set(hashes)=={c['id'] for c in plan['cases']},'Canonical hypothesis grid')
            labels={e['id']:e for e in contrast_value['auto_labels']['cases']}
            for c in plan['cases']:
                a,b=[rows[(c['id'],m['id'],mode,1)] for m in (before,after)]
                hs=[r['measurement'].get('hypothesis_sha256') if good(r) else None for r in (a,b)]
                expected_hash=hs[0]==hs[1] if all(valid_sha(h) for h in hs) else None
                same(hashes[c['id']],{'id':c['id'],'language':c['language'],'identical_hypothesis_hash':expected_hash},'Canonical native hypothesis identity')
                if mode=='auto':
                    al,ar=automatic(a);bl,br=automatic(b);entry=labels[c['id']]
                    require(entry['baseline']==al and entry['candidate']==bl and entry['baseline_unknown_reason']==ar and entry['candidate_unknown_reason']==br,'Canonical automatic native label/reason differs')
        control=value.get('permuted_f16_control')
        if control:
            for e in control['hypothesis_identity']:
                require(e['language']==next(c['language'] for c in plan['cases'] if c['id']==e['id']),'Numerical source language differs')
                pair=[rows[(e['id'],arms[role]['id'],mode,e['repeat'])] for role in ('original','permuted_f16')]
                hs=[r['measurement'].get('hypothesis_sha256') if good(r) else None for r in pair]
                same(e['identical_hypothesis_hash'],hs[0]==hs[1] if all(valid_sha(h) for h in hs) else None,'Numerical native hypothesis identity')
            for e in control['auto_label_identity']:
                a,ar=automatic(rows[(e['id'],arms['original']['id'],mode,e['repeat'])]);b,br=automatic(rows[(e['id'],arms['permuted_f16']['id'],mode,e['repeat'])])
                require(e['baseline']==a and e['candidate']==b and e['baseline_unknown_reason']==ar and e['candidate_unknown_reason']==br,'All-repeat native label evidence differs')

def barrier(family,events):
    require(family.get('schema_version')=='mlp-permutation-family-pre-inference-v1' and [s['id'] for s in family['stages']]==IDS,'Frozen family schema/order differs')
    require((family['planned_cells'],family['planned_native_parent_pairs'],family['planned_assessor_derived_q4_pairs'],family['planned_reference_runtime_placeholders'])==(4554,2484,828,1242),'Frozen planned totals differ')
    require(events and events[0].get('event')=='serial_started' and events[-1].get('event')=='serial_finished'
        and sum(e.get('event')=='serial_started' for e in events)==sum(e.get('event')=='serial_finished' for e in events)==1
        and not any(e.get('event') in {'serial_stopped','owned_guard_cleanup_pending'} for e in events),'All15 terminal barrier not satisfied; no outcome reads')
    start,end=events[0],events[-1]
    require(start.get('family_seal_sha256')==end.get('family_seal_sha256')==FAMILY_SHA
        and start.get('coordinator_sha256')==family['tools']['coordinator']['sha256']
        and start.get('initial_attestation')==end.get('initial_attestation'),'Final source/admission identities differ')
    assessed=[e for e in events if e.get('event')=='stage_assessed']
    launches=[e for e in events if e.get('event')=='command_start' and e.get('action')=='guarded_inference']
    ends=[e for e in events if e.get('event')=='command_finished' and e.get('action')=='guarded_inference']
    require([e.get('id') for e in assessed]==[e.get('stage') for e in launches]==[e.get('stage') for e in ends]==IDS,'All15 unique launch/end/assessment grid required')
    previous=0
    for s,e,launch,finish in zip(family['stages'],assessed,launches,ends):
        require(previous<events.index(launch)<events.index(finish)<events.index(e),'Serial launch/end/assessment chronology differs');previous=events.index(e)
        require(e.get('stage')==s['stage'] and e.get('analysis_source')==family['tools']['assessor'] and e.get('default_promotion') is False,'Stage source decision binding differs')
        require(all(valid_sha(e.get(k)) for k in ('matrix_sha256','report_sha256','assessment_sha256','guard_sha256','plan_sha256')),'Stage digest absent')
        require(all(integer(e.get(k)) for k in FIELDS) and e['planned_cells']==e['attempted_cells']==s['planned_cells']
            and e['completed_cells']+e['failed_cells']==s['planned_cells']
            and type(finish.get('returncode')) is int and finish['returncode']==int(e['failed_cells']>0),'Terminal attempts/return code differs')
    accepts=[e for e in events if e.get('event')=='heldout_family_accepted'];require(len(accepts)==1,'All-five release missing/duplicated');accept=accepts[0]
    require(events.index(assessed[9])<events.index(accept)<events.index(launches[10]) and valid_sha(accept.get('freeze_sha256'))
        and accept.get('family_seal_sha256')==FAMILY_SHA and accept.get('analysis_source')==family['tools']['assessor']
        and accept.get('initial_attestation')==start['initial_attestation'],'All10 before all5 frozen chronology differs')
    totals={k:sum(e[k] for e in assessed) for k in FIELDS}
    require(all(integer(end.get(k)) and end[k]==v for k,v in totals.items()) and totals['attempted_cells']==4554
        and totals['planned_native_parent_pairs']==totals['completed_native_parent_pairs']+totals['pending_native_parent_pairs']==2484
        and totals['planned_assessor_derived_q4_pairs']==totals['completed_assessor_derived_q4_pairs']+totals['pending_assessor_derived_q4_pairs']==828
        and totals['runtime_reference_placeholders']==1242 and end.get('default_promotion') is False
        and end.get('status')==('completed_with_failures' if totals['failed_cells'] else 'completed'),'Final exact totals differ')
    return assessed,accept,totals

def held_provenance(family,events,accept):
    held=load(Path(family['paths']['heldout_family_freeze']),accept['freeze_sha256'])
    require(held.get('schema_version')=='mlp-permutation-heldout-family-freeze-v1'
        and held.get('original_family_seal_sha256')==FAMILY_SHA and held.get('analysis_source')==family['tools']['assessor']
        and held.get('initial_attestation')==events[0]['initial_attestation'] and held.get('fresh_heldout_reference_content_inspected') is False
        and held.get('heldout_outcomes_used_for_selection') is False and held.get('default_promotion') is False,'Held family source/preservation policy differs')
    for key in ('budgets','permutation','quantization'):same(held[key],family[key],'Held '+key)
    expected=[{k:s[k] for k in ('id','corpus_sha256','configuration_sha256','assessment_pre_freeze_plan_sha256','models')} for s in family['stages'][10:]]
    same(held['all_heldout_partitions'],expected,'All-five frozen source/model descriptors')
    same(held['partitions'],accept['partitions'],'Journal all-five partition links')
    history=held['development_history'];prior=[e for e in events if e.get('event')=='stage_assessed'][:10]
    require(len(history)==10 and all(all(e.get(k)==v for k,v in h.items()) for h,e in zip(history,prior)),'All10 terminal history changed')
    require([p['id'] for p in held['partitions']]==IDS[10:] and all(all(valid_sha(p.get(k)) for k in ('freeze_sha256','final_plan_sha256','configuration_sha256','corpus_sha256','pre_freeze_plan_sha256')) for p in held['partitions']),'Held digest grid differs')
    return held,{p['id']:p for p in held['partitions']}

def static_metadata_provenance(family,admission,events):
    """Retain data-amendment/export seals without any payload-path traversal."""
    source_pin=family['inputs']['corpus_sources'];sources=load(Path(source_pin['path']),source_pin['sha256'])
    require(sources.get('schema_version')=='round5-corpus-source-receipt-v1' and sources.get('state')=='completed'
        and sources.get('opaque') is True and sources.get('reference_text_semantically_inspected') is False
        and (sources.get('development_cases'),sources.get('held_out_cases'),sources.get('case_count'))==(72,144,216)
        and sources.get('native_human_approval') is False and sources.get('approved_v2_corpus') is False,'Fresh opaque completed corpus policy differs')
    for role in ('panel','development','held_out','integrity'):
        expected=family['inputs'][{'panel':'panel_corpus','development':'development_corpus','held_out':'held_out_corpus','integrity':'integrity'}[role]]
        require(sources[role]['path']==expected['path'] and sources[role]['sha256']==expected['sha256'],'Data source descriptor '+role)
    records={}
    for role in ('acquisition_freeze','acquisition_stop','completion_freeze','completion_receipt','assembly_receipt'):
        d=family['inputs'][role];same(sources[role],d,'Data amendment receipt '+role)
        records[role]=load(Path(d['path']),d['sha256'])
    require(records['assembly_receipt'].get('status')=='COMPLETED_METADATA_ONLY' and records['assembly_receipt'].get('initial_case_objects_unchanged')==192
      and records['assembly_receipt'].get('new_swiss_case_objects_unchanged')==24 and records['assembly_receipt'].get('audio_reference_copies_links_or_overwrites') is False,'Opaque assembly state differs')
    guard_pin=family['inputs']['corpus_integrity_guard'];g=jsonl(Path(guard_pin['path']),guard_pin['sha256']);last=g[-1];shutdown=last.get('shutdown',{})
    require(g[0].get('event')=='starting' and last.get('event')=='finished' and last.get('canceled') is False and last.get('reason') is None and last.get('failure') is None
      and shutdown.get('returncode')==0 and type(shutdown.get('returncode')) is int and shutdown.get('cli_reaped') is True and shutdown.get('owned_session_present') is False
      and shutdown.get('shutdown_errors')==[] and not any(v.get('event') in {'owned_group_signal','owned_cli_signal','cancel_requested','interrupted','cancelled'} for v in g),'Corpus assembly guard differs')
    require(numeric(last.get('time')),'Actual assembly guard timestamp required')
    assembly_time=datetime.fromtimestamp(last['time'],timezone.utc).isoformat()
    stamps=[records['acquisition_freeze']['created_utc'],records['completion_freeze']['created_utc'],assembly_time,family['created_utc'],admission['created_utc'],events[0]['created_utc']]
    dates=[datetime.fromisoformat(t.replace('Z','+00:00')) for t in stamps]
    require(all(t.tzinfo is not None for t in dates) and dates==sorted(dates),'Prospective data/model/launch chronology differs')
    static_pin=admission['independent_static_audit'];native_static=load(Path(static_pin['path']),static_pin['sha256'])
    require(native_static.get('schema_version')=='round5-independent-pre-inference-audit-v1' and native_static.get('status')=='PASSED_STATIC_PROVENANCE_ONLY_NO_QUALITY_CLAIM'
      and native_static.get('family',{}).get('sha256')==FAMILY_SHA,'Independent pre-inference static audit receipt differs')
    receipt=load(Path(family['artifact_family_receipt']['path']),family['artifact_family_receipt']['sha256'])
    require(receipt.get('schema_version')=='round5-artifact-family-v1' and receipt.get('state')=='completed','Artifact family receipt differs')
    for name,roles in family['artifacts'].items():
        require(name in ADAPTED and set(roles)==set(KINDS),'Frozen artifact role family differs')
        for role,model in roles.items():
            if role=='original':continue
            for key in ('audit','guard','permutation_plan','plan'):
                if key not in model:continue
                d=model[key];path=Path(d['path'])
                register_pin(d);require(path.suffix in {'.json','.jsonl'},'Only explicit export audit metadata may be followed')
                read(path,d['sha256'])
    return {'corpus_source_receipt_sha256':family['inputs']['corpus_sources']['sha256'],
        'fresh_integrity_sha256':family['fresh_integrity_sha256'],'fresh_integrity_payloads_rehashed_here':False,
        'independent_preflight_receipt_sha256':static_pin['sha256'],
        'artifact_family_receipt_sha256':family['artifact_family_receipt']['sha256'],'data_completion_is_separate_prospective_amendment':True,
        'source_data_artifact_family_launch_order':stamps,'payload_postrun_rehash_authority':'Separate parent/root retained audit required'}

def preservation_provenance(family,events,journal_sha,receipt_sha,guard_sha,admission):
    """Verify the parent's completed opaque authority; never reopen its payloads."""
    frozen=load(Path(OPTIONS.preservation_freeze),PRESERVATION_FREEZE_SHA)
    require(frozen.get('schema_version')=='round5-postrun-preservation-freeze-v1'
        and frozen.get('source',{}).get('sha256')==PRESERVATION_SOURCE_SHA and frozen.get('dynamic_cli_pins') is True
        and frozen.get('mandatory_all15_terminal_barrier') is True and frozen.get('campaign_outcomes_read') is False
        and frozen.get('default_promotion') is False,'Prospective opaque-preservation operation differs')
    read(Path(OPTIONS.preservation_source),PRESERVATION_SOURCE_SHA,1024*1024)
    value=load(Path(OPTIONS.preservation_receipt),receipt_sha)
    guard=jsonl(Path(OPTIONS.preservation_guard),guard_sha)
    require(guard and guard[0].get('event')=='starting' and guard[0].get('foreign_cpu_limit')==1000
        and not any(e.get('event') in {'owned_group_signal','owned_cli_signal','cancel_requested','interrupted','cancelled'} for e in guard),'Post-run capture/cancellation guard differs')
    last=guard[-1];shutdown=last.get('shutdown',{})
    require(last.get('event')=='finished' and last.get('canceled') is False and all(last.get(k) is None for k in ('reason','failure','guard_observation'))
        and type(shutdown.get('returncode')) is int and shutdown['returncode']==0 and shutdown.get('cli_reaped') is True
        and shutdown.get('owned_session_present') is False and shutdown.get('shutdown_errors')==[],'Post-run preservation guard did not close cleanly')
    command=guard[0].get('command',[])
    for key,expected in (('--family-seal-sha256',FAMILY_SHA),('--admission-capsule-sha256',ADMISSION_SHA),('--journal-sha256',journal_sha),
      ('--integrity-sha256',family['inputs']['integrity']['sha256']),('--operation-freeze-sha256',PRESERVATION_FREEZE_SHA),
      ('--expected-source-sha256',PRESERVATION_SOURCE_SHA),('--output',str(Path(OPTIONS.preservation_receipt).parent))):
        require(isinstance(command,list) and command.count(key)==1 and command.index(key)+1<len(command) and command[command.index(key)+1]==expected,'Actual opaque authority CLI binding differs '+key)
    require(value.get('schema_version')=='round5-postrun-opaque-preservation-v1' and value.get('status')=='PASS_OPAQUE_INPUT_AND_RETAINED_OUTPUT_HASHES'
        and value.get('source',{}).get('sha256')==PRESERVATION_SOURCE_SHA and value.get('family_seal_sha256')==FAMILY_SHA
        and value.get('final_journal_sha256')==journal_sha and value.get('admission_sha256')==ADMISSION_SHA
        and value.get('fresh_integrity_sha256')==family['inputs']['integrity']['sha256'] and value.get('operation_freeze_sha256')==PRESERVATION_FREEZE_SHA and value.get('native_review')=='PENDING'
        and value.get('controlled_resource_acceptance')=='NOT_EVALUATED' and value.get('default_promotion') is False
        and all(value.get(k) is False for k in ('training','recognition','rescoring','reference_or_transcript_semantic_decode','input_or_output_bytes_modified')),'Opaque preservation authority source/semantic claims differ')
    inputs=value.get('frozen_inputs');outputs=value.get('retained_outputs')
    require(isinstance(inputs,list) and isinstance(outputs,list) and inputs and outputs
        and type(value.get('frozen_input_count')) is int and value['frozen_input_count']==len(inputs)
        and type(value.get('retained_output_count')) is int and value['retained_output_count']==len(outputs),'Opaque preservation inventory counts differ')
    imap={v['path']:v for v in inputs};omap={v['path']:v for v in outputs}
    require(len(imap)==len(inputs) and len(omap)==len(outputs)
        and all(valid_sha(v.get('sha256')) and integer(v.get('bytes')) and isinstance(v.get('path'),str) and Path(v['path']).is_absolute() for v in inputs+outputs),'Opaque preservation inventory descriptor shape differs')
    for pin in family['immutable_files']:
        require(pin['path'] in imap and imap[pin['path']]['sha256']==pin['sha256'],'Frozen input absent from completed opaque authority')
    panel_pin=admission['source_payload_inventory'];register_pin(panel_pin);panel=load(Path(panel_pin['path']),panel_pin['sha256'])
    require(panel.get('schema_version')=='round5-panel-source-payload-inventory-v1' and panel.get('case_count')==len(panel.get('cases',[]))==9
      and panel.get('reference_or_audio_semantic_decode') is False and panel.get('recognition_performed') is False and isinstance(panel.get('pending'),list),'Opaque panel9 inventory API differs')
    for item in panel['payloads']:
        require(item['path'] in imap and imap[item['path']]['sha256']==item['sha256'],'Panel payload absent from post-run opaque authority')
    coverage=value.get('source_case_coverage',{})
    same(coverage,{'fresh_cases':216,'panel_cases':9,'distinct_source_cases':225,'panel_inventory_sha256':panel_pin['sha256'],
      'panel_pending':panel['pending'],'complete_panel_payload_evidence':not panel['pending']},'225-case opaque input scope')
    for model in family['models']:
        require(model['path'] in imap and imap[model['path']]['sha256']==model['sha256'] and imap[model['path']]['bytes']==model['model_file_bytes'],'Model identity/bytes absent from post-run opaque authority')
    mapped={s['id']:s for s in family['stages']}
    for event in (e for e in events if e.get('event')=='stage_assessed'):
        path=mapped[event['id']]['paths']['matrix_json']
        require(path in omap and omap[path]['sha256']==event['matrix_sha256'] and omap[path]['bytes']>0,'Retained output matrix digest absent from opaque authority')
    held=next(e for e in events if e.get('event')=='command_start' and e.get('action')=='guarded_inference' and e.get('stage')==IDS[0])
    before=datetime.fromisoformat(frozen['created_utc'].replace('Z','+00:00'));first_held=datetime.fromisoformat(held['created_utc'].replace('Z','+00:00'))
    after=datetime.fromisoformat(value['created_utc'].replace('Z','+00:00'));finish=datetime.fromisoformat(events[-1]['created_utc'].replace('Z','+00:00'))
    require(all(v.tzinfo is not None for v in (before,first_held,after,finish)) and before<first_held and finish<=after,'Opaque authority must freeze before ANY quality and execute after final terminal chronology')
    return {'operation_freeze_sha256':PRESERVATION_FREEZE_SHA,'source_sha256':PRESERVATION_SOURCE_SHA,'receipt_sha256':receipt_sha,'guard_sha256':guard_sha,
        'frozen_inputs':len(inputs),'retained_outputs':len(outputs),'source_case_coverage':coverage,'payload_paths_reopened_here':False,'status':value['status']}

def native_identity(value,row,execution):
    observed=0;expected='auto' if row['language_mode']=='auto' else row['language'].split('-')[0]
    if isinstance(value,dict):
        if value.get('engine')=='whisper.cpp':
            require(value.get('binary_sha256')==execution['whisper_binary_sha256'] and value.get('model_sha256')==row['model_sha256']
                and value.get('vad_model_sha256') is None and value.get('decoding',{}).get('profile_sha256')==execution['runtime_settings_sha256'],'Native binary/model/VAD/settings identity differs')
            require(value.get('asr_language')==expected and value.get('language_policy',{}).get('effective_argument')==expected,'Native configured language differs')
            command=value.get('command');require(isinstance(command,list) and command and all(isinstance(x,str) for x in command),'Native command absent')
            args=[]
            for i,arg in enumerate(command[1:],1):
                if arg in ('-l','--language'):
                    require(i+1<len(command) and command[i+1] and not command[i+1].startswith('-'),'Native language option malformed');args.append(command[i+1])
                require(not arg.startswith(('--language=','-l=')),'Unpinned language option syntax')
            require(args==[expected],'Actual native language argument differs');observed+=1
        for child in value.values():observed+=native_identity(child,row,execution)
    elif isinstance(value,list):
        for child in value:observed+=native_identity(child,row,execution)
    return observed

def planned_arm_models(partition):
    """Plan arms omit kind; the frozen role contract supplies that meaning."""
    arms=partition['arms'] if partition['kind']=='family' else {'original':partition['model']}
    require(set(arms)==(set(KINDS) if partition['kind']=='family' else {'original'}),'Plan role contract differs')
    result={model['id']:(role,model,KINDS[role]) for role,model in arms.items()}
    require(len(result)==len(arms),'Duplicate planned artifact ID');return arms,result

def stage_provenance(family,s,event,held,bindings):
    paths=s['paths'];folder=Path(paths['stage_directory']);pre=load(Path(s['assessment_pre_freeze_plan']),s['assessment_pre_freeze_plan_sha256']);plan=pre
    if s['stage']=='held_out':
        binding=bindings[s['id']];freeze=load(Path(paths['freeze']),binding['freeze_sha256']);plan=load(Path(paths['final_plan']),binding['final_plan_sha256'])
        require(freeze.get('original_family_seal_sha256')==FAMILY_SHA and freeze.get('frozen_before_held_out') is True
            and freeze.get('initial_attestation')==held['initial_attestation'] and freeze.get('analysis_source')==family['tools']['assessor'],'Held partition policy differs')
        for key in ('budgets','permutation','quantization','all_heldout_partitions','development_history'):same(freeze[key],held[key],'Held partition '+key)
        require(binding['configuration_sha256']==s['configuration_sha256'] and binding['corpus_sha256']==s['corpus_sha256']
            and binding['pre_freeze_plan_sha256']==s['assessment_pre_freeze_plan_sha256']
            and plan.get('pre_freeze_family_seal_sha256')==FAMILY_SHA and plan.get('pre_freeze_plan_sha256')==s['assessment_pre_freeze_plan_sha256']
            and plan['execution'].get('freeze_sha256')==binding['freeze_sha256'],'Held final link differs')
        stripped=json.loads(json.dumps(plan));stripped['execution'].pop('freeze_sha256');stripped.pop('pre_freeze_family_seal_sha256');stripped.pop('pre_freeze_plan_sha256')
        same(stripped,pre,'Only three final plan links may change')
    else:require(event['plan_sha256']==s['assessment_pre_freeze_plan_sha256'],'Preplan SHA differs')
    require(INPUTS[str(Path(paths['final_plan']) if s['stage']=='held_out' else Path(s['assessment_pre_freeze_plan']))]['sha256']==event['plan_sha256'],'Journal final plan binding differs')
    require(plan.get('schema_version')=='mlp-permutation-assessment-plan-v1' and plan['runtime_record']==family['runtime_record'],'Plan/runtime version differs')
    for key in ('permutation','quantization'):same(plan[key],family[key],'Plan '+key)
    for path_key,digest_key in (('corpus','corpus_sha256'),('source_snapshot','source_snapshot_sha256')):
        # Hash opaque manifest bytes only; do not decode references or follow their paths.
        read(Path(s[path_key]),s[digest_key])
    config=load(Path(s['configuration']),s['configuration_sha256']);require(isinstance(config,dict),'Config snapshot shape differs')
    runtime=load(Path(family['runtime_record']['path']),family['runtime_record']['sha256']);execution=plan['execution']
    require(runtime['runner_sha256']==execution['runner_sha256'] and any(v.get('sha256')==execution['whisper_binary_sha256'] and v.get('path','').endswith('/whisper-cli') for v in runtime['files']),'Runtime binary/runner metadata differs')
    matrix=load(Path(paths['matrix_json']),event['matrix_sha256']);report=load(Path(paths['report_json']),event['report_sha256']);assessment=load(Path(paths['assessment_json']),event['assessment_sha256'])
    guards=jsonl(Path(paths['guard_receipt']),event['guard_sha256'])
    require(guards and guards[0].get('event')=='starting' and guards[0].get('foreign_cpu_limit')==1000
        and guards[0].get('timeout_seconds')==s['guard_timeout_seconds'] and not any(e.get('event') in {'owned_group_signal','owned_cli_signal','cancel_requested','interrupted','cancelled'} for e in guards),'Canceled/changed guard cannot pass')
    end=guards[-1];shutdown=end.get('shutdown',{});failed=[r for r in matrix['rows'] if r['status']=='failed']
    require(end.get('event')=='finished' and end.get('canceled') is False and all(end.get(k) is None for k in ('reason','failure','guard_observation'))
        and shutdown.get('returncode')==int(bool(failed)) and type(shutdown.get('returncode')) is int and shutdown.get('cli_reaped') is True
        and shutdown.get('owned_session_present') is False and shutdown.get('shutdown_errors')==[],'Only clean natural terminal guard admitted')
    require(not Path(paths['matrix_cancel']).exists(),'Campaign cancellation cannot pass')
    if failed:
        ref=event['failure_classification'];require(isinstance(ref,dict) and ref.get('path')==paths['classification_receipt'],'Failure receipt absent or producer filename differs')
        classification=load(Path(ref['path']),ref['sha256'])
        require(classification.get('matrix')=={'path':paths['matrix_json'],'sha256':event['matrix_sha256']}
            and classification.get('classifier')==family['tools']['failure_classifier'] and classification.get('all_failures_classified') is True
            and classification.get('failure_count')==len(failed) and classification.get('unclassified_cells')==[],'Failure receipt grid/source differs')
        require({tuple(c['key'][k] for k in ('id','model','language_mode','path','source_channel','repeat')) for c in classification['failed_cells']}=={tuple(r[k] for k in ('id','model','language_mode','path','source_channel','repeat')) for r in failed},'Failed keys differ')
    else:require(event.get('failure_classification') is None,'Successful grid has failure receipt')
    require(report['schema_version']=='quality-pilot-report-1.1' and report['source_matrix_sha256']==event['matrix_sha256']
        and matrix.get('dry_run') is False and type(matrix.get('threads')) is int and matrix['threads']==2 and matrix['split']==plan['split'],'Native/report scope differs')
    require(not any(matrix.get(k) is True for k in ('canceled','cancelled','cancellation_requested')),'Canceled matrix cannot pass')
    for key in ('corpus_sha256','configuration_sha256','runner_sha256','whisper_binary_sha256'):
        require(matrix.get(key)==execution[key] and report.get('provenance',{}).get(key)==execution[key],'Native/report execution identity differs '+key)
    snapshots=[('corpus.original.json','corpus_sha256'),('experiment.original.json','configuration_sha256')]
    if s['stage']=='held_out':
        snapshots.append(('freeze.original.json','freeze_sha256'));require(matrix.get('freeze_sha256')==report['provenance'].get('freeze_sha256')==execution['freeze_sha256'],'Native held freeze differs')
    for name,key in snapshots:
        snapshot=report.get('snapshot_evidence',{}).get(name,{})
        require(snapshot.get('status')=='verified' and snapshot.get('expected_sha256')==snapshot.get('observed_sha256')==execution[key],'Snapshot attestation differs')
        read(Path(paths['matrix_directory'])/name,execution[key])
    arms,models=planned_arm_models(plan['partition']);cases={c['id']:c for c in plan['cases']}
    common=sorted(plan['cases'],key=lambda c:c['id'])
    if s['stage'] in PLANNED_CASES:same(common,PLANNED_CASES[s['stage']],'Same fixed source cases across all5 partitions')
    else:PLANNED_CASES[s['stage']]=common
    require(collections.Counter(c['language'] for c in cases.values())==collections.Counter({l:1 if s['stage']=='panel' else 8 if s['stage']=='development' else 16 for l in LANGS}),'Planned nine-language quotas differ')
    expected=set(itertools.product(cases,models,plan['language_modes'],range(1,plan['repetitions']+1)));seen={};preparations=set()
    for row in matrix['rows']:
        key=(row['id'],row['model'],row['language_mode'],row['repeat']);require(type(row['repeat']) is int and key in expected and key not in seen,'Native exact once grid differs');seen[key]=row
        c=cases[row['id']];role,model,kind=models[row['model']]
        for name in ('language','task','source_channel','source_sha256','reference_sha256'):same(row[name],c[name],'Planned source '+name)
        require(row['task']==('standard_rendering' if row['language']=='de-CH' else 'transcription') and row['model_sha256']==model['sha256'] and row['model_kind']==kind,'Task/arm source identity differs')
        original=arms['original'];parent=model if role=='original' else original
        require(row.get('baseline_model_id')==parent['id'] and row.get('baseline_model_sha256')==parent['sha256']
            and (row.get('intervention_id') is None if role=='original' else isinstance(row.get('intervention_id'),str) and bool(row['intervention_id'])),'Original self baseline/derived original parent differs')
        for name,value in (('profile_sha256',execution['profile_sha256']),('runtime_settings_sha256',execution['runtime_settings_sha256']),('effective_profile_sha256',execution['runtime_settings_sha256']),('whisper_binary_sha256',execution['whisper_binary_sha256']),('transcription_runner_sha256',execution['runner_sha256']),('vad_model_sha256',None),('threads',2)):same(row.get(name),value,'Native '+name)
        preparations.add(row.get('preparation_policy'));require(isinstance(row.get('preparation_policy'),str) and row['preparation_policy'] and len(preparations)==1,'Preparation policy differs')
        require(good(row) or row['status']=='failed' and row.get('measurement') is None,'Nonterminal or recovered failed measurement')
        if good(row):
            require(native_identity(row['measurement'].get('engine_passes'),row,execution)>0,'Native identity evidence absent')
            for field in ('reference_words','reference_characters'):
                value=row['measurement'].get(field)
                if value is not None:
                    require(integer(value),'Invalid measured reference denominator');uk=(row['id'],row['reference_sha256'],row['scoring_policy'],row['source_channel'],field)
                    require(uk not in REFERENCE_UNITS or REFERENCE_UNITS[uk]==value,'Reference denominator changed across models/modes/repeats');REFERENCE_UNITS[uk]=value
                    require(len(REFERENCE_UNITS)<=450,'Reference-unit ledger exceeds225sources')
    require(set(seen)==expected and len(seen)==s['planned_cells']==event['attempted_cells'],'Attempted grid incomplete')
    require(report.get('requested_cells')==len(seen) and report.get('completed_cells')==sum(good(r) for r in seen.values())
        and report.get('cell_status_counts')==dict(collections.Counter(r['status'] for r in seen.values())),'Native/report aggregate coverage differs')
    pairs=matrix['paired_comparisons'];pairkeys=set();completed_pairs=0
    if plan['partition']['kind']=='family':
        comparisons=plan['partition']['comparison_ids'];inverse={v:k for k,v in comparisons.items()}
        expected_pairs=set(itertools.product(inverse,cases,plan['language_modes'],range(1,plan['repetitions']+1)))
        for pair in pairs:
            pk=(pair['comparison_id'],pair['id'],pair['language_mode'],pair['repeat']);require(pk in expected_pairs and pk not in pairkeys,'Native parent pair grid differs');pairkeys.add(pk)
            role=inverse[pk[0]];a=seen[(pk[1],arms['original']['id'],pk[2],pk[3])];b=seen[(pk[1],arms[role]['id'],pk[2],pk[3])]
            complete=good(a) and good(b);require((pair['status']=='paired_exploratory') is complete,'Native pair availability differs');completed_pairs+=complete
            require(pair['baseline_model']==arms['original']['id'] and pair['candidate_model']==arms[role]['id'] and pair['intervention']==KINDS[role],'Native pair lineage differs')
            for metric in ('cer','wer'):
                if complete and not (a['language']=='zh' and metric=='wer'):
                    av,bv=a['measurement'].get(metric),b['measurement'].get(metric);same(pair.get(metric+'_delta'),bv-av if numeric(av) and numeric(bv) else None,'Native pair delta')
        require(pairkeys==expected_pairs,'Missing native parent pairs')
    else:
        for pair in pairs:
            key=(pair['id'],pair['candidate_model'],pair['language_mode'],pair['repeat']);require(key in seen and key not in pairkeys,'Reference placeholder grid differs');pairkeys.add(key)
            require(pair.get('status')=='pending_pair' and pair.get('comparison_id') is None and pair.get('baseline_profile') is None and pair.get('intervention_id') is None,'Reference placeholder cannot become a real pair')
            row=seen[key];original=arms['original']
            require(set(pair)=={'identity','candidate_profile','id','task','repeat','language_mode','path','source_channel','candidate_model','candidate_model_sha256','baseline_model','baseline_profile','comparison_id','intervention','intervention_id','language','conditions','coverage_role','pairing_contract_version','status'}
                and pair['baseline_model']==pair['candidate_model']==original['id'] and pair['candidate_model_sha256']==original['sha256']
                and pair['candidate_profile']==execution['profile_id'] and pair['intervention']=='runtime' and pair['pairing_contract_version']=='model-lineage-v2','Strict reference placeholder lineage differs')
            for field in ('id','task','repeat','language_mode','path','source_channel','language','conditions','coverage_role'):same(pair[field],row[field],'Reference placeholder source '+field)
            require(pair['identity']=='|'.join(row[k] for k in ('id','language','language_mode','path','source_sha256','reference_sha256','scoring_policy','task'))+'|'+str(row['source_channel'])+'|'+str(row['repeat']),'Reference placeholder identity differs')
        require(pairkeys==expected,'Reference placeholder grid incomplete')
    derived=sum(good(seen[(c,arms['plain_q4']['id'],mode,r)]) and good(seen[(c,arms['permuted_q4']['id'],mode,r)]) for c,mode,r in itertools.product(cases,plan['language_modes'],range(1,plan['repetitions']+1))) if plan['partition']['kind']=='family' else 0
    require(event['completed_cells']==sum(good(r) for r in matrix['rows']) and event['failed_cells']==len(failed)
        and event['completed_native_parent_pairs']==completed_pairs and event['completed_assessor_derived_q4_pairs']==derived
        and event['runtime_reference_placeholders']==(len(pairs) if plan['partition']['kind']=='reference' else 0),'Terminal native/pair counts differ')
    evidence={'report_sha256':event['report_sha256'],'matrix_sha256':event['matrix_sha256'],'plan_sha256':event['plan_sha256'],'runtime_record_sha256':family['runtime_record']['sha256'],'analyzer_sha256':family['tools']['assessor']['sha256'],'reused_affine_helpers_sha256':family['tools']['affine_helpers']['sha256'],'public_reporter_sha256':family['tools']['reporter']['sha256']}
    same(assessment['evidence'],evidence,'Assessment exact evidence');same(assessment['partition'],plan['partition'],'Assessment arms')
    require(assessment['schema_version']=='mlp-permutation-assessment-v1' and assessment['scoring_policy']==POLICY and assessment['default_promotion'] is False,'Frozen analyzer version/promotion differs')
    require(assessment.get('native_review')==assessment.get('product_acceptance')=='PENDING'
        and assessment.get('resource_acceptance')=='UNCONTROLLED / NOT EVALUATED','Numerical evidence cannot promote native/product/resource acceptance')
    for key in ('permutation','quantization'):same(assessment[key],family[key],'Assessment '+key)
    return plan,matrix,report,assessment

def audit_numeric(s,family,assessed,held,held_bindings,qmap,rmap,mmap):
    gate_headlines=[]
    models={v['id']:v for v in s['artifacts']};native_held=collections.defaultdict(list)
    load_rows=[];quality_headlines=[];totals=collections.Counter();failed=[];partial=[]
    for index,stage in enumerate(s['stages']):
        check();spec=family['stages'][index];event=assessed[index]
        plan,matrix,report,assessment=stage_provenance(family,spec,event,held,held_bindings)
        bind_gate_inputs(assessment,plan,matrix)
        gates_for_stage=[]
        for mode in assessment['model_mode_assessments']:
            gates,headline=mode_audit(mode,plan);gates_for_stage.append(gates)
            CHECKS['gates']+=len(gates)
            for value in gates.values():CHECKS['gates_'+('unknown' if value is None else str(value).lower())]+=1
            if headline:gate_headlines.append({'stage_id':stage['id'],**headline})
        independent_partition='reject' if any(v['decision']=='reject' for v in assessment['model_mode_assessments']) else 'inconclusive_no_promotion' if any(v['decision']=='inconclusive_no_promotion' for v in assessment['model_mode_assessments']) else 'reference_observed_no_promotion' if plan['partition']['kind']=='reference' else 'continue_no_promotion'
        same(assessment['partition_assessment'],{'id':plan['partition']['id'],'kind':plan['partition']['kind'],'decision':independent_partition,'mode_decisions':{v['language_mode']:v['decision'] for v in assessment['model_mode_assessments']}},'Partition decision')
        same(assessment['model_mode_assessments'],stage['model_mode_assessments'],'Frozen assessment projection')
        same(assessment['partition_assessment'],stage['partition_assessment'],'Partition summary projection')
        same(stage['evidence'],assessment['evidence'],'Summary evidence projection')
        require(all(stage[k]==event[k] and type(stage[k]) is int for k in FIELDS),'Summary exact stage coverage differs')
        rows=matrix['rows'];totals['attempted']+=len(rows);totals['completed']+=sum(good(v) for v in rows);totals['failed']+=sum(v['status']=='failed' for v in rows)
        require(len(rows)==stage['attempted_cells'] and sum(good(v) for v in rows)==stage['completed_cells'],'Native terminal count differs')
        groups=collections.defaultdict(list)
        for row in rows:
            require(row['scoring_policy']==POLICY and type(row['source_channel']) is int and row['source_channel']==0
              and row['profile']=='current-defaults' and row['path']=='final','Native policy/channel/profile differs')
            groups[cohort(row)].append(row)
            if stage['stage']=='held_out':native_held[(row['model'],row['language_mode'])]
            if row['status']=='failed':
                require(row.get('measurement') is None,'Failed native row has a measurement')
                failed.append({'stage':stage['id'],'model':row['model'],'language_mode':row['language_mode'],'language':row['language'],'repeat':row['repeat']})
            if good(row):
                m=row['measurement'];require(m['scoring_version']==POLICY,'Native scoring version differs')
                require(m.get('normalization')=='swift-nfc-casefold-alphanumeric-v1; punctuation to spaces, collapsed whitespace; CER omits spaces'
                    and m.get('character_unit')=='Unicode scalar after normalization; spaces omitted'
                    and m.get('word_segmentation')=='whitespace-v1' and isinstance(m.get('memory_method'),str) and m['memory_method'],'Native scoring/resource unit metadata differs')
                for key in ('scoring_version','normalization','character_unit','word_segmentation','memory_method'):VERSIONS[key].add(m.get(key))
                require(m['source_sha256']==row['source_sha256'] and m['reference_sha256']==row['reference_sha256'],'Native source/reference identity differs')
                require(numeric(m['wall_seconds']) and m['wall_seconds']>=0 and numeric(m['source_audio_seconds']) and m['source_audio_seconds']>0,'Native duration/wall unavailable')
                require(near(m['real_time_factor'],m['wall_seconds']/m['source_audio_seconds'])
                    and (near(m['end_to_end_audio_seconds_per_second'],m['source_audio_seconds']/m['wall_seconds']) if m['wall_seconds']>0 else m['end_to_end_audio_seconds_per_second'] is None),'Native RTF/inverse units differ')
                if stage['stage']=='held_out':native_held[(row['model'],row['language_mode'])].append(row)
        report_groups={cohort(v):v for v in report['cohorts']};require(set(groups)==set(report_groups) and len(report_groups)==len(report['cohorts']),'Native/report cohort grid differs')
        observations={(v['id'],mode['language_mode']):mode for v in stage['artifact_observations'] for mode in v['modes']}
        require(len(observations)==sum(len(v['modes']) for v in stage['artifact_observations'])
            and set(observations)==set(itertools.product(spec['models'],spec['language_modes'])),'Summary model/mode grid differs')
        for v in stage['artifact_observations']:
            require(v['kind']==models[v['id']]['kind'] and v['sha256']==models[v['id']]['sha256'] and v['actual_model_file_bytes']==models[v['id']]['model_file_bytes'],'Summary observation artifact identity differs')
            for mode in v['modes']:require(len(mode['per_language'])==9 and {x['language'] for x in mode['per_language']}==set(LANGS),'Summary per-language grid differs')
        per_mode=collections.defaultdict(lambda:{'cer':[],'wer':[]});stage_cases={}
        for key,group in groups.items():
            model,mode,language,task=key;reported=report_groups[key];observation=observations[(model,mode)]
            value=next(v for v in observation['per_language'] if v['language']==language)
            planned={case(row) for row in group};cells=[(case(row),row['repeat']) for row in group]
            require(len(cells)==len(set(cells)) and len(planned)==(1 if index<5 else 8 if index<10 else 16),'Canonical source/repeat grid differs')
            if language in stage_cases:require(stage_cases[language]==planned,'Source/reference identities differ across arms/modes')
            else:stage_cases[language]=planned
            first=[v for v in group if v['repeat']==1 and good(v)];measured=[v for v in group if good(v)]
            require(value['planned_unique_sources']==len(planned) and value['completed_unique_sources']==len(first) and value['task']==task,'Summary planned/completed source counts differ')
            require(reported['quality']['planned_unique_utterances']==len(planned) and reported['quality']['completed_unique_utterances']==len(first),'Successful repeat1 denominator differs')
            same(value['quality'],reported['quality'],'Report/formatter quality');same(value['timing'],reported['timing'],'Report/formatter timing')
            same(value['peak_process_rss_bytes'],reported['peak_process_rss_bytes'],'Report/formatter RSS');same(value['artifact_metrics'],reported['artifact_metrics'],'Report/formatter artifact bytes')
            same(value['sample_grouping'],reported.get('sample_grouping'),'Report/formatter source grouping metadata')
            repeat_records={v['id']:v for v in reported['utterance_repeats']}
            require(len(repeat_records)==len(planned) and set(repeat_records)=={r['id'] for r in group},'Repeat source-group grid differs')
            stability={'planned_source_groups':len(planned),'stable_multiple_repeats':0,'observed_varied':0,'single_repeat_observed':0,'unknown':0}
            for identifier,entry in repeat_records.items():
                repeated=[r for r in group if r['id']==identifier];successful=[r for r in repeated if good(r)]
                hashes={r['measurement'].get('hypothesis_sha256') for r in successful if r['measurement'].get('hypothesis_sha256')}
                count=len(hashes) if hashes else None
                require(entry['requested_repeats']==len(repeated) and entry['completed_repeats']==len(successful)
                    and entry['distinct_hypothesis_hashes']==count and entry['transcript_variation'] is (len(hashes)>1 if hashes else None),'Native/report repeat hashes or denominator differs')
                if count is not None and count>1:stability['observed_varied']+=1
                elif len(successful)==len(repeated) and count==1:stability['stable_multiple_repeats' if len(repeated)>1 else 'single_repeat_observed']+=1
                else:stability['unknown']+=1
            stability['scope']='Descriptive transcript-hash variation; single-repeat quality is not determinism evidence or independent speech'
            same(value['repeat_stability'],stability,'Native-derived repeat stability summary')
            prefix={'stage':stage['id'],'phase':stage['stage'],'model':model,'kind':models[model]['kind'],'mode':mode,'language':language,'task':task,'model_file_bytes':models[model]['model_file_bytes']}
            qexpected={**prefix,'completed_sources':len(first)}
            for metric in ('cer','wer'):
                if language=='zh' and metric=='wer':
                    require(reported['quality']['wer'] is None and value['counted_metric_coverage']['wer']=={'status':'not_reported_chinese_whitespace_wer'},'Chinese WER was reported')
                    selected={'status':'not_reported_chinese_whitespace_wer','planned':len(planned),'scored':None,'errors':None,'units':None,'observed_rate':None,'full_rate':None}
                else:
                    counted_value=counted(first,metric);same(reported['quality'][metric],counted_value,'Native/report counted '+metric)
                    n=counted_value['scored_unique_utterances'];complete=n==len(planned);full=counted_value['corpus_weighted_rate'] if complete else None
                    coverage=value['counted_metric_coverage'][metric]
                    require(coverage['scored_unique_sources']==n and coverage['coverage_complete'] is complete,'Formatter count completeness differs')
                    same(coverage['full_planned_rate'],full,'Formatter full planned rate')
                    selected={'status':'complete' if complete else 'PENDING_missing_quality','planned':len(planned),'scored':n,
                      'errors':counted_value['errors'],'units':counted_value['reference_units'],'observed_rate':counted_value['corpus_weighted_rate'],'full_rate':full}
                    per_mode[(model,mode)][metric].append((language,full))
                    if not complete:partial.append({'stage':stage['id'],'model':model,'mode':mode,'language':language,'metric':metric,'scored':n,'planned':len(planned),'full_planned_rate':None})
                qexpected.update({metric+'_'+k:v for k,v in selected.items()})
            csv_same(qmap[(stage['id'],model,mode,language)],qexpected,'Quality CSV');CHECKS['quality_cohorts']+=1
            workloads=[]
            for repeat in sorted({v['repeat'] for v in group},key=str):
                repeated=[v for v in group if v['repeat']==repeat and good(v)];complete={case(v) for v in repeated}==planned
                wall=sum(v['measurement']['wall_seconds'] for v in repeated) if complete else None
                audio=sum(v['measurement']['source_audio_seconds'] for v in repeated) if complete else None
                workloads.append({'repeat':repeat,'status':'completed' if complete else 'incomplete','completed_utterances':len(repeated),'planned_utterances':len(planned),
                  'wall_seconds':wall,'audio_seconds':audio,'real_time_factor':wall/audio if complete else None,'end_to_end_audio_seconds_per_second':audio/wall if complete and wall>0 else None})
            timing=reported['timing'];same(timing['workloads'],workloads,'Native/report workloads')
            require(timing['completed_cells']==len(measured) and timing['complete_workload_repeats']==sum(v['status']=='completed' for v in workloads),'Resource invocation/workload count differs')
            dists={'wall_seconds':dist(v['measurement']['wall_seconds'] for v in measured),
              'workload_rtf':dist(v['real_time_factor'] for v in workloads),'peak_process_rss_bytes':dist(v['measurement'].get('peak_rss_bytes') for v in measured)}
            same(timing['wall_seconds_per_utterance_invocation'],dists['wall_seconds'],'Wall distribution');same(timing['complete_workload_real_time_factor'],dists['workload_rtf'],'RTF distribution')
            same(timing['complete_workload_wall_seconds'],dist(v['wall_seconds'] for v in workloads),'Workload wall distribution');same(timing['complete_workload_end_to_end_audio_seconds_per_second'],dist(v['end_to_end_audio_seconds_per_second'] for v in workloads),'Workload inverse distribution')
            same(reported['peak_process_rss_bytes'],dists['peak_process_rss_bytes'],'RSS distribution')
            seconds=[];parsers=set();invocations=0
            for row in measured:
                for invocation in row['measurement'].get('engine_runtime_measurements',[]):
                    invocations+=1;native=invocation['runtime_timings'];parsers.add(native['parser_version'])
                    seconds.extend(v['seconds'] for v in native.get('observations',{}).get('load',[]) if numeric(v.get('seconds')) and v['seconds']>=0)
            load_timer=timing['model_load_seconds_per_native_invocation'];load_dist=dist(seconds)
            same({k:load_timer[k] for k in load_dist},load_dist,'Native/report load timer');require(load_timer['native_invocations_recorded']==invocations and load_timer['parser_versions']==sorted(parsers),'Native load timer scope/count differs')
            require(timing['first_result_latency_seconds'] is None,'First result latency must remain unmeasured')
            load_rows.append({**prefix,'native_invocations_recorded':invocations,'load_observations':len(seconds),
              **{k+'_seconds':load_dist[k] for k in ('median','minimum','maximum')},
              **{k+'_ms':load_dist[k]*1000 if load_dist[k] is not None else None for k in ('median','minimum','maximum')},
              'parser_versions':';'.join(sorted(parsers)),'scope':'Upstream reported model-load timer only; not total initialization or first-result latency'})
            resource={**prefix,'artifact_bytes_observed':reported['artifact_metrics']['model_file_bytes'],'planned_sources':len(planned),'completed_sources':len(first),
              'repeats':3 if index<5 else 1,'completed_invocations':len(measured),'resource_acceptance':'UNCONTROLLED / NOT EVALUATED',
              'model_load_native_invocations':invocations,'model_load_scope':'Upstream model load per native invocation; not full initialization/first result'}
            dists['model_load_seconds']=load_dist
            resource.update({name+'_'+('count' if k=='measured_count' else k):v for name,stats in dists.items() for k,v in stats.items()})
            csv_same(rmap[(stage['id'],model,mode,language)],resource,'Resource CSV');CHECKS['resource_cohorts']+=1
            if index>=10:require(dists['wall_seconds']['measured_count']==len(measured) and dists['workload_rtf']['measured_count']==int(len(measured)==16),'Held wall-invocation versus aggregate RTF count differs')
            require(reported['artifact_metrics']['model_file_bytes'] is None or reported['artifact_metrics']['model_file_bytes']==models[model]['model_file_bytes'],'Actual artifact bytes mismatch')
        for (model,mode),rates in per_mode.items():
            projected={'stage':stage['id'],'phase':stage['stage'],'model':model,'kind':models[model]['kind'],'mode':mode,'model_file_bytes':models[model]['model_file_bytes']}
            for metric,denom in (('cer',9),('wer',8)):
                require(len(rates[metric])==denom,'Macro language denominator differs')
                rates[metric].sort(key=lambda pair:LANGS.index(pair[0]));valid=sum(v is not None for _,v in rates[metric]);macro=sum(v for _,v in rates[metric])/denom if valid==denom else None
                observation=observations[(model,mode)];same(observation['macro_'+metric],macro,'Native-derived formatter macro')
                require(observation['macro_'+metric+'_complete_languages']==valid,'Macro complete-language count differs')
                projected.update({metric+'_full_planned_rate':macro,metric+'_complete_languages':valid,metric+'_planned_languages':denom})
            csv_same(mmap[(stage['id'],model,mode)],projected,'Macro CSV');CHECKS['macro_rows']+=1
            if index>=10:quality_headlines.append(projected)
        stage_complete=all(all(rate is not None for _,rate in per_mode[key][metric]) for key in per_mode for metric in ('cer','wer'))
        require(stage['complete_counted_quality_coverage'] is stage_complete,'Stage complete quality flag differs')
    return models,native_held,load_rows,quality_headlines,totals,failed,partial,gate_headlines

def family_conclusions(stages):
    conclusions=[]
    for model in ADAPTED:
        selected=[s for s in stages if s['partition_id']==model]
        require(len(selected)==3,'One panel/DEV/held group per family required')
        panel=next(s for s in selected if s['stage']=='panel');held=next(s for s in selected if s['stage']=='held_out')
        controls=all(all(v is True for v in m['gates'].values()) for m in panel['model_mode_assessments'])
        complete=all(s['complete_counted_quality_coverage'] for s in selected)
        modes={m['language_mode']:m['decision'] for m in held['model_mode_assessments']}
        decision='REJECT' if any(v=='reject' for v in modes.values()) else 'NUMERICAL_GATES_MET_NATIVE_PENDING' if controls and complete and all(v=='continue_no_promotion' for v in modes.values()) else 'INCONCLUSIVE_NO_PROMOTION'
        conclusions.append({'family':model,'decision':decision,'frozen_heldout_mode_decisions':modes,
            'all_three_repeat_panel_controls_observed':controls,'complete_counted_family_quality':complete,
            'development_performance_is_not_a_new_gate':True,'default_promotion':False})
    return conclusions

def publish_files(out,files):
    """Exclusive protected publication is shared with synthetic CLI-write tests."""
    out=Path(out);require(out.is_absolute() and R in out.parents and '..' not in out.parts and not out.exists()
        and not any(p.is_symlink() for p in (out,*out.parents)),'New protected audit output directory required')
    require(sum(len(v) for v in files.values())<8*1024*1024 and all(isinstance(k,str) and Path(k).name==k and k not in {'.','..'} for k in files),'Bounded flat audit outputs required')
    check();out.mkdir(mode=0o700)
    for name,data in files.items():
        check()
        with (out/name).open('xb') as f:f.write(data)
        (out/name).chmod(0o600)

def main(argv=None):
    global R,DEADLINE,OPTIONS,FAMILY_SHA,ADMISSION_SHA,FORMATTER_SHA,PROJECTOR_SHA,REPORTING_FREEZE_SHA,PRESERVATION_SOURCE_SHA,PRESERVATION_FREEZE_SHA
    global INPUTS,CHECKS,VERSIONS,REFERENCE_UNITS,PLANNED_CASES,EXTERNAL_PINS,PHYSICAL_READ_BYTES
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('audit-freeze-sha256','preservation-sha256','preservation-guard-sha256','journal-sha256','summary','summary-sha256','projection-audit','projection-audit-sha256',
                 'summary-source-sha256','projector-source-sha256','expected-source-sha256','output',
                 'family-seal','family-seal-sha256','admission-capsule','admission-capsule-sha256','journal',
                 'summary-source','projector-source','reporting-freeze','reporting-freeze-sha256','audit-freeze',
                 'preservation-source','preservation-source-sha256','preservation-freeze','preservation-freeze-sha256','preservation-receipt','preservation-guard'):
        parser.add_argument('--'+name,required=True)
    parser.add_argument('--timeout-seconds',type=int,choices=range(1,301),default=180)
    a=parser.parse_args(argv);OPTIONS=a;R=Path(a.family_seal).absolute().parent;DEADLINE=time.monotonic()+a.timeout_seconds
    INPUTS={};CHECKS=collections.Counter();VERSIONS=collections.defaultdict(set);REFERENCE_UNITS={};PLANNED_CASES={};EXTERNAL_PINS={};PHYSICAL_READ_BYTES=0
    require(all(valid_sha(value) for key,value in vars(a).items() if key.endswith('_sha256')),'Every input/source SHA must be explicit')
    FAMILY_SHA=a.family_seal_sha256;ADMISSION_SHA=a.admission_capsule_sha256;FORMATTER_SHA=a.summary_source_sha256;PROJECTOR_SHA=a.projector_source_sha256
    REPORTING_FREEZE_SHA=a.reporting_freeze_sha256;PRESERVATION_SOURCE_SHA=a.preservation_source_sha256;PRESERVATION_FREEZE_SHA=a.preservation_freeze_sha256
    for path,digest in [(str(Path(__file__).absolute()),a.expected_source_sha256),(a.family_seal,FAMILY_SHA),(a.admission_capsule,ADMISSION_SHA),(a.journal,a.journal_sha256),
      (a.summary_source,FORMATTER_SHA),(a.projector_source,PROJECTOR_SHA),(a.reporting_freeze,REPORTING_FREEZE_SHA),(a.audit_freeze,a.audit_freeze_sha256),
      (a.preservation_source,PRESERVATION_SOURCE_SHA),(a.preservation_freeze,PRESERVATION_FREEZE_SHA),(a.preservation_receipt,a.preservation_sha256),
      (a.preservation_guard,a.preservation_guard_sha256),(a.summary,a.summary_sha256),(a.projection_audit,a.projection_audit_sha256)]:register_pin({'path':path,'sha256':digest})
    require(Path(a.summary).name=='summary.json' and Path(a.projection_audit).name=='audit.json','Canonical summary/projection metadata filenames required')
    read(Path(__file__).absolute(),a.expected_source_sha256,1024*1024)
    family=load(Path(a.family_seal),FAMILY_SHA)
    require(family['paths']['journal']==a.journal,'Journal must use sealed campaign path')
    events=jsonl(Path(a.journal),a.journal_sha256)
    assessed,accept,coverage=barrier(family,events)  # NO outcome input may be opened before this point.
    validate_paths(family)
    for descriptor in family['inputs'].values():register_pin(descriptor)
    for descriptor in family['tools'].values():register_pin(descriptor)
    for key in ('runtime_record','profile','artifact_family_receipt'):
        if key in family:register_pin(family[key])
    for stage in family['stages']:
        for path_key,hash_key in (('configuration','configuration_sha256'),('corpus','corpus_sha256'),('assessment_pre_freeze_plan','assessment_pre_freeze_plan_sha256'),('source_snapshot','source_snapshot_sha256')):
            register_pin({'path':stage[path_key],'sha256':stage[hash_key]})
    own_freeze=load(Path(a.audit_freeze),a.audit_freeze_sha256)
    require(own_freeze.get('schema_version')=='round5-independent-final-audit-tools-freeze-v1'
        and own_freeze.get('source',{}).get('sha256')==a.expected_source_sha256
        and own_freeze.get('reporting_tools_freeze_sha256')==REPORTING_FREEZE_SHA
        and own_freeze.get('preservation_tools_freeze_sha256')==PRESERVATION_FREEZE_SHA
        and own_freeze.get('dynamic_cli_pins') is True and own_freeze.get('mandatory_all15_terminal_barrier') is True
        and own_freeze.get('campaign_outcomes_read') is False and own_freeze.get('default_promotion') is False,'Independent prospective source freeze differs')
    frozen_time=datetime.fromisoformat(own_freeze['created_utc'].replace('Z','+00:00'))
    first_held=next(e for e in events if e.get('event')=='command_start' and e.get('action')=='guarded_inference' and e.get('stage')==IDS[0])
    require(frozen_time.tzinfo is not None and frozen_time<datetime.fromisoformat(first_held['created_utc'].replace('Z','+00:00')),'Independent audit source must freeze before ANY quality launch')
    admission=load(Path(a.admission_capsule),ADMISSION_SHA)
    for key in ('native_load_receipt','native_load_guard','native_load_launch','independent_static_audit'):
        register_pin(admission[key])
    att=events[0]['initial_attestation'];require(isinstance(att,dict) and valid_sha(att.get('sha256')),'Native idle descriptor absent')
    register_pin(att)
    idle=load(Path(att['path']),att['sha256'])
    require(idle.get('recording_active') is False and idle.get('live_transcription_active') is False and idle.get('inspection_method')=='native-ui','Native idle/live-off attestation differs')
    pins=admission.get('frozen_inputs',{})
    require(any(v.get('sha256')==FAMILY_SHA for v in pins.values()) and any(v.get('path')==att['path'] and v.get('sha256')==att['sha256'] for v in pins.values()),'Launch admission binding differs')
    preservation=preservation_provenance(family,events,a.journal_sha256,a.preservation_sha256,a.preservation_guard_sha256,admission)
    metadata_provenance=static_metadata_provenance(family,admission,events)
    for tool in family['tools'].values():
        p=Path(tool['path'])
        require(p.suffix=='.py','Only Python tool source may be followed');read(p,tool['sha256'],1024*1024)
    read(Path(a.summary_source),a.summary_source_sha256,1024*1024)
    read(Path(a.projector_source),a.projector_source_sha256,1024*1024)
    reporting=load(Path(a.reporting_freeze),REPORTING_FREEZE_SHA)
    require(reporting.get('schema_version')=='round5-final-reporting-tools-freeze-v1'
        and reporting.get('dynamic_cli_pins') is True and reporting.get('mandatory_all15_terminal_barrier') is True
        and reporting.get('sources',{}).get('summarize-round5-v1.py',{}).get('sha256')==FORMATTER_SHA
        and reporting.get('sources',{}).get('project-round5-report-v1.py',{}).get('sha256')==PROJECTOR_SHA
        and reporting.get('campaign_outcomes_read') is False and reporting.get('default_promotion') is False,'Prospective reporting source freeze differs')
    reporting_time=datetime.fromisoformat(reporting['created_utc'].replace('Z','+00:00'))
    require(reporting_time.tzinfo is not None and reporting_time<datetime.fromisoformat(first_held['created_utc'].replace('Z','+00:00')),'Reporting tools must freeze before ANY quality launch')
    s=load(Path(a.summary),a.summary_sha256);audit=load(Path(a.projection_audit),a.projection_audit_sha256)
    require(s.get('schema_version')=='round5-retained-numeric-summary-v1' and s.get('summary_source_sha256')==a.summary_source_sha256
        and s.get('journal_sha256')==a.journal_sha256 and s.get('frozen_family_seal_sha256')==FAMILY_SHA and s.get('admission_sha256')==ADMISSION_SHA
        and s.get('terminal_plan_complete') is True and s.get('integrity_failures')==[] and s.get('default_promotion') is False,'Final summary source/completion binding differs')
    same(s['coverage'],coverage,'Final summary exact attempt/pair coverage');same(s['artifacts'],family['models'],'Frozen model metadata')
    require(len(family['models'])==11 and len({m['id'] for m in family['models']})==11 and [x['id'] for x in s['stages']]==IDS,'Exact model/stage grid differs')
    same(s['tools'],family['tools'],'Summary tools');same(s['scientific_budgets'],family['budgets'],'Summary scientific budgets')
    for key in ('permutation','quantization'):same(s[key],family[key],'Summary '+key)
    require(audit.get('input_summary',{}).get('sha256')==a.summary_sha256
        and audit.get('projection_source',{}).get('sha256')==a.projector_source_sha256
        and audit.get('formatter_sha256')==a.summary_source_sha256
        and audit.get('frozen_family_sha256')==FAMILY_SHA and audit.get('admission_sha256')==ADMISSION_SHA,'Projection exact input/source binding differs')
    require(audit.get('schema_version')=='round5-report-projection-v1' and audit.get('all_terminal_attempts') is True
        and audit.get('status')=='PASSED_NUMERIC_PROJECTION_AUDIT_NO_ACCEPTANCE_CLAIM' and audit.get('default_promotion') is False
        and audit.get('resource_acceptance')=='UNCONTROLLED / NOT EVALUATED' and audit.get('native_review')==audit.get('product_acceptance')=='PENDING'
        and audit.get('artifacts')==11 and audit.get('language_cohorts')==495 and audit.get('canonical_model_modes')==55,'Projection schema/coverage/acceptance claim differs')
    same(audit['coverage'],coverage,'Projection exact attempt/pair totals');same(audit['frozen_family_conclusions'],s['family_conclusions'],'Projection family decisions')
    projection=Path(a.projection_audit).parent
    qcsv=csv_rows(projection/'quality.csv',audit['output_sha256']['quality.csv'])
    rcsv=csv_rows(projection/'resources.csv',audit['output_sha256']['resources.csv'])
    mcsv=csv_rows(projection/'macros.csv',audit['output_sha256']['macros.csv'])
    read(projection/'report.md',audit['output_sha256']['report.md'])
    qmap={tuple(v[k] for k in ('stage','model','mode','language')):v for v in qcsv}
    rmap={tuple(v[k] for k in ('stage','model','mode','language')):v for v in rcsv}
    mmap={tuple(v[k] for k in ('stage','model','mode')):v for v in mcsv}
    require((len(qcsv),len(rcsv),len(mcsv),len(qmap),len(rmap),len(mmap))==(495,495,55,495,495,55),'Projection row grid/uniqueness differs')
    held,bindings=held_provenance(family,events,accept)
    same(s['heldout_family'],{'sha256':accept['freeze_sha256'],'partitions':held['partitions']},'Summary held family descriptor')
    models,native_held,load_rows,quality_headlines,totals,failed,partial,gate_headlines=audit_numeric(s,family,assessed,held,bindings,qmap,rmap,mmap)
    require(dict(totals)=={'attempted':4554,'completed':coverage['completed_cells'],'failed':coverage['failed_cells']},'Final native row totals differ')
    require(CHECKS['quality_cohorts']==CHECKS['resource_cohorts']==495 and CHECKS['macro_rows']==55,'Independent numeric projection coverage incomplete')
    complete=not partial
    require(s['complete_quality_coverage'] is complete and s['status']==('COMPLETE_TERMINAL_ATTEMPTS_NO_PROMOTION' if complete else 'COMPLETE_TERMINAL_ATTEMPTS_QUALITY_INCOMPLETE_NO_PROMOTION'),'Missing quality or final summary status differs')
    require(audit.get('complete_quality_coverage') is complete and audit.get('summary_status')==s['status'],'Projection complete quality/status differs')
    same(s['family_conclusions'],family_conclusions(s['stages']),'All3 panel/held/native aggregate decisions')
    resources=[]
    for (model,mode),rows in sorted(native_held.items()):
        require(len(rows)<=144 and len({case(v) for v in rows})==len(rows),'Held native invocation denominator differs')
        wall=dist(v['measurement']['wall_seconds'] for v in rows);rss=dist(v['measurement'].get('peak_rss_bytes') for v in rows)
        native_load=[x['seconds'] for row in rows for inv in row['measurement'].get('engine_runtime_measurements',[]) for x in inv.get('runtime_timings',{}).get('observations',{}).get('load',[]) if numeric(x.get('seconds')) and x['seconds']>=0]
        load_distribution=dist(native_load);wall_total=sum(v['measurement']['wall_seconds'] for v in rows);audio_total=sum(v['measurement']['source_audio_seconds'] for v in rows)
        full=len(rows)==144
        resources.append({'model':model,'kind':models[model]['kind'],'mode':mode,'planned_invocations':144,'successful_invocations':len(rows),'model_file_bytes':models[model]['model_file_bytes'],
            'wall_measured_count':wall['measured_count'],'wall_median_seconds':wall['median'],'wall_minimum_seconds':wall['minimum'],'wall_maximum_seconds':wall['maximum'],
            'rss_measured_count':rss['measured_count'],'peak_process_rss_median_bytes':rss['median'],'peak_process_rss_median_mib':rss['median']/1048576 if rss['median'] is not None else None,
            'peak_process_rss_maximum_mib':rss['maximum']/1048576 if rss['maximum'] is not None else None,'upstream_load_observations':load_distribution['measured_count'],
            'upstream_load_median_ms':load_distribution['median']*1000 if load_distribution['median'] is not None else None,
            'complete_sum_invocation_wall_seconds':wall_total if full else None,'complete_source_audio_seconds':audio_total if full else None,
            'whole144_invocation_wall_over_audio':wall_total/audio_total if full else None,'complete_workload_aggregate_observations':int(full),
            'resource_acceptance':'UNCONTROLLED / NOT EVALUATED'})
    require(len(resources)==22 and len(quality_headlines)==22,'All11 held model/mode headlines required')
    files={'native-load-observations.csv':csv_bytes(load_rows),'heldout-quality-headlines.csv':csv_bytes(quality_headlines),'heldout-resource-headlines.csv':csv_bytes(resources),
        'gate-headlines.json':(json.dumps(gate_headlines,indent=2,allow_nan=False)+'\n').encode()}
    receipt={'schema_version':VERSION,'created_utc':datetime.now(timezone.utc).isoformat(),'status':'PASSED_INDEPENDENT_COUNTED_NUMERIC_GATES_PROJECTION_AND_METADATA_CHAIN',
        'audit_source':INPUTS[str(Path(__file__).absolute())],'input_summary_sha256':a.summary_sha256,'input_projection_audit_sha256':a.projection_audit_sha256,
        'journal_sha256':a.journal_sha256,'family_seal_sha256':FAMILY_SHA,'admission_sha256':ADMISSION_SHA,'reporting_tools_freeze_sha256':REPORTING_FREEZE_SHA,
        'independent_audit_tools_freeze_sha256':a.audit_freeze_sha256,'counts':dict(totals),'coverage':coverage,'metadata_provenance':metadata_provenance,'completed_opaque_preservation_authority':preservation,
        'checks':dict(CHECKS),'scoring_metadata':{k:sorted(v) for k,v in VERSIONS.items()},'failed_cells':failed,'partial_counted_metrics':partial,
        'quality_coverage_complete':complete,'heldout_cells_successful':sum(len(v) for v in native_held.values()),'native_load_cohorts':len(load_rows),
        'family_conclusions':s['family_conclusions'],'known_auto_reuse_sources':True,'panel_repeats_are_independent_speech':False,
        'quality_scope':'Canonical successful repeat1 only. CER9/WER8 equal-language full-planned macros; Chinese whitespace WER suppressed; missing remains null with no fallback.',
        'gate_scope':'Independent native counts, exact hypothesis hashes and structured coarse labels; original-parent versus Q4 sibling contrasts kept distinct; frozen65%size floor and strict3repeat numerical panel unchanged.',
        'resource_scope':'UNCONTROLLED shared desktop. Wall includes setup/inspection/load/inference/rendering; RSS is process bytes converted to MiB by1048576. Per-language complete held RTF has1 aggregate observation from16jobs; pooled144 medians use individual jobs. No medians of medians.',
        'load_scope':'Upstream model-load timer seconds converted to ms. Not total initialization, warmup or first-result latency.',
        'provenance_scope':'Metadata and analysis source hashes only. Actual post-run model/binary/audio/reference payload rehash is a separate root audit; this audit does not perform it.',
        'raw_audio_reference_transcript_model_paths_followed':False,'recognition_performed':False,'rescoring_performed':False,'retry_performed':False,'new_quality_gates':False,
        'default_promotion':False,'native_review':'PENDING','product_acceptance':'PENDING','resource_acceptance':'UNCONTROLLED / NOT EVALUATED',
        'input_metadata':list(INPUTS.values()),'output_sha256':{name:sha(data) for name,data in files.items()}}
    files['receipt.json']=(json.dumps(receipt,indent=2,allow_nan=False)+'\n').encode()
    out=Path(a.output);publish_files(out,files)
    print(json.dumps({'output':str(out),'status':receipt['status'],'counts':dict(totals),'checks':dict(CHECKS),
        'output_sha256':{k:sha(v) for k,v in files.items()},'default_promotion':False}))

if __name__=='__main__':main()
