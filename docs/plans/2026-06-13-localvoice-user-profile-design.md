# LocalVoice 用户画像（User Profile）实现方案

日期：2026-06-13
状态：设计定稿，待实施

---

## 1. 目标与非目标

**目标**

1. 系统在后台自动维护一份用户画像，用户不需要手动维护，前台不展示任何入口。
2. 画像用于持续优化转写整理质量：
   - 领域偏好（如检测到用户长期涉及软件工程内容，整理时倾向保留技术术语）。
   - 个人术语表（glossary）：高频专有名词的规范写法，用于纠正 ASR 误转写和大小写归一。
   - 个人事实（邮箱、电话、地址、常用联系人）：供邮件等场景自动补全。
   - 风格偏好（语言比例、句长、是否常写邮件）。
3. 对听写主路径**零新增延迟**：所有学习发生在文本插入完成之后的后台任务里。

**非目标（首版不做）**

- 不做 LLM 蒸馏摘要（二期可选，见 §9）。
- 不做画像的 UI 展示与手动编辑。
- 不做跨设备同步；数据只存本地。
- 不修改 `SFSpeechRecognizer` 识别层本身（contextualStrings 注入作为二期优化，见 §9）。

---

## 2. 总体架构

```
听写完成（文本已插入）
        │
        ▼ fire-and-forget，不阻塞主路径
┌──────────────────────────────┐
│ UserProfileStore (actor)     │  Sources/LocalVoiceApp/UserProfileStore.swift
│  - ingest(session)           │
│  - snapshot() -> ProfileHint │
│  - 防抖落盘 profile.json     │
└──────────────┬───────────────┘
               │ 调用纯函数（可单测）
               ▼
┌──────────────────────────────┐
│ ProfileExtractor (enum)      │  Sources/LocalVoiceCore/UserProfile.swift
│  - 术语候选提取（正则+分词）  │
│  - 联系方式/地址提取（正则）  │
│  - 领域打分（静态词典查表）   │
│  - 候选晋升/衰减/淘汰        │
└──────────────────────────────┘

下一次听写开始整理时
        │
        ▼
PromptBuilder.processingPrompt(..., profileHint:)   ← 注入紧凑画像块
        │
        ▼ 模型输出验证通过后
GlossaryNormalizer.normalize(output, glossary:)      ← 确定性术语归一（大小写/变体）
```

两条增强路径互补：

- **Prompt 注入**（语义层）：让 4B 模型在整理时知道用户的术语表和领域，纠正音译误转写（"酷伯内特斯" → "Kubernetes"）。模型不可用时此路径自然失效，不影响降级链。
- **确定性归一**（字符层）：模型输出（或降级的规则输出）之后，再跑一遍零成本的字符串归一，保证大小写和拼写变体统一。**降级路径同样受益**，且不依赖模型「听话」。

---

## 3. 数据模型与存储

### 3.1 `UserProfile`（Codable，存于 LocalVoiceCore）

```swift
public struct GlossaryTerm: Codable, Equatable, Sendable {
    public let canonical: String        // 规范写法，如 "Kubernetes"
    public var surfaceCounts: [String: Int]  // 用户最终文本中各形式出现次数，如 ["Kubernetes": 7, "kubernetes": 2]
    public var occurrences: Int         // 总出现次数
    public var sessionCount: Int        // 出现过的会话数（去重）
    public var lastSeen: Date           // 最近出现时间，用于衰减
}

public struct ContactFact: Codable, Equatable, Sendable {
    public enum Kind: String, Codable { case email, phone, address }
    public let kind: Kind
    public let value: String
    public var occurrences: Int
    public var lastSeen: Date
}

public struct UserProfile: Codable, Equatable, Sendable {
    public var version: Int                  // schema 版本，当前 1
    public var domains: [String: Double]     // 领域 -> 累积得分（指数衰减）
    public var glossary: [GlossaryTerm]      // 已晋升的正式术语，上限 64
    public var candidates: [GlossaryTerm]    // 候选池，上限 256（LRU）
    public var contacts: [ContactFact]       // 已晋升的事实，上限 16
    public var contactCandidates: [ContactFact]  // 候选池，上限 64
    public var style: StyleStats             // 中英比例/平均句长/邮件占比等累计计数器
    public var sessionCount: Int
}
```

