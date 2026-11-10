#!/usr/bin/env python3
"""Actual new CLI refusal before absent late metadata/payloads; synthetic only."""
import hashlib,importlib.util,json,os,subprocess,sys,tempfile,unittest
from pathlib import Path
R=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
spec=importlib.util.spec_from_file_location('r5_cli_barrier_fixture',R/'test-final-numeric-audit-v1.py');T=importlib.util.module_from_spec(spec);spec.loader.exec_module(T)
class Contracts(unittest.TestCase):
    def stopped(self,root):
        f,e=T.fixture();f['paths']={'journal':str(root/'journal.jsonl')};p=root/'family.json';p.write_text(json.dumps(f))
        for event in (e[0],e[-1]):event['family_seal_sha256']=sha(p)
        e[-1]['event']='serial_stopped';j=root/'journal.jsonl';j.write_text(''.join(json.dumps(x)+'\n' for x in e));return p,j
    def run_refusal(self,kind):
        with tempfile.TemporaryDirectory(prefix='recscribe-r5-cli-refusal-') as folder:
            root=Path(folder).resolve();family,journal=self.stopped(root);source=R/('audit-'+kind+'-v1.py');out=root/'new-output'
            args={'family-seal':str(family),'family-seal-sha256':sha(family),'journal':str(journal),'journal-sha256':sha(journal),
              'admission-capsule':str(root/'MUST-NOT-OPEN-admission.json'),'admission-capsule-sha256':'f'*64,'expected-source-sha256':sha(source),'output':str(out)}
            if kind=='postrun-preservation':
                args.update({'integrity':str(root/'MUST-NOT-OPEN-integrity.json'),'integrity-sha256':'f'*64,
                  'operation-freeze':str(root/'MUST-NOT-OPEN-operation.json'),'operation-freeze-sha256':'f'*64})
            else:
                for key in ('audit-freeze','preservation-freeze','reporting-freeze','preservation-receipt','preservation-guard'):
                    args[key]=str(root/('MUST-NOT-OPEN-'+key+'.json'))
                for key in ('preservation-source','summary-source','projector-source'):args[key]=str(root/('MUST-NOT-OPEN-'+key+'.py'))
                args.update({'summary':str(root/'missing-summary/summary.json'),'projection-audit':str(root/'missing-projection/audit.json')})
                for key in ('audit-freeze-sha256','preservation-sha256','preservation-guard-sha256','summary-sha256','projection-audit-sha256',
                  'summary-source-sha256','projector-source-sha256','reporting-freeze-sha256','preservation-source-sha256','preservation-freeze-sha256'):args[key]='f'*64
            command=[sys.executable,'-B',str(source)]
            for key,value in args.items():command+=['--'+key,value]
            result=subprocess.run(command,capture_output=True,text=True,timeout=10)
            self.assertNotEqual(result.returncode,0,result.stdout);self.assertIn('All15 terminal barrier not satisfied',result.stderr)
            self.assertFalse(out.exists());self.assertNotIn('FileNotFoundError',result.stderr)
    def test_actual_postrun_cli_refuses_stopped_journal_before_payload(self):self.run_refusal('postrun-preservation')
    def test_actual_numeric_cli_refuses_stopped_journal_before_outcomes(self):self.run_refusal('final-numeric-gates')
if __name__=='__main__':
    Path(os.environ['RECSCRIBE_RUN_DIR'],'.pin').touch(exist_ok=True);unittest.main()
