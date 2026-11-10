# Round 5 archive: replay prerequisites and limits

Draft for the final archive README. This is a source/metadata reconstruction
guide, not an instruction to start inference. Evaluation and publication status
must be filled from the final audited evidence separately.

## What the archive provides

The approved 107-file archive contains exact inspection copies of frozen Python
programs, protocol, configurations, 15 assessment preplans, source snapshots,
runtime/profile metadata and selected validation/provenance JSON. Preserve its
`round-5/` layout, particularly `quality/scripts/quality/` and the generation
source tree. The manifest maps each copy to its original absolute path, SHA-256
and phase. Copies were not the executing versions. The outer admission verifier
archive is explicitly post-launch; it is not a retrospective prospective freeze.

Only the separately approved final numeric export addendum will contain actual
benchmark aggregates. Synthetic fixture receipts describe invented test data,
not speech results. CSVs are not part of the 107-file source selection.

This is **not a standalone portable replay package**. Do not launch controllers
from the checkout. Historical seals contain protected absolute paths and existing
exclusive output locations. Replacing those paths, binaries or hashes requires
a new external reproduction record; it does not reproduce the original receipt.

## Inputs retained outside the archive

The companion `replay-prerequisites-v1.json` records exact pins and original
locations without reading or redistributing their payloads:

- Eleven GGML model artifacts: five original multilingual models plus Small/Turbo
  permuted-F16, ordinary-Q4 and permuted-Q4 arms. Original models are under
  RecScribe's external `Models` directories; derived weights are under protected
  `Research/112/round-5/artifacts`. Obtain matching originals separately and
  verify hashes. The deterministic export recipe is not a bundled model.
- The actual comparison CLI is source revision `a55b9ef1c3a5ab4ede43659e8c35c89001d0fc0f`,
  binary SHA `5190e4d3849b8f5aa37ef7031d9557d6ebd17866c798b9c6412cba64b587c1c4`.
  The unchanged control is revision `c214a8ed03f972a5a9cab64105145a67371b97b4`,
  binary SHA `9788fa4e7e3af5ff802ba788f830bc1ebfc6da3b371ae685bc9bce10af7140d6`.
  Scientific tool sources are from `e03c5caa9d428c4b0964a6aedcfe167aa68bc76a`.
  Rebuilding a commit does not guarantee the recorded executable bytes.
- Official whisper.cpp 1.9.5 CLI/quantizer, all eleven native file pins and their
  ggml 0.27.0/libomp 23.1.4 dependencies remain external. Native-load source
  witnesses also require the retained round-3 upstream source tree at
  `d1be6fde11ac6e0407606b4e42fe72d34add8037`.
- Corpus manifests, original/prepared audio, references, provenance and retained
  raw transcripts remain in protected `Benchmarks/Corpora` and per-stage matrix
  directories. The nine-source panel and fresh 72/144 manifests have separate
  exact pins. No raw data is implicitly available from public aggregate tables.
  Exact reanalysis also needs the retained journals, matrices, reports,
  assessments, final held-out freezes and closed guards.

Recorded software is Python 3.15.0, NumPy 2.5.4, macOS 26.6.2, Xcode 27.1 and
Swift 6.4 on arm64. Use one numeric worker and the frozen settings/limits. A new
ASR run still needs recording-priority ownership, cancellation, idle admission
and fresh prospective outputs; this archive grants no execution approval.

## Pinned source and new-build entrypoints

The [comparison CLI package](https://github.com/moreaki/recscribe/blob/a55b9ef1c3a5ab4ede43659e8c35c89001d0fc0f/core/Package.swift)
and [retained control package](https://github.com/moreaki/recscribe/blob/c214a8ed03f972a5a9cab64105145a67371b97b4/core/Package.swift)
declare the `recscribe-text` executable with Swift tools 6.2 and macOS 15 minimum.
The repository's CLI build entrypoint is `swift build --package-path core -c release`
from the selected source checkout. Use the managed-job workflow, reuse caches and
keep review products in `Build/Products`; no build is authorized by this guide.
The [pinned whisper.cpp quick start](https://github.com/ggml-org/whisper.cpp/blob/d1be6fde11ac6e0407606b4e42fe72d34add8037/README.md#quick-start)
documents the upstream native build. Those instructions do not recreate the exact
recorded Homebrew binary/library bytes automatically. A new build needs new
hashes and prospective admission, not replacement of historical hashes.

## License, access and dependency boundaries

RecScribe's source revision contains Apache-2.0 `LICENSE`/`NOTICE`; link them from
the final README. That license does not relicense external binaries, models or
datasets. The frozen acquisition metadata records FLEURS as CC BY 4.0 and FHNW's
Swiss release as MIT, with pinned card/release README and attribution retained.
These are recorded upstream labels, not a new redistribution or access grant.
Source availability and third-party terms must be checked independently before
retrieval or redistribution. FHNW's `private` is a source split name, not an
archive permission or a claim that its data is redistributed here.

The selection intentionally excludes `requirements.txt`, Swift sources and
native C++ source files. The dependency inventory supplies their hashes/versions.
The separate replay addendum supplies the receipt-pinned synthetic smoke
factory, base driver and v7 driver plus the exact dependency file. They are
additional inspection sources, not new executing versions. Protected metadata
blueprints and raw fixtures are still not redistributed, so the complete smoke
suite is not promised runnable from the archive alone. The addendum's successful
copy receipt must accompany that supply claim. Public numeric inspection,
protected exact reanalysis and a new experiment remain distinct operations.
