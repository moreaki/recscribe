#!/usr/bin/env python3
"""Synthetic literal/actual child contracts; no real model/native/ASR loads."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

R=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('toy_native_load',R/'native-load-check-v1.py')
tool=importlib.util.module_from_spec(spec);spec.loader.exec_module(tool)


def raw_log(fixture):
    lines=['whisper_init_with_params_no_state: use gpu    = 1',
        'whisper_init_with_params_no_state: flash attn = 1','whisper_backend_init_gpu: using MTL0 backend']
    lines += ['whisper_init_state: compute buffer ('+label+') = 1.00 MB' for label in ('conv','encode','cross','decode')]
    lines += ['read_audio_data: failed to read audio data',"error: failed to read audio file '"+str(fixture)+"'",
        'whisper_print_timings:     fallbacks =   0 p /   0 h','whisper_print_timings:      mel time =     0.00 ms']
    lines += ['whisper_print_timings: '+label+' time = 0.00 ms / 1 runs ( 0.00 ms per run)' for label in ('sample','encode','decode','batchd','prompt')]
    lines += ['error: 1 input file(s) failed']
    return ('\n'.join(lines)+'\n').encode()


def descriptor(path):return {'path':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bytes':path.stat().st_size}


class Fixture:
    def __init__(self,root):
        self.root=Path(root).resolve()
        def file(name,data):
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True)
            if not isinstance(data,bytes):data=(json.dumps(data)+'\n').encode()
            path.write_bytes(data);return descriptor(path)
        self.file=file
        program=('#!'+sys.executable+'\nimport sys\nf=sys.argv[sys.argv.index("-f")+1]\n'
            +'sys.stdout.write('+repr(raw_log('{fixture}').decode())+'.replace("{fixture}",f))\nsys.exit(11)\n').encode()
        binary=file('native/whisper-cli',program);Path(binary['path']).chmod(0o700)
        self.native=[binary]+[file('native/lib'+str(i),('library'+str(i)).encode()) for i in range(10)]
        originals={name:file('models/'+name,('original'+name).encode()) for name in ('tiny','base','small','large-v3-turbo','large-v3')}
        families={};models=[]
        for family in ('small','large-v3-turbo'):
            parent=originals[family]
            arms={'original':{**parent,'id':family,'kind':'pretrained','parent_original_id':family,
                'parent_original_sha256':parent['sha256'],'model_file_bytes':parent['bytes']}}
            for role,kind in tool.ROLES.items():
                identifier=family+'-'+role.replace('_','-');d=file('models/'+identifier,identifier.encode())
                arms[role]={**d,'id':identifier,'kind':kind,'parent_original_id':family,
                    'parent_original_sha256':parent['sha256'],'model_file_bytes':d['bytes']}
                models.append({**d,'id':identifier,'kind':kind,'role':role,'family':family})
            models.append({**parent,'id':family,'kind':'pretrained','role':'original','family':family});families[family]=arms
        for family in ('tiny','base','large-v3'):
            models.append({**originals[family],'id':family,'kind':'pretrained','role':'original','family':family})
        artifact={'schema_version':'round5-artifact-family-v1','state':'completed','quality_inference_executed':False,
            'default_promotion':False,'families':families,'original_models':originals}
        self.artifact=file('artifact.json',artifact)
        inventory={'schema_version':'round5-pre-execution-inventory-v1','verified_model_files':11,
            'quality_inference_executed':False,'installed_app_changed':False,'native_files':self.native,
            'models':models,'original_models':originals,'artifact_family':self.artifact}
        self.inventory=file('inventory.json',inventory)
        self.artifact_value=artifact;self.inventory_value=inventory
        self.source=file('native/whisper.cpp/toy.cpp',b'toy source; not a compiled runtime provenance claim')

    def run(self,name='output'):
        own=descriptor(R/'native-load-check-v1.py')
        with patch.object(tool,'CLI_SHA',self.native[0]['sha256']),patch.object(tool,'R3',self.root),\
             patch.object(tool,'SOURCE_PINS',{'toy.cpp':self.source['sha256']}):
            return tool.run_check(self.artifact['path'],self.artifact['sha256'],self.inventory['path'],
                self.inventory['sha256'],own['sha256'],self.root/name)


class NativeLoadContracts(unittest.TestCase):
    def test_literal_path_proves_no_asr_without_fabricating_zero_displayed_runs(self):
        result=tool.validate_log(raw_log('/synthetic/empty.bin'),11,Path('/synthetic/empty.bin'))
        self.assertEqual(result['inference_calls_from_pinned_control_flow'],0)
        self.assertIs(result['actual_internal_run_counts_observable'],False)
        self.assertEqual({v['displayed_runs'] for v in result['displayed_compute_timings'].values()},{1})
        self.assertFalse(result['quality_or_performance_measured'])

    def test_return11_alone_gpu_request_alone_or_nonzero_inference_cannot_pass(self):
        base=raw_log('/synthetic/empty.bin')
        changes=[(base,0),(base,True),(base,11.0),
            (base.replace(b'use gpu    = 1',b'use gpu    = 0'),11),
            (base.replace(b'flash attn = 1',b'flash attn = 0'),11),
            (base.replace(b'using MTL0 backend',b'no GPU found'),11),
            (base.replace(b'compute buffer (decode)',b'missing decode allocator'),11),
            (base.replace(b'encode time = 0.00',b'encode time = 0.01'),11),
            (base.replace(b'1 runs',b'0 runs'),11),
            (base+b'error: failed to initialize whisper context\n',11),
            (base+b'ggml_backend: failed to allocate buffer\n',11),
            (base+b'whisper_full: processing\n',11),
            (base+b'error: 1 input file(s) failed\n',11),
            (base.replace(b'/synthetic/empty.bin',b'/foreign/audio.wav'),11)]
        for data,code in changes:
            with self.subTest(code=code,data_sha=hashlib.sha256(data).hexdigest()),self.assertRaises(ValueError):
                tool.validate_log(data,code,Path('/synthetic/empty.bin'))

    def test_exact_six_models_and_native_inventory_metadata_are_required(self):
        with tempfile.TemporaryDirectory() as name:
            f=Fixture(name)
            with patch.object(tool,'CLI_SHA',f.native[0]['sha256']):
                native,models=tool.validate_inputs(f.artifact_value,f.inventory_value)
                self.assertEqual(len(native),11);self.assertEqual(len(models),6)
                self.assertEqual([(d['family'],d['role']) for d in models],[(m,r) for m in ('small','large-v3-turbo') for r in tool.ROLES])
                for change in ('missing_role','parent','inventory_hash','wrong_kind','duplicate_path','zero_bytes'):
                    artifact,inventory=copy.deepcopy(f.artifact_value),copy.deepcopy(f.inventory_value)
                    arm=artifact['families']['small']['permuted_f16']
                    if change=='missing_role':artifact['families']['small'].pop('plain_q4')
                    elif change=='parent':arm['parent_original_sha256']='0'*64
                    elif change=='inventory_hash':inventory['models'][0]['sha256']='0'*64
                    elif change=='wrong_kind':arm['kind']='pretrained'
                    elif change=='duplicate_path':inventory['native_files'][1]['path']=inventory['native_files'][0]['path']
                    else:arm['model_file_bytes']=0
                    with self.subTest(change=change),self.assertRaises(ValueError):tool.validate_inputs(artifact,inventory)

    def test_actual_six_toy_cli_launches_preserve_sources_and_write_exclusive_receipts(self):
        with tempfile.TemporaryDirectory() as name:
            f=Fixture(name);before={d['path']:descriptor(Path(d['path'])) for d in (*f.native,*f.inventory_value['models'])}
            result=f.run();self.assertEqual(result['status'],'passed');self.assertEqual(len(result['results']),6)
            self.assertEqual(result['verified_derived_artifacts'],6);self.assertFalse(result['recognition_performed'])
            self.assertEqual((f.root/'output/empty-invalid-audio.bin').stat().st_size,0)
            for row in result['results']:
                self.assertEqual(row['shutdown']['returncode'],11);self.assertTrue(row['shutdown']['cli_reaped'])
                self.assertFalse(row['shutdown']['owned_group_present']);self.assertEqual(row['shutdown']['signals'],[])
                self.assertEqual(row['command'][-5:],['-t','2','-l','auto','-fa'])
            self.assertEqual(before,{p:descriptor(Path(p)) for p in before})
            with self.assertRaisesRegex(ValueError,'New protected'):f.run()

    def test_bad_input_hash_prevents_any_native_launch(self):
        with tempfile.TemporaryDirectory() as name:
            f=Fixture(name);Path(f.inventory_value['models'][0]['path']).write_bytes(b'changed')
            with patch.object(tool.subprocess,'Popen') as popen,self.assertRaisesRegex(ValueError,'payload differs'):f.run()
            popen.assert_not_called();self.assertFalse((f.root/'output').exists())

    def test_cancel_after_popen_reaps_only_owned_group_and_preserves_foreign_session(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);log=root/'native.log';children=[]
            foreign=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True)
            original=tool.subprocess.Popen
            def create(*args,**kwargs):
                child=original(*args,**kwargs)
                if kwargs.get('process_group')==0:children.append(child)
                return child
            def check():
                if log.exists() and b'READY' in log.read_bytes():raise InterruptedError('synthetic cancel')
            try:
                with patch.object(tool.subprocess,'Popen',side_effect=create),self.assertRaises(InterruptedError):
                    tool.run_child([sys.executable,'-c','import time;print("READY",flush=True);time.sleep(30)'],log,check)
                self.assertEqual(len(children),1);self.assertIsNotNone(children[0].poll());self.assertIsNone(foreign.poll())
            finally:
                foreign.terminate();foreign.wait(timeout=2)

    def test_per_load_timeout_is_finite_and_reaps_actual_toy_child(self):
        with tempfile.TemporaryDirectory() as name:
            log=Path(name)/'native.log';started=time.monotonic()
            with self.assertRaises(TimeoutError):tool.run_child([sys.executable,'-c','import time;time.sleep(30)'],log,lambda:None,timeout=.1)
            self.assertLess(time.monotonic()-started,5)

    def test_inventory_uncertainty_reaps_known_child_but_cannot_claim_clean_group(self):
        with tempfile.TemporaryDirectory() as name:
            child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],process_group=0)
            with patch.object(tool,'members',side_effect=ValueError('synthetic inventory unavailable')):
                result=tool.cleanup(child,child.pid,os.getsid(0))
            self.assertTrue(result['cli_reaped']);self.assertIsNone(result['owned_group_present']);self.assertTrue(result['errors'])


if __name__=='__main__':unittest.main(verbosity=2)
