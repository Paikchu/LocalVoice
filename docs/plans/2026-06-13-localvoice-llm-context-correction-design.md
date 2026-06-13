# LocalVoice 中英夹杂语境纠错（LLM Contextual Correction）实现方案

日期：2026-06-13
状态：设计定稿，待实施
关联文档：`2026-06-13-localvoice-user-profile-design.md`（用户画像方案）

---

## 1. 问题定义与目标

### 1.1 问题

中文模式（zh-CN 设备端识别）下，用户话语中夹杂英文单词时，ASR 经常把英文词
识别成读音相近的另一个词（近音词错误），例如：

| 用户实际说的 | ASR 可能识别成 | 类型 |
|---|---|---|
| 我们今天要 **deploy** 新版本 | 我们今天要 **employ** 新版本 | 英文近音词 |
| 把这个 **branch** merge 进去 | 把这个 **branch march** 进去 | 英文近音词 |
| 用 **Redis** 做缓存 | 用 **ready is** 做缓存 | 词被拆碎 |
| 部署到 **Kubernetes** | 部署到 **酷伯内特斯** | 中文音译（画像方案已覆盖） |

用户画像方案（glossary）能覆盖**高频、可积累**的专有名词，但覆盖不了：

1. 冷启动期（画像还没积累出词条）；
2. 长尾词（一个普通英文动词/名词如 deploy、schema、refactor，永远不会进 glossary——
   画像方案的候选提取明确排除纯小写常用英文词）；
3. 第一次出现的新词。

### 1.2 目标

1. **以 LLM 语境推理为主要纠错手段**：模型读完整句，判断某个英文词在当前语境下
   是否"不通顺、像是近音误识别"，并替换为最贴合语境的词。**不依赖任何术语表也能工作**。
2. **把 ASR 自己的不确定性证据交给模型**：采集识别器的逐段置信度（confidence）与
   n-best 候选转写（alternatives），把"识别器自己也拿不准的片段 + 它的候选写法"
   注入 prompt，让模型在有据可依的候选中选择，而不是凭空猜。
3. **纠错必须可验证、可回滚**：模型显式申报每一处替换（corrections 列表），
   由确定性验证层逐条核查"读音相近性"，不相近的替换被逐条还原。
   保证最坏情况是"没纠"，而不是"改错"。
4. **零新增模型调用、零可感知延迟**：复用现有单次 LLM pass，只增加 prompt 内容
   与输出字段。
5. 与画像方案正交互补：glossary 注入提供领域先验（"优先纠成这些词"），
   本方案提供通用能力（没有先验也能纠）。两者共用同一个 prompt、同一道验证链。

### 1.3 非目标

- 不做第二次 LLM 调用做专门的"纠错 pass"（延迟不可接受，4B 模型一次往返已占
  主路径大头）。
- 不改变现有降级链：模型不可用时行为与现状完全一致。
- 中文→中文的同音字纠错不在本期范围（zh ASR 的中文部分准确率已可接受，
  且中文同音字误改风险远高于英文近音词）。
- 不替换 `SFSpeechRecognizer` 为第三方 ASR（如 Whisper），那是独立立项。

---

## 2. 总体架构

```
SFSpeechRecognizer 最终结果 (isFinal)
        │
        ▼ 新增：不再只取 bestTranscription 的字符串
┌────────────────────────────────────────────┐
│ ① SpeechSignalExtractor（纯函数, Core）      │
│  输入: segments(text, confidence) + n-best  │
│  输出: [SuspectSpan]                        │
│   - 含拉丁字母 且 confidence < 0.45 的片段    │
│   - n-best 各候选在该片段上的不同写法          │
│  上限: 8 个疑点，超出取置信度最低的 8 个        │
└──────────────────┬─────────────────────────┘
                   │ 随 transcript 一起传入处理层
                   ▼
┌────────────────────────────────────────────┐
│ ② PromptBuilder.processingPrompt           │
│  新增「语境纠错规则」（放宽逐字保留）           │
│  新增「低置信片段块」（疑点 + 候选写法）        │
│  新增「术语表块」（画像方案提供, 可为空）       │
│  JSON schema 新增 "corrections" 字段        │
└──────────────────┬─────────────────────────┘
                   ▼ 单次生成（不变）
┌────────────────────────────────────────────┐
│ ③ CorrectionValidator（纯函数, Core）        │
│  对模型申报的每条 {from, to} 逐条核查:        │
│   a. from 必须真实出现在原文中                │
│   b. from 不得命中 hard facts 保护区          │
│   c. from/to 读音相近（音形相似度门槛）        │
│   d. 条数上限 8                              │
│  不合格的纠错 → 在输出文本中逐条还原为 from    │
└──────────────────┬─────────────────────────┘
                   ▼
        现有校验链（facts / preservesInput / 列表结构）→ 格式化 → 插入
```

