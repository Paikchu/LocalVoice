# LocalVoice 项目文档

> 一款完全离线、隐私优先的 macOS 菜单栏语音输入工具。
> 适用代码基线：2026-06-13（`main`）。

LocalVoice 常驻菜单栏，按下快捷键即可对任意应用的输入框进行语音听写或「中文→英文」语音翻译。语音识别（Apple `Speech` 框架）、文本整理与翻译（本地 MLX 大模型 `Qwen3-4B`）全部在本机完成，音频与文字不会离开设备。

---

## 1. 快速上手

### 环境要求
- macOS 26 / Apple Silicon（`arm64`）
- Xcode 26、`xcodegen`（`brew install xcodegen`）
- 首次运行需授予：**麦克风**、**语音识别**、**辅助功能** 三项权限

### 构建与运行
```bash
./scripts/build-app.sh        # 生成 build/LocalVoice.app（含签名）
open build/LocalVoice.app     # 启动；图标出现在菜单栏，无 Dock 图标
swift test                    # 运行 LocalVoiceCore 纯逻辑单元测试
```

### 使用
| 操作 | 默认快捷键 | 说明 |
|------|-----------|------|
| 听写模式 | `⌘⇧D` | 识别普通话，整理后写入当前输入框 |
| 英文模式 | `⌘⇧E` | 识别普通话，本地翻译为英文后写入 |
| 停止 | 再按一次同一快捷键 / 点击悬浮条勾号 | 触发最终整理与插入 |
| 取消 | 点击悬浮条 ✕ | 丢弃本次会话 |

快捷键可在菜单栏面板点击「快捷键胶囊」后重新录制；中英文模式不能使用相同组合键。

> **首次本地模型**：菜单栏面板可下载 `Qwen3-4B-Instruct`（4-bit，约数 GB）。未下载或加载失败时，系统自动降级为**规则整理**（去口语化 + 标点 + 排版），听写依然可用，只是不做语义级整理/翻译。

---

## 2. 项目结构

```
LocalVoice/
├── Package.swift            # SPM：仅暴露 LocalVoiceCore 库（供 swift test 用）
├── project.yml              # XcodeGen 工程定义（真正的 App 构建入口）
├── scripts/build-app.sh     # 一键构建 + 签名脚本
├── Sources/
│   ├── LocalVoiceCore/      # 纯逻辑、无 UI、可测试（平台无关 Foundation）
│   │   ├── LocalVoiceCore.swift     # 状态机、快捷键、文本累加/校正、布局常量
│   │   └── DraftProcessing.swift    # 草稿整理：提示词、校验、回退、口语结构化
│   └── LocalVoiceApp/       # macOS App（AppKit + SwiftUI + 系统框架集成）
│       ├── LocalVoiceApp.swift          # @main，MenuBarExtra 入口
│       ├── AppDelegate.swift            # 生命周期，持有 AppModel
│       ├── AppModel.swift               # ★ 中枢：编排整个会话流程
│       ├── SpeechRecognitionService.swift  # SFSpeechRecognizer 实时识别
│       ├── MLXLanguageModelService.swift   # 本地 LLM 加载与生成
│       ├── LocalModelManager.swift         # 模型下载/加载状态机
│       ├── TextInsertionService.swift      # 剪贴板 + ⌘V 跨应用插入
│       ├── HotkeyController.swift           # Carbon 全局热键
│       ├── PermissionCoordinator.swift      # 麦克风/语音/辅助功能权限
│       ├── FloatingPanelController.swift    # 底部实时波形悬浮条
│       └── MenuBarContentView.swift         # 菜单栏 SwiftUI 面板
├── Tools/
│   ├── LocalVoiceBenchmark/  # 命令行：跑模型整理质量/性能基准
│   └── generate_quality_corpus.swift   # 生成质量评测语料
├── Tests/                   # LocalVoiceCore 的 Swift Testing 用例 + 语料 fixture
└── docs/                    # 设计方案、实现报告、模型评测
```

**分层原则**：所有可单元测试的纯逻辑（状态机、文本算法、提示词、校验）都放在 `LocalVoiceCore`，不依赖 AppKit；`LocalVoiceApp` 只负责把系统框架（Speech / MLX / AX / Carbon）接到这些纯逻辑上。

---

## 3. 整体架构

```
        全局热键(Carbon)            麦克风(AVAudioEngine)
              │                          │
              ▼                          ▼
        HotkeyController          SFSpeechRecognizer (zh-CN, 本地)
              │                          │ partial / final
              └──────────┐    ┌──────────┘
                         ▼    ▼
                ┌───────────────────────┐
                │       AppModel        │  ← @MainActor 中枢
                │  SessionStateMachine  │
                └───────────┬───────────┘
        实时预览 │           │ 最终转写
                ▼           ▼
        FloatingPanel   DraftProcessingService (actor)
        + 菜单栏面板         │  调用本地 LLM 整理/翻译
                            ▼  (失败 → 规则回退)
                    DocumentFormatter 排版
                            │
                            ▼
                   TextInsertionService
                   (剪贴板写入 + 模拟 ⌘V)
                            │
                            ▼
                     目标应用输入框
```