### 3.2 存储

- 路径：`~/Library/Application Support/LocalVoice/profile.json`（与现有 `Models/` 目录同级）。
- 写入：序列化到临时文件后 `FileManager.replaceItemAt` 原子替换，避免崩溃产生半截文件。
- 防抖：`ingest` 后标记 dirty，延迟 2 秒合并落盘；`shutdown()` 时强制同步落盘一次。
- 启动：`AppModel.init` 中由 `UserProfileStore` 异步加载；加载失败（损坏/版本不识别）时重置为空画像并归档坏文件为 `profile.json.corrupt`，不影响启动。
- 体积上限：所有列表有硬上限（见 3.1），整个文件预期 < 64 KB。

### 3.3 隐私

- 全部数据仅存本地，不参与任何网络请求（本项目本身无网络依赖，模型下载除外）。
- 不存原始转写全文，只存提取后的统计结果。
- 用户在悬浮窗取消（`cancel()`）的会话**不进入** ingest——取消是负反馈信号。

---

## 4. 后台维护机制（怎么"默默"跑）

### 4.1 触发点

`AppModel.completeSession()` 成功路径（文本已插入、用户未取消）追加：

```swift
let session = ProfileIngestInput(
    finalText: insertedPlainText,     // 模型整理并通过验证后的最终文本
    mode: mode,
    wasEmail: outcome.result.intent == .composeEmail,
    usedFallback: outcome.usedFallback
)
Task.detached(priority: .utility) { await profileStore.ingest(session) }
```

要点：

- **学习来源是最终插入文本，不是原始 ASR partial。** 最终文本已经过模型整理 + `ProcessingResultValidator` 事实校验，噪声远低于 ASR 原始输出，这是「确保提取的词正确」的第一道防线（详见 §6）。
- `usedFallback == true`（模型不可用、走规则整理）的会话照常 ingest，但术语候选**权重减半**（计 0.5 次），因为未经语义清洗。
- `Task.detached(priority: .utility)`：不占主线程，不与下一次听写争资源。

### 4.2 单次 ingest 的工作量（性能预算）

全部是 O(n) 字符串操作，目标 **< 5 ms / 千字**（M 系列芯片实测预期 < 1 ms）：

| 步骤 | 实现 | 复杂度 |
|---|---|---|
| 术语候选提取 | 预编译正则（见 §5.1）一次扫描 | O(n) |
| 联系方式提取 | 预编译正则（邮箱/手机号/中文地址） | O(n) |
| 领域打分 | `NLTokenizer` 分词 + 静态词典 `Set` 查表 | O(n) |
| 候选合并/晋升/淘汰 | 字典 upsert + 上限裁剪 | O(候选数) |

正则全部 `static let` 预编译；actor 串行执行天然避免并发竞争。验收时跑 micro-benchmark（见 §8）。

### 4.3 读取路径（注入 prompt）

`beginProcessing()` 在调模型前取一次快照：

```swift
let hint = await profileStore.snapshot()  // 返回值类型 ProfileHint，actor 内 O(1) 组装
```

`ProfileHint` 是已经裁剪好的注入数据：glossary 取 top-16（按出现频次×新近度排序）、领域取 top-2、联系人 top-4。**注入 prompt 的画像块硬上限 400 字符**，避免增加可感知的 prefill 时间（按现有 benchmark，4B 模型 prefill 几百 token 的增量 < 0.2 s）。

---

## 5. 术语归一机制（"Kubernetes" 问题的完整设计）

