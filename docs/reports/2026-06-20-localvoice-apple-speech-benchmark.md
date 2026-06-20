# LocalVoice Quality Benchmark Report

- Commit: `260b144`
- macOS: Version 26.5.1 (Build 25F80)
- Chip: Apple M5
- Memory: 24.00 GB
- Model: `Foundation Models`
- Model revision: `system`
- Model load: 0.00s
- Model error: none
- Speech provider: Apple Speech
- Speech authorization: authorized
- Source: `macOS say Tingting synthetic local-smoke`
- Source license: `local generated`
- Samples: 5

## ASR Raw

| Metric | Result |
|---|---:|
| Recognized | 5/5 |
| CER | 0.21 |
| WER | 1.54 |
| RTFx | 0.07 |
| Empty-reference hallucinations | 0 |

## LLM Processing

| Path | Pass rate |
|---|---:|
| LLM from ASR | 0.00% (0/5) |
| LLM oracle from reference | 80.00% (4/5) |

## Failure Cases

- `local-zh-001`: recognition=`ok`, fromASR=false, oracle=true, llmError=none, missing=, forbidden=
- `local-zh-002`: recognition=`ok`, fromASR=false, oracle=true, llmError=none, missing=, forbidden=
- `local-mixed-001`: recognition=`ok`, fromASR=false, oracle=true, llmError=none, missing=, forbidden=
- `local-mixed-002`: recognition=`ok`, fromASR=false, oracle=true, llmError=none, missing=, forbidden=
- `local-email-001`: recognition=`ok`, fromASR=false, oracle=false, llmError=none, missing=, forbidden=