三个新组件全部是 LocalVoiceCore 内的纯函数/值类型，可独立单测；
app 层只有一个薄适配（从 `SFSpeechRecognitionResult` 抽值类型）。

---

## 3. 详细设计

### 3.1 ① ASR 信号采集：SpeechSignalExtractor

**现状**：[SpeechRecognitionService.swift:51] 只取 `result.bestTranscription.formattedString`，
丢弃了两类对近音纠错最有价值的证据：

- `result.transcriptions: [SFTranscription]` —— n-best 候选转写。近音词错误的典型特征
  是几个候选在**同一位置**给出不同写法（employ / deploy / the ploy）。
- `SFTranscriptionSegment.confidence` —— 逐段置信度（仅 `isFinal` 结果上有效，
  partial 结果恒为 0）。识别器对自己拿不准的英文片段会给出低置信度。

**数据模型（LocalVoiceCore，Codable + Sendable）**：

```swift
public struct TranscriptSegmentInfo: Equatable, Sendable {
    public let text: String
    public let confidence: Double      // 0...1
}

public struct SuspectSpan: Equatable, Sendable {
    public let text: String            // best 转写中的片段原文
    public let confidence: Double
    public let alternatives: [String]  // n-best 在该片段位置的不同写法（去重，≤3）
}

public enum SpeechSignalExtractor {
    public static func suspects(
        best: [TranscriptSegmentInfo],
        alternatives: [[TranscriptSegmentInfo]],   // 其余 n-best 的分段
        confidenceThreshold: Double = 0.45,
        limit: Int = 8
    ) -> [SuspectSpan]
}
```

**提取规则**：

1. 候选条件（满足其一即为疑点）：
   - 片段含拉丁字母 且 `confidence < confidenceThreshold`；
   - 片段含拉丁字母 且 n-best 候选在对应位置（按片段序号对齐，错位时按
     字符区间重叠对齐）给出了**不同的拉丁写法**。
2. 纯中文片段不进疑点（本期不做中文纠错）；URL/邮箱模式（复用 `FactExtractor`
   正则）不进疑点。
3. 超过 `limit` 时按 confidence 升序取前 8 个——置信度最低的最可能是错的。
4. **空信号 = 现状**：识别器没给 n-best、或所有片段置信度正常时返回空数组，
   后续 prompt 与今天完全一致（回归保护的关键性质）。

**app 层适配**（SpeechRecognitionService）：

- 回调签名扩展：`PartialHandler` 改为 `(String, Bool, [SuspectSpan]) -> Void`，
  仅 `isFinal == true` 时计算并传非空疑点（partial 恒传 `[]`，不做任何额外工作，
  partial 路径零开销）。
- 从 `SFSpeechRecognitionResult` 到值类型的映射是 5 行的薄转换，不含逻辑，
  逻辑全部在可单测的 `SpeechSignalExtractor` 里。

**已知限制（设计为可降级）**：设备端 zh-CN 识别返回的 `transcriptions` 数量
不保证（可能只有 1 个），confidence 粒度也因系统版本而异。因此疑点块只是
**增强证据**，不是纠错的前提——见 3.2，模型在没有疑点块时依然被授权做语境纠错。

### 3.2 ② Prompt 改造：语境纠错规则

`PromptBuilder.processingPrompt` 三处改动：

**A. JSON schema 增加 corrections 字段**：

```
{
  "intent": ...,
  "confidence": ...,
  "outputText": "...",
  "corrections": [{"from": "原文中的词", "to": "替换后的词"}],
  "email": ...
}
```

模型每做一处近音替换，必须在 corrections 里申报。这是验证层（3.3）的输入。
`ProcessingResult` 增加 `corrections: [TermCorrection]` 字段，
`decodeIfPresent ?? []` 保持向后兼容（与现有 `missingFields` 的解码风格一致）。

**B. 规则区改写**（替换现行第 641 行附近的"逐字保留"条款）：

