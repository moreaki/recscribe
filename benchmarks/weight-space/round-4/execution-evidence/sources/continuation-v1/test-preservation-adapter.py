#!/usr/bin/env python3
"""Tiny metadata/caller contracts; actual stopped campaign is never opened."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

R=Path(__file__).absolute().parent.parent
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
base=load("old_preservation_tests",R/"test-postrun-preservation-v1.py")
new=load("continued_preservation",R/"continuation-v1/audit-postrun-preservation.py")
base.audit=new

PROJECTOR=r'''
import hashlib,json
from pathlib import Path
def desc(p):
    p=Path(p);return {"path":str(p),"sha256":hashlib.sha256(p.read_bytes()).hexdigest()}
def validate_chain(capsule_path,capsule_sha256,projection_path,projection_sha256,logical_journal_sha256,check=lambda:None):
    check()
    assert desc(capsule_path)["sha256"]==capsule_sha256
    assert desc(projection_path)["sha256"]==projection_sha256
    value=json.loads(Path(projection_path).read_bytes())
    if value.get("cancel"):raise InterruptedError("toy canceled chain")
    logical=value["logical_journal"]
    assert desc(logical["path"])["sha256"]==logical_journal_sha256
    events=[json.loads(x) for x in Path(logical["path"]).read_bytes().splitlines()]
    if value.get("bad_events"):events[-1]["attempted_cells"]-=1
    return {"events":events,"logical_journal":logical,"original_journal":value["original_journal"],
        "continuation_journal":value["continuation_journal"],"continuation_capsule":desc(capsule_path),
        "projection_receipt":desc(projection_path),"projector_source":desc(__file__),
        "stop_provenance":{"synthetic_metadata_only":True}}
'''

def prepare(f,**options):
    f.file("audit-postrun-preservation-v1.py",(R/"audit-postrun-preservation-v1.py").read_bytes())
    logical=f.file("logical-serial-continuation-v1.events.jsonl",b"".join(base.encoded(e) for e in f.events))
    original=f.file("stopped-original.jsonl",b'{"event":"serial_stopped"}\n')
    continued=f.file("continued.jsonl",b'{"event":"continuation_finished"}\n')
    source=f.file("continuation-v1/project-journal.py",PROJECTOR.encode())
    capsule=f.file("continuation.freeze.v1.json",{"schema_version":"round4-metadata-filename-continuation-v1",
        "allow_inference_retries":False,"model_settings_changed":False,"scorer_changed":False,"quality_gates_changed":False,
        "sources":{"journal_projector":source}})
    projection=f.file("logical-serial-continuation-v1.receipt.json",{"logical_journal":logical,
        "original_journal":original,"continuation_journal":continued,**options})
    return logical,capsule,projection

def execute(f,name="result",prepared=None):
    logical,capsule,projection=prepared or prepare(f)
    own=base.digest((R/"continuation-v1/audit-postrun-preservation.py").read_bytes())
    with patch.object(new,"R",f.root),patch.object(new,"FAMILY_SHA",f.family_d["sha256"]),\
         patch.object(new,"INTEGRITY_SHA",f.integrity["sha256"]),patch.object(new,"ADMISSION_SHA",f.admission["sha256"]),\
         patch.object(new.signal,"signal"):
        new.main(["--journal-sha256",logical["sha256"],"--expected-source-sha256",own,"--output",str(f.root/name),
            "--continuation-freeze",capsule["path"],"--continuation-freeze-sha256",capsule["sha256"],
            "--journal-projection",projection["path"],"--journal-projection-sha256",projection["sha256"]])
    return json.loads((f.root/name/"preservation.json").read_bytes())

base.Fixture.run=execute

class AdapterContracts(unittest.TestCase):
    def test_actual_main_writer_keeps_executing_and_reused_sources_distinct(self):
        with tempfile.TemporaryDirectory() as folder:
            f=base.Fixture(folder);before={d["path"]:Path(d["path"]).read_bytes() for d in f.payloads}
            v=execute(f)
            self.assertEqual(v["status"],"PASS_OPAQUE_INPUT_AND_RETAINED_OUTPUT_HASHES")
            self.assertEqual(v["retained_output_count"],75)
            self.assertEqual(v["reused_preservation_core"]["sha256"],"9ba1fdf806ce592dc21f052e386f0ebc2d410c7a58bb66e84262cf18bb82f8f9")
            self.assertNotEqual(v["source"]["sha256"],v["reused_preservation_core"]["sha256"])
            self.assertFalse(v["preservation_algorithm_changed"])
            self.assertEqual(v["execution_context"]["stop_provenance"],{"synthetic_metadata_only":True})
            self.assertEqual(before,{p:Path(p).read_bytes() for p in before})

    def test_bad_or_canceled_chain_cannot_open_opaque_inputs(self):
        for options,error in (({"bad_events":True},ValueError),({"cancel":True},InterruptedError)):
            with tempfile.TemporaryDirectory() as folder:
                f=base.Fixture(folder);prepared=prepare(f,**options);opened=[];actual=new.Audit.digest
                def tracked(worker,path,*args,**kwargs):opened.append(str(path));return actual(worker,path,*args,**kwargs)
                with patch.object(new.Audit,"digest",tracked),self.assertRaises(error):execute(f,prepared=prepared)
                self.assertFalse({d["path"] for d in f.payloads}&set(opened))
                self.assertFalse((f.root/"result").exists())

    def test_changed_projector_source_is_rejected_before_opaque_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            f=base.Fixture(folder);prepared=prepare(f);p=f.root/"continuation-v1/project-journal.py"
            p.write_bytes(p.read_bytes()+b"\n# unexpected edit\n")
            with self.assertRaises(ValueError):execute(f,prepared=prepared)
            self.assertFalse((f.root/"result").exists())

if __name__=="__main__":
    suite=unittest.TestSuite()
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(base.OpaqueHashContracts))
    for name in ("test_final_counts_require_nonnegative_exact_ints_and_all_fifteen_stages",
        "test_unreadable_walk_is_not_a_successful_empty_inventory",
        "test_new_file_after_directory_enumeration_invalidates_snapshot",
        "test_write_failure_cannot_publish_partial_final_receipt",
        "test_cancel_during_publication_cannot_publish_pass_receipt"):
        suite.addTest(base.LifecycleContracts(name))
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(AdapterContracts))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
