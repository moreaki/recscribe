#!/usr/bin/env python3
"""Strict metadata verifier and all-five held-out sealer; no recognition/rescoring.

Importing this file opens nothing. Callers supply immutable family/source SHA256
locks. Model/audio/reference bytes are hashed, never decoded or displayed.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.util
import itertools
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import sys

R = Path(__file__).resolve().parent
MODELS = ("tiny", "base", "small", "large-v3-turbo", "large-v3")
LANGUAGES = ("de-CH", "de", "fr", "it", "en", "ar", "zh", "es", "pt")
STAGE_RULES = (("panel", "panel", 9, ["known", "auto"], 3),
               ("development", "dev-validation", 72, ["known"], 1),
               ("held_out", "heldout", 144, ["known", "auto"], 1))
TOTALS = (4554, 2484, 828)
PLACEHOLDERS = 1242
GUARD_SHA = "7697f60e8a2c0aa150b598afe2e8c552435e1d8a4cb2f99489c9fa10de0dc56c"
CLASSIFIER_SHA = "b5fa141cab70dce2401d095aacc3f4d192b92e157878afddfb72a4a4608bc353"
RECIPE_SHA = "0a33ffab0c343b88e1cffa3e571619b414148d4b88673b69fa77386124087122"
ARM_KINDS = {"permuted_f16":"conversion_control", "plain_q4":"compression", "permuted_q4":"combined"}
PENDING_FIELDS = {"identity","candidate_profile","id","task","repeat","language_mode","path","source_channel",
    "candidate_model","candidate_model_sha256","baseline_model","baseline_profile","comparison_id",
    "intervention","intervention_id","language","conditions","coverage_role","pairing_contract_version","status"}
MAX_JSON = 64 * 1024 * 1024
COMPLETE = {"completed", "completed_with_review"}


def require(condition, message):
    if not condition: raise ValueError(message)


def valid_sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def safe_path(value, existing=True):
    require(isinstance(value, (str, Path)), "Explicit path required")
    path = Path(value)
    require(path.is_absolute() and ".." not in path.parts and
            not any(p.is_symlink() for p in (path, *path.parents)), "Use absolute nonsymlink paths")
    if existing: require(stat.S_ISREG(path.stat().st_mode), "Expected a regular input file")
    return path


def identity(path):
    value = path.lstat()
    require(stat.S_ISREG(value.st_mode), "Input changed from a regular file")
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def sha(path, check=lambda: None):
    path = safe_path(path); before = identity(path)
    require(before[2] <= 4 * 1024**3, "Frozen input exceeds its 4 GiB per-file bound")
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            check(); block = stream.read(1024 * 1024)
            if not block: break
            value.update(block)
    require(identity(path) == before, "Input changed during hashing")
    return value.hexdigest()


def read(path, expected=None, check=lambda: None):
    path = safe_path(path); before = identity(path)
    require(before[2] <= MAX_JSON, "Metadata exceeds 64 MiB")
    check()
    with path.open("rb") as stream: raw = stream.read(MAX_JSON + 1)
    require(len(raw) <= MAX_JSON and identity(path) == before, "Metadata changed/exceeded its byte bound")
    digest = hashlib.sha256(raw).hexdigest()
    require(expected is None or valid_sha(expected) and digest == expected, "Metadata differs from immutable SHA256 lock")
    def fields(pairs):
        out = {}
        for key, value in pairs:
            require(key not in out, "Duplicate metadata key"); out[key] = value
        return out
    def constant(_): raise ValueError("Nonfinite JSON metadata")
    def number(value):
        result = float(value)
        require(math.isfinite(result), "Nonfinite JSON metadata")
        return result
    value = json.loads(raw, object_pairs_hook=fields, parse_constant=constant, parse_float=number)
    require(isinstance(value, dict), "Metadata root must be an object")
    check()
    return value, digest


def save_new(path, value, check=lambda: None):
    path = safe_path(path, existing=False)
    require(not path.exists() and path.parent.is_dir(), "New output with existing parent required")
    raw = (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode()
    require(len(raw) <= MAX_JSON, "Published metadata exceeds its byte bound")
    partial = path.with_name("." + path.name + ".partial")
    check()
    fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream: stream.write(raw); stream.flush(); os.fsync(stream.fileno())
    check(); os.link(partial, path, follow_symlinks=False); partial.unlink()
    return hashlib.sha256(raw).hexdigest()


def cell_key(row):
    require(isinstance(row,dict) and all(isinstance(row.get(k),str) for k in ('id','model','language_mode'))
        and type(row.get('repeat')) is int, 'Invalid attempted-cell identity')
    return row['id'],row['model'],row['language_mode'],row['repeat']


def classification_key(value):
    require(isinstance(value,dict) and set(value) == {'id','model','language_mode','path','source_channel','repeat'}
        and isinstance(value.get('path'),str) and type(value.get('source_channel')) is int,
        'Complete forensic failure identity required')
    return cell_key(value)


def require_clean_guard(guard,returncode):
    shutdown=guard.get('shutdown',{}) if isinstance(guard,dict) else {}
    require(isinstance(guard,dict) and guard.get('event')=='finished' and guard.get('canceled') is False
        and guard.get('reason') is None and guard.get('failure') is None and guard.get('guard_observation') is None
        and isinstance(shutdown,dict) and set(shutdown)=={'returncode','cli_reaped','owned_session_present','shutdown_errors'}
        and type(shutdown.get('returncode')) is int and shutdown['returncode']==returncode
        and shutdown.get('cli_reaped') is True and shutdown.get('owned_session_present') is False and shutdown.get('shutdown_errors')==[],
        'Only a clean natural terminal guard exit is admissible; capture/cancel/timeout/signal/setup failures stop')


def validate_raw_failure_proof(item):
    proof=item.get('raw_json',{})
    require(isinstance(proof,dict) and isinstance(proof.get('path'),str) and Path(proof['path']).is_absolute()
        and '..' not in Path(proof['path']).parts and isinstance(proof.get('sha256'),str)
        and re.fullmatch(r'[0-9a-f]{64}',proof['sha256']) is not None
        and type(proof.get('bytes')) is int and proof['bytes']>0,
        'Bound raw malformed artifact identity required')
    def spans(values,size):
        require(isinstance(values,list) and values, 'Nonempty byte spans required for malformed output')
        previous=0
        for value in values:
            require(isinstance(value,dict) and set(value)=={'start','end','reason'}
                and type(value.get('start')) is int and type(value.get('end')) is int
                and previous<=value['start']<value['end']<=size
                and isinstance(value.get('reason'),str) and value['reason'], 'Invalid forensic UTF8 byte spans')
            previous=value['end']
    spans(proof.get('invalid_byte_spans'),proof['bytes'])
    paths=proof.get('replacement_field_paths')
    require(isinstance(paths,list) and paths and len(paths)==len(set(paths))
        and all(isinstance(p,str) and re.fullmatch(r'\$\.transcription\[\d+\](?:\.tokens\[\d+\])?\.text',p) for p in paths),
        'Malformed bytes may occur only in retained ASR segment/token text fields')
    segment=any(re.fullmatch(r'\$\.transcription\[\d+\]\.text',p) for p in paths)
    require(proof.get('canonical_segment_text_invalid') is segment
        and item['classification']==('invalid_utf8_canonical_asr_segment' if segment else 'invalid_utf8_asr_token_text_only')
        and type(proof.get('segment_count')) is int and proof['segment_count']>0
        and isinstance(proof.get('diagnostic_only'),str) and proof['diagnostic_only'], 'Malformed-field classification scope differs')
    fields=proof.get('field_diagnostics')
    require(isinstance(fields,list) and len(fields)==len(paths)
        and {v.get('path') for v in fields if isinstance(v,dict)}==set(paths), 'Exact failed field diagnostics required')
    for field in fields:
        require(type(field.get('payload_bytes')) is int and 0<field['payload_bytes']<=proof['bytes'], 'Invalid malformed-field payload bound')
        spans(field.get('invalid_utf8_spans'),field['payload_bytes'])


NATIVE_ERROR_HASHES = {
    'unsupported_transcription_scaffold':'aba8053f8d9bb5a63524d39c7729f6a148ba63fef694b53766547685c6c618d2',
    'invalid_offsets_or_speech':'e011f55264ce549d891e7ed7a763b3856ec183b054e5154e3b8c9dbb80994a05',
    'zero_duration_speech':'e6299686c73f2b8f51a96066b26f7ec022f8d74fec2710739606d4f1485e0fef'}


def validate_native_output_proof(item):
    """Validate a source-pinned, opaque witness; never repair/read raw speech.

    The separately pinned classifier verifies the raw bytes, exact native error
    and first rejection order. This consumer admits only its finite predicates.
    """
    kind=item.get('classification'); raw=item.get('raw_json',{})
    require(kind in NATIVE_ERROR_HASHES and isinstance(raw,dict)
        and isinstance(raw.get('path'),str) and Path(raw['path']).is_absolute() and '..' not in Path(raw['path']).parts
        and isinstance(raw.get('sha256'),str) and re.fullmatch(r'[0-9a-f]{64}',raw['sha256']) is not None
        and type(raw.get('bytes')) is int and raw['bytes']>0
        and raw.get('valid_utf8') is True and raw.get('strict_json') is True
        and all(raw.get(k)==[] for k in ('invalid_byte_spans','replacement_field_paths','field_diagnostics'))
        and raw.get('canonical_segment_text_invalid') is False, 'Finite valid-JSON native output witness required')
    proof=raw.get('native_validation',{})
    require(isinstance(proof,dict) and proof.get('contract')=='native-whisper-read-structural-rejection-v1'
        and proof.get('branch')==kind and proof.get('error_message_sha256')==NATIVE_ERROR_HASHES[kind]
        and proof.get('text_emitted') is False, 'Native read branch/cause identity differs')
    witnesses=proof.get('violations')
    require(isinstance(witnesses,list) and len(witnesses)==1, 'Exactly one first-rejection witness required')
    value=witnesses[0]
    require(isinstance(value,dict) and set(value)=={'path','reason','from_ms','to_ms','offset_types','nonblank_nonmarker'}, 'Malformed structural witness fields')
    path,reason=value.get('path'),value.get('reason'); start,end=value.get('from_ms'),value.get('to_ms')
    def integer(v): return type(v) is int and -(2**63)<=v<2**63
    require(isinstance(path,str) and (start is None or integer(start)) and (end is None or integer(end)), 'Timestamp witness must preserve bounded Int64 or null')
    types=value.get('offset_types'); enum={'missing','null','bool','integer','number','string','array','object','not_applicable'}
    require(isinstance(types,list) and len(types)==2 and all(isinstance(v,str) and v in enum for v in types)
        and (value.get('nonblank_nonmarker') is None or type(value['nonblank_nonmarker']) is bool), 'Malformed offset/text witness types')
    require(all(t=='integer' or v is None for t,v in zip(types,(start,end))), 'Noninteger offset witnesses may not carry integer values')
    if kind=='unsupported_transcription_scaffold':
        require(reason=='transcription_missing_or_not_array' and path=='$.transcription' and raw.get('segment_count') is None
            and start is None and end is None and types==['not_applicable','not_applicable'] and value['nonblank_nonmarker'] is None,
            'Unsupported scaffold witness does not prove the finite native rejection')
        return
    count=raw.get('segment_count'); match=re.fullmatch(r'\$\.transcription\[(\d+)\](.*)',path)
    require(type(count) is int and 1<=count<=4096 and match is not None and int(match[1])<count, 'Structural witness segment is outside retained scaffold')
    suffix=match[2]
    if kind=='zero_duration_speech':
        require(reason=='zero_duration_nonblank_nonmarker' and suffix=='' and integer(start) and integer(end)
            and 0<=start==end and types==['integer','integer'] and value['nonblank_nonmarker'] is True,
            'Zero-duration witness cannot discard, retime or invent speech')
        return
    require(value['nonblank_nonmarker'] is None, 'Invalid-offset/text witness may not synthesize canonical speech')
    if reason=='segment_not_object':
        valid=suffix=='' and start is None and end is None and types==['missing','missing']
    elif reason=='offsets_not_object':
        valid=suffix=='.offsets' and start is None and end is None and types==['missing','missing']
    elif reason=='offset_not_supported_int64':
        side={'.offsets.from':0,'.offsets.to':1}.get(suffix)
        valid=side is not None and types[side] not in {'number','not_applicable'} and (types[side]!='integer' or (start,end)[side] is None)
    elif reason=='speech_not_string':
        valid=suffix=='.text' and all((t=='integer' and integer(v)) or (t=='number' and v is None) for t,v in zip(types,(start,end)))
    elif reason=='negative_start_or_reversed_interval':
        valid=suffix=='.offsets' and integer(start) and integer(end) and types==['integer','integer'] and (start<0 or end<start)
    else: valid=False
    require(valid, 'Invalid offset/text witness does not prove an admitted rejection')


def validate_attempted_cells(stage, plan, matrix, guard):
    """Reject partial/setup/cancel grids before following any forensic path."""
    arms = plan['partition']['arms'] if stage['partition_kind'] == 'family' else {'original':plan['partition']['model']}
    expected = set(itertools.product((c['id'] for c in plan['cases']),
        (a['id'] for a in arms.values()),plan['language_modes'],range(1,plan['repetitions']+1)))
    rows = matrix.get('rows')
    require(isinstance(rows,list), 'Attempted rows must be present')
    keyed = {cell_key(row):row for row in rows}
    require(len(rows) == len(keyed) == stage['planned_cells'] and set(keyed) == expected,
        'Every exact planned cell must be terminal once; no missing/duplicate/selective attempts')
    require(all(row.get('status') in COMPLETE|{'failed'} for row in rows), 'Queued/canceled/nonterminal cells stop continuation')
    require(not any(matrix.get(k) is True for k in ('canceled','cancelled','cancellation_requested')), 'Canceled matrix cannot continue')
    failed = {key:row for key,row in keyed.items() if row['status'] == 'failed'}
    require(all(row.get('measurement') is None for row in failed.values()), 'Failed output must remain unscored')
    rc = 1 if failed else 0
    require_clean_guard(guard,rc)
    return keyed,failed


def validate_terminal_attempts(stage, plan, matrix, guard, classification=None):
    """Pure exact-grid and finite-failure contract; no raw-evidence reads."""
    keyed,failed=validate_attempted_cells(stage,plan,matrix,guard)
    arms=plan['partition']['arms'] if stage['partition_kind']=='family' else {'original':plan['partition']['model']}
    expected=set(keyed); rows=matrix['rows']
    if failed:
        require(isinstance(classification,dict) and classification.get('schema_version') == 'round3-natural-case-failure-classification-v2'
            and classification.get('all_failures_classified') is True
            and type(classification.get('failure_count')) is int and classification['failure_count'] == len(failed)
            and classification.get('unclassified_cells') == []
            and all(classification.get(k) is False for k in ('recognition_performed','rescoring_performed','retry_performed')),
            'Every failed cell needs a sealed, unscored malformed-output classification')
        items = classification.get('failed_cells')
        require(isinstance(items,list) and len(items) == len(failed), 'Failure classification is not exact')
        classified = set()
        for item in items:
            key = classification_key(item.get('key'))
            require(key in failed and key not in classified and all(item['key'][k] == failed[key].get(k) for k in ('path','source_channel')),
                'Forensic failure identity does not match its failed row')
            require(item.get('classification') in {'invalid_utf8_canonical_asr_segment','invalid_utf8_asr_token_text_only',
                'zero_duration_speech','unsupported_transcription_scaffold','invalid_offsets_or_speech'}
                and item.get('status') == 'classified_unscored_failed', 'Only source-pinned malformed-output failures are admissible')
            if item['classification'].startswith('invalid_utf8_'): validate_raw_failure_proof(item)
            else: validate_native_output_proof(item)
            classified.add(key)
        require(classified == set(failed), 'Unclassified failed cells stop continuation')
    else:
        require(classification is None, 'Successful stage may not hide a failure-classification receipt')

    pairs = matrix.get('paired_comparisons')
    require(isinstance(pairs,list), 'Explicit native pair/placeholder grid required')
    paired = pending = derived = derived_pending = placeholders = 0
    if stage['partition_kind'] == 'reference':
        # The unchanged78 analyzer validates the exact canonical20 fields.
        keys = [(x.get('id'),x.get('candidate_model'),x.get('language_mode'),x.get('repeat')) for x in pairs]
        require(len(keys) == len(set(keys)) == len(expected) and set(keys) == expected
            and all(x.get('status') == 'pending_pair' and x.get('comparison_id') is None for x in pairs),
            'Reference placeholders must remain separate exact full-grid runtime markers')
        placeholders = len(pairs)
    else:
        original = arms['original']; comparisons = plan['partition']['comparison_ids']
        roles = {comparisons[role]:role for role in ('permuted_f16','plain_q4','permuted_q4')}
        expected_pairs = set(itertools.product(roles,(c['id'] for c in plan['cases']),
            plan['language_modes'],range(1,plan['repetitions']+1)))
        seen = set()
        for pair in pairs:
            require(isinstance(pair,dict) and type(pair.get('repeat')) is int, 'Invalid native pair identity')
            key = (pair.get('comparison_id'),pair.get('id'),pair.get('language_mode'),pair['repeat'])
            require(key in expected_pairs and key not in seen, 'Missing/duplicate/unplanned native pair')
            role = roles[key[0]]; candidate = arms[role]
            before,after = [keyed[(key[1],a['id'],key[2],key[3])] for a in (original,candidate)]
            endpoints_failed = before['status'] == 'failed' or after['status'] == 'failed'
            require(pair.get('baseline_model') == original['id'] and pair.get('candidate_model') == candidate['id'],
                'Native pair changes original-parent identity')
            require(pair.get('status') == ('pending_pair' if endpoints_failed else 'paired_exploratory'),
                'Pending pairs must correspond exactly to failed endpoints')
            if endpoints_failed:
                require(set(pair) == PENDING_FIELDS and pair.get('pairing_contract_version') == 'model-lineage-v2'
                    and pair.get('candidate_model_sha256') == candidate['sha256']
                    and pair.get('candidate_profile') == pair.get('baseline_profile') == plan['execution']['profile_id'],
                    'Pending pairs must retain only canonical identity, never fabricated deltas/evidence')
                for field in ('id','task','repeat','language_mode','path','source_channel','language','conditions','coverage_role','intervention_id'):
                    require(type(pair.get(field)) is type(after.get(field)) and pair.get(field) == after.get(field), 'Pending pair source identity differs')
                identity_fields = ('id','language','language_mode','path','source_sha256','reference_sha256','scoring_policy','task')
                identity = '|'.join(after[field] for field in identity_fields)+'|'+str(after['source_channel'])+'|'+str(after['repeat'])
                require(pair.get('identity') == identity and pair.get('intervention') == ARM_KINDS[role], 'Pending pair lineage differs')
                pending += 1
            else: paired += 1
            seen.add(key)
        require(seen == expected_pairs and len(seen) == stage['planned_native_parent_pairs'], 'Native planned pair grid differs')
        for case,mode,repeat in itertools.product(plan['cases'],plan['language_modes'],range(1,plan['repetitions']+1)):
            endpoints = [keyed[(case['id'],arms[role]['id'],mode,repeat)] for role in ('plain_q4','permuted_q4')]
            if any(x['status'] == 'failed' for x in endpoints): derived_pending += 1
            else: derived += 1
    require(paired+pending == stage['planned_native_parent_pairs']
        and derived+derived_pending == stage['planned_assessor_derived_q4_pairs']
        and placeholders == stage['runtime_reference_placeholders_planned'], 'Terminal pair accounting differs from fixed plan')
    return {'planned_cells':stage['planned_cells'],'attempted_cells':len(rows),'completed_cells':len(rows)-len(failed),'failed_cells':len(failed),
        'planned_native_parent_pairs':stage['planned_native_parent_pairs'],'completed_native_parent_pairs':paired,'pending_native_parent_pairs':pending,
        'planned_assessor_derived_q4_pairs':stage['planned_assessor_derived_q4_pairs'],'completed_assessor_derived_q4_pairs':derived,
        'pending_assessor_derived_q4_pairs':derived_pending,'runtime_reference_placeholders':placeholders,'all_native_cells_successful':not failed}

def campaign_paths(root):
    root=Path(root)
    return {'journal':str(root/'serial.events.jsonl'),'heldout_family_freeze':str(root/'heldout-family.freeze.json'),
            'cancel_marker':str(root/'cancel-serial.request')}


def stage_paths(root,identifier,held):
    require(isinstance(identifier,str) and re.fullmatch(r'[A-Za-z0-9_-]+',identifier), 'Safe stage ID required')
    folder=Path(root)/identifier; matrix=folder/'matrix'; report=folder/'report-v1.1'; assessment=folder/'assessment-v1'
    return {'stage_directory':str(folder),'matrix_directory':str(matrix),'matrix_json':str(matrix/'matrix.json'),
        'matrix_cancel':str(matrix/'cancel.request'),'guard_receipt':str(folder/'matrix.guard.jsonl'),
        'report_directory':str(report),'report_json':str(report/'report.json'),
        'assessment_directory':str(assessment),'assessment_json':str(assessment/'assessment.json'),
        'classification_receipt':str(folder/'natural-failures.attempted-v2.json'),
        'freeze':str(folder/'freeze.json') if held else None,'final_plan':str(folder/'assessment-plan.final.json') if held else None}


def output_paths(stage):
    return [Path(stage['paths'][key]) for key in ('matrix_directory','guard_receipt','report_directory',
        'assessment_directory','classification_receipt','freeze','final_plan') if stage['paths'][key] is not None]


class Family:
    def __init__(self, path, expected_sha, check=lambda: None):
        require(valid_sha(expected_sha), "Initial family SHA256 argument is required")
        self.path = safe_path(path); self.root = self.path.parent; self.expected_sha = expected_sha; self.check = check
        self.value, _ = read(self.path, expected_sha, check)
        self.bindings, self.snapshots, self.plans = {}, {}, {}
        self.assessor = None; self.attestation = None
        self.validate()

    def bind(self, path, digest):
        path = safe_path(path)
        require(valid_sha(digest) and (str(path) not in self.bindings or self.bindings[str(path)] == digest), "Conflicting/missing input SHA256")
        self.bindings[str(path)] = digest
        require(len(self.bindings) <= 2048, "Immutable file count exceeds its bound")

    def required_binding(self, descriptor):
        require(isinstance(descriptor, dict) and valid_sha(descriptor.get("sha256")), "Complete path/hash descriptor required")
        path = safe_path(descriptor.get("path"))
        require(self.bindings.get(str(path)) == descriptor["sha256"], "Required file is absent from immutable family pins")
        return path

    def validate(self):
        f = self.value
        require(f.get("paths")==campaign_paths(self.root), "Exact sealed campaign paths required")
        require(f.get("schema_version") == "mlp-permutation-family-pre-inference-v1" and
                all(type(f.get(k)) is int for k in ("planned_cells","planned_native_parent_pairs","planned_assessor_derived_q4_pairs")) and
                tuple(f.get(k) for k in ("planned_cells", "planned_native_parent_pairs", "planned_assessor_derived_q4_pairs")) == TOTALS,
                "Incorrect fixed family/grid totals")
        require(f.get("promotion_authorized") is False and f.get("fresh_heldout_reference_content_inspected") is False and
                f.get("native_v2_grouping_approval") is False and f.get("controlled_resources") == "NOT EVALUATED",
                "Pending native/resource/promotion policy differs")
        require(isinstance(f.get("budgets"), dict) and f["budgets"], "Predeclared quality budgets required")
        pins = f.get("immutable_files")
        require(isinstance(pins, list) and pins and len(pins) <= 2048, "Bounded immutable pin list required")
        for pin in pins:
            require(isinstance(pin, dict), "Invalid immutable pin")
            path = safe_path(pin.get("path"))
            require(str(path) not in self.bindings and path != self.path, "Duplicate/circular immutable pin")
            self.bind(path, pin.get("sha256"))
        require(isinstance(f.get("tools"), dict) and set(f["tools"]) ==
                {"guard", "reporter", "assessor", "affine_helpers", "ggml_parser", "coordinator", "sealer", "failure_classifier"}, "All exact orchestration/tool pins required")
        self.tools = f["tools"]
        for tool in self.tools.values(): self.required_binding(tool)
        for name,file in (('coordinator','run-remaining.py'),('sealer','seal-heldout.py')):
            require(self.tools[name]['path']==str(self.root/file),'Canonical orchestration source path required')
        quality=self.root/'quality/scripts/quality'
        for name,file in (('assessor','assess-mlp-permutation.py'),('affine_helpers','assess-affine-pilot.py'),
                          ('reporter','report-pilot.py'),('ggml_parser','ggml_weights.py')):
            require(self.tools[name]['path']==str(quality/file),'Canonical deep helper package required for output boundaries/imports')
        require(self.tools["guard"] == {"path":str(self.root/"run-guard.py"), "sha256":GUARD_SHA}, "Exact inspected guard required")
        require(self.tools["failure_classifier"] == {"path":str(self.root/"classify-native-output-failure-v2.py"), "sha256":CLASSIFIER_SHA}, "Exact finite forensic classifier required")
        require(f.get("permutation") == {"version":"whisper-mlp-permutation-v1", "recipe_sha256":RECIPE_SHA}, "Global frozen permutation policy differs")
        q=f.get("quantization", {})
        require(set(q)=={"format","ftype","quantizer_sha256"} and q.get("format")=="q4_0" and type(q.get("ftype")) is int and q["ftype"]==2 and valid_sha(q.get("quantizer_sha256")), "Frozen official Q4 quantization differs")
        require(type(f.get("planned_reference_runtime_placeholders")) is int and f["planned_reference_runtime_placeholders"]==PLACEHOLDERS, "Reference placeholder grid differs")
        require(self.bindings.get(str(quality/'mlp-permute.py'))==RECIPE_SHA,'Frozen operator source is missing')
        self.required_binding(f.get("runner")); self.required_binding(f.get("baseline_control"))
        self.required_binding(f.get("profile")); self.required_binding(f.get("runtime_record"))
        require(f["profile"].get("id") == "current-defaults" and valid_sha(f["profile"].get("settings_sha256")), "Fixed profile/settings required")
        natives = f.get("native_files")
        require(isinstance(natives, list) and len(natives) == 11 and len({x.get("path") for x in natives}) == 11,
                "Exact eleven-file native inventory pins required")
        for value in natives: self.required_binding(value)
        quantizer=self.required_binding(f.get('quantizer'))
        require(quantizer.name=='whisper-quantize' and f['quantizer']['sha256']==q['quantizer_sha256'],'Separate official Q4 executable pin differs')
        models = f.get("models")
        require(isinstance(models, list) and len(models) == 11 and all(isinstance(m, dict) for m in models), "Exactly11 frozen artifacts required")
        self.models = {m.get("id"): m for m in models}
        require(len(self.models) == 11 and all(isinstance(k, str) and k for k in self.models), "Duplicate/missing artifact ID")
        require(Counter(m.get("kind") for m in models) == Counter(pretrained=5, conversion_control=2, compression=2, combined=2), "Frozen model roles differ")
        for model in models:
            self.required_binding(model)
            require(type(model.get("model_file_bytes")) is int and model["model_file_bytes"] > 0, "Positive exact model bytes required")
        require({m['id'] for m in models if m['kind']=='pretrained'}==set(MODELS),'Five exact original model identities required')
        for model in models:
            parent=self.models.get(model.get('parent_original_id'),{})
            require(parent.get('kind')=='pretrained' and model.get('parent_original_sha256')==parent.get('sha256')
                and (model['kind']!='pretrained' or model['id']==parent.get('id')),'Full-family original-parent lineage differs')
        stages = f.get("stages")
        expected = [(stage, prefix + "-" + model, model, count, modes, repetitions)
                    for stage, prefix, count, modes, repetitions in STAGE_RULES for model in MODELS]
        require(isinstance(stages, list) and len(stages) == 15, "All15 predeclared partitions required")
        signatures = {}
        for s, (stage, identifier, model, count, modes, repetitions) in zip(stages, expected):
            require(isinstance(s, dict) and s.get("id") == identifier and s.get("stage") == stage and s.get("partition_id") == model,
                    "Stage order or partition identity differs")
            kind = "family" if model in {"small", "large-v3-turbo"} else "reference"
            nmodels, npairs = (4, 3) if kind == "family" else (1, 0)
            multiplier = count * len(modes) * repetitions
            require(s.get("partition_kind") == kind and s.get("language_modes") == modes and type(s.get("repetitions")) is int and s["repetitions"] == repetitions and
                    all(type(s.get(k)) is int for k in ('planned_cells','planned_native_parent_pairs','planned_assessor_derived_q4_pairs')) and
                    (s.get("planned_cells"), s.get("planned_native_parent_pairs"), s.get("planned_assessor_derived_q4_pairs")) ==
                    (multiplier * nmodels, multiplier * npairs, multiplier if kind == "family" else 0) and
                    type(s.get("guard_timeout_seconds")) is int and s["guard_timeout_seconds"] == (10800 if stage == "held_out" else 3600), "Fixed stage grid/bound differs")
            for field, sha_field in (("corpus", "corpus_sha256"), ("configuration", "configuration_sha256"),
                                     ("assessment_pre_freeze_plan", "assessment_pre_freeze_plan_sha256"), ("source_snapshot", "source_snapshot_sha256")):
                self.required_binding({"path": s.get(field), "sha256": s.get(sha_field)})
            folder = Path(s["configuration"]).parent
            require(s.get("paths")==stage_paths(self.root,identifier,stage=="held_out"), "Exact sealed stage path-map differs")
            require(folder==self.root/identifier,'Exact stage folder must match its predeclared ID')
            require(self.root in folder.parents and all(Path(s[k]).parent == folder for k in ("corpus", "assessment_pre_freeze_plan", "source_snapshot")), "Stage metadata must share its protected folder")
            require(s.get("freeze") == str(folder / "freeze.json") if stage == "held_out" else s.get("freeze") is None, "Predeclared held-out freeze path differs")
            require(type(s.get("runtime_reference_placeholders_planned")) is int and s["runtime_reference_placeholders_planned"]== (multiplier if kind=="reference" else 0), "Stage reference placeholder grid differs")
            plan, _ = read(s["assessment_pre_freeze_plan"], s["assessment_pre_freeze_plan_sha256"], self.check)
            require(plan.get("schema_version") == "mlp-permutation-assessment-plan-v1" and plan.get("stage") == stage and
                    plan.get("split") == ("held_out" if stage == "held_out" else "development") and plan.get("language_modes") == modes and plan.get("repetitions") == repetitions,
                    "Assessment preplan scope differs")
            require("freeze_sha256" not in plan.get("execution", {}) and not any(k in plan for k in ("pre_freeze_plan_sha256", "pre_freeze_family_seal_sha256")), "Preplan already changed by a freeze")
            require(plan.get("permutation")==f["permutation"] and plan.get("quantization")==f["quantization"], "Stage recipe/quantizer policy differs")
            cases = plan.get("cases")
            require(isinstance(cases, list) and len(cases) == count and all(isinstance(c, dict) for c in cases) and
                    Counter(c.get("language") for c in cases) == Counter({language: count // 9 for language in LANGUAGES}), "Incorrect source/language denominator")
            case_signature = {(c.get("id"), c.get("source_id"), c.get("source_sha256"), c.get("reference_sha256")) for c in cases}
            require(len(case_signature) == count and all(all(isinstance(x, str) and x for x in row) and valid_sha(row[2]) and valid_sha(row[3]) for row in case_signature), "Invalid case/source/hash grid")
            require(all(len({row[column] for row in case_signature}) == count for column in range(4)) and
                    all(type(c.get("source_channel")) is int and c["source_channel"] >= 0 and
                        c.get("task") == ("standard_rendering" if c["language"] == "de-CH" else "transcription") for c in cases), "Duplicate source identity or incorrect source task/channel")
            require(stage not in signatures or signatures[stage] == case_signature, "Sources differ between model partitions")
            signatures[stage] = case_signature
            partition = plan.get("partition", {})
            require(partition.get("id") == model and partition.get("kind") == kind, "Planned model family differs")
            arms = partition.get("arms", {}) if kind == "family" else {"original": partition.get("model", {})}
            require(len(arms) == nmodels and {v.get("id") for v in arms.values()} == set(s.get("models", [])), "Stage model membership differs")
            require(set(arms) == ({"original", "permuted_f16", "plain_q4", "permuted_q4"} if kind == "family" else {"original"}), "Missing/extra family arm role")
            kinds = {"original": "pretrained", "permuted_f16": "conversion_control", "plain_q4": "compression", "permuted_q4": "combined"}
            for role, arm in arms.items():
                reference = self.models.get(arm.get("id"), {})
                require(arm.get("sha256") == reference.get("sha256") and arm.get("model_file_bytes") == reference.get("model_file_bytes") and
                        reference.get("kind") == kinds[role] and reference.get('parent_original_id')==model, "Stage artifact/role differs from full-family pin")
            comparisons = partition.get("comparison_ids", {})
            require(set(comparisons) == (set(kinds) - {"original"} if kind == "family" else set()) and
                    len(set(comparisons.values())) == npairs, "Incorrect native parent-comparison grid")
            execution = plan.get("execution", {})
            for key, value in (("runner_sha256", f["runner"]["sha256"]), ("profile_sha256", f["profile"]["sha256"]),
                               ("runtime_settings_sha256", f["profile"]["settings_sha256"]), ("profile_id", "current-defaults"), ("threads", 2),
                               ("vad_model_sha256", None), ("corpus_sha256", s["corpus_sha256"]), ("configuration_sha256", s["configuration_sha256"])):
                require(type(execution.get(key)) is type(value) and execution.get(key) == value, "Preplan runtime/profile pin differs")
            require(plan.get("runtime_record", {}).get("path") == f["runtime_record"]["path"] and
                    plan["runtime_record"]["sha256"] == f["runtime_record"]["sha256"], "Preplan runtime record differs")
            require(any(x["sha256"] == execution.get("whisper_binary_sha256") and Path(x["path"]).name == "whisper-cli" for x in natives), "Preplan native CLI pin missing")
            config, _ = read(s["configuration"], s["configuration_sha256"], self.check)
            require(config.get("split") == plan["split"] and type(config.get("repetitions")) is int and config["repetitions"] == repetitions and
                    config.get("language_modes") == modes and config.get("threads") == 2 and config.get("paths") == ["final"] and
                    config.get("freeze") == s.get("freeze"), "Actual runner configuration differs from planned bounded stage")
            config_models = config.get("models", [])
            require(isinstance(config_models, list) and len(config_models) == nmodels and {v.get("id") for v in config_models} == set(s["models"]), "Actual runner model grid differs")
            for value in config_models:
                pinned = self.models[value["id"]]
                require(all(value.get(k) == pinned.get(k) for k in ("path", "sha256", "kind")), "Actual runner model artifact differs")
                if pinned["kind"] == "pretrained":
                    require(all(value.get(k) is None for k in ("baseline_model_id", "baseline_model_sha256", "intervention_id")),
                            "Original runner configuration cannot contain adaptation lineage")
                else:
                    require(value.get("baseline_model_id") == model and value.get("baseline_model_sha256") == arms["original"]["sha256"] and
                            value.get("intervention_id") == value["id"], "Actual runner adaptation lineage differs")
            require(len(config.get("comparisons", [])) == npairs and {v.get("id") for v in config["comparisons"]} == set(comparisons.values()), "Actual native parent pairs differ")
            by_comparison = {v["id"]: v for v in config["comparisons"]}
            for role, comparison_identifier in comparisons.items():
                value = by_comparison[comparison_identifier]
                require(value.get("intervention") == kinds[role] and value.get("baseline_model_id") == model and
                        value.get("candidate_model_id") == arms[role]["id"] and
                        value.get("baseline_profile_id") == value.get("candidate_profile_id") == "current-defaults",
                        "Actual native pair lineage/profile differs")
            require(self.bindings.get(config.get("whisper_cli")) == execution["whisper_binary_sha256"], "Actual native binary differs")
            require(config.get("schema_version") == "1.0" and config.get("baseline_revision") == f["baseline_control"]["source_revision"] and
                    config.get("baseline_cli") == f["baseline_control"]["path"] and config.get("baseline_cli_sha256") == f["baseline_control"]["sha256"] and
                    config.get("capture_inactive") is True, "Actual untouched control/capture attestation differs")
            require(config.get("profiles") == [{"id": "current-defaults", "kind": "candidate", "source_revision": f["runner"]["source_revision"], "settings": f["profile"]["path"]}], "Actual runtime profile differs")
            corpus, _ = read(s["corpus"], s["corpus_sha256"], self.check)
            corpus_cases = corpus.get("cases")
            require(corpus.get("schema_version") == "1.0" and isinstance(corpus_cases, list) and len(corpus_cases) == count and
                    len({c.get("id") for c in corpus_cases}) == count, "Actual runner corpus grid differs")
            planned_cases = {c["id"]: c for c in cases}
            for case in corpus_cases:
                planned = planned_cases.get(case.get("id"), {})
                require(all(type(case.get(k)) is type(planned.get(k)) and case.get(k) == planned.get(k)
                            for k in ("id", "language", "task", "source_channel", "source_id", "reference_sha256")) and
                        case.get("sha256") == planned.get("source_sha256") and case.get("split") == plan["split"] and
                        case.get("scoring_policy") == "swift-nfc-casefold-alphanumeric-v1" and case.get("reviewed") is False and
                        case.get("code_switches", []) == planned.get("code_switches", []), "Actual runner source/scoring metadata differs")
                for path_field, hash_field in (("audio", "sha256"), ("reference", "reference_sha256")):
                    self.bind(case.get(path_field), case.get(hash_field))
            if stage == "held_out":
                require(corpus.get("frozen") is True and corpus.get("native_review_status") == "UNRESOLVED" and
                        corpus.get("reference_content_inspected") is False,
                        "Held-out corpus freeze/native/content attestation differs")
            self.plans[s["id"]] = plan
        for a, b in itertools.combinations(signatures.values(), 2):
            for column in range(4): require(not ({r[column] for r in a} & {r[column] for r in b}), "Panel/development/held-out source identity overlap")
        require(set(self.plans) == {s["id"] for s in stages}, "All15 stage plans must remain addressable by their exact stage ID")
        require(tuple(sum(s[k] for s in stages) for k in ("planned_cells", "planned_native_parent_pairs", "planned_assessor_derived_q4_pairs")) == TOTALS, "Cumulative grids differ")

    def verify_step(self):
        self.check(); read(self.path, self.expected_sha, self.check)
        require(self.snapshots and all(identity(Path(path)) == value for path, value in self.snapshots.items()), "Frozen file identity changed between steps")
        self.check()

    def verify_all(self):
        self.check(); read(self.path, self.expected_sha, self.check)
        require(sum(identity(Path(path))[2] for path in self.bindings) <= 32 * 1024**3, "Family inputs exceed 32 GiB bound")
        current = {}
        for name, expected in self.bindings.items():
            path = safe_path(name); before = identity(path)
            require(sha(path, self.check) == expected and identity(path) == before, "Frozen family input changed")
            current[name] = before
        for model in self.value["models"]: require(current[model["path"]][2] == model["model_file_bytes"], "Frozen model byte count differs")
        require(not self.snapshots or current == self.snapshots, "Frozen input was changed/replaced")
        self.snapshots = current
        self.verify_step()

    def tool(self, name):
        descriptor = self.value["tools"][name]
        require(sha(descriptor["path"], self.check) == descriptor["sha256"], "Frozen tool changed")
        specification = importlib.util.spec_from_file_location("round5_" + name, descriptor["path"])
        module = importlib.util.module_from_spec(specification); sys.modules[specification.name] = module
        specification.loader.exec_module(module)
        return module

    def bind_initial_attestation(self, descriptor):
        require(self.attestation is None and isinstance(descriptor, dict) and set(descriptor)=={'path','sha256'},
                'Exactly one separately pinned native idle attestation is required')
        value,_=read(descriptor['path'],descriptor['sha256'],self.check)
        require(value.get('schema_version')=='round5-native-idle-attestation-v1'
            and value.get('recording_active') is False and value.get('live_transcription_active') is False
            and value.get('inspection_method')=='native-ui' and isinstance(value.get('inspected_utc'),str)
            and value['inspected_utc'] and isinstance(value.get('app_path'),str) and value['app_path'].startswith('/')
            and isinstance(value.get('bundle_identifier'),str) and value['bundle_identifier'],
            'Native idle/live-off observation is not complete; metadata preparation is not that check')
        require(datetime.fromisoformat(value['inspected_utc'].replace('Z','+00:00')).tzinfo is not None,'Idle observation requires an explicit timezone')
        self.bind(descriptor['path'],descriptor['sha256']); self.attestation=dict(descriptor)

    def guard_metadata(self,path):
        self.check(); path=safe_path(path); before=identity(path)
        require(before[2]<=4*1024*1024,'Guard evidence exceeds its bound')
        with path.open('rb') as stream: raw=stream.read(4*1024*1024+1)
        require(len(raw)<=4*1024*1024 and identity(path)==before,'Guard changed during bounded read')
        events=[json.loads(line) for line in raw.splitlines() if line.strip()]
        require(events and all(isinstance(x,dict) for x in events)
            and not any(x.get('event') in {'owned_group_signal','owned_cli_signal','cancel_requested','interrupted','cancelled'} for x in events),
            'Any guard interruption or signal prevents natural-failure continuation')
        self.check(); return events,hashlib.sha256(raw).hexdigest()

    def terminal(self,stage,plan=None):
        self.verify_step(); folder=Path(stage['configuration']).parent
        require(not (Path(stage['paths']['matrix_cancel'])).exists(),'Matrix cancellation stops work; cell cleanup markers are separate')
        if plan is None: plan=self.plans[stage['id']]
        matrix,matrix_sha=read(Path(stage['paths']['matrix_json']),check=self.check)
        events,guard_sha=self.guard_metadata(Path(stage['paths']['guard_receipt']))
        classification=classification_ref=None
        if any(row.get('status')=='failed' for row in matrix.get('rows',[])):
            path=Path(stage['paths']['classification_receipt']); classification,digest=read(path,check=self.check)
            classification_ref={'path':str(path),'sha256':digest}
            require(classification.get('matrix')=={'path':str(Path(stage['paths']['matrix_json'])),'sha256':matrix_sha}
                and type(classification.get('matrix_bytes')) is int and classification['matrix_bytes']==identity(Path(stage['paths']['matrix_json']))[2]
                and classification.get('classified_failure_count')==classification.get('failure_count')
                and classification.get('classifier')==self.tools['failure_classifier']
                and all(classification.get(k) is False for k in ('reference_audio_model_paths_followed','text_emitted','source_bytes_modified')),
                'Failure classification does not bind the exact matrix/tool or preserve opaque bytes')
        else: require(not (Path(stage['paths']['classification_receipt'])).exists(),'Successful grid cannot hide a forensic receipt')
        counts=validate_terminal_attempts(stage,plan,matrix,events[-1],classification)
        self.check(); require(not (Path(stage['paths']['matrix_cancel'])).exists(),'Matrix cancellation arrived during terminal verification')
        return matrix,{**counts,'matrix_sha256':matrix_sha,'guard_sha256':guard_sha,'failure_classification':classification_ref}

    def stage_evidence(self,stage,binding=None):
        folder=Path(stage['configuration']).parent
        plan_path=stage['assessment_pre_freeze_plan'] if binding is None else Path(stage['paths']['final_plan'])
        plan_sha=stage['assessment_pre_freeze_plan_sha256'] if binding is None else binding['final_plan_sha256']
        plan,_=read(plan_path,plan_sha,self.check); matrix,result=self.terminal(stage,plan)
        report,report_sha=read(Path(stage['paths']['report_json']),check=self.check)
        assessment,assessment_sha=read(Path(stage['paths']['assessment_json']),check=self.check)
        expected={'report_sha256':report_sha,'matrix_sha256':result['matrix_sha256'],'plan_sha256':plan_sha,
            'runtime_record_sha256':self.value['runtime_record']['sha256'],'analyzer_sha256':self.tools['assessor']['sha256'],
            'reused_affine_helpers_sha256':self.tools['affine_helpers']['sha256'],'public_reporter_sha256':self.tools['reporter']['sha256']}
        require(assessment.get('evidence')==expected,'Assessment evidence/source identity differs')
        if self.assessor is None: self.assessor=self.tool('assessor')
        rebuilt=self.assessor.assess(report,matrix,result['matrix_sha256'],plan)
        for key,value in rebuilt.items():
            if key!='created_utc': require(self.assessor.equivalent(assessment.get(key),value),'Frozen assessment rebuild differs: '+key)
        modes=assessment['model_mode_assessments']
        require(sum(x['coverage']['completed_inference_cells'] for x in modes)==result['completed_cells']
            and sum(x['coverage']['completed_native_parent_pair_cells'] for x in modes)==result['completed_native_parent_pairs']
            and sum(x['coverage'].get('completed_assessor_derived_q4_pair_cells',0) for x in modes)==result['completed_assessor_derived_q4_pairs'],
            'Successful native/derived coverage differs from frozen analyzer')
        if result['failed_cells']:
            failed_modes={row['language_mode'] for row in matrix['rows'] if row['status']=='failed'}
            require(assessment.get('default_promotion') is False
                and assessment.get('partition_assessment',{}).get('decision') in {'reject','inconclusive_no_promotion'}
                and all(x.get('gates',{}).get('complete_planned_inference_grid') is None
                    and x.get('decision') in {'reject','inconclusive_no_promotion'} for x in modes if x['language_mode'] in failed_modes),
                'Missing quality cannot pass or promote')
        result.update(id=stage['id'],stage=stage['stage'],report_sha256=report_sha,assessment_sha256=assessment_sha,
            plan_sha256=plan_sha,decision=assessment['partition_assessment'],default_promotion=False,analysis_source=self.tools['assessor'])
        self.verify_step(); return result


def seal(family,output):
    output=safe_path(output,existing=False)
    require(output==Path(family.value['paths']['heldout_family_freeze']) and not output.exists(),'New all-five held-out receipt required')
    require(family.attestation is not None,'Initial native idle attestation must be separately bound')
    family.verify_all(); earlier=family.value['stages'][:10]; held=family.value['stages'][10:]
    require(len(earlier)==10 and len(held)==5 and all(s['stage']!='held_out' for s in earlier)
        and all(s['stage']=='held_out' for s in held),'All10 prior and all5 held stages required')
    history=[family.stage_evidence(s) for s in earlier]
    require(all(x['attempted_cells']==x['planned_cells'] for x in history),'All10 complete terminal attempt grids required')
    descriptors=[]
    for s in held:
        folder=Path(s['configuration']).parent
        require(not any(path.exists() for path in output_paths(s)),'Held-out outcome or freeze already exists; no retry')
        descriptors.append({k:s[k] for k in ('id','corpus_sha256','configuration_sha256','assessment_pre_freeze_plan_sha256','models')})
    shared={'created_utc':datetime.now(timezone.utc).isoformat(),'original_family_seal_sha256':family.expected_sha,
        'initial_attestation':family.attestation,'analysis_source':family.tools['assessor'],
        'attestation_actor':{'kind':'AI','name':'Codex','human_native_approval':False,'scope':'Hash and terminal-attempt chronology only'},
        'selection':'All11 artifacts/all5 held partitions fixed; failed native output remains unscored; no retry or retuning',
        'fresh_heldout_reference_content_inspected':False,'heldout_outcomes_used_for_selection':False,'source_files_preserved':True,
        'budgets':family.value['budgets'],'development_history':history,'all_heldout_partitions':descriptors,
        'development_attempted_cells':sum(x['attempted_cells'] for x in history),
        'development_completed_cells':sum(x['completed_cells'] for x in history),'development_failed_cells':sum(x['failed_cells'] for x in history),
        'permutation':family.value['permutation'],'quantization':family.value['quantization'],
        'default_promotion':False,'native_review':'PENDING','resource_acceptance':'NOT EVALUATED'}
    parts=[]
    for s in held:
        family.verify_step(); original=family.plans[s['id']]
        freeze={**shared,'schema_version':'1.0','frozen_before_held_out':True,'corpus_sha256':s['corpus_sha256'],
            'experiment_sha256':s['configuration_sha256'],'profiles':{family.value['profile']['id']:family.value['profile']['sha256']},
            'runner_sha256':original['execution']['runner_sha256'],'whisper_binary_sha256':original['execution']['whisper_binary_sha256'],
            'partition':original['partition'],'assessment_tool_sha256':family.tools['assessor']['sha256']}
        freeze_sha=save_new(Path(s['freeze']),freeze,family.check)
        final=json.loads(json.dumps(original)); final['execution']['freeze_sha256']=freeze_sha
        final['pre_freeze_plan_sha256']=s['assessment_pre_freeze_plan_sha256']; final['pre_freeze_family_seal_sha256']=family.expected_sha
        stripped=json.loads(json.dumps(final)); stripped['execution'].pop('freeze_sha256')
        stripped.pop('pre_freeze_plan_sha256'); stripped.pop('pre_freeze_family_seal_sha256')
        require(stripped==original,'Only the three declared final-plan links may change')
        final_sha=save_new(Path(s['paths']['final_plan']),final,family.check)
        parts.append({'id':s['id'],'freeze_sha256':freeze_sha,'final_plan_sha256':final_sha,'configuration_sha256':s['configuration_sha256'],
            'corpus_sha256':s['corpus_sha256'],'pre_freeze_plan_sha256':s['assessment_pre_freeze_plan_sha256']})
    family.verify_all(); family.check()
    record={**shared,'schema_version':'mlp-permutation-heldout-family-freeze-v1','partitions':parts,
        'planned_cells':TOTALS[0],'planned_native_parent_pairs':TOTALS[1],'planned_assessor_derived_q4_pairs':TOTALS[2],
        'planned_reference_runtime_placeholders':PLACEHOLDERS}
    return save_new(output,record,family.check),record


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--family-seal',type=Path,required=True); parser.add_argument('--family-seal-sha256',required=True)
    parser.add_argument('--expected-source-sha256',required=True); parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--initial-attestation',type=Path,required=True); parser.add_argument('--initial-attestation-sha256',required=True)
    args=parser.parse_args(argv); requested={'stop':False}
    def stop(_number,_frame): requested['stop']=True
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP): signal.signal(number,stop)
    def check():
        if requested['stop'] or (R/'cancel-serial.request').exists(): raise InterruptedError('Round5 sealing canceled')
    require(sha(Path(__file__),check)==args.expected_source_sha256,'Explicit sealer source lock differs')
    require(args.family_seal==R/'pre-inference-family-seal.json','Exact round5 family path required')
    family=Family(args.family_seal,args.family_seal_sha256,check)
    require(family.tools['sealer']=={'path':str(Path(__file__).resolve()),'sha256':args.expected_source_sha256},'Family sealer source differs')
    family.bind_initial_attestation({'path':str(args.initial_attestation),'sha256':args.initial_attestation_sha256})
    digest,record=seal(family,args.output)
    print(json.dumps({'heldout_family_freeze_sha256':digest,'partitions':record['partitions'],'default_promotion':False}))


if __name__=='__main__':
    try: main()
    except (ValueError,OSError,InterruptedError) as error:
        print(type(error).__name__+': '+str(error),file=sys.stderr); raise SystemExit(1)