用户口述「我想部署到 Kubernetes 上」，可能出现三类形式问题：

| 问题 | 例子 | 解决层 |
|---|---|---|
| A. 大小写/连写变体 | `kubernetes`、`KUBERNETES`、`K8s` | 确定性归一层 |
| B. 拼写近似变体 | `Kubernates`、`Kuberneties` | 确定性归一层（编辑距离） |
| C. 中文音译误转写 | `酷伯内特斯`、`库班内提斯` | Prompt 注入层（交给模型） |

### 5.1 候选提取：什么样的 token 进入候选池

一次正则扫描，符合任一模式即成为候选：

- 含大写字母的英文词（`Kubernetes`、`PostgreSQL`）。
- 字母数字混合或含连字符/点（`K8s`、`gRPC`、`io.k8s.api`）。
- camelCase / 全大写缩写（`localStorage`、`HTTP`）。
- 复用现有 `FactExtractor` 的产品编号模式。

排除：纯小写常用英文词（用一张 ~2000 词的英文常用词 `Set` 过滤，避免 `the`、`deploy` 进表）、纯数字、长度 < 2 或 > 40。

### 5.2 规范写法（canonical）的确定

每个术语记录 `surfaceCounts`（用户最终文本中各形式的出现次数）。规范写法 = **众数形式**，平票时取最近使用的形式。

这正是用户例子的语义：如果用户的最终文本里 `kubernetes`（小写）出现得最多，规范形式就是小写；系统跟随用户的实际书写习惯，而不是硬编码官方拼写。种子词典（见 5.4）只提供初始值，用户用法可以覆盖它。

### 5.3 确定性归一层 `GlossaryNormalizer`

位置：`DraftProcessingService.process` 末尾，模型输出验证通过后、`DocumentFormatter` 之前（降级路径同样经过）。

规则：

1. **保护区先挖空**：先用现有 `FactExtractor` 的 URL/邮箱/编号正则标出保护区间，区间内不做任何替换（与现有「不得在 URL 内部插标点」一致）。
2. **大小写归一**：对 glossary 中每个词做带词边界的大小写不敏感精确匹配（`\bkubernetes\b` 不命中 `kubernetesy`），替换为 canonical 形式。
3. **拼写变体归一**：对输出中「含大写或字母数字混合」的 token（即本身就像术语的 token），与 glossary 词计算 Damerau-Levenshtein 距离；长度 ≥6 且距离 ≤2、长度 ≥10 且距离 ≤3 时替换。**纯小写普通词不参与**，避免把 `deployed` 错改成什么术语。
4. 中文音译**不在这一层处理**——确定性音译匹配误判率太高，交给模型层。

复杂度：glossary 上限 64、注入 top-16，编辑距离只对疑似术语 token 计算，单次整理新增耗时 < 1 ms。

### 5.4 静态种子词典

`Sources/LocalVoiceCore/Resources/seed-glossary.json`：约 200 个高频技术/商业术语的官方拼写（Kubernetes、PostgreSQL、gRPC、iOS、GitHub…），随包分发。

作用：

- 用户第一次说 "Kubernetes" 还没积累出 surfaceCounts 时，种子提供初始 canonical。
- 模型层 prompt 提示「这些词请用规范拼写」。
- 种子词的 canonical 可被用户实际用法覆盖（§5.2 众数规则优先于种子）。

### 5.5 Prompt 注入层（处理音译误转写）

`PromptBuilder.processingPrompt` 新增参数 `profileHint: String?`，注入块追加在「用户签名」之前：

```
用户术语表（如原文出现读音相近的误写，请改为下列规范写法；不得据此添加原文没有的内容）：
Kubernetes、gRPC、PostgreSQL、LocalVoice

用户领域：软件工程

常用联系人：张伟 <zhangwei@example.com>
```

