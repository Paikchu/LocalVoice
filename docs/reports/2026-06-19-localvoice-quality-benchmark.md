# LocalVoice Quality Benchmark Report

- Commit: `99b0efa`
- macOS: Version 26.5.1 (Build 25F80)
- Chip: Apple M5
- Memory: 24.00 GB
- Model: `Foundation Models`
- Model revision: `system`
- Model load: 0.00s
- Model error: none
- Speech authorization: authorized
- Source: `PolyAI/minds14 zh-CN train`
- Source license: `CC-BY-4.0`
- Samples: 15

## ASR Raw

| Metric | Result |
|---|---:|
| Recognized | 15/15 |
| CER | 0.08 |
| WER | 1.63 |
| RTFx | 0.03 |
| Empty-reference hallucinations | 0 |

## LLM Processing

| Path | Pass rate |
|---|---:|
| LLM from ASR | 26.67% (4/15) |
| LLM oracle from reference | 53.33% (8/15) |

## Failure Cases

- `minds14-zh_cn-0001`: recognition=`ok`, fromASR=false, oracle=true, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0002`: recognition=`ok`, fromASR=false, oracle=false, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0003`: recognition=`ok`, fromASR=false, oracle=true, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0004`: recognition=`ok`, fromASR=false, oracle=false, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0005`: recognition=`ok`, fromASR=true, oracle=false, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0006`: recognition=`ok`, fromASR=false, oracle=true, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0007`: recognition=`ok`, fromASR=false, oracle=false, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0009`: recognition=`ok`, fromASR=false, oracle=false, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0010`: recognition=`ok`, fromASR=false, oracle=false, llmError=none, missing=Show,me,my, forbidden=
- `minds14-zh_cn-0011`: recognition=`ok`, fromASR=false, oracle=false, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0012`: recognition=`ok`, fromASR=false, oracle=true, llmError=none, missing=, forbidden=
- `minds14-zh_cn-0014`: recognition=`ok`, fromASR=false, oracle=true, llmError=none, missing=, forbidden=