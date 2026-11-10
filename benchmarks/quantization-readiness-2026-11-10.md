# Quantization readiness — 10 November 2026

Ordinary quantization clears the requested **30% same-model file-size gate** for
Small, large-v3-turbo and full large-v3. Quality preservation, native load
compatibility, latency and memory acceptance remain **pending**. This is a
feasibility result, not a recommendation to change a shipped model or default.

| Model | Original F16 bytes | Q5_1 bytes | Reduction | Q4_0 bytes | Reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| Small | 487,601,967 | 190,085,487 | 61.02% | 145,458,015 | 70.17% |
| large-v3-turbo | 1,624,555,275 | 624,065,675 | 61.59% | 473,992,235 | 70.82% |
| large-v3 | 3,095,033,483 | 1,177,039,883 | 61.97% | 889,340,843 | 71.27% |

The [machine-readable evidence](quantization-readiness-2026-11-10.json) contains
exact hashes, parent lineage, all five unchanged multilingual F16 controls,
measured file lengths and six separate threshold decisions. Every artifact was
stream-hashed and checked for identity changes during the audit. Architecture
headers match their respective parents; that check does not prove tensor validity
or native compatibility. The quantizer was whisper.cpp 1.9.5, binary SHA-256
`2efffddc246a52e7ba9a81145926d07e7f1c5fc7ba56a95586602a12ec5e00bd`.

Small/Turbo Q4 artifacts are reused read-only from the retained round-5 ordinary
compression controls. Q5 artifacts and full large-v3 Q4 were exported into new
protected locations. Original F16 files were hashed before/after export. The
interrupted first full-large Q5 export and all failed/deferred attempts remain
retained separately. Fixed Q4/Q5 recipes were not changed in response to outcomes.
Export wall times are not inference performance evidence. Background CPU limits
were explicitly amended for deterministic file export only; timed ASR retains
the stricter quiet-host and recording-priority admission policy.

## Corpus preparation

The source plan attempted two public YouTube sources per requested language:
Swiss German, German, French, Italian, English, Arabic, Chinese, Spanish and
Portuguese. Seventeen audio-only originals and seventeen 60-second mono views
were prepared. The Swiss held-out source exceeded the 1,200-second source bound
and was rejected. Nine sources are marked development and eight held-out;
these partition labels do not establish independent speakers or sessions.

No selected source exposed a downloadable manual same-language VTT track.
Automatic captions were not accepted as references; burned-in subtitles were
not converted into gold text. **Zero references are approved**, and no scored
quality evaluation has been performed. Original audio, metadata, logs, source
intervals and hashes remain protected externally. A subsequent preservation
audit rechecked all 121 retained source-package files unchanged. Its source
preparation receipt SHA-256 is
`562e0462a949b4c99650aa233a818987b20f6b00fc8719db00393ba16c9402a6`.
Those packages used preparer v1; the subsequent v1.1 helper adds continuous
recording-priority checks and verified descendant cleanup. It was validated
offline, without rewriting the retained v1 source packages.

Eighteen development derivatives add exact 1/8 attenuation and 30-second digital
silence prefixes. These share their parents' source groups. They do not provide
natural adverse-condition coverage or additional independent speakers. The new
deterministic white-noise primitive records achieved SNR and clipping; generating
additional real-source noisy views is separate from this source-package receipt.

Actual language, regional variety, script, word boundaries, subtitle correctness,
code switches and permitted-use review remain unadjudicated. Planning tags from
search cannot establish coverage of Arabic dialects/MSA, Chinese scripts/regions,
Brazilian/European Portuguese or any other regional distinction. Swiss speech
targets written Standard German, with optional dialect spelling kept separate.
The consented recording and review checklist is tracked in #122 and
[real-world-recording-scenarios.md](real-world-recording-scenarios.md).

## Validation and remaining gates

Local compatibility validation used Xcode 27.1 / Swift 6.4. The repository's
pinned Xcode 27.2 hosted validation remains required.

- Full native suite: **92 tests in 16 suites passed**, including mandatory frozen
  reference contracts and a non-silent resource-only matrix using a synthetic
  ASR helper. This tests orchestration, not real-model compatibility or accuracy.
- Offline script suite: **153 tests passed**, including source preparation,
  cancellation/owned-helper cleanup, scoring separation and exact size gates.
- Source-boundary self-test and repository check passed; the PCM ownership probe
  processed 20,000 buffers with zero owner overlap or corruption. This probe is
  not a full app Thread Sanitizer pass.
- Release build, native real-model probes, controlled three-repeat resource
  comparisons, reviewed nine-language quality evaluation and full hosted
  functional/Thread Sanitizer checks are tracked separately as pending until
  actual evidence is retained.

The existing runner's explicit `resources_only` mode permits resource work before
references are ready. It retains raw transcripts and timing without reading or
scoring references; exact output-hash agreement cannot prove accuracy. Fresh
held-out quality remains unopened until reviewed references, independence and
prospective quality/runtime budgets satisfy the freeze contract. No model is
promoted from a file-size result.
