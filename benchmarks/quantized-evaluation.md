# Quantized-model evaluation: Small, Turbo and full large-v3

Tracks #104/#105 and the real-world scenarios in #122. The default and installed
models remain unchanged. This protocol uses ordinary supported quantization;
rejected AI weight-space recipes and all their frozen evidence remain archived.

## Admission and attribution

The user's minimum useful compression is **30% fewer model-file bytes compared
with the same standard F16 model**, while preserving transcription quality.
Compare ordinary Small Q5_1/Q4_0 with Small F16, Turbo Q5_1/Q4_0 with Turbo F16,
and full large-v3 Q5_1/Q4_0 with full large-v3 F16. Each comparison keeps the exact
parent hash, quantizer hash/version, output hash, command, precision and file
length. Q4_0 and Q5_1 are fixed candidate recipes, not an outcome-selected sweep.
An interrupted export remains incomplete evidence; it is never overwritten or
silently treated as a compatible model.

Cross-model replacements (Base F16 versus Small Q4, Small F16 versus Turbo Q4)
are separate product comparisons. Their nearly equal file lengths do **not**
satisfy a 30% size-reduction claim. They may improve accuracy per model byte,
but have different architectures and potentially different computation/memory.

The existing reporter accepts an optional `model_size_policy` in the retained
experiment JSON. It is bound by the experiment's existing freeze hash:

```json
{
  "schema_version": "1.0",
  "minimum_reduction_percent": 30,
  "comparisons": [{
    "id": "small-q4-size",
    "baseline_model_id": "small",
    "candidate_model_id": "small-q4",
    "purpose": "same_model_compression"
  }]
}
```

`purpose` may instead be `cross_model_replacement`. Compression comparisons
require the derived artifact's actual declared untouched parent. Both identities
need exact SHA-256s. Gates use positive integer model-file byte observations,
with exact threshold arithmetic; missing observations stay pending and conflicts
fail. Download bytes, filesystem allocation, runtime memory and assembled bundle
bytes are separate quantities. A size pass never approves quality or a default.

## Corpus and source preparation

Use the existing nine-language versioned corpus contract. Prior research held-out
sets are consumed evidence and cannot become a fresh blind test. New sources must
exclude prior source/audio/reference identities and retain original bytes, timing,
attribution, permitted-use evidence and known speaker/session grouping.

`scripts/quality/prepare-video-cases.py` takes a source plan and prepares public
video **audio only**, raw same-language manual VTT tracks when available, metadata
and derived mono PCM views in a new protected external directory. It uses no
cookies, upload, ASR or reference correction. It disables downloader config and
plugins, bounds source count, duration, output, rates, helper time/logs and total
time, and responds to `cancel.request`. Partial/error evidence is retained.
Run it with `scripts/work-artifacts.py`; do not run conversion concurrently with
resource comparisons. Its retained-output limit is not a measured network budget.

```json
{
  "schema_version": "1.0",
  "cases": [{
    "id": "example-development",
    "url": "https://www.youtube.com/watch?v=T492BPuRd-M",
    "language": "de-CH",
    "subtitle_language": "de",
    "split": "development",
    "start_seconds": 30,
    "duration_seconds": 60
  }]
}
```

Subtitles remain provisional. Manual upload does not establish correct wording,
timing or audible language; automatic/translated tracks are not human references.
If only burned-in subtitles exist, the audio package has a missing reference.
Keep original cues unchanged. A reviewer derives a separate, versioned aligned
reference, checks clip boundaries and critical content, and records actual review
attribution. Never turn Whisper output into the reference it is scored against.
Public availability alone does not establish redistribution rights; media remains
external and permitted-use review remains explicit.

Use natural street/noisy/quiet/long-form sources alongside clean speech. Separate
synthetic attenuation/pauses from natural-condition claims; the existing
`derive-sensitivity.py` retains parent groups and provenance for those diagnostic
conditions. Derivatives and repeat runs never add independent speakers. Videos
from one channel may share speakers; distinct video IDs alone do not prove
speaker/session separation. Unknown groups stay unknown. Mono mixes do not test
independent final-channel behavior.

Swiss speech targets faithful written Standard German, with dialect spelling
separate. Declare actual regional varieties and scripts: an Arabic street clip
does not establish MSA, a Taiwan clip does not establish Simplified references,
and Brazilian Portuguese does not cover European Portuguese. Do not infer audible
variety or script from a search query or downloader language tag.

The reporter's `corpus_preparation` inventories declared cases, scripts, varieties,
conditions, review/group gaps and missing priority-language splits. It reads no
audio/reference text and grants no eligibility. Native `CorpusManifest` remains
the validation/eligibility authority; reviewed-v2 approval remains pending where
actual review or evidence is missing.

## Measurements and decision

The existing matrix runner also accepts explicit
`"measurement_scope": "resources_only"` for recordings whose references are not
ready. This mode validates actual audio hashes/layout/duration/channel and retains
the real native job, commands, raw output, timing and source hashes. It does not
read references, produce WER/CER/false-speech scores, approve a v2 corpus or count
language-ID accuracy. Reports mark quality unmeasured. The default remains
`quality_and_resources` with its existing reference/eligibility checks. Unknown
scope values fail; resource-only results cannot satisfy quality acceptance.

Use this to characterize runtime costs while subtitle review is pending. Source
language tags obtained from search are planning labels until actual audio review;
they are not demonstrated language coverage. Keep performance-only panels separate
from any subsequent scored evaluation and preserve all raw transcripts privately.

1. Retain tiny/base/small/turbo/full-large untouched controls and run static/hash
   and native compatibility checks on the compressed candidates.
2. Establish development baselines and review eligibility before selecting quality
   or runtime budgets. Measure known and automatic modes separately. Report paired
   per-language WER/CER and edit counts, Chinese CER, critical content, language
   uncertainty/switches, omissions and invented speech. Swiss rendering retains a
   non-regression gate without dominating product optimization.
3. Run one job at a time, with fresh native idle/live-off admission, the existing
   recording-priority guard, a fixed thread budget and cancellation. Record stable
   hardware/software, power/thermal state, workload, model/binary/profile/scoring
   identities and at least three repeats for the timing/stability panel. Record
   complete end-to-end wall time/RTF, native timers and observed process RSS. First
   result, full initialization and unified CPU/GPU memory remain unmeasured unless
   an actual instrument observes them. Do not infer them from file savings or RSS.
4. Freeze eligible candidates, hashes, settings, review status, minimum coverage,
   per-language quality/non-inferiority and runtime budgets **before** opening fresh
   held-out outcomes. Report uncertainty using independent source/speaker units;
   repeated inference does not increase the quality sample.
5. Run the frozen held-out comparisons. Report file-size pass/fail, quality and
   resource decisions independently. Any failed/missing gate prevents product
   promotion. Packaging/offline/redistribution/rollback review follows under #103.

Original captures, references, manifests, transcripts and failed attempts remain
protected externally. Full CI, mandatory frozen-reference checks and meaningful
focused validation remain required for delivery PRs. No automatic merge.