```
- URL、邮箱、编号、金额、时间必须逐字保留，一个字符都不能改。
- 中文内容逐字保留含义，不得改写中文用词。
- 原文是中文夹英文的语音转写。句中的英文词可能被识别成读音相近的
  错词。如果某个英文词在当前语境下明显不通顺，请结合整句语义把它
  替换成读音相近、且最符合语境的词；每处替换必须在 corrections 中
  申报 {"from": 原词, "to": 新词}。
- 只在有把握时替换：替换词必须与原词读音相近，不得改成读音无关的词，
  不得增删原文没有的内容。没有把握就保留原词并不申报。
- corrections 最多 8 条。
```

**C. 疑点块注入**（有疑点时追加，放在"用户签名"之前；空疑点时不输出该块）：

```
识别器低置信片段（这些位置最可能是近音误识别；括号内是识别器的
其他候选写法，可作参考但不必采用）：
- "employ"（候选：deploy / the ploy，置信度 0.31）
- "march"（候选：merge，置信度 0.38）
```

**D. 术语表块**（来自画像方案的 `profileHint`，本方案直接复用其注入位，
两块独立、互不依赖）。

**Prompt 体积预算**：规则区 +180 字符（固定）；疑点块每条 ≤ 60 字符、
上限 8 条 ≤ 480 字符。按现有 benchmark 口径，prefill 增量 < 0.2 s。

### 3.3 ③ 确定性验证层：CorrectionValidator

这是本方案的安全核心。glossary 路径的安全性来自"表里的词是用户确认过的"；
本路径没有表，安全性必须来自**对每条替换的机械核查**。

```swift
public struct TermCorrection: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
}

public enum CorrectionValidator {
    /// 返回 (净化后的输出文本, 被接受的纠错, 被还原的纠错)
    public static func apply(
        corrections: [TermCorrection],
        to output: String,
        source: String,
        protectedFacts: [String],
        maxCorrections: Int = 8
    ) -> (text: String, accepted: [TermCorrection], reverted: [TermCorrection])
}
```

**逐条核查规则**（任一不过即"还原"——在 outputText 中把 `to` 按词边界替换回 `from`）：

| # | 规则 | 拦截的风险 |
|---|---|---|
| 1 | `from` 必须在原文 transcript 中真实出现（词边界匹配） | 模型虚构"原词"来夹带新内容 |
| 2 | `from` 不得与任何 hard fact（URL/编号/金额/时间，复用 `FactExtractor`）重叠 | 改坏事实 |
| 3 | `from`/`to` 音形相似度达标（见下） | 改成读音无关的词 = 改写而非纠错 |
| 4 | 总条数 ≤ 8，超出部分整体还原 | 模型大面积重写 |
| 5 | `to` 不得为空、不得含换行、长度 ≤ 40 | 结构破坏 |

**音形相似度（PhoneticSimilarity）**——纯英文词对的判定：

```swift
public enum PhoneticSimilarity {
    public static func isPlausibleCorrection(
        from: String, to: String
    ) -> Bool
}
```

判定为相近，需满足其一：

1. **音键相等**：对两词计算简化音键（辅音骨架法：小写化 → 去元音（保留首字母）
   → 折叠常见等价辅音组 ph→f、ck→k、c→k、qu→k、x→ks、wr→r、kn→n →
   去重相邻重复）。`deploy → dpl`、`employ → mpl` 不等——所以需要规则 2 兜底；
2. **编辑距离门槛**：小写化后 Damerau-Levenshtein 距离 ≤ max(2, ⌊较长词长/3⌋)。
   `deploy/employ` 距离 2 ✅；`deploy/banana` 距离 5 ❌；
3. **多词拆分**：`from` 含空格时（"ready is" → "Redis"），对去空格小写串与 `to`
   计算编辑距离，门槛同上（`readyis/redis` 距离 3，词长 7 → 门槛 max(2,2)=2 ❌；
   放宽为 ⌊len/2⌋ 仅限多词拆分场景 → 3 ✅）。

特殊情形：

- `from` 为纯中文（音译串）：本层**不放行**（中文↔英文的音似判定误判率高），
  这类纠错只在 `to` 命中 glossary 词条时放行——即音译纠写仍走画像方案的
  受信路径，两方案在此处咬合。
- `from` 与 `to` 仅大小写不同：直接放行（无风险）。

**与现有校验链的顺序**：`CorrectionValidator.apply` 在 JSON 解析成功之后、
`ProcessingResultValidator` 的 facts 校验之前执行。这样：

