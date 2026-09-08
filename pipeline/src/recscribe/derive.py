"""New immutable job derived from a canonical transcript; never reruns ASR."""
import copy
import hashlib
import json
from pathlib import Path

from .job import validate
from .process import Cancelled
from .storage import sha256, write_json, write_text

MAX_TRANSCRIPT_BYTES = 16 * 1024 * 1024


def run(job, cloud_key=None):
    try:
        job.cancel.check()
        with job.source.open("rb") as source:
            data = source.read(MAX_TRANSCRIPT_BYTES + 1)
        if len(data) > MAX_TRANSCRIPT_BYTES:
            raise ValueError("Transcript exceeds the post-processing size limit")
        original = json.loads(data)
        validate(original)
        write_json(job.directory / "input-transcript.json", original)
        digest = hashlib.sha256(data).hexdigest()
        if sha256(job.source, job.cancel.check) != digest:
            raise ValueError("Parent transcript changed during loading")
        job.manifest["parent_transcript"] = {"path": str(job.source), "sha256": digest}
        job.manifest["source_path"] = original["source"]["path"]
        # Existing evidence remains in the parent job. Do not duplicate hours of
        # working audio or rewrite raw ASR just to improve a text rendition.
        write_json(job.directory / "transcript.raw.json", {
            "schema_version": "1.0", "kind": "parent_transcript_reference",
            "parent": job.manifest["parent_transcript"], "raw_asr_unchanged": True})
        write_json(job.directory / "audio-report.json", original["source"])
        job.options["source_language"] = original["processing"]["source_language"]
        job.options["profile"] = original["processing"]["profile"]
        reasons = [r for r in original["review_reasons"] if not r.endswith("_processor_not_configured") and r != "ai_summary_unverified"]
        retained = copy.deepcopy(original) if job.options.get("summarize") and job.options["mode"] == "verbatim" else None
        if retained:
            for derivation in retained["language_processing"]["derivations"]:
                for field in ("raw_path", "model_metadata_path"):
                    if field in derivation and not Path(derivation[field]).is_absolute():
                        derivation[field] = str(job.source.parent / derivation[field])
        return job.finish(original["source"], copy.deepcopy(original["segments"]),
                          original["processing"]["engine_passes"], reasons,
                          job.started_monotonic, cloud_key=cloud_key, retained_text=retained)
    except (Exception, KeyboardInterrupt) as error:
        state = "cancelled" if isinstance(error, (Cancelled, KeyboardInterrupt)) else "failed"
        job.manifest["error"] = {"type": type(error).__name__, "message": str(error)}
        write_text(job.directory / "review.md", f"# Post-processing {state}\n\nOriginal transcript retained.\n\n{error}\n")
        job.inventory()
        job.transition(state, job.manifest["progress"])
        raise
