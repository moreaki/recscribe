# Fresh evaluation data acquisition

`scripts/quality/acquire-fresh-slice.py` is the reusable acquisition helper
extracted from the archived research work. It uses the existing public-source
acquirer and standard-library Python; it performs no ASR, training or uploads.
The extraction preserves the tested source bytes and does not regenerate a
historical corpus or change an earlier result.

Prepare a prospective selection record before running it. Supply every consumed
manifest with repeated `--exclude-manifest` arguments, an explicit new
`--corpus-version`, and a new protected output directory outside the checkout and
`Build/Artifacts`. The legacy default version label is retained for compatibility;
use an explicit version for new work.

```sh
python3 scripts/work-artifacts.py run --label fresh-corpus benchmark -- \
  python3 scripts/quality/acquire-fresh-slice.py \
  --exclude-manifest /protected/previous-corpus.json \
  --corpus-version fresh-evaluation-v1 \
  --count 8 --heldout-count 16 \
  --max-network-mib 512 --max-output-mib 512 --timeout-seconds 600 \
  --output /protected/new-corpus
```

The example is a bounded acquisition command, not an instruction to download
data automatically or approve its references. Source attribution/access records
and software identities are retained with the output. Dependency and source
availability must match the pinned acquisition contract.

## Preservation and separation

- Prior and newly accepted source IDs, original/prepared audio hashes, reference
  hashes and known speaker/session IDs exclude duplicates across the new splits.
  Unknown identities stay unknown and do not establish speaker independence.
- Original source audio and published references are retained byte-for-byte.
  Preparation verifies mono source headers and records source frames, sample
  rate, channel identity, conversion and resampling duration evidence. Sources
  are not mixed.
- Development and held-out selection use separate declared source splits and
  counts. The source split called `private` is a dataset split name, not a new
  redistribution or access grant. Held-out reference text is not displayed.
- Network/output bytes, archive streams, conversion and elapsed time are bounded.
  Cancellation and a reached budget retain partial input and acquisition records
  and exit nonzero; they do not reduce the requested counts or grow the budget.

The selected public read speech covers de_DE, fr_FR, it_IT, en_US, ar_EG,
cmn_hans_CN, es_419 and pt_BR, plus Swiss speech with published written Standard
German references. Swiss dialect wording is a separate reference task. These
locale/script labels do not establish all regional, dialect or script coverage.
The helper does not grant human/native-speaker approval or reviewed-v2 scoring
eligibility. Natural/adverse/long-form/switch/independent-channel coverage and
missing cases remain pending.

The checked-in acquisition tests use synthetic containers and mocked network or
conversion operations. They protect exclusion, preservation and budget behavior;
they neither download a corpus nor produce recognition scores.
