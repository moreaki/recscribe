"""Model-free bounded HTTP, opaque selection and preservation contracts."""
from contextlib import redirect_stdout
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch
import wave

SPEC = importlib.util.spec_from_file_location("realworld_acquisition", Path(__file__).resolve().parents[1] / "quality/acquire-realworld.py")
real = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(real)


def plan():
    sources = []
    for split in real.SPLITS:
        source_split = "test" if split == "held_out" else "validation"
        sources.append({"id": "vox-en-" + split, "kind": "voxpopuli", "dataset": "facebook/voxpopuli",
            "revision": "a" * 40, "config": "en", "language": "en", "split": split,
            "source_split": source_split, "license": "CC0; fixture provenance",
            "source_use_review": "pending", "variety": "publisher declaration; unreviewed", "script": "Latn",
            "conditions": ["parliamentary; fixture"], "files": [{"path": "en/" + source_split + "-00000-of-00001.parquet", "bytes": 100}]})
    return {"schema_version": real.VERSION, "corpus_version": "realworld-test-v1", "languages": ["en"],
            "counts_per_language": {"development": 2, "held_out": 16, "resource": 1},
            "budgets": {"network_bytes": 64 * real.MIB, "output_bytes": 64 * real.MIB, "timeout_seconds": 60},
            "sources": sources}


def wav_bytes(value=100, seconds=2, channels=1):
    result = io.BytesIO()
    with wave.open(result, "wb") as stream:
        stream.setnchannels(channels); stream.setsampwidth(2); stream.setframerate(16000)
        stream.writeframes(value.to_bytes(2, "little", signed=True) * int(16000 * seconds) * channels)
    return result.getvalue()


class Response(io.BytesIO):
    def __init__(self, data, status=206, headers=None):
        super().__init__(data)
        self.status = status
        self.headers = headers or {}
    def geturl(self): return "https://cdn.example.invalid/pinned"


def http_file(data, alter=None):
    calls = []
    def open_(request, timeout):
        calls.append((request, timeout))
        value = request.get_header("Range")
        if value:
            first, last = map(int, value.removeprefix("bytes=").split("-"))
            headers = {"Content-Range": f"bytes {first}-{last}/{len(data)}", "Content-Length": str(last-first+1), "ETag": '"stable"'}
            response = Response(data[first:last+1], headers=headers)
        else:
            response = Response(data, 200, {"Content-Length": str(len(data))})
        if alter: alter(response, len(calls))
        return response
    return open_, calls


class FakeRows:
    selected_calls = []
    def __init__(self, acquisition, source, file):
        self.source = source
    def metadata_rows(self):
        for index in range(20):
            identifier = self.source["id"] + ":" + str(index)
            yield 0, index, {"audio_id": identifier, "speaker_id": identifier, "is_gold_transcript": True}
    def selected(self, group, offset, with_reference):
        self.selected_calls.append((self.source["split"], with_reference))
        identifier = self.source["id"] + ":" + str(offset)
        value = int(hashlib.sha256(identifier.encode()).hexdigest()[:4], 16) % 30000 + 1
        return {"bytes": wav_bytes(value), "path": identifier + ".wav"}, "synthetic opaque " + identifier if with_reference else None


def conversion(self, command, timeout, capture=False, target=None, maximum_bytes=None):
    if command == ["ffmpeg", "-version"]: return b"fixture ffmpeg\n"
    original = Path(command[command.index("-i") + 1])
    with wave.open(str(original), "rb") as stream:
        channels=stream.getnchannels()
        frames = min(stream.getnframes(), int(float(command[command.index("-t") + 1]) * 16000)) if "-t" in command else stream.getnframes()
        data = stream.readframes(frames)
    if "-af" in command:
        if command[command.index("-af")+1]!="pan=mono|c0=c0" or channels!=2:raise AssertionError("unexpected fixture channel mapping")
        data=b"".join(data[index:index+2] for index in range(0,len(data),4))
    with wave.open(str(target), "wb") as stream:
        stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000); stream.writeframes(data)


def acquisition(*args, **kwargs):
    kwargs.setdefault("priority_probe", None)
    return real.Acquisition(*args, **kwargs)


