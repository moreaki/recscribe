# Fresh real-world ASR confirmation — 11 November 2026

Whisper large-v3 Q4_0 achieves the requested large storage reduction: its file is **71.27% smaller** than unchanged F16. Known-language mode meets all eight available exploratory language bounds. Automatic mode retains failed Swiss CER/WER and Portuguese CER bounds; Arabic quality and full primary macros remain pending. Q5_0 saves 65.07% but retains Chinese CER failures in both modes and Swiss CER failure in auto. Neither artifact is approved as a multilingual default.

The separate Qwen3-ASR-1.7B-8bit comparison shows substantial Mandarin and Portuguese lexical gains, with Swiss and Italian losses. Its weight file saves only about 20.4% versus Whisper F16, below the 30% storage goal. Qwen is a separately trained architecture and MLX runtime comparator; this file difference does not measure a Whisper compression effect. Language-specific investigation remains useful; the evidence supports no general replacement or AI weight-space-programming gain.

| Artifact | Recorded weight-file bytes | Saving versus F16 |
|---|---:|---:|
| Whisper large-v3 F16 |3,095,033,483|0%|
| Whisper large-v3 Q4_0 |889,340,843|71.27%|
| Upstream large-v3 Q5_0 |1,081,140,203|65.07%|
| Qwen3-ASR-1.7B-8bit |2,463,307,541|about 20.4%|

Qwen's model-directory inventory totals 2,467,862,900 bytes; its separate runtime inventory totals 588,963,174 bytes. These do not establish shipping-package sizes. Q4 retains the unchanged F16 parent. Q5's actual upstream parent/export settings are unknown, despite its hosted F16 matching the baseline. File reduction does not establish fewer parameters.

Qwen is pinned to mlx-community/Qwen3-ASR-1.7B-8bit revision a8379a2e2f9e313c9292cdf1af4055ab56d50d55; recorded weight SHA-256 bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c. No large artifact was rehashed for this draft.

## Language-specific quality

The table copies Qwen-minus-F16 point deltas from sealed descriptive JSON: percentage points (pp), with positive meaning more lexical errors. Complete cells have 16 original sources; no formal adoption/equivalence gate is inferred. Full counts and paired upper bounds remain in the [Qwen tables](<realworld/confirmation-2026-11-11/qwen-quality.md>) and [Whisper tables](<realworld/confirmation-2026-11-11/whisper-quality.md>).

| Language | Known CER / WER Δ pp | Auto CER / WER Δ pp |
|---|---:|---:|
| Swiss German → written Standard German |+7.049 / +15.909|+6.584 / +15.000|
| German |−0.674 / −0.325|−0.674 / −0.325|
| French |+0.252 / −0.475|+0.252 / −0.475|
| Italian |+1.358 / +2.355|Pending 15/16; no metric|
| English |−0.438 / −1.412|−0.438 / −1.412|
| Arabic |Pending 0/16|Pending 0/16|
| Mandarin / Simplified |−18.056 / — (CER only)|−18.056 / — (CER only)|
| Spanish |+0.153 / +0.960|+0.153 / +0.960|
| Portuguese |−4.728 / −4.412|−4.728 / −4.412|

Mandarin CER moves from 42.262% to 24.206%, Portuguese CER from 15.522% to 10.794%, and English WER from 7.059% to 5.647%. Swiss known-mode CER moves from 14.950% to 21.998%; Italian from 20.740% to 22.098%. Native-language semantic/critical-content review remains pending.

Whisper's Portuguese Q4 auto bound remains failed although its point improves; identical per-source counts/hypothesis hashes across modes show that the different upper bounds arise from the frozen mode-specific resampling streams. No seed or gate was changed. Swiss runtime base-language labels are metadata, not proof of dialect fidelity or the sole cause of errors.

## Coverage and preserved first outcomes

