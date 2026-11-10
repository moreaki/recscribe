#!/usr/bin/env python3
"""Run the exact audit metadata CLI while refusing every fixed model payload."""
import builtins
import io
import json
import os
from pathlib import Path
import runpy
import sys

root=Path(__file__).resolve().parent
family=root/'pre-inference-family-seal.json'
models={str(Path(m['path']).resolve()) for m in json.loads(family.read_bytes())['models']}
original_io=io.open
original_builtin=builtins.open
attempts=[]
def guarded(function):
    def opened(file,*args,**kwargs):
        if isinstance(file,(str,bytes,os.PathLike)) and str(Path(os.fsdecode(file)).resolve()) in models:
            attempts.append(os.fsdecode(file))
            raise PermissionError('Model payload open forbidden in metadata CLI smoke')
        return function(file,*args,**kwargs)
    return opened
io.open=guarded(original_io)
builtins.open=guarded(original_builtin)
sys.argv[0]=str(root/'independent-preflight-audit-v1.py')
try:
    runpy.run_path(sys.argv[0],run_name='__main__')
except SystemExit as ended:
    if ended.code not in (None,0):raise
    if attempts:raise RuntimeError('Metadata smoke attempted a model payload open')
    print(json.dumps({'fixed_model_payload_paths_denied':len(models),'model_payload_open_attempts':len(attempts),'actual_audit_cli_exitcode':0}),flush=True)