- 被还原的纠错不会导致 facts 校验失败（还原先发生）；
- facts 校验仍以**原文**提取的 requiredFacts 为准，纠错动不了保护区（规则 2
  已先行拦截，双保险）。

`preservesInput`（长度比例）与 `preservesNumberedListStructure` 不受影响：
近音替换是等量级的词替换。

### 3.4 降级与失败行为

| 场景 | 行为 |
|---|---|
| 识别器无 n-best / confidence 全正常 | 疑点块为空，prompt 仅多出固定规则区；模型仍可自主纠错并申报 |
| 模型输出无 corrections 字段 | 解析为 `[]`，输出按现状走（向后兼容） |
| 模型替换了词但没申报 | 现有 facts/长度校验兜底；漏申报的普通词替换无法逐条核查——通过 corpus 的"不虚构"样本约束模型行为（见 §5），并在重试 prompt 中强调申报义务 |
| 全部 corrections 被还原 | 输出 = 模型输出逐条还原后文本，等价于"没纠"，安全 |
| JSON 两次都无效 / 超时 | 现有确定性 fallback，与今天逐字一致 |

---

## 4. 代码改动清单

| 文件 | 改动 |
|---|---|
| `Sources/LocalVoiceCore/SpeechSignals.swift` | **新增**。`TranscriptSegmentInfo`、`SuspectSpan`、`SpeechSignalExtractor`（纯函数） |
| `Sources/LocalVoiceCore/CorrectionValidation.swift` | **新增**。`TermCorrection`、`PhoneticSimilarity`、`CorrectionValidator`（纯函数） |
| `Sources/LocalVoiceCore/DraftProcessing.swift` | `ProcessingResult` 加 `corrections` 字段（兼容解码）；`PromptBuilder.processingPrompt` 加 `suspects: [SuspectSpan]` 参数与规则/疑点块；`retryPrompt` 强调申报义务；`DraftProcessingService.process/processSingle` 接 `suspects`，在 `validated` 前插入 `CorrectionValidator.apply` |
| `Sources/LocalVoiceApp/SpeechRecognitionService.swift` | final 结果上抽 `segments + transcriptions` → 值类型 → `SpeechSignalExtractor`；回调签名扩展 |
| `Sources/LocalVoiceApp/AppModel.swift` | 透传 final 疑点到 `DraftProcessingService.process` |
| `Tests/LocalVoiceCoreTests/SpeechSignalsTests.swift` | **新增**，见 §5.1 |
| `Tests/LocalVoiceCoreTests/CorrectionValidationTests.swift` | **新增**，见 §5.1 |
| `Tests/LocalVoiceCoreTests/DraftProcessingTests.swift` | prompt 回归 + 接线用例 |
| `Tests/Fixtures/processing-quality-corpus.json` | 追加近音纠错样本组，见 §5.2 |
| `Tools/generate_quality_corpus.swift` | 支持样本携带 `suspects` 前置条件 |

**实施顺序**（每步独立提交、可独立验证）：

1. `PhoneticSimilarity` + `CorrectionValidator` + 单测（纯逻辑，无依赖，是安全核心，最先落地）。
2. `ProcessingResult.corrections` 兼容解码 + `PromptBuilder` 规则区/schema 改造 +
   prompt 回归测试（此步完成后模型已可自主纠错，疑点块尚未接入）。
3. `DraftProcessingService` 接 `CorrectionValidator` + corpus 近音样本跑通。
4. `SpeechSignalExtractor` + 单测（纯逻辑）。
5. `SpeechRecognitionService` / `AppModel` 接线，端到端真机验证。

注：步骤 1–3 完成即获得本方案约 70% 的收益（模型自主语境纠错 + 安全验证），
步骤 4–5 是证据增强。若真机发现 zh-CN 设备端识别的 n-best/confidence 信号
质量不可用，可只保留 1–3，方案依然成立。

---

## 5. 测试方案

### 5.1 单元测试（确定性逻辑，要求 100% 通过）

**`CorrectionValidationTests.swift`**

PhoneticSimilarity 判定：

| from | to | 期望 | 验证点 |
|---|---|---|---|
| employ | deploy | ✅ | 编辑距离 2 路径 |
| march | merge | ✅ | 短词门槛 max(2,·) |
| ready is | Redis | ✅ | 多词拆分放宽路径 |
| record | recode | ✅ | 音键路径 |
| deploy | banana | ❌ | 读音无关拒绝 |
| the | deploy | ❌ | 长度悬殊拒绝 |
| Deploy | deploy | ✅ | 仅大小写直接放行 |
| 酷伯内特斯 | Kubernetes | ❌（glossary 未含时） | 中文音译不走本层 |
| 酷伯内特斯 | Kubernetes | ✅（glossary 含 Kubernetes） | 与画像方案咬合点 |