The corpus has 16 development/128 held-out/9 reference-free resource sources against unchanged requirements 18/144/9. Swiss material is Bern parliamentary speech rendered into written Standard German; dialect spelling is not required. German/French/Italian/English/Spanish cover a European parliamentary slice in Latin script; individual accents and wider regions remain unreviewed. Portuguese is the CORAA Brazilian slice. Chinese is AISHELL-4 Mandarin meeting speech with Simplified references; Traditional Chinese and other varieties remain pending. Arabic's Egyptian Casablanca originals have differing stereo channels and unproved reference/channel applicability: quality remains absent; its resource case uses channel 0 without mixing or a channel-quality claim.

Publisher/source groups are retained; person/session independence is unestablished. Human reference/source-use review, difficult acoustics, long sessions, language switches, live fallback and independent-channel quality remain pending. Tasks are transcription/Standard German rendering; translation is unassessed.

All 867 Whisper calls completed: 3 warmups, 96 development, 768 held-out. Qwen collection scored 255 first held-out transcripts against 768 native-control rows for 765 comparisons. Italian auto cell 160 stopped and remains missing. Only original unstarted cells 161–288 received a separately sealed first attempt; all 128 completed. No warmup/failed first was repeated. Italian auto has no descriptive metric/interval, Arabic has 0/16, and full primary macros remain null.

## Resources, reproducibility and local status

Controlled latency/memory findings remain **pending**. Quality timings/RSS were UNCONTROLLED under the separate 1000% CPU guard and support no efficiency comparison. Host: M2 Ultra, 24 CPU/60 GPU cores, 64 GiB, macOS 26.6.2. Original audio/references, raw transcripts, source timing and first guards remain protected. Whisper's incomplete pre-execution library coverage remains unestablished; later hashes do not repair its freeze.

The subsequent strict-50 resource attempts preserve two distinct cancellations. Plan `6bda5d5d…` stopped after 3.477 seconds on `fileproviderd` at 50.9% CPU, before a native coordinator launched. Independently frozen plan `e8a65bf9…` stopped after 6.146 seconds on `mds_stores` at 68.5% CPU, after its first coordinator launched but before a model cell was reached. Both owned sessions were reaped. The second audit finds no matrix, checkpoint or cell directory and excludes the consumed coordinator block from continuation. Neither attempt produced controlled ASR timing or memory measurements. Their one-use claims, deadlines, raw logs and failed/partial outputs remain intact.

Maintenance removed the frozen ggml/libomp installation. Private recovery matched all nine missing files to the original size/SHA targets; eleven still-present retained files were copied exactly. Actual model-free loader/backend validation passed using a separately hashed launcher and the unchanged real CLI. It does not pass resource acceptance or repair the earlier quality freeze. No global library link or installed app was changed.

The runner now supports an optional SHA-bound static host snapshot to avoid repeating `system_profiler`, static power-policy and toolchain discovery before every microblock. Cached use still verifies the same host, retains raw evidence and collects fresh thermal/power observations; ASR timing scope and recording-priority controls are unchanged. Implementation validation is tracked in #136.

On 12 November, nine new fixed 120–132-second excerpts from the retained YouTube sources were prepared: exact 192,000-frame mono 16 kHz PCM16, physical channel 0 without mixing. Original hashes/stat identities matched before and after; output hashes are distinct from prior prepared views. The sources themselves are reused development groups, with at least 30 seconds separating these excerpts from prior 30–90-second views. They do not establish independent speakers or new source groups. The bounded guard completed in 5.719 seconds with all workers reaped. The new protected `quantized-resource-hostsnapshot-20261112-v1.noindex` campaign retains selected corpus revision SHA `e1aa841ec5d214b41ba3441e4e9f75512b0b0197caa35e82a408912b1769c57c` and wording-only derivation receipt SHA `7b0fea9fb24c8676e38e8292cbc154ad180be95e9b89882d64b6dc065791e25b`; the original manifest/handoff remain preserved. These reference-free inputs prepare a separately frozen resource panel. Source-use, audible language/region, speaker and reference approval remain pending. No model inference or improvement is implied by this preparation.

