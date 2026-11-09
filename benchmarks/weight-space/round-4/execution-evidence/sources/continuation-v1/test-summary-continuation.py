#!/usr/bin/env python3
"""Tiny entry-point contracts; frozen builder/projector numerical APIs are stubs."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock,patch

HERE=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('toy_summary_adapter',HERE/'summarize-continuation-v1.py')
adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)


def fixture(root):
    args=SimpleNamespace(continuation_freeze=str(root/'continuation.freeze.v1.json'),continuation_freeze_sha256='a'*64,
        journal_projection=str(root/'logical-serial-continuation-v1.receipt.json'),journal_projection_sha256='b'*64,journal_sha256='c'*64)
    chain={'events':[{'event':'serial_finished','attempted_cells':4554}],
        'logical_journal':{'path':str(root/'logical-serial-continuation-v1.events.jsonl'),'sha256':'c'*64},
        'original_journal':{'path':str(root/'serial.events.jsonl'),'sha256':'d'*64},
        'continuation_journal':{'path':str(root/'serial-continuation-v1.events.jsonl'),'sha256':'e'*64},
        'continuation_capsule':{'path':args.continuation_freeze,'sha256':'a'*64},
        'projection_receipt':{'path':args.journal_projection,'sha256':'b'*64},
        'projector_source':{'path':str(root/'continuation-v1/project-journal.py'),'sha256':'f'*64},
        'stop_provenance':{'original_stop_preserved':True,'logical_marker':'verified_prior_serial_stop'},
        'no_inference_retry':True,'no_scoring_or_gate_change':True,'default_promotion':False}
    value={'status':'synthetic_entrypoint_contract_only','quality':{'cer':None,'gate':False},'default_promotion':False}
    reader=SimpleNamespace(check=Mock(),ledger={'/synthetic-only/metadata.json':{'sha256':'9'*64,'bytes':2}},raw=Mock())
    builder=SimpleNamespace(build=Mock(side_effect=lambda *a:copy.deepcopy(value)))
    projector=SimpleNamespace(validate_chain=Mock(side_effect=lambda *a:copy.deepcopy(chain)))
    return args,chain,value,reader,builder,projector


class SummaryAdapterContracts(unittest.TestCase):
    def test_incomplete_chain_prevents_builder_and_outcome_reads(self):
        args,chain,value,reader,builder,projector=fixture(Path('/synthetic'))
        projector.validate_chain.side_effect=ValueError('all15 not terminal')
        with self.assertRaisesRegex(ValueError,'all15'):adapter.build_verified(builder,reader,{},projector,args,'1'*64)
        builder.build.assert_not_called();reader.raw.assert_not_called()

    def test_verified_chain_preserves_null_false_and_identifies_actual_adapter(self):
        root=Path('/synthetic');args,chain,value,reader,builder,projector=fixture(root);family={'fixed':'family'}
        with patch.object(adapter,'R',root):out=adapter.build_verified(builder,reader,family,projector,args,'1'*64)
        self.assertEqual(out['quality'],value['quality']);self.assertFalse(out['default_promotion'])
        builder.build.assert_called_once_with(reader,family,chain['events'],root/'inference-launch.freeze.v1.json',adapter.ADMISSION)
        self.assertEqual(projector.validate_chain.call_count,2)
        self.assertEqual(out['summary_source_sha256'],adapter.BUILDER);self.assertEqual(out['executing_adapter_sha256'],'1'*64)
        context=out['execution_context'];self.assertIs(context['original_builder_main_executed'],False)
        self.assertIs(context['logical_journal_is_raw'],False);self.assertIs(context['original_serial_stop_retained'],True)
        self.assertNotIn('events',context)
        for key in ('original_journal','continuation_journal','logical_journal','stop_provenance'):
            self.assertEqual(context[key],chain[key])
        reader.raw.assert_called_once_with('/synthetic-only/metadata.json','9'*64)

    def test_mutated_chain_or_retry_policy_cannot_publish_summary(self):
        for changed in (False,True):
            args,chain,value,reader,builder,projector=fixture(Path('/synthetic'))
            if changed:
                second=copy.deepcopy(chain);second['original_journal']['sha256']='0'*64
                projector.validate_chain.side_effect=[chain,second]
            else:
                chain['no_inference_retry']=False;projector.validate_chain.side_effect=lambda *a:chain
            with self.subTest(changed=changed),self.assertRaises(ValueError):adapter.build_verified(builder,reader,{},projector,args,'1'*64)
            reader.raw.assert_not_called()

    def test_bootstrap_hash_and_symlink_checks_remain_real(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();p=root/'source.py';p.write_bytes(b'tiny source');sha=hashlib.sha256(p.read_bytes()).hexdigest()
            with patch.object(adapter,'R',root):
                self.assertEqual(adapter.source_bytes(p,sha),b'tiny source')
                with self.assertRaises(ValueError):adapter.source_bytes(p,'0'*64)
                link=root/'link.py';link.symlink_to(p)
                with self.assertRaises(ValueError):adapter.source_bytes(link,sha)

    def test_actual_main_parses_cli_and_writes_exclusive_summary_with_stubbed_analysis_only(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();args,chain,value,reader,builder,projector=fixture(root)
            reader.ledger={};cap={'schema_version':'round4-metadata-filename-continuation-v1','sources':{'journal_projector':chain['projector_source']}}
            def read(path,sha,maximum):
                reader.ledger[str(path)]={'sha256':sha,'bytes':2}
                return (cap if Path(path).name=='continuation.freeze.v1.json' else {'fixed':'family'}),sha
            reader.read=read;reader.raw=lambda path,sha,*a:reader.ledger.setdefault(str(path),{'sha256':sha,'bytes':2})
            builder.Reader=lambda seconds:reader;builder.MAX_SMALL=4*1024**2
            def module(path,sha,name):return builder if Path(path).name=='summarize-round4-v1.py' else projector
            argv=[]
            for key in ('continuation_freeze','continuation_freeze_sha256','journal_projection','journal_projection_sha256','journal_sha256'):
                argv += ['--'+key.replace('_','-'),getattr(args,key)]
            argv += ['--expected-source-sha256','1'*64,'--output',str(root/'output')]
            with patch.object(adapter,'R',root),patch.object(adapter,'module',side_effect=module),\
                 patch.object(adapter,'source_bytes',return_value=b'bootstrap identities stubbed only for synthetic namespace'),\
                 patch.object(adapter.signal,'signal'):
                adapter.main(argv)
                result=json.loads((root/'output/summary.json').read_bytes())
                self.assertEqual(result['quality'],value['quality']);self.assertEqual(result['executing_adapter_sha256'],'1'*64)
                self.assertFalse((root/'output/summary.partial.json').exists())
                with self.assertRaises(ValueError):adapter.main(argv)

    def test_cancel_after_partial_write_retains_partial_and_publishes_no_final(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();output=root/'output';original=os.fdopen;state={'canceled':False}
            def check():
                if state['canceled']:raise InterruptedError('synthetic cancel')
            reader=SimpleNamespace(check=check)
            class Writer:
                def __init__(self,stream):self.stream=stream
                def __getattr__(self,k):return getattr(self.stream,k)
                def __enter__(self):return self
                def __exit__(self,*a):self.stream.close()
                def write(self,data):
                    n=self.stream.write(data);state['canceled']=True;return n
            with patch.object(adapter,'R',root),patch.object(adapter.os,'fdopen',side_effect=lambda *a:Writer(original(*a))),\
                 self.assertRaises(InterruptedError):adapter.publish(reader,output,{'status':'synthetic'})
            self.assertTrue((output/'summary.partial.json').exists());self.assertFalse((output/'summary.json').exists())


if __name__=='__main__':unittest.main(verbosity=2)
