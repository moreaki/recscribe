#!/usr/bin/env python3
"""Actual new reporting mains over completed explicitly synthetic15-stage fixture."""
import argparse,hashlib,json,os,pathlib,subprocess,sys
R=pathlib.Path(__file__).resolve().parent
def digest(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def write(p,v):
 b=(json.dumps(v,indent=2,allow_nan=False)+"\n").encode()
 with p.open("xb") as f:f.write(b)
 return {"path":str(p),"sha256":hashlib.sha256(b).hexdigest()}
def write_line(p,v):
 b=(json.dumps(v,allow_nan=False)+"\n").encode()
 with p.open("xb") as f:f.write(b)
 return {"path":str(p),"sha256":hashlib.sha256(b).hexdigest()}
def main():
 pathlib.Path(os.environ["RECSCRIBE_RUN_DIR"],".pin").touch()
 p=argparse.ArgumentParser();p.add_argument("--fixture",type=pathlib.Path,required=True);a=p.parse_args()
 f=a.fixture.resolve(); s=json.loads((f/"packaged-smoke.receipt.json").read_text())
 assert s["synthetic_only"] is True and s["recognition_or_model_initialization_or_quantization_executed"] is False and s["stage_count"]==15
 family=f/"pre-inference-family-seal.json"; journal=f/"serial.events.jsonl"
 assert digest(family)==s["family_sha256"] and digest(journal)==s["journal_sha256"]
 events=[json.loads(x) for x in journal.read_text().splitlines()];assert events[-1]["event"]=="serial_finished"
 att=events[0]["initial_attestation"]
 load=write(f/"synthetic-load-receipt.json",{"synthetic_only":True,"status":"passed","verified_derived_artifacts":6,"recognition_performed":False,"quality_inference_grid_cells_added":0})
 guard=write_line(f/"synthetic-load-guard.jsonl",{"event":"finished","synthetic_only":True,"canceled":False,"reason":None,"failure":None,"shutdown":{"returncode":0,"cli_reaped":True,"owned_session_present":False,"shutdown_errors":[]}})
 admission=write(f/"inference-launch.freeze.v1.json",{"synthetic_only":True,"frozen_inputs":{"family":{"path":str(family),"sha256":s["family_sha256"]},"idle":att},"unchanged_initial_family_seal":True,"candidates_or_settings_changed":False,"preflight_added_quality_cells":0,"default_promotion":False,"native_load_receipt":load,"native_load_guard":guard})
 sources={}
 for name in ("summarize-round5-v1.py","project-round5-report-v1.py"):
  b=(R/name).read_bytes()
  with (f/name).open("xb") as stream:stream.write(b)
  sources[name]=hashlib.sha256(b).hexdigest()
 summary=f/"reporting-cli-summary";projection=f/"reporting-cli-projection"
 c=[sys.executable,"-B",str(f/"summarize-round5-v1.py"),"--family-seal",str(family),"--family-seal-sha256",s["family_sha256"],"--journal",str(journal),"--journal-sha256",s["journal_sha256"],"--admission-capsule",admission["path"],"--admission-capsule-sha256",admission["sha256"],"--expected-source-sha256",sources["summarize-round5-v1.py"],"--output",str(summary)]
 results=[]
 for command in (c,[sys.executable,"-B",str(f/"project-round5-report-v1.py"),"--summary",str(summary/"summary.json"),"--summary-sha256","DEFER","--family-seal-sha256",s["family_sha256"],"--admission-capsule-sha256",admission["sha256"],"--expected-source-sha256",sources["project-round5-report-v1.py"],"--output",str(projection)]):
  command=[digest(summary/"summary.json") if v=="DEFER" else v for v in command]
  result=subprocess.run(command,capture_output=True,text=True,timeout=60);results.append({"command":command,"returncode":result.returncode,"stdout":result.stdout,"stderr":result.stderr})
  if result.returncode:break
 if len(results)==2 and all(v["returncode"]==0 for v in results):
  v=json.loads((summary/"summary.json").read_text());assert v["coverage"]["attempted_cells"]==4554 and v["coverage"]["failed_cells"]==2 and v["complete_quality_coverage"] is False
  a=json.loads((projection/"audit.json").read_text());assert (a["language_cohorts"],a["canonical_model_modes"])==(495,55)
  status="PASSED_ACTUAL_REPORTING_MAINS_SYNTHETIC_ONLY"
 else:status="FAILED_MODEL_FREE_REPORTING_SMOKE"
 receipt={"schema_version":"round5-reporting-cli-write-smoke-v1","status":status,"synthetic_only":True,"model_initialization_asr_or_quantization_executed":False,"source_files":sources,"fixture_receipt":{"path":str(f/"packaged-smoke.receipt.json"),"sha256":digest(f/"packaged-smoke.receipt.json")},"results":results}
 out=write(f/"reporting-cli-smoke.receipt.json",receipt);print(json.dumps({"status":status,"receipt":out}));return 0 if status.startswith("PASSED") else 1
if __name__=="__main__":raise SystemExit(main())