**核心设计取舍**：录音过程中**不**向目标应用写入 partial 文本，只在底部悬浮条预览。用户停止后才执行一次「整段语义整理 → 单次跨应用插入」，避免增量写入造成的光标跳动与脏文本。

---

## 4. 内部逻辑详解

### 4.1 会话状态机（`SessionStateMachine`，LocalVoiceCore.swift）

整个会话由一个确定性状态机驱动，`AppModel` 是它唯一的调用方：

```
ready ──start(mode)──▶ listening(mode) ──finish──▶ finalizing(mode)
                            │                            │ finalTranscriptReady
            start(其它mode) │（暂存 pendingMode）         ▼
                            ▼                       processing(mode)
                       finalizing                       │ succeeded / fallback
                                                         ▼
                                                   inserting(mode)
                                                         │ insertionCompleted
                                                         ▼
                              ready（或切到暂存的 pendingMode 继续）
任意状态 ──fail(msg)──▶ failed(msg)      任意状态 ──cancel──▶ ready
```

`pendingMode` 支持「听写中直接按英文键」无缝切换：先完成当前模式的收尾，再自动开启新模式。

### 4.2 实时识别与文本累加

- `SpeechRecognitionService` 用 `AVAudioEngine` 抓音频，喂给 `SFSpeechRecognizer(zh-CN)`，强制 `requiresOnDeviceRecognition = true`（纯本地）、`addsPunctuation = true`（自动标点）。同时计算 RMS 音量驱动波形。
- `RecognitionTranscriptAccumulator`（Core）解决识别器**回改**问题：识别器会反复重写最近一段假设。累加器用「公共前缀 / 后缀重叠」判断当前假设是「修订」还是「新内容」，只在确认推进时把旧假设并入 `committedText`，避免重复拼接。
- `TextCorrector`（Core）做确定性清洗：中文删句首 `嗯/呃/啊/怎么说`、有上下文证据时删口头语「那个」、去相邻重复词、压空白；英文删 `um/uh/er/well/you know`、修标点前空格、首字母大写。

### 4.3 草稿整理管线（`DraftProcessingService`，DraftProcessing.swift）★

这是项目的「大脑」，一个 `actor`。最终转写经过：

1. **预处理**：`TextCorrector` 去口语 → `SpokenStructureNormalizer` 把口述指令落地。
2. **口语结构化**（`SpokenStructureNormalizer`，本次新增）：
   - 口述标点词转符号：`句号→。`、`逗号→，`、`问号→？`、`感叹号→！`、`换行→\n`、`另起一段→\n\n`。
   - 「第一点…第二点…」「一是…二是…」自动重排为 `1. / 2. / 3.` 编号列表。
   - 防误伤：当标点词本身是被讨论的内容（如「逗号是中文标点」「这个字段叫句号状态」）时，靠 `literalPrefixes/literalSuffixes` 白名单跳过。
3. **英文模式分块**：长文按句切成 ≤70 字的 chunk 逐段翻译（`translationChunks`），降低长文截断风险。
4. **本地 LLM 生成**：`PromptBuilder` 构造严格的 JSON-only 提示词，要求模型输出 `{intent, confidence, outputText, email}`；带 12s 超时（`withThrowingTaskGroup`）。
5. **多重校验 + 一次重试**（`validated`）：
   - JSON 可解析、`outputText` 非空（`ProcessingResultValidator`）。
   - **硬事实保留**（`FactExtractor`）：URL、产品编号（`ABC-123`）、金额（`¥/$`、万元/元/%）、时间（`12:30`）必须逐字出现在输出里。
   - **长度保留**（`preservesInput`）：输出字数不得低于原文一定比例（中文 0.55 / 英文 0.45），防止模型偷偷总结/截断。
   - **编号列表保留**（`preservesNumberedListStructure`）：输入有 `1./2./3.` 时输出编号必须一致。
   - **翻译完整性**（`isTranslatedWhenRequired`）：英文模式输出残留中文字符比例须 ≤20%。
   - 任一校验失败 → 用 `retryPrompt` 重试一次；再失败 → **回退**。
6. **确定性回退**：模型不可用/超时/两次校验都失败时，直接用 `DocumentFormatter` 对清洗后的原文排版输出（`usedFallback = true`）。保证**离线永远有可用结果**。
7. **邮件结构化**：命中邮件意图（`IntentHintDetector` + 置信度≥0.85）时，`EmailOutputFormatter` 套上称呼/正文/落款/签名；`RecipientExtractor` 从原文抽收件人。
8. **排版**：`DocumentFormatter` 统一换行、合并空行、生成 plain + HTML 两种表示供粘贴。

