"""Tiny static-proof/budget/publication contracts; no real checkpoint or NN."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
SPEC=importlib.util.spec_from_file_location('r5_static_contracts',Path(__file__).with_name('independent-preflight-audit-v1.py'))
a=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(a)
import numpy as np

class StaticContracts(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve();self.reader=a.Reader(self.root)
    def tearDown(self):self.temp.cleanup()
    def test_json_nonfinite_duplicate_and_bounded_source_refusal(self):
        for raw in (b'{"a":1,"a":2}',b'{"x":NaN}',b'{"x":1e999}'):
            with self.assertRaises(ValueError):a.decode(raw)
        p=self.root/'tiny';p.write_bytes(b'abc')
        with self.assertRaises(ValueError):self.reader.raw(p,maximum=2)
        self.assertEqual(self.reader.direct,0)
        self.assertEqual(self.reader.raw(p,a.sha(b'abc')),b'abc')
        link=self.root/'link';link.symlink_to(p)
        with self.assertRaises(ValueError):self.reader.raw(link)
    def test_hash_growth_and_later_replacement_are_rejected(self):
        p=self.root/'tiny';p.write_bytes(b'abc');calls=[0]
        original=self.reader.check
        def grow():
            original();calls[0]+=1
            if calls[0]==3:
                with p.open('ab') as f:f.write(b'x')
        with patch.object(self.reader,'check',side_effect=grow),self.assertRaises(ValueError):self.reader.digest(p,a.sha(b'abc'))
        p.write_bytes(b'abc');self.reader.digest(p,a.sha(b'abc'));p.unlink();p.write_bytes(b'abc')
        with self.assertRaises(ValueError):self.reader.final()
    def test_read_budget_is_admitted_before_tiles_and_helpers(self):
        with patch.object(a,'MAX_READ',3):
            self.reader.debit(2,helper=True)
            with self.assertRaises(ValueError):self.reader.debit(2,helper=True)
            p=self.root/'x';p.write_bytes(b'12')
            with p.open('rb') as f,self.assertRaises(ValueError):self.reader.block(f,0,2)
        self.assertEqual(self.reader.debited,2);self.assertEqual(self.reader.direct,0)
    def test_metadata_budget_is_checked_before_opening_stream(self):
        p=self.root/'metadata';p.write_bytes(b'123')
        with patch.object(a,'MAX_READ',3),patch.object(Path,'open',side_effect=AssertionError('must refuse before stream IO')):
            with self.assertRaises(ValueError):self.reader.raw(p)
        self.assertEqual(self.reader.debited,0)
    def test_typed_guard_cleanup_and_cancellation_veto(self):
        p=self.root/'guard';events=[{'event':'starting','time':1.},
            {'event':'finished','time':2.,'reason':None,'failure':None,'canceled':False,
             'shutdown':{'returncode':0,'cli_reaped':True,'owned_session_present':False,'shutdown_errors':[]}}]
        def pin():
            raw='\n'.join(json.dumps(e) for e in events).encode();p.write_bytes(raw);return {'path':str(p),'sha256':a.sha(raw)}
        self.assertEqual(len(a.closed_events(self.reader,pin())),2)
        events[-1]['shutdown']['returncode']=False
        with self.assertRaises(ValueError):a.closed_events(self.reader,pin())
        events[-1]['shutdown']['returncode']=1
        with self.assertRaises(ValueError):a.closed_events(self.reader,pin())
        self.assertEqual(len(a.closed_events(self.reader,pin(),True)),2)
        events.insert(1,{'event':'owned_cli_signal','time':1.5})
        with self.assertRaises(ValueError):a.closed_events(self.reader,pin(),True)
    def fixture(self):
        site='encoder.blocks.0.mlp';state=2;hidden=8
        w1=[struct.pack('<e',v) for v in [0.,-0.,.125,-.25,.5,-.5,1.,-1.,.75,-.75,.375,-.375,.0625,-.0625,2.,-2.]]
        bias=[struct.pack('<f',v) for v in [-0.,0.,1.,-1.,.5,-.5,.25,-.25]]
        scales=[4.,1.,3.,2.,8.,5.,7.,6.]
        w2=[struct.pack('<e',v*(-1 if row else 1)) for row in range(2) for v in scales]
        order=sorted(range(hidden),key=lambda i:(scales[i],i));parts=[w1,bias,w2]
        moved=[[atom for old in order for atom in w1[old*2:old*2+2]], [bias[i] for i in order], [w2[row*8+i] for row in range(2) for i in order]]
        prefix=b'protected-header';tail=b'outside-tail';original=prefix+b''.join(b''.join(x) for x in parts)+tail
        candidate=prefix+b''.join(b''.join(x) for x in moved)+tail
        p=self.root/'original';q=self.root/'candidate';p.write_bytes(original);q.write_bytes(candidate)
        tensors={};edits=[];offset=len(prefix)
        for suffix,shape,dtype,operation,left,right in zip(('.0.weight','.0.bias','.2.weight'),((2,8),(8,),(8,2)),('f16','f32','f16'),('rows','bias','columns'),parts,moved):
            before,after=b''.join(left),b''.join(right);name=site+suffix
            tensors[name]=SimpleNamespace(name=name,shape=shape,dtype=dtype,offset=offset,bytes=len(before),elements=len(left))
            edits.append({'tensor':name,'before_sha256':a.sha(before),'after_sha256':a.sha(after),'inverse_permutation_sha256':a.sha(before),
                'inverse_permutation_equal':True,'changed_elements':sum(x!=y for x,y in zip(left,right)),'selected_elements':len(left),'operation':operation})
            offset+=len(before)
        architecture={'n_text_state':2,'n_audio_layer':1,'n_text_layer':0}
        model=lambda path:SimpleNamespace(path=path,architecture=architecture,source_sha256=a.sha(original),bytes=len(original),tensor=lambda name:tensors[name])
        plan={'schema_version':'whisper-mlp-permutation-v1','model_id':'small','source_sha256':a.sha(original),'ordering':a.ORDERING,'sites':[{'site':site,'hidden_channels':8,'permutation':order,
            'permutation_sha256':a.sha(struct.pack('<8I',*order)),'nonidentity_positions':sum(i!=v for i,v in enumerate(order)),
            'column_max_abs_min':1.,'column_max_abs_max':8.,'zero_scale_channels':0}]}
        audit={'model_id':'small','source_sha256':a.sha(original),'edits':edits,'selected_tensor_count':3,'selected_elements':40,'changed_elements':sum(e['changed_elements'] for e in edits),'no_op':False,
            'unchanged_regions_sha256':a.sha(prefix+tail)}
        return model(p),model(q),plan,audit,tensors
    def test_independent_actual_bytes_order_inverse_and_changed_counts(self):
        p,q,plan,audit,_=self.fixture();proof=a.permutation_proof(self.reader,p,q,'small',plan,audit,np)
        self.assertEqual((proof['sites'],proof['selected_tensors'],proof['outside_declared_changed_bytes']),(1,3,0))
        self.assertTrue(proof['actual_original_weight_order_recomputed'])
    def test_wrong_order_bias_or_outside_bytes_cannot_be_rebound_as_a_pass(self):
        for kind in ('order','bias','outside'):
            with self.subTest(kind=kind):
                p,q,plan,audit,tensors=self.fixture()
                if kind=='order':plan['sites'][0]['permutation']=list(reversed(plan['sites'][0]['permutation']))
                else:
                    with q.path.open('r+b') as f:
                        f.seek(tensors['encoder.blocks.0.mlp.0.bias'].offset if kind=='bias' else 0);f.write(b'\x01')
                    # The independent byte proof, not merely a whole-model hash,
                    # must detect corruption even if a caller has rebound it.
                with self.assertRaises(ValueError):a.permutation_proof(self.reader,p,q,'small',plan,audit,np)
    def test_plan_model_source_and_selected_aggregate_are_independently_bound(self):
        for record,key,value in (('plan','model_id','large-v3-turbo'),('audit','model_id','base'),
            ('plan','source_sha256','0'*64),('audit','source_sha256','0'*64),('audit','selected_elements',39),('audit','selected_elements',True)):
            with self.subTest(record=record,key=key,value=value):
                p,q,plan,audit,_=self.fixture();(plan if record=='plan' else audit)[key]=value
                with self.assertRaises(ValueError):a.permutation_proof(self.reader,p,q,'small',plan,audit,np)
    def test_canceled_publication_retains_partial_and_refuses_existing_output(self):
        output=self.root/'audit';self.reader.stopped=True
        with self.assertRaises(InterruptedError):a.publish(self.reader,output,{'status':'x'})
        self.assertFalse(output.exists());self.reader.stopped=False
        original=self.reader.final
        def stop_before_link():original();self.reader.stopped=True;self.reader.check()
        with patch.object(self.reader,'final',side_effect=stop_before_link),self.assertRaises(InterruptedError):a.publish(self.reader,output,{'status':'x'})
        self.assertTrue((output/'audit.partial.json').exists());self.assertFalse((output/'audit.json').exists())
        self.reader.stopped=False
        with self.assertRaises(ValueError):a.publish(self.reader,output,{'status':'x'})

if __name__=='__main__':unittest.main()