约束措辞与现有 prompt 风格一致（硬规则式）。注意与现有事实校验的交互：`ProcessingResultValidator.requiredFacts` 来自原文的 hard facts（URL/编号/金额），术语纠写不会改动这些区域，因此校验不冲突；若模型纠写导致输出整体校验失败，按现有逻辑回退——回退文本仍会经过 5.3 的确定性归一，保底大小写正确。

---

## 6. 正确性保障：怎么确保学到的词是对的

防止「学错一次、错一辈子」，五道机制：

1. **来源清洗**：只学最终插入文本（已过模型整理 + 事实校验 + 用户未取消）。取消的会话不学；降级会话权重减半（§4.1）。
2. **候选晋升门槛**：候选 → 正式 glossary 需同时满足：
   - 累计出现 ≥ 3 次（降级会话计 0.5）；
   - 跨 ≥ 2 个不同会话（防一次会话内重复刷次数）；
   - 不在英文常用词表内。
   联系方式晋升门槛：同一值出现 ≥ 2 次（正则本身已强约束格式，门槛可低些）。
3. **时间衰减**：每次落盘时，90 天未出现的正式词条移回候选池，180 天未出现的候选直接删除；领域得分按月衰减 ×0.8。学错或过时的词最终自然消失。
4. **冲突保护**：归一层替换是保守的（词边界 + 仅疑似术语 token + 保护区挖空），错误词条最坏情况是「没生效」，而不是污染正常文本。
5. **负反馈通道（轻量）**：如果一次会话最终走了 `cancel()`，且取消前的预览文本里出现了某 glossary 词的归一改写，该词条 `occurrences -1`。首版只做这一个隐式信号，不引入任何 UI。

---

## 7. 代码改动清单

| 文件 | 改动 |
|---|---|
| `Sources/LocalVoiceCore/UserProfile.swift` | **新增**。`UserProfile` 等数据模型、`ProfileExtractor`（候选提取/晋升/衰减，纯函数）、`GlossaryNormalizer`、`ProfileHintBuilder`（组装注入文本，含 400 字符上限）。 |
| `Sources/LocalVoiceCore/Resources/seed-glossary.json` | **新增**。种子术语词典 + 英文常用词过滤表 + 领域词典。 |
| `Sources/LocalVoiceCore/DraftProcessing.swift` | `PromptBuilder.processingPrompt` 增加 `profileHint: String?` 参数；`DraftProcessingService.process` 增加 `profileHint`、`glossary` 参数，输出末尾接 `GlossaryNormalizer`。 |
| `Sources/LocalVoiceApp/UserProfileStore.swift` | **新增**。actor：加载/快照/ingest/防抖原子落盘/损坏恢复。 |
| `Sources/LocalVoiceApp/AppModel.swift` | `init` 加载 store；`beginProcessing` 取 snapshot 传入；`completeSession` 后台 ingest；`cancel` 走负反馈；`shutdown` 强制落盘。 |
| `Package.swift` / `project.yml` | LocalVoiceCore 增加 resources 声明。 |
| `Tests/LocalVoiceCoreTests/UserProfileTests.swift` | **新增**。见 §8。 |
| `Tests/Fixtures/processing-quality-corpus.json` | 追加术语纠写样本。 |

实施顺序（每步可独立提交、测试通过）：

1. 数据模型 + `ProfileExtractor` + 单测（纯 Core，无 app 依赖）。
2. `GlossaryNormalizer` + 单测。
3. `UserProfileStore` + 落盘/恢复测试。
4. `PromptBuilder` / `DraftProcessingService` 接线 + corpus 样本。
5. `AppModel` 接线 + 端到端验证。

---

## 8. 测试与验收标准

### 8.1 单元测试（`UserProfileTests.swift`）

提取与晋升：