Resource RSS is the maximum resident-set high-water reported by `/usr/bin/time -l` around the retained transcription executable, including waited-child accounting. It is not simultaneous summed process memory or total unified GPU allocation. Complete initialization, first-result latency, unified GPU allocation, energy and shipping-package increments remain unmeasured.

The host-snapshot change passed the complete 146-test native/core suite, including mandatory frozen references and nine new host-evidence contracts, plus source-boundary and 20,000-buffer PCM ownership checks. No reference fixture was rebaselined. Current-head full functional/Thread Sanitizer/Release CI remains required and is tracked in #136; earlier green heads do not validate this change.

Execution source b5442c9 and the prior PR head acf16ab are preserved as codex/realworld-execution-frozen-b5442c9 and codex/quantized-main-sync-frozen-acf16ab. The integration stack was subsequently rebased onto main 1c43574; the four upstream files added since execution do not alter retained model, scorer or controller bytes. Current PR heads and their fresh CI results are tracked in [#125](https://github.com/moreaki/recscribe/pull/125) and [#136](https://github.com/moreaki/recscribe/pull/136). Older green checks do not validate rewritten heads. Models, original audio/references and raw transcripts remain local; no model publication, merge or product default changed.

## Source identities

All paths below are within the protected campaign root. This draft reads small derived metadata only; it performs no inference, scoring, interval recomputation or transcript/reference word inspection.

| Source | SHA-256 |
|---|---|
| Native report-v2.md |9236d63816576cf42bda692a3f7618056d953d9284a5cecf8a04aaa1a9f2b479|
| Native native-counts.json |0918a50dad957c5af2568140d75cc27e0d277d5aa70533b88f60e451d13acea1|
| Qwen report-v2.md |7ecd5292fd215b77d2afae38c9576895c3cbb24fa77dd3b53d8effaa72fec4f3|
| Qwen descriptive-report.json |42527303b3fbbfcdecc2007a5cc172cd52c82cf39abe4c03bf8977c0e5804185|
| Independent Qwen facts.json |0d69d26c396c1f69c0bc0b1cc81157b3aad313ec4f594c1328f5ee48c2ab5618|
| Root Qwen collection receipt |5ed7931ce8daff9b681b63d10eed406470da5c42efd5e27c826fc35d1023b03d|
| Qwen model inventory |e428bc679697673280baab352f70ba2c0464ec5b2d2ead311793ca75cbbd52f9|
| Qwen inventory/runtime receipt |95f4f05d120c34c4ea80a9733d7152f8eff54ab139ad37c3636ff6cfb800142e|
| analysis/pre-native-resource-cancellation-v1/receipt.json |1cbe854ac9e4b71379a7287c8c636a18d5ae66a0766d8f520c9bbca0d2292968|
| analysis/resource-fresh-cancellation-audit-v1/attempt-v2/receipt.json |701c4e098d2047d01063d4e8b48ccc5c826694b342bf05446789a4adf259c58b|
| analysis/recovered-runtime-independent-v1/receipt.json |62e1bb5b7c06f77bac044bee0e52ace01915ea6009f868788dbc4df99978bc09|
| runtime-portable-preparation-v1/loader-validation-v3.json |f3ca92c8969c5ae8bead3812674f5af2dbe1daaf9413f5daa9fb0e7c910f653a|

Exact protected quality paths and verified byte lengths are recorded in [evidence-index.json](realworld/confirmation-2026-11-11/evidence-index.json), under `protected_source_inputs`. The four resource receipt paths above are relative to that same protected campaign root and were independently rehashed for this update. Scoring remains swift-nfc-casefold-alphanumeric-v1; frozen 2,000-draw, one-sided 95% source-unit bounds and required gaps are unchanged.
