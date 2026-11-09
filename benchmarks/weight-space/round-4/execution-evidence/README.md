# Round 4 execution-source and numeric evidence archive

This is an archival copy of the frozen round-4 execution and reporting sources.
The actual executing files and all original evidence remain in protected external
storage, unchanged. Files in `sources/` are byte-identical inspection copies;
they are not new executing versions and were not used to run the experiment.

Status: **audited aggregate copies published; complete terminal attempts, partial development quality**.
All 4,554 calls were attempted: 4,553 succeeded and one Base development call
remains failed/unscored. All 3,168 held-out calls succeeded. Full planned Base
development aggregates remain incomplete; global quality coverage is not complete. See the
[prospective protocol](../../../weight-space-round4-protocol.md),
[artifact checkpoint](../../../weight-space-round4-artifacts-2026-11-07.md) and
[execution record](../../../weight-space-round4-execution-2026-11-09.md).

`evidence-index.json` records every copied source SHA-256, byte count and role.
There are 14 tool sources (455,533 bytes) and 10 synthetic test/smoke sources
(82,384 bytes). These synthetic fixtures contain invented metadata, not corpus
transcripts. No archived source or test was executed during publication copying.

The original extra EOF blank lines in `classify-native-output-failure-v2.py`,
`run-remaining.py` and `seal-heldout.py` are retained. Git's whitespace check
reports those three archival findings; trimming them would change the recorded
historical source hashes. Curated reports and other added files have no such
findings. This does not relax any mandatory test or CI gate.

## Actual source attribution

- `run-remaining.py` is the original campaign controller, including the retained
  classifier-filename mismatch. Its stopped journal is not rewritten.
- `continuation-v1/run-remaining.py` is the actual resumed controller. It inherits
  the original stage runner and adapts only the classifier output basename, then
  creates an exclusive byte-identical metadata alias after the unchanged proof.
- `seal-heldout.py`, `classify-native-output-failure-v2.py` and `run-guard.py`
  retain the original finite failure, capture-priority and owned-cleanup rules.
- `continuation-v1/project-journal.py` verifies both raw journals and preserves
  the stop in an explicitly derived logical journal. That projection is not an
  actual raw execution journal.
- `continuation-v1/summarize-continuation-v1.py` is the final summary adapter.
  It calls the unchanged `build` function from `summarize-round4-v1.py`; the
  original builder's `main` is not the executing entry point.
- `project-round4-report-v1.py` projects that summary to three numeric CSVs and
  readable Markdown, without rescoring or changing frozen decisions.
- `continuation-v1/audit-final-numeric-gates.py` is the final independent audit.
  Its 41 scientific functions retain the original audit's bytes; provenance and
  entry-point adaptation are explicit. The old audit is retained for comparison.
- `continuation-v1/audit-postrun-preservation.py` is the final opaque preservation
  authority and reuses the original preservation core. Its result also requires
  a separately closed clean guard receipt; a running worker cannot attest cleanup.

These sources were authored for RecScribe with AI assistance. The operator's
mathematical motivation and primary-source attribution remain in the prospective
protocol. The archive does not claim a new quantizer or redistribute upstream
Whisper binaries, model weights or third-party training data.

## Reconstruction and dependency limits

Keep the relative layout under `sources/` when reconstructing an external tool
root: the original controller and sealer are at its top level; continuation
wrappers are one directory below. This preserves source-to-source lookup for
the controller, builder and opaque preservation core. The synthetic numeric and
preservation adapters also retain their original base-test files here.

This archive alone is not a portable replay package. Historical seals bind
absolute protected paths, exact binaries, all 15 preplans, corpus/source hashes,
runtime records and acquisition/exclusion history. Those files are not copied
here. `native-load-check-v1.py` additionally resolves the retained sibling
round-3 native inventory. Metadata-only tools still need their hash-bound
matrix/report/plan inputs; no raw input is implicitly substituted.

The pinned public attention assessor dynamically imports its sibling
`assess-affine-pilot.py`, which imports `report-pilot.py`. Those sources are already
in [scripts/quality](../../../../scripts/quality/); the independent archive index
links their exact historical revision. The historical packaged assessor layout
was `quality/scripts/quality/`, which matters to its external-output boundary.
Model export additionally depends on the public rotation/export/GGML tools,
the pinned official quantizer and the actual model hashes in the artifact record.

