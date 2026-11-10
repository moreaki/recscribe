import hashlib,json,os
from pathlib import Path
r=Path("/Users/moreaki/Library/Application Support/RecScribe/Benchmarks/Research/112/round-5")
Path(os.environ["RECSCRIBE_RUN_DIR"],".pin").touch()
def require(v,m):
 if not v:raise ValueError(m)
def read(p,expected=None):
 raw=Path(p).read_bytes();require(expected is None or hashlib.sha256(raw).hexdigest()==expected,"Pinned operation input differs");return json.loads(raw)
def pin(p):
 raw=Path(p).read_bytes();return {"path":str(p),"sha256":hashlib.sha256(raw).hexdigest(),"bytes":len(raw)}
freeze_pin={"path":str(r/"independent-preflight-audit.freeze.v1.json"),"sha256":"baa9a4bccdc58d4b28fa17a12e6e4f90a8c00bd7107975f587afe975ca59a720"}
f=read(freeze_pin["path"],freeze_pin["sha256"])
for key in ("source","test_source","model_denial_smoke_launcher","family","guard","validation"):
 require(pin(f[key]["path"])==f[key],"Prospective operation source changed")
gp=pin(r/"independent-preflight-smoke.guard.v1.jsonl")
events=[json.loads(x) for x in Path(gp["path"]).read_bytes().splitlines() if x.strip()]
command=f["smoke_command"];expected=command[command.index("--")+1:];end=events[-1]
expected[0]=str(Path(expected[0]).expanduser().resolve(strict=True))
expected[expected.index("--output")+1]=str(Path(expected[expected.index("--output")+1]).expanduser().resolve())
require(events[0]["event"]=="starting" and events[0]["command"]==expected and end["event"]=="finished","Actual smoke guard command differs")
require(end.get("reason") is None and end.get("failure") is None and end.get("canceled") is False and end["shutdown"]=={"returncode":0,"cli_reaped":True,"owned_session_present":False,"shutdown_errors":[]},"Actual smoke did not cleanly finish")
require(type(end["shutdown"]["returncode"])is int and not any(e.get("event") in ("cancel_requested","owned_group_signal","owned_cli_signal","interrupted","cancelled") for e in events),"Canceled or malformed smoke")
sp=pin(r/"independent-preflight-smoke-v1"/"audit.json");s=read(sp["path"],sp["sha256"])
require(s["status"]=="PREFLIGHT_METADATA_ONLY_NO_MODEL_PAYLOAD" and s["models_verified"]==0 and s["model_payloads_opened"]is False and s["family"]["sha256"]==f["family"]["sha256"] and s["audit_source"]["sha256"]==f["source"]["sha256"],"Smoke actual output differs")
require(not(r/"independent-preflight-audit.guard.v1.jsonl").exists() and not(r/"independent-preflight-audit-v1").exists(),"Actual audit already attempted")
failure=pin(Path("/Users/moreaki/.codex/worktrees/swiss-written-corpus/recscribe/Build/Artifacts/benchmark/20261109-215326-issue-112-r5-independent-static-audit-2764eb05/console.log"))
value={"schema_version":"round5-independent-preflight-admission-v1","status":"passed","operation_freeze":freeze_pin,"smoke_guard":gp,"smoke_receipt":sp,"metadata_cli_exitcode":0,"model_payload_open_attempts":0,"fixed_model_payload_paths_denied":11,"source":f["source"],"actual_command":f["actual_command"],"recognition_or_model_initialization":False,"prior_admission_verifier_packaging_failure":{"console":failure,"payload_worker_launched":False,"cause":"Verifier did not apply pinned guard argv[0] canonicalization; corrected exactly to existing7697 semantics, no audit source or freeze change"}}
with (r/"independent-preflight-admission.v1.json").open("x") as stream:json.dump(value,stream,indent=2);stream.write("\n");stream.flush();os.fsync(stream.fileno())
print(json.dumps({"admission":pin(r/"independent-preflight-admission.v1.json")}),flush=True)
c=f["actual_command"];os.execv(c[0],c)