### 4.4 跨应用文本插入（`TextInsertionService`）

- 会话开始即记录前台应用 PID（`captureTarget`）。
- 插入时若前台已切走，先 `activate` 回原应用。
- 通过临时写剪贴板（同时写入 string / HTML / RTF）+ 模拟 `⌘V`（`CGEvent` 虚拟键 9）完成粘贴。
- 700ms 后若剪贴板未被他人改动，**恢复用户原有剪贴板内容**（`PasteboardItemSnapshot` 按类型快照，避免复用 `NSPasteboardItem` 崩溃）。

### 4.5 本地模型（`MLXLanguageModelService` + `LocalModelManager`）

- 模型：`mlx-community/Qwen3-4B-Instruct-2507-4bit`，经 HuggingFace Hub 下载到 `~/Library/Application Support/LocalVoice/Models`。
- `LocalModelManager` 维护下载、加载、移除和失败状态，App 启动时 `preloadIfInstalled()` 预热。
- 用户可在菜单栏移除 Qwen；删除范围包含模型仓库、下载元数据和锁文件，不影响个性化数据。
- 生成参数：`maxTokens 2048, temperature 0.1, topP 0.9, repetitionPenalty 1.05`，流式累积。
- 通过 `LocalLanguageModelService` 协议与 Core 解耦——测试里可注入假模型，无需真跑 LLM。

---

## 5. 如何打包封装

构建脚本：[`scripts/build-app.sh`](../scripts/build-app.sh)

```bash
./scripts/build-app.sh
```

它做了四件事：
1. `xcodegen generate` —— 从 [`project.yml`](../project.yml) 生成 `LocalVoice.xcodeproj`（工程文件不入库，由 `project.yml` 单一来源生成）。
2. `xcodebuild` —— Release 配置、`arm64`、`CODE_SIGNING_ALLOWED=NO` 先构建；依赖缓存到 `.packages`，中间产物在 `.derived`。
3. `ditto` 把产物复制到 `build/LocalVoice.app`。
4. **签名**：自动查找本机 `Apple Development` 证书——
   - 有证书：对每个内嵌 framework 逐个签名，再对 App 用 `--options runtime`（Hardened Runtime）+ entitlements 签名。
   - 无证书：用 ad-hoc 签名（`--sign -`），仅供本机运行。

**关键配置（`project.yml`）**：
- `LSUIElement: true` —— 无 Dock 图标，纯菜单栏应用。
- 三个 SPM 依赖：`MLXSwiftLM`（LLM 推理）、`swift-huggingface`（模型下载）、`swift-transformers`（分词）。
- Info.plist 内置麦克风/语音识别用途说明（中文）。
- entitlements：关闭 App Sandbox（需要 AX 注入与全局热键），开启 `device.audio-input`。

**分发提示**：要给他人使用需用 Developer ID 证书签名并做 **公证（notarization）**，否则 Gatekeeper 会拦截。当前脚本面向开发者本机自用。

---

## 6. 测试与质量

- `swift test` 跑 `LocalVoiceCoreTests`（Swift Testing 框架），覆盖：状态机、快捷键校验、文本累加/稳定化、校正、草稿整理、菜单布局、插入请求等。
- **质量语料**：`Tests/Fixtures/processing-quality-corpus.json` 由 [`Tools/generate_quality_corpus.swift`](../Tools/generate_quality_corpus.swift) 生成，`ProcessingQualityEvaluator` 据此判定整理结果是否保留事实/语义/结构。
- **基准工具**：`LocalVoiceBenchmark`（XcodeGen target）跑真实模型，输出 token 速率、首字延迟、整体耗时等指标，结果见 [docs/reports](reports/)。

---

## 7. 关键文件速查

| 想了解… | 看这里 |
|---------|--------|
| 会话怎么编排 | `Sources/LocalVoiceApp/AppModel.swift` |
| 状态机/快捷键/文本算法 | `Sources/LocalVoiceCore/LocalVoiceCore.swift` |
| 整理/校验/提示词/回退 | `Sources/LocalVoiceCore/DraftProcessing.swift` |
| 实时识别 | `Sources/LocalVoiceApp/SpeechRecognitionService.swift` |
| 本地模型加载/生成 | `MLXLanguageModelService.swift` / `LocalModelManager.swift` |
| 跨应用插入 | `Sources/LocalVoiceApp/TextInsertionService.swift` |
| 打包 | `scripts/build-app.sh` + `project.yml` |
| 设计/评测背景 | `docs/plans/`、`docs/reports/` |

> 注意：`docs/plans/2026-06-12-localvoice-product-implementation-report.md` 描述的是**早期**用系统 `TranslationSession` 的版本；当前主线已改为 MLX 本地大模型整理/翻译。以本文件与代码为准。
