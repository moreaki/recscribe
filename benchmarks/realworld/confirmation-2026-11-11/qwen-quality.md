# Descriptive Qwen comparison

Generated solely from qwen-counts.json; all numeric policy is unchanged. Rates are percentages; delta columns are percentage points (pp). Values are rounded to three decimals; JSON retains the underlying numeric values.

These are descriptive source-unit bootstrap comparisons, not a significance, equivalence, compression or adoption gate. Each complete cohort has 16 original sources; 2,000 draws use seed 10410520261110 and the one-sided 95% nearest-rank upper delta. Unknown person/session dependence and reference/source-use review gaps remain.

Italian auto remains 15/16 and has no descriptive metric/interval. Arabic lacks 2 development and 16 held-out sources; full required primary CER/WER macros remain null. Chinese WER is unreported. Resource observations are UNCONTROLLED; no speed/memory acceptance is inferred.

| Language | Mode | Control | Sources | Qwen CER | Control CER | CER delta | Upper CER delta | Qwen WER | Control WER | WER delta | Upper WER delta |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| de-CH | known | large-v3 | 16/16 | 21.998% | 14.950% | 7.049 pp | 10.454 pp | 39.091% | 23.182% | 15.909 pp | 24.786 pp |
| de-CH | auto | large-v3 | 16/16 | 21.534% | 14.950% | 6.584 pp | 9.519 pp | 38.182% | 23.182% | 15.000 pp | 22.791 pp |
| de-CH | known | large-v3-q4_0 | 16/16 | 21.998% | 14.330% | 7.668 pp | 11.604 pp | 39.091% | 22.273% | 16.818 pp | 26.087 pp |
| de-CH | auto | large-v3-q4_0 | 16/16 | 21.534% | 15.414% | 6.119 pp | 9.956 pp | 38.182% | 25.455% | 12.727 pp | 22.318 pp |
| de-CH | known | large-v3-upstream-q5_0 | 16/16 | 21.998% | 14.407% | 7.591 pp | 10.878 pp | 39.091% | 20.909% | 18.182 pp | 26.408 pp |
| de-CH | auto | large-v3-upstream-q5_0 | 16/16 | 21.534% | 15.724% | 5.809 pp | 9.225 pp | 38.182% | 21.818% | 16.364 pp | 24.103 pp |
| de | known | large-v3 | 16/16 | 5.446% | 6.120% | -0.674 pp | 0.214 pp | 10.390% | 10.714% | -0.325 pp | 0.872 pp |
| de | auto | large-v3 | 16/16 | 5.446% | 6.120% | -0.674 pp | 0.213 pp | 10.390% | 10.714% | -0.325 pp | 0.932 pp |
| de | known | large-v3-q4_0 | 16/16 | 5.446% | 5.671% | -0.225 pp | 0.476 pp | 10.390% | 10.390% | 0.000 pp | 1.064 pp |
| de | auto | large-v3-q4_0 | 16/16 | 5.446% | 5.671% | -0.225 pp | 0.446 pp | 10.390% | 10.390% | 0.000 pp | 1.031 pp |
| de | known | large-v3-upstream-q5_0 | 16/16 | 5.446% | 5.727% | -0.281 pp | 0.874 pp | 10.390% | 10.065% | 0.325 pp | 1.987 pp |
| de | auto | large-v3-upstream-q5_0 | 16/16 | 5.446% | 5.727% | -0.281 pp | 0.917 pp | 10.390% | 10.065% | 0.325 pp | 2.006 pp |
| fr | known | large-v3 | 16/16 | 10.081% | 9.829% | 0.252 pp | 0.909 pp | 14.489% | 14.964% | -0.475 pp | 0.656 pp |
| fr | auto | large-v3 | 16/16 | 10.081% | 9.829% | 0.252 pp | 0.891 pp | 14.489% | 14.964% | -0.475 pp | 0.637 pp |
| fr | known | large-v3-q4_0 | 16/16 | 10.081% | 9.829% | 0.252 pp | 0.866 pp | 14.489% | 14.964% | -0.475 pp | 0.691 pp |
| fr | auto | large-v3-q4_0 | 16/16 | 10.081% | 9.829% | 0.252 pp | 0.864 pp | 14.489% | 14.964% | -0.475 pp | 0.711 pp |
| fr | known | large-v3-upstream-q5_0 | 16/16 | 10.081% | 9.879% | 0.202 pp | 0.847 pp | 14.489% | 15.202% | -0.713 pp | 0.633 pp |
| fr | auto | large-v3-upstream-q5_0 | 16/16 | 10.081% | 9.879% | 0.202 pp | 0.847 pp | 14.489% | 15.202% | -0.713 pp | 0.633 pp |
| it | known | large-v3 | 16/16 | 22.098% | 20.740% | 1.358 pp | 3.644 pp | 28.442% | 26.087% | 2.355 pp | 4.216 pp |
| it | auto | large-v3 | 15/16 | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported |
| it | known | large-v3-q4_0 | 16/16 | 22.098% | 20.808% | 1.290 pp | 3.719 pp | 28.442% | 26.268% | 2.174 pp | 4.069 pp |
| it | auto | large-v3-q4_0 | 15/16 | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported |
| it | known | large-v3-upstream-q5_0 | 16/16 | 22.098% | 20.333% | 1.765 pp | 4.025 pp | 28.442% | 25.906% | 2.536 pp | 4.294 pp |
| it | auto | large-v3-upstream-q5_0 | 15/16 | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported | PENDING/unreported |
| en | known | large-v3 | 16/16 | 3.842% | 4.280% | -0.438 pp | 0.391 pp | 5.647% | 7.059% | -1.412 pp | -0.243 pp |
| en | auto | large-v3 | 16/16 | 3.842% | 4.280% | -0.438 pp | 0.375 pp | 5.647% | 7.059% | -1.412 pp | -0.260 pp |
| en | known | large-v3-q4_0 | 16/16 | 3.842% | 4.280% | -0.438 pp | 0.377 pp | 5.647% | 7.059% | -1.412 pp | -0.253 pp |
| en | auto | large-v3-q4_0 | 16/16 | 3.842% | 4.280% | -0.438 pp | 0.370 pp | 5.647% | 7.059% | -1.412 pp | -0.239 pp |
| en | known | large-v3-upstream-q5_0 | 16/16 | 3.842% | 4.377% | -0.535 pp | 0.291 pp | 5.647% | 7.294% | -1.647 pp | -0.271 pp |
| en | auto | large-v3-upstream-q5_0 | 16/16 | 3.842% | 4.377% | -0.535 pp | 0.333 pp | 5.647% | 7.294% | -1.647 pp | -0.459 pp |
| zh | known | large-v3 | 16/16 | 24.206% | 42.262% | -18.056 pp | -12.849 pp | — (CER only) | — (CER only) | — (CER only) | — (CER only) |
| zh | auto | large-v3 | 16/16 | 24.206% | 42.262% | -18.056 pp | -12.950 pp | — (CER only) | — (CER only) | — (CER only) | — (CER only) |
| zh | known | large-v3-q4_0 | 16/16 | 24.206% | 41.270% | -17.063 pp | -12.316 pp | — (CER only) | — (CER only) | — (CER only) | — (CER only) |
| zh | auto | large-v3-q4_0 | 16/16 | 24.206% | 41.270% | -17.063 pp | -12.500 pp | — (CER only) | — (CER only) | — (CER only) | — (CER only) |
| zh | known | large-v3-upstream-q5_0 | 16/16 | 24.206% | 42.262% | -18.056 pp | -13.181 pp | — (CER only) | — (CER only) | — (CER only) | — (CER only) |
| zh | auto | large-v3-upstream-q5_0 | 16/16 | 24.206% | 42.262% | -18.056 pp | -13.071 pp | — (CER only) | — (CER only) | — (CER only) | — (CER only) |
| es | known | large-v3 | 16/16 | 5.912% | 5.759% | 0.153 pp | 0.744 pp | 9.981% | 9.021% | 0.960 pp | 2.505 pp |
| es | auto | large-v3 | 16/16 | 5.912% | 5.759% | 0.153 pp | 0.762 pp | 9.981% | 9.021% | 0.960 pp | 2.582 pp |
| es | known | large-v3-q4_0 | 16/16 | 5.912% | 5.721% | 0.191 pp | 0.816 pp | 9.981% | 8.445% | 1.536 pp | 3.309 pp |
| es | auto | large-v3-q4_0 | 16/16 | 5.912% | 5.721% | 0.191 pp | 0.796 pp | 9.981% | 8.445% | 1.536 pp | 3.189 pp |
| es | known | large-v3-upstream-q5_0 | 16/16 | 5.912% | 5.721% | 0.191 pp | 0.739 pp | 9.981% | 8.829% | 1.152 pp | 2.609 pp |
| es | auto | large-v3-upstream-q5_0 | 16/16 | 5.912% | 5.721% | 0.191 pp | 0.787 pp | 9.981% | 8.829% | 1.152 pp | 2.660 pp |
| pt | known | large-v3 | 16/16 | 10.794% | 15.522% | -4.728 pp | -1.843 pp | 20.956% | 25.368% | -4.412 pp | 0.395 pp |
| pt | auto | large-v3 | 16/16 | 10.794% | 15.522% | -4.728 pp | -1.716 pp | 20.956% | 25.368% | -4.412 pp | 0.778 pp |
| pt | known | large-v3-q4_0 | 16/16 | 10.794% | 14.719% | -3.925 pp | -0.860 pp | 20.956% | 25.000% | -4.044 pp | 0.323 pp |
| pt | auto | large-v3-q4_0 | 16/16 | 10.794% | 14.719% | -3.925 pp | -0.748 pp | 20.956% | 25.000% | -4.044 pp | 0.676 pp |
| pt | known | large-v3-upstream-q5_0 | 16/16 | 10.794% | 15.165% | -4.371 pp | -1.438 pp | 20.956% | 25.000% | -4.044 pp | 0.481 pp |
| pt | auto | large-v3-upstream-q5_0 | 16/16 | 10.794% | 15.165% | -4.371 pp | -1.344 pp | 20.956% | 25.000% | -4.044 pp | 0.873 pp |

Input/report provenance is recorded in qwen-counts.json and evidence-index.json. The original `input.original.json` remains under `analysis/qwen-descriptive-real-v1` in the protected campaign root. Original source hashes, case IDs, declared source groups, missing first identities and the root collection receipt pin remain preserved. No re-scoring, inference, thresholds or primary macros were added.

Descriptive JSON SHA-256: `42527303b3fbbfcdecc2007a5cc172cd52c82cf39abe4c03bf8977c0e5804185`