- 含 `Kubernetes`、`gRPC`、`K8s` 的文本各提取为候选；`the`、`deploy`、纯数字不进候选。
- 同一会话内重复 5 次只计 1 个会话；3 次出现 + 2 个会话才晋升；降级会话计 0.5 次。
- 邮箱/手机号/中文地址正则各有正反例（如 `lv-2048@example.com` 是邮箱不是产品编号；`13800138000` 提取、`LV-2048` 不当成电话）。
- 90 天未出现的词条被降回候选；候选池超 256 时按 LRU 淘汰。
- 领域打分：连续 10 段工程文本后 `domains["软件工程"]` 超过晋升阈值；混合文本不误判。

归一层（`GlossaryNormalizer`）：

- `"部署到 kubernetes 上"` + glossary `[Kubernetes]` → `"部署到 Kubernetes 上"`；用户众数形式为小写时反向成立（覆盖用户给的例子）。
- 词边界：`kubernetesy` 不被替换。
- 编辑距离：`Kubernates` → `Kubernetes`；`deployed` 不被改写（纯小写普通词不参与）。
- 保护区：`https://kubernetes.io/docs` URL 内部不替换。
- canonical 众数规则：`surfaceCounts ["k8s": 5, "K8s": 2]` 时 canonical 为 `k8s`；种子词典初值被用户用法覆盖。

存储（`UserProfileStore`）：

- 落盘后重新加载内容一致；写入是原子的（替换不留临时文件）。
- 损坏 JSON 启动不崩溃，归档为 `.corrupt` 并重建空画像。
- 取消会话不 ingest；取消触发对应词条 `occurrences -1`。

Prompt 注入：

- `ProfileHintBuilder` 输出 ≤ 400 字符；空画像时 `processingPrompt` 与现状完全一致（回归保护）。

### 8.2 质量语料库（corpus 集成测试）

新增样本（带 glossary 前置条件）：

- 音译纠写：原文含 `酷伯内特斯`，glossary 含 `Kubernetes`，期望输出含 `Kubernetes`、不含音译串（模型层，允许标记为 model-required 样本）。
- 纠写不虚构：术语表含 `PostgreSQL` 但原文未提及，输出不得出现 `PostgreSQL`。
- 现有全部 corpus 样本在「空画像」下结果不回归。

### 8.3 验收指标

| 指标 | 标准 |
|---|---|
| 听写主路径新增延迟 | ingest 完全后台化，stop→insert 链路新增 **0 ms**（代码审查 + 日志时间戳验证） |
| 单次 ingest 耗时 | < 5 ms / 千字（micro-benchmark，M 系列实测） |
| `GlossaryNormalizer` 耗时 | < 1 ms / 次（glossary=64 词、输出 2000 字时） |
| Prompt 注入增量 | 画像块 ≤ 400 字符；prefill 增量 < 0.2 s（用现有 `LocalVoiceBenchmark` 对比空画像/满画像） |
| 大小写/变体归一准确率 | corpus 样本 100% 通过（确定性逻辑） |
| 音译纠写 | 模型可用时 corpus 样本通过率 ≥ 80%（模型层非确定，允许阈值）；模型不可用时不劣化现状 |
| 误改写率 | 非术语文本被归一层错误改写：corpus 全量 0 例 |
| 存储 | `profile.json` < 64 KB；损坏文件不影响启动 |
| 回归 | 现有全部单测与 corpus 通过；空画像下输出与改造前逐字一致 |

---

## 9. 二期扩展（本期不实施）

1. **`SFSpeechRecognizer.contextualStrings` 注入**：把 glossary top-N 喂给系统识别器本身，从源头减少误转写。收益最大但需验证对识别延迟的影响，单独立项。
2. **LLM 蒸馏**：累计 ≥ 20 段且距上次 ≥ 24 h、app 空闲（非听写中）且模型已常驻时，用一次生成把风格统计提炼为自然语言偏好句注入 prompt。
3. **联系人自动补全的交互落地**：邮件意图缺收件人邮箱时，从 `contacts` 补全 `email.recipient`。数据本期已开始积累，交互后做。
