#!/usr/bin/env python3
"""Tiny opaque files only; never open campaign outcomes/models/audio/references."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

R=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('toy_postrun_preservation',R/'audit-postrun-preservation-v1.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)


def encoded(value):return (json.dumps(value,sort_keys=True)+'\n').encode()
def digest(raw):return hashlib.sha256(raw).hexdigest()


class Fixture:
    def __init__(self,root,reverse=False):
        self.root=Path(root).resolve()
        def file(name,data):
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True)
            if not isinstance(data,bytes):data=encoded(data)
            path.write_bytes(data);return {'path':str(path),'sha256':digest(data)}
        self.file=file
        self.payloads=[file('inputs/'+name,(name+' opaque toy').encode()) for name in ('weight.bin','audio.bin','reference.bin','provenance.bin')]
        integrity={'case_count':216,'raw_reference_semantic_inspection':False,
            'input_metadata_and_hashes':[self.payloads[3]],'opaque_case_evidence':[{'opaque_inputs':self.payloads[1:3]}]}
        self.integrity=file('integrity.json',integrity)
        self.admission=file('inference-launch.freeze.v1.json',{'frozen_inputs':{'toy':self.payloads[3]},
            **{k:self.payloads[3] for k in ('native_load_receipt','native_load_guard','native_load_launch','independent_static_audit')}})
        stages=[];assessed=[]
        for stage,prefix,count,modes,repetitions in (('panel','panel',9,2,3),('development','dev-validation',72,1,1),('held_out','heldout',144,2,1)):
            for model in ('tiny','base','small','large-v3-turbo','large-v3'):
                family=model in {'small','large-v3-turbo'};mult=count*modes*repetitions;identifier=prefix+'-'+model
                s={'id':identifier,'stage':stage,'partition_kind':'family' if family else 'reference',
                    'planned_cells':mult*(4 if family else 1),'planned_native_parent_pairs':mult*(3 if family else 0),
                    'planned_assessor_derived_q4_pairs':mult if family else 0,'runtime_reference_placeholders_planned':0 if family else mult}
                stages.append(s)
                event={'event':'stage_assessed','id':identifier,'stage':stage,'planned_cells':s['planned_cells'],
                    'attempted_cells':s['planned_cells'],'completed_cells':s['planned_cells'],'failed_cells':0,
                    'planned_native_parent_pairs':s['planned_native_parent_pairs'],'completed_native_parent_pairs':s['planned_native_parent_pairs'],
                    'pending_native_parent_pairs':0,'planned_assessor_derived_q4_pairs':s['planned_assessor_derived_q4_pairs'],
                    'completed_assessor_derived_q4_pairs':s['planned_assessor_derived_q4_pairs'],'pending_assessor_derived_q4_pairs':0,
                    'runtime_reference_placeholders':s['runtime_reference_placeholders_planned'],'default_promotion':False}
                for relative,key in (('matrix/matrix.json','matrix_sha256'),('matrix.guard.jsonl','guard_sha256'),
                    ('report-v1.1/report.json','report_sha256'),('assessment-v1/assessment.json','assessment_sha256')):
                    event[key]=file(identifier+'/'+relative,{'toy':identifier,'file':relative})['sha256']
                names=['z-root.bin','a-root.bin','nested/z.bin','nested/a.bin']
                if reverse:names.reverse()
                for name in names:file(identifier+'/matrix/'+name,('retained opaque '+name).encode())
                assessed.append(event)
        self.family={'stages':stages,'immutable_files':[self.payloads[0]],'inputs':{'integrity':self.integrity}}
        self.family_d=file('pre-inference-family-seal.json',self.family)
        keys=('planned_cells','attempted_cells','completed_cells','failed_cells','planned_native_parent_pairs','completed_native_parent_pairs',
            'pending_native_parent_pairs','planned_assessor_derived_q4_pairs','completed_assessor_derived_q4_pairs',
            'pending_assessor_derived_q4_pairs','runtime_reference_placeholders')
        totals={k:sum(e[k] for e in assessed) for k in keys}
        self.events=[{'event':'serial_started','family_seal_sha256':self.family_d['sha256']},*assessed,
            {'event':'serial_finished','family_seal_sha256':self.family_d['sha256'],'default_promotion':False,**totals}]
        self.publish_journal()

    def publish_journal(self):
        self.journal_d=self.file('serial.events.jsonl',b''.join(encoded(e) for e in self.events))

    def run(self,name='result'):
        own=digest((R/'audit-postrun-preservation-v1.py').read_bytes())
        with patch.object(audit,'R',self.root),patch.object(audit,'FAMILY_SHA',self.family_d['sha256']),\
             patch.object(audit,'INTEGRITY_SHA',self.integrity['sha256']),patch.object(audit,'ADMISSION_SHA',self.admission['sha256']),\
             patch.object(audit.signal,'signal'):
            audit.main(['--journal-sha256',self.journal_d['sha256'],'--expected-source-sha256',own,'--output',str(self.root/name)])
        return json.loads((self.root/name/'preservation.json').read_bytes())


class OpaqueHashContracts(unittest.TestCase):
    def test_missing_mutated_and_replaced_files_fail_without_modifying_them(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();p=root/'toy.bin';p.write_bytes(b'original');original=digest(p.read_bytes())
            a=audit.Audit(root/'result');a.digest(p,original)
            replacement=root/'replacement.bin';replacement.write_bytes(b'original');os.replace(replacement,p)
            with self.assertRaisesRegex(ValueError,'changed'):a.digest(p,original)
            p.write_bytes(b'mutated')
            with self.assertRaisesRegex(ValueError,'SHA'):audit.Audit(root/'result').digest(p,original)
            self.assertEqual(p.read_bytes(),b'mutated')
            p.unlink()
            with self.assertRaises(OSError):a.digest(p,original)

    def test_symlinks_and_per_file_or_total_bounds_are_rejected_before_open(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();p=root/'toy.bin';p.write_bytes(b'12345');link=root/'link.bin';link.symlink_to(p)
            with self.assertRaisesRegex(ValueError,'nonsymlink'):audit.Audit(root/'result').digest(link)
            with self.assertRaisesRegex(ValueError,'bound'):audit.Audit(root/'result').digest(p,maximum=4)
            with patch.object(audit,'MAX_TOTAL_BYTES',4),self.assertRaisesRegex(ValueError,'32GiB'):audit.Audit(root/'result').digest(p)

    def test_cancel_before_and_during_hash_retains_bytes_and_never_caches_success(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();p=root/'toy.bin';p.write_bytes(b'opaque');a=audit.Audit(root/'result');a.stopped=True
            with self.assertRaises(InterruptedError):a.digest(p)
            a.stopped=False;real_open=Path.open
            class Reader:
                def __init__(self,handle):self.handle=handle
                def __enter__(self):return self
                def __exit__(self,*args):self.handle.close()
                def read(self,count):a.stopped=True;return self.handle.read(count)
            def opened(path,*args,**kwargs):
                handle=real_open(path,*args,**kwargs)
                return Reader(handle) if path==p and args and args[0]=='rb' else handle
            with patch.object(Path,'open',opened),self.assertRaises(InterruptedError):a.digest(p)
            self.assertNotIn(str(p),a.files);self.assertEqual(p.read_bytes(),b'opaque')

    def test_actual_growth_cannot_read_a_second_full_file_past_its_initial_bound(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();p=root/'toy.bin';p.write_bytes(b'x'*4096);a=audit.Audit(root/'result');real_open=Path.open;physical={'bytes':0}
            class Growing:
                def __init__(self,handle):self.handle=handle;self.grown=False
                def __enter__(self):return self
                def __exit__(self,*args):self.handle.close()
                def read(self,count):
                    data=self.handle.read(count)
                    physical['bytes']+=len(data)
                    if not self.grown:
                        self.grown=True
                        with real_open(p,'ab') as target:target.write(b'y'*4096)
                    return data
            def opened(path,*args,**kwargs):
                handle=real_open(path,*args,**kwargs)
                return Growing(handle) if path==p and args and args[0]=='rb' else handle
            with patch.object(Path,'open',opened),self.assertRaises(ValueError):a.digest(p,maximum=4096)
            self.assertLessEqual(physical['bytes'],4097);self.assertLessEqual(a.total_bytes,4097);self.assertNotIn(str(p),a.files)

    def test_nonfinite_exponent_is_not_valid_metadata(self):
        with self.assertRaises(ValueError):audit.decode(b'{"number":1e999}')

    def test_metadata_reread_is_refused_before_physical_budget_overrun(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();p=root/'toy.json';raw=b'{"x":1}';p.write_bytes(raw);a=audit.Audit(root/'result');a.digest(p,digest(raw))
            with patch.object(audit,'MAX_TOTAL_BYTES',len(raw)),patch.object(Path,'open',side_effect=AssertionError('No reread may start')):
                with self.assertRaisesRegex(ValueError,'before IO'):a.metadata(p,digest(raw))
            self.assertEqual(a.total_bytes,len(raw))

    def test_metadata_raw_helper_counts_both_bounded_reads(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();p=root/'toy.json';raw=b'{"x":1}';p.write_bytes(raw);a=audit.Audit(root/'result')
            self.assertEqual(a.metadata(p,digest(raw)),{'x':1});self.assertEqual(a.total_bytes,2*len(raw))



if __name__=="__main__":unittest.main(verbosity=2)