class QualityRealWorldTests(unittest.TestCase):
    def test_validation_is_network_dependency_free_and_does_not_weaken_counts(self):
        self.assertIs(real.validate_plan(plan())["counts_per_language"]["held_out"], 16)
        for mutate in [lambda p:p["counts_per_language"].update(held_out=8),
                       lambda p:p["budgets"].update(network_bytes=4*real.GIB+1),
                       lambda p:p["budgets"].update(output_bytes=2*real.GIB+1),
                       lambda p:p["budgets"].update(timeout_seconds=1801),
                       lambda p:p["sources"][0].update(revision="main"),
                       lambda p:p["sources"][0]["files"][0].update(path="../escape.parquet"),
                       lambda p:p["sources"][0].update(source_use_review="approved"),
                       lambda p:p.update(transport={"strategy":"memory","physical_bytes":real.GIB}),
                       lambda p:p.update(transport={"strategy":"sparse-mmap-v1","physical_bytes":2*real.GIB+1})]:
            p=plan();mutate(p)
            with self.assertRaises(real.Failure):real.validate_plan(p)
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/"plan.json";p.write_text(json.dumps(plan()))
            with patch.object(real.Acquisition,"open",side_effect=AssertionError("network")), redirect_stdout(io.StringIO()):
                self.assertEqual(real.main([str(p),"--validate-plan"]),0)

    def test_exact_ranges_cache_and_seeks_preserve_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            opener,calls=http_file(b"0123456789")
            a=acquisition(Path(directory),plan(),real.Exclusions(),opener)
            f=real.RangeFile(a,"https://example.invalid/data",10)
            self.assertEqual(f.read(4),b"0123")
            f.seek(0);self.assertEqual(f.read(4),b"0123")
            self.assertEqual(len(calls),1)
            self.assertEqual(f.seek(-3,io.SEEK_END),7)
            self.assertEqual(f.read(),b"789")
            self.assertEqual(a.network_bytes,7)
            self.assertEqual(a.requests[0]["range_sha256"],hashlib.sha256(b"0123").hexdigest())
            self.assertFalse(a.requests[0]["whole_file_sha256_verified"])
            with self.assertRaises(real.Failure):f.seek(-1)
            with self.assertRaises(real.Failure):f.read(real.MAX_READ+1)
            f.close()
            with self.assertRaises(real.Failure):f.read(1)

    def test_wrong_status_range_length_encoding_etag_and_overread_are_rejected(self):
        changes=[lambda r,n:setattr(r,"status",200),
                 lambda r,n:r.headers.update({"Content-Range":"bytes 1-4/10"}),
                 lambda r,n:r.headers.update({"Content-Length":"9"}),
                 lambda r,n:r.headers.update({"Content-Encoding":"gzip"}),
                 lambda r,n:r.headers.pop("ETag"),
                 lambda r,n:(r.seek(0),r.write(b"12345"),r.seek(0))]
        for change in changes:
            with self.subTest(change=change),tempfile.TemporaryDirectory() as directory:
                opener,_=http_file(b"0123456789",change)
                a=acquisition(Path(directory),plan(),real.Exclusions(),opener)
                with self.assertRaises(real.Failure):real.RangeFile(a,"https://example.invalid/data",10).read(4)
        with tempfile.TemporaryDirectory() as directory:
            opener,_=http_file(b"0123456789",lambda r,n:r.headers.update(ETag="changed" if n>1 else "stable"))
            a=acquisition(Path(directory),plan(),real.Exclusions(),opener);f=real.RangeFile(a,"https://example.invalid/data",10)
            f.read(1)
            with self.assertRaises(real.Failure):f.read(1)

    def test_network_cancel_signal_time_and_output_bounds_stop_new_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);opener,calls=http_file(b"0123456789")
            a=acquisition(root,plan(),real.Exclusions(),opener)
            a.maximum_network_bytes=2
            with self.assertRaises(real.Failure):real.RangeFile(a,"https://example.invalid/data",10).read(3)
            self.assertEqual(a.network_bytes,0)
            a.maximum_network_bytes=100;a.interrupted_signal=signal.SIGINT
            with self.assertRaises(InterruptedError):a.check()
            a.interrupted_signal=None;a.deadline=0
            with self.assertRaises(TimeoutError):a.check()
            a.deadline=float("inf");(root/"cancel.request").touch()
            with self.assertRaises(InterruptedError):a.fetch("https://example.invalid/card")
            (root/"cancel.request").unlink();a.output_bytes=a.maximum_output_bytes-real.FINAL_RESERVE
            with self.assertRaises(real.Failure):a.save(root/"oversized",b"x")
            self.assertFalse((root/"oversized").exists())

    def test_metadata_selection_preserves_groups_unknowns_without_loading_audio_or_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();prior=root/"prior.json";prior.write_text('{"cases":[]}')
            output=root/"metadata";FakeRows.selected_calls=[]
            opener,_=http_file(b"fixture card")
            a,complete=real.run(plan(),output,[prior],FakeRows,opener,priority_probe=None,metadata_only=True)
            self.assertTrue(complete);self.assertEqual(len(a.selected),19);self.assertEqual(a.cases,[])
            self.assertEqual(FakeRows.selected_calls,[])
            self.assertEqual(len({v["source_id"] for v in a.selected}),19)
            self.assertEqual(len({v["speaker_ids"][0] for v in a.selected}),19)
            self.assertTrue(all(v["session_id"] is None for v in a.selected))
            self.assertEqual(list(output.rglob("reference.original.txt")),[])
            self.assertEqual(list(output.rglob("source.original.*")),[])
            with self.assertRaises(FileExistsError):real.run(plan(),output,[prior],FakeRows,opener,priority_probe=None,metadata_only=True)

    def test_prior_ids_hashes_speakers_sessions_and_parents_are_excluded(self):
        source=plan()["sources"][0]
        item=real.identity(source,{"audio_id":"prior-row","speaker_id":"prior-speaker"})
        with tempfile.TemporaryDirectory() as directory:
            a=acquisition(Path(directory),plan(),real.Exclusions())
            a.exclusions.add({"id":item["id"],"source_id":item["source_id"],"original_audio_sha256":"audio",
                              "reference_sha256":"reference","speaker_ids":item["speaker_ids"],"session_id":"session",
                              "source_group_ids":item["source_group_ids"]})
            item["session_id"]="session"
            self.assertEqual(set(real.rejection(a,item,"audio","reference")),{"id","source_id","audio","reference","speaker","session","source_parent"})

    def test_parent_and_speaker_collisions_never_cross_partitions(self):
        p=plan();s=p["sources"][0];s["grouping"]={"parent_separator":":","parent_parts":1,"session_from_parent":True}
        first=real.identity(s,{"audio_id":"event:clip1","speaker_id":"speaker1"})
        second=real.identity(s,{"audio_id":"event:clip2","speaker_id":"speaker2"})
        with tempfile.TemporaryDirectory() as directory:
            a=acquisition(Path(directory),p,real.Exclusions());a.exclusions.add(first)
            self.assertIn("source_parent",real.rejection(a,second))
            self.assertIn("session",real.rejection(a,second))
        c=dict(s,kind="casablanca",dataset="UBC-NLP/Casablanca",config="Egypt",language="ar")
        unknown=real.identity(c,{"seg_id":"new-recording"})
        self.assertEqual(unknown["speaker_ids"],[])

    def test_publisher_missing_speaker_sentinels_stay_unknown(self):
        source=plan()["sources"][0]
        for value in (None,"", "None", " none ", "null", "Unknown", "nan", "n/a"):
            with self.subTest(value=value):
                item=real.identity(source,{"audio_id":"source-with-unknown-person","speaker_id":value})
                self.assertEqual(item["speaker_ids"],[])
                self.assertIsNone(item["session_id"])
        self.assertEqual(real.identity(source,{"audio_id":"zero-person","speaker_id":0})["speaker_ids"],["voxpopuli:speaker:0"])

    def test_actual_fake_table_acquisition_keeps_originals_resource_is_reference_free(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();prior=root/"prior.json";prior.write_text('{"cases":[]}')
            output=root/"measured";opener,_=http_file(b"fixture card");FakeRows.selected_calls=[]
            with patch.object(real.Acquisition,"run_command",conversion):
                a,complete=real.run(plan(),output,[prior],FakeRows,opener,priority_probe=None)
            self.assertTrue(complete);self.assertEqual(len(a.cases),19)
            self.assertEqual(len(list(output.rglob("reference.original.txt"))),18)
            self.assertTrue(all(not with_ref for split,with_ref in FakeRows.selected_calls if split=="resource"))
            for case in a.cases:
                self.assertFalse(case["reviewed"])
                self.assertEqual(case["source_use_review"],"pending")
                folder=Path(case["audio"]).parent
                original=next(folder.glob("source.original.*"))
                self.assertEqual(case["original_audio_sha256"],hashlib.sha256(original.read_bytes()).hexdigest())
                if case["split"]=="resource":self.assertNotIn("reference",case)
                else:self.assertEqual(case["reference_sha256"],hashlib.sha256(Path(case["reference"]).read_bytes()).hexdigest())
            receipt=json.loads((output/"acquisition.receipt.json").read_text())
            self.assertFalse(receipt["recognition_performed"])
            self.assertFalse(receipt["human_review_performed"])

    def test_resource_view_stays_at_twenty_seconds_and_original_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();a=acquisition(root,plan(),real.Exclusions())
            source=plan()["sources"][1];item=real.identity(source,{"audio_id":"long","speaker_id":"one"})
            original=wav_bytes(seconds=30)
            with patch.object(real.Acquisition,"run_command",conversion):
                case=real.prepare_selected(a,source,item,{"bytes":original},None,{"url":"https://example.invalid/pinned"})
            self.assertEqual(case["duration_seconds"],20)
            self.assertEqual(next(Path(case["audio"]).parent.glob("source.original.*")).read_bytes(),original)
            self.assertNotIn("reference",case)

    def test_stereo_is_retained_and_rejected_before_mono_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();a=acquisition(root,plan(),real.Exclusions());s=plan()["sources"][0]
            item=real.identity(s,{"audio_id":"stereo","speaker_id":"one"})
            with patch.object(real.Acquisition,"run_command") as run:
                self.assertIsNone(real.prepare_selected(a,s,item,{"bytes":wav_bytes(channels=2)},"fixture",{"url":"https://example.invalid/pinned"}))
                run.assert_not_called()
            self.assertEqual(len(list(root.rglob("source.original.wav"))),1)
            self.assertEqual(len(list(root.rglob("REJECTED.json"))),1)

    def test_bounded_helpers_exclude_only_owned_session_and_reap_on_cancel(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();seen=[]
            a=acquisition(root,plan(),real.Exclusions(),priority_probe=lambda session:seen.append(session) or bool(session))
            with self.assertRaises(InterruptedError):a.run_command([sys.executable,"-c","import time;time.sleep(5)"],2)
            self.assertIsNone(a.owned_session)
            records=list((root/"helpers").glob("cleanup-*.json"));self.assertEqual(len(records),1)
            saved=json.loads(records[0].read_text())
            self.assertTrue(saved["cli_reaped"]);self.assertFalse(saved["owned_session_present"])
            self.assertEqual(saved["shutdown_errors"],[])

    def test_short_source_failure_retains_pending_counts_and_never_approves(self):
        class Empty(FakeRows):
            def metadata_rows(self):return iter([])
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();prior=root/"prior.json";prior.write_text('{"cases":[]}')
            opener,_=http_file(b"card")
            a,complete=real.run(plan(),root/"incomplete",[prior],Empty,opener,priority_probe=None,metadata_only=True)
            self.assertFalse(complete)
            receipt=json.loads((root/"incomplete/acquisition.receipt.json").read_text())
            self.assertFalse(receipt["complete_requested_selection"])
            self.assertTrue(receipt["missing_counts_remain_pending"])
            self.assertEqual(receipt["budgets"]["timeout_seconds"],60)

    def test_selected_parquet_batch_cursor_and_memory_bounds_without_pyarrow(self):
        class Scalar:
            def __init__(self,value):self.value=value
            def as_py(self):return self.value
        class Table:
            nbytes=10
            num_rows=1
            def column(self,name):return [Scalar({"bytes":b"a"}) if name=="audio" else Scalar("opaque")]
        class Column:
            total_uncompressed_size=10
            total_compressed_size=10;file_path=None;dictionary_page_offset=None
            def __init__(self,path):self.path_in_schema=path;self.data_page_offset=4 if path=="audio.bytes" else 14
        class Group:
            num_rows=2;num_columns=2
            def column(self,index):return Column(["audio.bytes","raw_text"][index])
        class Metadata:
            num_row_groups=2
            def row_group(self,group):return Group()
        class File:
            schema_arrow=types.SimpleNamespace(names={"audio","raw_text","audio_id","speaker_id","is_gold_transcript"})
            metadata=Metadata()
            def __init__(self,*args,**kwargs):self.calls=[]
            def read_row_group(self,group,columns,use_threads):self.calls.append((group,columns));return Table()
            def iter_batches(self,batch_size,row_groups,columns,use_threads):
                self.calls.append((row_groups[0],columns));return iter([Table(),Table()])
            def close(self):pass
        pool=types.SimpleNamespace(bytes_allocated=lambda:10,max_memory=lambda:20)
        package=types.ModuleType("pyarrow");pq=types.ModuleType("pyarrow.parquet");pq.ParquetFile=File;package.parquet=pq
        package.default_memory_pool=lambda:pool
        maps=[]
        def memory_map(path,mode):
            self.assertEqual(mode,"r");self.assertTrue(Path(path).is_file());maps.append(path)
            return types.SimpleNamespace(close=lambda:None)
        package.memory_map=memory_map
        with tempfile.TemporaryDirectory() as directory,patch.dict(sys.modules,{"pyarrow":package,"pyarrow.parquet":pq}),patch.dict(os.environ,{"RECSCRIBE_RUN_DIR":str(Path(directory).resolve())}):
            p=plan();source=p["sources"][0]
            data=b"PAR1"+b"x"*78+b"f"*10+(10).to_bytes(4,"little")+b"PAR1"
            opener,_=http_file(data);a=acquisition(Path(directory),p,real.Exclusions(),opener)
            rows=real.ParquetRows(a,source,source["files"][0])
            profile=rows.transport_preflight([(0,True)])
            self.assertEqual(profile["required_transport_bytes"],42)
            self.assertFalse(profile["audio_or_reference_columns_read"])
            rows.selected(0,0,True);rows.selected(0,1,True)
            self.assertEqual(len(rows._selected_file.calls),1)
            self.assertEqual(rows.parquet.calls,[])
            self.assertEqual(len(maps),1)
            with self.assertRaisesRegex(real.Failure,"advance"):rows.selected(0,0,True)
            rows.selected(1,0,False);self.assertEqual(rows._selected_file.calls[-1][1],["audio"])
            with patch.object(Group,"column",return_value=types.SimpleNamespace(total_uncompressed_size=real.MAX_ROW_GROUP+1,path_in_schema="audio.bytes")):
                with self.assertRaises(real.Failure):rows._table(0,["audio"],real.MAX_ROW_GROUP)
            rows._clear_selected()
            with patch.object(Group,"column",return_value=types.SimpleNamespace(total_uncompressed_size=real.MAX_SOURCE_ROW_GROUP+1,path_in_schema="audio.bytes")):
                with self.assertRaisesRegex(real.Failure,"source_row_group"):rows.selected(0,0,True)
            rows._clear_selected()
            with patch.object(Table,"nbytes",real.MAX_ROW_GROUP+1):
                with self.assertRaisesRegex(real.Failure,"materialized_batch"):rows.selected(0,0,True)
            rows._clear_selected()
            with patch.object(Table,"num_rows",0):
                with self.assertRaisesRegex(real.Failure,"progress"):rows.selected(0,0,True)
            rows._clear_selected()
            with patch.object(pool,"max_memory",return_value=real.MAX_ROW_GROUP+1):
                with self.assertRaisesRegex(real.Failure,"arrow_pool"):rows.selected(0,0,True)
            rows._clear_selected()
            with patch.object(a,"check",side_effect=[None,InterruptedError("cancel")]):
                with self.assertRaises(InterruptedError):rows.selected(0,0,True)
            rows.close();a.transport.close()
            self.assertEqual(list(Path(directory).glob("parquet-transport-*")),[])

    def test_sparse_staging_is_bounded_reuses_ranges_and_evicts_only_owned_transport(self):
        with tempfile.TemporaryDirectory() as directory,patch.dict(os.environ,{"RECSCRIBE_RUN_DIR":str(Path(directory).resolve())}):
            root=Path(directory);protected=root/"original.flac";protected.write_bytes(b"original")
            data=b"0123456789"*100
            opener,calls=http_file(data);a=acquisition(root,plan(),real.Exclusions(),opener)
            f=real.RangeFile(a,"https://example.invalid/one",len(data),"stable")
            stage=real.SparseTransport(a)
            path=stage.stage(f,[(0,4),(100,200),(996,1000)])
            self.assertEqual(path.stat().st_size,1000)
            with path.open("rb") as stream:
                stream.seek(100);self.assertEqual(stream.read(100),data[100:200])
                stream.seek(500);self.assertEqual(stream.read(10),b"\0"*10)
            first=len(calls);stage.stage(f,[(0,4),(150,250),(996,1000)])
            self.assertEqual(len(calls),first+1)
            self.assertEqual(a.network_bytes,158)
            g=real.RangeFile(a,"https://example.invalid/two",len(data),"stable")
            stage.stage(g,[(20,30)])
            self.assertEqual(stage.present,[(20,30)])
            self.assertEqual(path.read_bytes()[100:200],b"\0"*100)
            stage.close();self.assertFalse(path.exists());self.assertEqual(protected.read_bytes(),b"original")
            self.assertEqual(list(root.glob("parquet-transport-*")),[])
            self.assertTrue(any(v["event"]=="evict_disposable_partial_transport" for v in a.transport_events))

    def test_sparse_staging_preflights_physical_and_network_caps_and_cancels(self):
        with tempfile.TemporaryDirectory() as directory,patch.dict(os.environ,{"RECSCRIBE_RUN_DIR":str(Path(directory).resolve())}):
            root=Path(directory);opener,calls=http_file(b"x"*1000)
            a=acquisition(root,plan(),real.Exclusions(),opener);f=real.RangeFile(a,"https://example.invalid/file",1000,"stable")
            stage=real.SparseTransport(a);stage.maximum=1
            with self.assertRaisesRegex(real.Failure,"physical_preflight"):stage.stage(f,[(0,10)])
            self.assertEqual(calls,[])
            stage.maximum=real.MAX_TRANSPORT;a.maximum_network_bytes=5
            with self.assertRaisesRegex(real.Failure,"network_preflight"):stage.stage(f,[(0,10)])
            self.assertEqual(calls,[])
            a.maximum_network_bytes=1000;(root/"cancel.request").touch()
            with self.assertRaises(InterruptedError):stage.stage(f,[(0,10)])
            stage.close();self.assertEqual(calls,[])
        with tempfile.TemporaryDirectory() as directory,patch.dict(os.environ,{"RECSCRIBE_RUN_DIR":""}):
            a=acquisition(Path(directory),plan(),real.Exclusions())
            with self.assertRaisesRegex(real.Failure,"managed_transport"):real.SparseTransport(a)

    def test_staging_large_chunks_never_asks_rangefile_for_a_whole_chunk(self):
        with tempfile.TemporaryDirectory() as directory,patch.dict(os.environ,{"RECSCRIBE_RUN_DIR":str(Path(directory).resolve())}),patch.object(real,"MAX_RANGE",8),patch.object(real,"MAX_READ",16):
            opener,calls=http_file(b"x"*100)
            a=acquisition(Path(directory),plan(),real.Exclusions(),opener)
            f=real.RangeFile(a,"https://example.invalid/large-chunk",100,"stable")
            stage=real.SparseTransport(a);path=stage.stage(f,[(0,60)])
            self.assertEqual(path.read_bytes()[:60],b"x"*60)
            self.assertEqual(len(calls),8)
            for request,_ in calls:
                first,last=map(int,request.get_header("Range").removeprefix("bytes=").split("-"))
                self.assertLessEqual(last-first+1,8)
            stage.close()

    def test_chunk_costs_include_complete_leaf_chunks_and_reject_external_or_outside_ranges(self):
        class Column:
            file_path=None;dictionary_page_offset=10;data_page_offset=20
            total_compressed_size=100;total_uncompressed_size=200;path_in_schema="audio.bytes"
        group=types.SimpleNamespace(num_rows=100,num_columns=1,column=lambda _:Column())
        metadata=types.SimpleNamespace(row_group=lambda _:group)
        self.assertEqual(real.parquet_chunk_intervals(metadata,0,["audio"],200),([(10,110)],200))
        with patch.object(Column,"file_path","external.parquet"):
            with self.assertRaisesRegex(real.Failure,"external"):real.parquet_chunk_intervals(metadata,0,["audio"],200)
        with patch.object(Column,"total_compressed_size",200):
            with self.assertRaisesRegex(real.Failure,"outside"):real.parquet_chunk_intervals(metadata,0,["audio"],200)
        self.assertEqual(real.missing_intervals([(0,30)],[(0,10),(15,20)]),[(10,15),(20,30)])

    def test_development_reuse_checks_all_input_hashes_and_reserves_groups_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();prior=root/"prior.json";prior.write_text('{"cases":[]}')
            opener,_=http_file(b"fixture card")
            with patch.object(real.Acquisition,"run_command",conversion):
                original,complete=real.run(plan(),root/"original",[prior],FakeRows,opener,priority_probe=None)
            self.assertTrue(complete)
            manifest=root/"original/development/manifest.exploratory.legacy.json"
            before={str(v):hashlib.sha256(v.read_bytes()).hexdigest() for v in (root/"original").rglob("*") if v.is_file()}
            p=plan();p["reuse_development"]=[{"manifest":str(manifest),"sha256":hashlib.sha256(manifest.read_bytes()).hexdigest()}]
            self.assertIs(real.validate_plan(p),p)
            a=acquisition(root/"new",p,real.Exclusions());a.root.mkdir()
            real.import_development(a)
            self.assertEqual(len(a.cases),2);self.assertEqual(len(a.reused_development),1)
            self.assertTrue(all(v["split"]=="development" for v in a.cases))
            case=a.cases[0]
            collision=real.identity(p["sources"][0],{"audio_id":case["published_source_id"],"speaker_id":"new-speaker"})
            self.assertIn("source_parent",real.rejection(a,collision))
            after={str(v):hashlib.sha256(v.read_bytes()).hexdigest() for v in (root/"original").rglob("*") if v.is_file()}
            self.assertEqual(before,after)
            p["reuse_development"][0]["sha256"]="0"*64
            with self.assertRaisesRegex(real.Failure,"manifest_hash"):
                real.import_development(acquisition(root/"bad",p,real.Exclusions()))
            p["reuse_development"][0]["sha256"]=before[str(manifest)]
            with patch.object(real,"digest",return_value="0"*64):
                with self.assertRaises(real.Failure):real.import_development(acquisition(root/"bad",p,real.Exclusions()))

    def test_frozen_external_recipe_does_not_misclassify_protected_parent_as_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();recipe=root/"recipes/frozen/acquire-realworld.py";recipe.parent.mkdir(parents=True);recipe.write_bytes(b"frozen source fixture")
            prior=root/"prior.json";prior.write_text('{"cases":[]}');opener,_=http_file(b"card")
            with patch.object(real,"__file__",str(recipe)):
                a,complete=real.run(plan(),root/"metadata",[prior],FakeRows,opener,priority_probe=None,metadata_only=True)
                self.assertTrue(complete)
                repo=Path(__file__).resolve().parents[2]
                with self.assertRaisesRegex(real.Failure,"outside_checkout"):
                    real.run(plan(),repo/"must-not-create-acquisition",[prior],FakeRows,opener,priority_probe=None,metadata_only=True)
                self.assertFalse((repo/"must-not-create-acquisition").exists())

    def test_oversized_footer_is_rejected_before_arrow_constructor(self):
        package=types.ModuleType("pyarrow");pq=types.ModuleType("pyarrow.parquet");package.parquet=pq
        with tempfile.TemporaryDirectory() as directory,patch.dict(sys.modules,{"pyarrow":package,"pyarrow.parquet":pq}):
            data=b"PAR1"+b"x"*80+(real.MAX_METADATA+1).to_bytes(4,"little")+b"PAR1"
            opener,calls=http_file(data);p=plan();source=p["sources"][0];source["files"][0]["bytes"]=len(data)
            a=acquisition(Path(directory),p,real.Exclusions(),opener)
            with patch.object(pq,"ParquetFile",create=True) as constructor:
                with self.assertRaisesRegex(real.Failure,"footer_size"):
                    real.ParquetRows(a,source,source["files"][0])
                constructor.assert_not_called()
            self.assertEqual(a.network_bytes,12)
            self.assertEqual(len(calls),2)

    def test_owned_rss_watchdog_breach_and_uncertainty_reap_only_its_child(self):
        for observed,label in ((2,"rss_bound"),(None,"probe_uncertain")):
            with self.subTest(observed=observed),tempfile.TemporaryDirectory() as directory:
                root=Path(directory).resolve();a=acquisition(root,plan(),real.Exclusions())
                with self.assertRaisesRegex(real.Failure,label):
                    a.run_command([sys.executable,"-c","import time;time.sleep(5)"],2,
                                  maximum_rss_bytes=1,rss_probe=lambda _pid,_timeout:observed)
                saved=json.loads(next((root/"helpers").glob("cleanup-*.json")).read_bytes())
                self.assertTrue(saved["cli_reaped"]);self.assertFalse(saved["owned_session_present"])
                self.assertEqual(saved["shutdown_errors"],[]);self.assertIsNone(a.owned_session)
        with patch.object(real.subprocess,"run",return_value=types.SimpleNamespace(returncode=0,stdout=b"invalid",stderr=b"")):
            with self.assertRaisesRegex(real.Failure,"probe_uncertain"):real.probe_child_rss(123,1)

    def test_isolated_worker_caps_progress_deadlines_and_no_overwrite_without_pyarrow(self):
        class Scalar:
            def __init__(self,value):self.value=value
            def as_py(self):return self.value
        class Batch:
            nbytes=100;num_rows=1
            def column(self,name):return [Scalar({"bytes":wav_bytes()}) if name=="audio" else Scalar("opaque fixture")]
        class Column:
            file_path=None;dictionary_page_offset=None;total_uncompressed_size=100;total_compressed_size=10
            def __init__(self,path):self.path_in_schema=path;self.data_page_offset=4 if path=="audio.bytes" else 14
        class Group:
            num_rows=2;num_columns=2
            def column(self,index):return Column(["audio.bytes","raw_text"][index])
        class File:
            def __init__(self,*_args,**_kwargs):self.metadata=types.SimpleNamespace(row_group=lambda _group:Group())
            def iter_batches(self,**kwargs):return iter([Batch(),Batch()])
            def close(self):pass
        pool=types.SimpleNamespace(bytes_allocated=lambda:10,max_memory=lambda:20)
        package=types.ModuleType("pyarrow");pq=types.ModuleType("pyarrow.parquet");package.parquet=pq;pq.ParquetFile=File
        package.memory_map=lambda *_args:types.SimpleNamespace(close=lambda:None);package.default_memory_pool=lambda:pool
        with tempfile.TemporaryDirectory() as directory,patch.dict(sys.modules,{"pyarrow":package,"pyarrow.parquet":pq}):
            root=Path(directory).resolve();source=root/"partial.parquet"
            source.write_bytes(b"PAR1"+b"x"*32+b"f"*10+(10).to_bytes(4,"little")+b"PAR1")
            request={"kind":"voxpopuli","limits":real.ISOLATED_LIMITS["voxpopuli"],"mmap_path":str(source),
                     "logical_file_bytes":source.stat().st_size,"footer_start":36,"staged_ranges":[[0,54]],
                     "row_group":0,"row_in_group":1,"with_reference":True,
                     "deadline_monotonic":time.monotonic()+30,"deadline_utc_seconds":time.time()+30}
            def execute(name,changes=None):
                p=root/(name+".json");p.write_text(json.dumps({**request,**(changes or {})}));out=root/name;out.mkdir()
                code=real.decode_mmap_worker(p,out);return code,out,json.loads((out/"result.json").read_bytes())
            code,out,result=execute("success")
            self.assertEqual(code,0);self.assertTrue(result["passed"])
            self.assertEqual(result["assets"]["audio.original.bin"]["sha256"],hashlib.sha256((out/"audio.original.bin").read_bytes()).hexdigest())
            with patch.object(pool,"max_memory",return_value=2*real.GIB+1):
                code,out,result=execute("pool-failure");self.assertEqual(code,1)
                self.assertEqual(result["error"]["reason"],"worker_arrow_pool_bound");self.assertFalse((out/"audio.original.bin").exists())
            with patch.object(Batch,"nbytes",real.MAX_ROW_GROUP+1):
                code,out,result=execute("batch-failure");self.assertEqual(result["error"]["reason"],"worker_materialized_batch_bound")
            code,out,result=execute("deadline",{"deadline_utc_seconds":0});self.assertEqual(code,1)
            self.assertEqual(result["error"]["type"],"TimeoutError")
            p=root/"no-overwrite.json";p.write_text(json.dumps(request));out=root/"no-overwrite";out.mkdir();(out/"audio.original.bin").write_bytes(b"existing")
            self.assertEqual(real.decode_mmap_worker(p,out),1);self.assertEqual((out/"audio.original.bin").read_bytes(),b"existing")

    def test_isolated_sidecars_are_bounded_preserved_and_scratch_is_owned(self):
        with tempfile.TemporaryDirectory() as directory,patch.dict(os.environ,{"RECSCRIBE_RUN_DIR":str(Path(directory).resolve())}):
            root=Path(directory).resolve();p=plan();p["budgets"]["output_bytes"]=256*real.MIB;p["isolated_decoder_limits"]={"voxpopuli":real.ISOLATED_LIMITS["voxpopuli"]}
            self.assertIs(real.validate_plan(p),p)
            bad=copy.deepcopy(p);bad["isolated_decoder_limits"]["voxpopuli"]["observed_arrow_bytes"]+=1
            with self.assertRaisesRegex(real.Failure,"prospective_isolated"):real.validate_plan(bad)
            blob=b"PAR1"+b"x"*32+b"f"*10+(10).to_bytes(4,"little")+b"PAR1";opener,_=http_file(blob)
            a=acquisition(root,p,real.Exclusions(),opener)
            rows=object.__new__(real.ParquetRows);rows.acquisition=a;rows.source=p["sources"][0];rows._footer_start=36
            rows.remote=real.RangeFile(a,"https://example.invalid/data",len(blob),"stable")
            rows.transport_preflight=lambda _: {"required_ranges":[(0,len(blob))]}
            def worker(command,*_args,**_kwargs):
                target=Path(command[-1]);assets={"audio.original.bin":wav_bytes(),"reference.original.txt":b"opaque fixture"}
                for name,value in assets.items():(target/name).write_bytes(value)
                (target/"result.json").write_text(json.dumps({"passed":True,"memory":{"maximum_observed_arrow_bytes":10,"maximum_reported_arrow_pool_peak_bytes":20,"process_peak_rss_bytes":100},"assets":{name:{"bytes":len(value),"sha256":hashlib.sha256(value).hexdigest()} for name,value in assets.items()}}))
            with patch.object(a,"run_command",worker):
                audio,reference=rows._isolated_selected(0,0,True)
            self.assertEqual(audio["bytes"],wav_bytes());self.assertEqual(reference,"opaque fixture")
            self.assertLess(a.output_bytes,real.MIB)
            self.assertEqual(len(list((root/"decoder-sidecars/worker-1").iterdir())),4)
            self.assertEqual(list(a.transport.directory.glob("worker-*")),[])
            def cancelled(*_args,**_kwargs):raise InterruptedError("cancel")
            with patch.object(a,"run_command",cancelled):
                with self.assertRaises(InterruptedError):rows._isolated_selected(0,1,True)
            self.assertEqual(list(a.transport.directory.glob("worker-*")),[])
            with patch.object(real,"MAX_AUDIO",10),patch.object(a,"run_command",worker):
                with self.assertRaisesRegex(real.Failure,"sidecar_bound"):rows._isolated_selected(0,1,True)
            self.assertTrue(a.transport.recovery_pending);self.assertTrue((root/".pin").exists())
            self.assertTrue(list(a.transport.directory.glob("worker-*/audio.original.bin")))
            recovery=a.transport.directory
            a.transport.close()
            self.assertTrue(recovery.exists())

    def test_protected_copy_failure_keeps_the_only_extracted_original_and_pins_recovery(self):
        for existing in (False,True):
            with self.subTest(existing=existing),tempfile.TemporaryDirectory() as directory,patch.dict(os.environ,{"RECSCRIBE_RUN_DIR":str(Path(directory).resolve())}):
                root=Path(directory).resolve();p=plan();p["isolated_decoder_limits"]={"voxpopuli":real.ISOLATED_LIMITS["voxpopuli"]}
                blob=b"PAR1"+b"x"*32+b"f"*10+(10).to_bytes(4,"little")+b"PAR1";opener,_=http_file(blob)
                a=acquisition(root,p,real.Exclusions(),opener)
                rows=object.__new__(real.ParquetRows);rows.acquisition=a;rows.source=p["sources"][0];rows._footer_start=36
                rows.remote=real.RangeFile(a,"https://example.invalid/data",len(blob),"stable")
                rows.transport_preflight=lambda _: {"required_ranges":[(0,len(blob))]}
                destination=root/"decoder-sidecars/worker-1/audio.original.bin"
                if existing:destination.parent.mkdir(parents=True);destination.write_bytes(b"existing protected input")
                def worker(command,*_args,**_kwargs):
                    out=Path(command[-1]);(out/"audio.original.bin").write_bytes(wav_bytes())
                original_open=Path.open
                def fail_copy(path,mode="r",*args,**kwargs):
                    if path==destination and mode=="xb" and not existing:raise OSError("synthetic copy failure")
                    return original_open(path,mode,*args,**kwargs)
                with patch.object(a,"run_command",worker),patch.object(Path,"open",fail_copy):
                    with self.assertRaises(OSError):rows._isolated_selected(0,0,True)
                self.assertTrue(a.transport.recovery_pending);self.assertTrue((root/".pin").exists())
                recovered=next(a.transport.directory.glob("worker-*/audio.original.bin"))
                self.assertEqual(recovered.read_bytes(),wav_bytes())
                if existing:self.assertEqual(destination.read_bytes(),b"existing protected input")
                a.transport.close();self.assertTrue(recovered.exists())

    def test_arabic_resource_projects_only_physical_channel_zero_without_reference_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();a=acquisition(root,plan(),real.Exclusions())
            s=plan()["sources"][1];s.update(kind="casablanca",dataset="UBC-NLP/Casablanca",config="Egypt",language="ar",resource_channel=0)
            item=real.identity(s,{"seg_id":"prospective-resource"})
            output=io.BytesIO()
            with wave.open(output,"wb") as stream:
                stream.setnchannels(2);stream.setsampwidth(2);stream.setframerate(16000)
                stream.writeframes((b"\x64\x00\x9c\xff")*32000)
            original=output.getvalue()
            with patch.object(real.Acquisition,"run_command",conversion):
                case=real.prepare_selected(a,s,item,{"bytes":original},None,{"url":"https://example.invalid/pinned"})
            self.assertEqual(Path(case["original_audio"]).read_bytes(),original)
            self.assertFalse(case["channel_view"]["mixing"]);self.assertFalse(case["channel_view"]["reference_applicability_claimed"])
            self.assertNotIn("reference",case)
            with wave.open(case["audio"],"rb") as stream:
                self.assertEqual(stream.getnchannels(),1);self.assertEqual(stream.readframes(1),b"\x64\x00")
            bad=plan();bad["sources"][0]["resource_channel"]=0
            with self.assertRaisesRegex(real.Failure,"resource_channel"):real.validate_plan(bad)

    def test_utc_deadline_and_free_disk_bounds_stop_before_new_transport(self):
        with tempfile.TemporaryDirectory() as directory:
            a=acquisition(Path(directory),plan(),real.Exclusions());a.deadline_utc_seconds=0
            with self.assertRaises(TimeoutError):a.check()
            a.deadline_utc_seconds=time.time()+30
            rows=object.__new__(real.ParquetRows);rows.acquisition=a
            with patch.object(real.shutil,"disk_usage",return_value=types.SimpleNamespace(free=20*real.GIB-1)):
                with self.assertRaisesRegex(real.Failure,"free_disk"):rows._isolated_selected(0,0,False)


if __name__ == "__main__":
    unittest.main()