CorrectionValidator 核查与还原：

- `from` 不在原文 → 还原；`from` 在原文但被还原后输出与模型原输出仅差该词 → 还原是定点的，不伤及其他内容。
- `from` 命中 URL（`https://employ.example.com`）→ 还原，URL 逐字保留。
- 9 条 corrections → 全部还原（超上限策略）。
- `to` 含换行 / 为空 → 还原。
- 全部合格 → 输出 = 模型输出原样，`accepted` 全量返回。
- 还原使用词边界匹配：`to = "merge"` 不误伤输出中本来就有的 `"merged"`。

**`SpeechSignalsTests.swift`**

- 低置信英文段（confidence 0.3）入疑点；高置信英文段（0.9）且无候选分歧不入。
- 中文段无论置信度均不入；URL 段不入。
- n-best 在同位置给出不同拉丁写法 → 即使置信度高也入疑点，alternatives 去重 ≤ 3。
- 12 个疑点 → 按置信度升序裁到 8。
- segments 与 n-best 分段数错位时按字符区间重叠对齐，不崩溃、不错配。
- 空输入 → 空输出。

**`DraftProcessingTests.swift` 增量**

- `suspects: []` 且无 profileHint 时，`processingPrompt` 输出与改造前**逐字一致**
  （除固定新增规则区——以 snapshot 断言锁定，防止后续 prompt 漂移）。
- 含 2 个疑点时 prompt 含格式正确的疑点块；疑点 `text` 含特殊字符时正确转义。
- 模型输出含 1 条合格 + 1 条不合格 correction 时：最终文本只保留合格替换，
  `DraftProcessingOutcome` 可观测到 reverted 条目（日志用）。
- 模型输出无 `corrections` 字段 → 解码为 `[]`，全链路行为与现状一致。

### 5.2 质量语料库（corpus 集成测试，模型参与，标记 model-required）

新增样本组 `homophone-correction`（每条样本含 `transcript` 模拟 ASR 错误输出、
可选 `suspects` 前置条件、`semanticGroups` 验收词组）：

**应纠正**（目标：通过率 ≥ 80%，模型层非确定允许阈值）：

1. `今天下午我们要把新版本employ到生产环境`（+疑点 employ→deploy 候选）
   → 输出含 `deploy`、不含 `employ`。
2. `把这个分支march到主干`（+疑点）→ 输出含 `merge`。
3. `缓存层我们用ready is来做` → 输出含 `Redis`（多词拆分 + 无疑点块版本各一条，
   验证模型自主纠错能力）。
4. `帮我把这个PR的reviewer改成小王，然后approve一下`（正确转写）
   → `reviewer`、`approve` 原样保留——**正确的英文不被乱改**。

**不得虚构 / 不得越界**（目标：100% 通过，违例即 bug）：

5. 疑点块含候选 `deploy`，但原文该处实为 `employ a new engineer`（语境下 employ
   正确）→ 输出保留 `employ`，corrections 为空或被还原。
6. 原文含 `https://employ.example.com/jobs` → URL 逐字保留。
7. 原文含产品编号 `MARCH-2048` → 逐字保留，不被"纠"成 MERGE-2048。
8. 现有全部 corpus 样本在 `suspects: []` 下结果**不回归**。

### 5.3 性能基准（复用 `LocalVoiceBenchmark`）

| 项 | 口径 | 标准 |
|---|---|---|
| prefill 增量 | 同一 transcript，空疑点 vs 8 疑点满载对比 | < 0.2 s |
| `SpeechSignalExtractor` | 100 段 × 3 候选 micro-benchmark | < 1 ms |
| `CorrectionValidator` | 8 条 corrections + 2000 字输出 | < 1 ms |
| 端到端 stop→insert | 真机 20 次对比改造前后中位数 | 增量 < 0.3 s |

### 5.4 真机人工验收脚本

固定 20 句中英夹杂测试语料（覆盖：技术动词 deploy/merge/rebase、名词
schema/token/cache、易碎词 Redis/Notion/Figma、正确英文不应被改的对照句），
同一人朗读两遍（改造前 build / 改造后 build），记录：

- 每句的 ASR 原始输出、最终插入文本、corrections 申报与还原日志；
- 统计三个指标（定义见 §6）。

