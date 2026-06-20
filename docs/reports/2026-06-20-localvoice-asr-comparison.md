# LocalVoice ASR Comparison

- Date: 2026-06-20
- Corpus: `benchmark-data/local-smoke/smoke.jsonl`
- Samples: 5 synthetic macOS `say` clips, zh-CN voice, focused on Mandarin plus English product/API terms
- Local baseline: Apple Speech, on-device `zh-CN`
- Cloud candidate: OpenRouter `openai/gpt-4o-mini-transcribe`
- Post-processing: unchanged, Apple Foundation Models

| Metric | Apple Speech | OpenRouter |
|---|---:|---:|
| Recognized | 5/5 | 5/5 |
| CER | 0.21 | 0.07 |
| WER | 1.54 | 0.77 |
| RTFx | 0.07 | 0.24 |
| LLM from ASR pass rate | 0/5 | 3/5 |
| Oracle LLM pass rate | 4/5 | 4/5 |

## Readout

- OpenRouter cut character error rate by about 68% on this smoke set.
- OpenRouter preserved the critical English terms: `LocalVoice`, `OpenRouter API`, `Whisper Backend`, `Final Transcription`.
- Apple Speech turned those into `look for the Open Rode API`, `Vesper back in the final Transcription`, and `bench Mark`.
- OpenRouter was slower in raw recognition: RTFx `0.24` vs Apple `0.07`.
- The latency trade is acceptable for final-quality dictation; live partials should stay conservative to avoid repeated cloud billing.
- This is a smoke benchmark, not a production corpus. Real user audio should decide the final default.

## Artifacts

- Apple report: `docs/reports/2026-06-20-localvoice-apple-speech-benchmark.md`
- OpenRouter report: `docs/reports/2026-06-20-localvoice-openrouter-benchmark.md`
- Apple JSON: `benchmark-results/2026-06-20-apple-speech.json`
- OpenRouter JSON: `benchmark-results/2026-06-20-openrouter.json`