Do not launch campaign controllers or write smoke fixtures from this checkout.
Offline reconstruction belongs in a new protected external root with explicit
inputs and bounds. Repeating an experiment requires its own prospective seals;
editing historical paths or hashes is not reproduction of the original receipt.
Two additional protected integration harnesses with original developer-workspace
path literals are not copied; their validation receipts remain part of the
external evidence. No actual audio/reference/hypothesis/model path is published.

## Published numeric evidence

All 15 grids reached their fixed terminal attempt counts and the final independent
numeric/provenance audit passed before these seven aggregate files were copied.
Every file below is byte-identical to its protected original; no CSV was parsed
and rewritten, no empty/null metric was replaced, and no gate JSON was edited.
Exact SHA-256s, byte counts and observed row/record counts are in the index.

| Published export | Data rows or JSON records | Generating source |
| --- | ---: | --- |
| [quality.csv](quality.csv) | 495 cohort rows | Frozen projector `ce29043f…` |
| [resources.csv](resources.csv) | 495 cohort rows | Frozen projector `ce29043f…` |
| [macros.csv](macros.csv) | 55 rows | Frozen projector `ce29043f…` |
| [heldout-resource-headlines.csv](heldout-resource-headlines.csv) | 22 artifact/mode rows | Independent audit `79516b2a…` |
| [heldout-quality-headlines.csv](heldout-quality-headlines.csv) | 22 artifact/mode rows | Independent audit `79516b2a…` |
| [native-load-observations.csv](native-load-observations.csv) | 495 cohort rows | Independent audit `79516b2a…` |
| [gate-headlines.json](gate-headlines.json) | 10 family/stage/mode records | Independent audit `79516b2a…` |

The [measurements appendix](../../../weight-space-round4-measurements-2026-11-09.md)
is the complete generated `report.md` from projector `ce29043f…`, copied verbatim
including its title, with no prefix or body edits. The actual independent
exporting audit is `sources/continuation-v1/audit-final-numeric-gates.py`, distinct
from the original audit retained for comparison. Full source attribution remains
in the index. Original exports, receipts and both raw journals remain external.

The independent audit verified 21,416 native count/rate relations and 327 frozen
gate values (279 true, 47 false, one unknown). Passing that integrity audit does
not mean all quality gates passed or that a model/default was promoted. The
one failed Base development call remains unscored in the original evidence and
the published null/coverage fields; no later-repeat fallback or retry fills it.

The 22 held-out resource headlines pool individual successful jobs for each of
11 artifacts and two language modes. They provide medians that cannot be
reconstructed from per-language medians. Planned 144/successful/measured counts
must accompany those observations. The full-144 wall-sum/audio-sum RTF is null
when the complete workload is unavailable. Load observations have separate
counts and retain the upstream-only model-load scope. No median of medians,
full-initialization latency or controlled resource acceptance is inferred.

Gate headlines cover Small and Turbo in two panel modes, one development mode
and two held-out modes each. References do not produce gate headlines. Relative
gains/saving are fractions; macro deltas multiplied by 100 are percentage points.
Known-mode numerical label matches are neutral internal bookkeeping, not
automatic-language evidence; presentation must label that scope N/A without
rewriting the exact JSON. False and unknown gate lists remain distinct.

Each cohort is one stage/artifact/language/mode, not an independent speaker.
CSV null fields remain missing, never zero. Chinese whitespace WER is unreported;
the full CER macro needs nine languages and WER eight. Partial observed counts
remain separate from full planned metrics. Failed cells remain failed/unscored.
Panel repeats do not add independent quality sources. Wall/load/RTF/RSS have
different scopes and observation counts. Shared-desktop resource acceptance is
**UNCONTROLLED / NOT EVALUATED**. Native, reviewed-v2 and product gates remain open.

The curated index identifies both unchanged raw journals, the explicitly
derived logical projection, final summary/projector/audit and clean closed
preservation guard by their original hashes. The opaque preservation authority
verified 1,029 frozen inputs and 72,969 retained outputs; those inventories and
raw evidence are not copied here. A curated index has its own hash; it is not a byte-identical copy of a
protected seal, journal or receipt containing absolute evidence paths.