---

## 6. 验收标准

| 指标 | 定义 | 标准 |
|---|---|---|
| **纠错精确率（最重要）** | 被接受的替换中语义正确的比例 | ≥ 90%（错改比漏改伤害大） |
| **纠错召回率** | 20 句真机语料中近音错误被修复的比例 | ≥ 60%（带疑点块）/ ≥ 40%（仅规则区） |
| **误改率** | 正确英文词被改错 / hard facts 被改动 | hard facts 0 容忍；正确词误改 ≤ 1/20 句 |
| 确定性单测 | §5.1 全部用例 | 100% 通过 |
| corpus 应纠组 | §5.2 样本 1–4 | ≥ 80% 通过 |
| corpus 防越界组 | §5.2 样本 5–8 | 100% 通过 |
| 延迟 | §5.3 全部口径 | 全部达标 |
| 回归 | 现有全部单测 + corpus；空疑点 + 空画像下输出与改造前一致（仅 prompt 规则区差异） | 100% 通过 |
| 降级 | 卸载本地模型后听写可用，行为与现状逐字一致 | 人工验证通过 |

**发布闸门**：精确率与"防越界组 100%"是硬闸门，不达标不发布；
召回率是软目标，不达标时记录 case 进入迭代（prompt 调优 / 疑点阈值调整），
不阻塞发布——因为本方案的失败模式被验证层钳制为"漏纠"，漏纠 = 现状，无回退风险。

---

## 7. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| zh-CN 设备端识别 n-best 只有 1 条 / confidence 全 0 | 疑点块退化为空 | 设计上疑点块是增强而非前提；步骤 1–3 不依赖它（见 §4 实施顺序注） |
| 4B 模型漏申报 corrections（改了不报） | 逐条核查失效 | 重试 prompt 强调；corpus 防越界组监控；facts/长度校验兜底；二期可对比 source/output 的英文 token diff 做申报完整性审计 |
| 模型把正确英文改错且读音相近（如 affect/effect） | 精确率下降 | 规则区"没有把握就保留"+ 温度 0.1；真机验收的对照句监控；超标则收紧规则区措辞为"仅限疑点块内片段" |
| 疑点块诱导模型过度采纳候选 | 把对的改错 | 疑点块措辞明确"可作参考但不必采用"；corpus 样本 5 专测此场景 |
| 回调签名改动波及 `StableTextAssembler` 等调用方 | 编译面扩散 | suspects 仅在 isFinal 传递，partial 路径传 `[]`，assembler 逻辑零改动 |

---

## 8. 与画像方案的协同关系

| 能力 | 画像方案（glossary） | 本方案（语境纠错） |
|---|---|---|
| 高频专有名词（Kubernetes） | ✅ 主力：种子词典 + 学习晋升 | 辅助：无表时也可凭语境纠 |
| 中文音译误转写（酷伯内特斯） | ✅ 主力：prompt 注入受信纠写 | 仅当 `to` 命中 glossary 时放行（§3.3） |
| 长尾普通英文词（deploy/employ） | ❌ 设计上排除纯小写常用词 | ✅ 主力 |
| 冷启动（画像为空） | ❌ 无数据 | ✅ 不依赖积累 |
| 大小写/拼写变体 | ✅ GlossaryNormalizer 确定性归一 | 不涉及 |

两方案共用：prompt 注入位（同一 `processingPrompt`）、`FactExtractor` 保护区、
验证-还原的安全哲学（最坏情况 = 没生效）。实施上无先后依赖，可并行；
若同期落地，corpus 回归基线以"空画像 + 空疑点"为锚点统一对齐。

---

## 9. 二期扩展（本期不实施）

1. **申报完整性审计**：diff source 与 output 的英文 token 集合，发现未申报的
   替换时按 PhoneticSimilarity 自动补验或整体回退，封死"改了不报"漏洞。
2. **负反馈闭环**：用户取消会话且预览中存在被接受的纠错时，该 (from→to) 对
   进入"禁纠对"黑名单（复用画像方案的负反馈通道与存储）。
3. **中文同音字纠错**：在英文路径精确率数据充分后，评估以同样的
   申报-核查架构扩展到中文（需拼音相似度模块）。
4. **疑点驱动的 contextualStrings 回灌**：高频出现在疑点中、最终被纠正的词
   反哺给 `SFSpeechRecognizer.contextualStrings`，从源头收敛错误（与画像方案
   二期第 1 条合并立项）。
