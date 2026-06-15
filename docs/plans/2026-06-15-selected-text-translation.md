# Selected Chinese Text Translation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Press the existing Chinese-to-English shortcut while Chinese text is selected, preview the translation, then replace exactly that selection with English.

**Architecture:** The English shortcut checks the focused accessibility element before starting voice capture. A valid Chinese selection enters the existing English processing and insertion states, reuses `DraftProcessingService`, previews through `FloatingPanelController`, and verifies the captured focus, range, text, and process before the existing pasteboard insertion. Missing or non-Chinese selections preserve the current voice-translation behavior.

**Tech Stack:** Swift 6, AppKit Accessibility APIs, Carbon global hotkeys, SwiftUI, MLX, Swift Testing.

---

## 实现方案

- 推荐方案：AX 读取选区 + 捕获元素和范围 + 现有剪贴板粘贴替换。兼容现有插入链路，也能在翻译完成前验证选区仍属于原控件。
- 备选方案：全程 AX 直接写 `kAXSelectedTextAttribute`。更快，但网页编辑器和 Electron 控件支持不稳定。
- 备选方案：模拟 `⌘C` 读取、模拟 `⌘V` 替换。覆盖面广，但会短暂修改剪贴板，且难以可靠判断是否真的选中了中文。
- `⌘⇧E` 在 `.ready` / `.failed` 状态优先读取选区。选区包含汉字时进入选区翻译；否则沿用语音英文模式。
- 选区翻译复用 `DraftProcessingService.process(... mode: .english)`，不新增模型或网络依赖。
- 翻译期间底部预览框先显示原中文，再显示英文结果。替换成功后按现有动画关闭。
- 本地模型未就绪、输出为空、输出仍含中文、模型回退、选区失效、辅助功能权限不足时停止替换并显示错误。
- 选区失效时不覆盖原文，已生成的英文保留在剪贴板。
- 语音结果写入前检查目标 App 是否仍有输入光标；光标失效时将整理结果保留在剪贴板。
- 取消操作终止翻译任务并关闭预览，不修改选中文本。

## 验收方案

- TextEdit 中选中一句中文，按 `⌘⇧E`，底部预览框出现，最终只替换选中范围，前后文本不变。
- 翻译过程中原中文仍保留；英文结果通过校验后才执行一次替换。
- 未选中文本时按 `⌘⇧E`，仍启动原有中文语音转英文流程。
- 选中纯英文时按 `⌘⇧E`，不进入选区翻译，仍保持原快捷键行为。
- 模型未就绪或翻译失败时，原选区不变，预览框显示明确错误。
- 翻译过程中点击取消，原选区不变。
- 翻译过程中切换目标控件或改变选区，系统拒绝替换，原文不变，英文留在剪贴板。
- 语音识别完成时目标输入光标已失效，不发送粘贴快捷键，整理结果留在剪贴板。
- 原剪贴板内容在替换完成后恢复。
- 走剪贴板兜底时不恢复旧剪贴板，确保结果可直接粘贴。

## 测试方案

- 状态机：新增“选区翻译开始”事件，从 `.ready` / `.failed` 进入 `.processing(.english)`，成功后进入 `.inserting(.english)`，插入完成回到 `.ready`。
- 请求校验：空白、纯英文不构成选区翻译请求；包含汉字的选区保留原始文本和目标 PID。
- 输出保护：只有非回退、非空、无汉字的英文结果允许替换。
- 插入策略：选区失效、语音光标失效、辅助功能权限失效均选择剪贴板兜底。
- 快捷键回归：原两个快捷键匹配和语音模式行为保持不变。
- 全量单测：`swift test`。
- App 构建：`xcodebuild -project LocalVoice.xcodeproj -scheme LocalVoice -configuration Debug -derivedDataPath .derived build CODE_SIGNING_ALLOWED=NO`。
- 手动端到端：运行签名 App，在 TextEdit 验证中文选区替换、选区失效后剪贴板兜底、正常插入后的剪贴板恢复。

## 执行任务

### Task 1: 选区翻译核心状态与校验

**Files:**
- Modify: `Sources/LocalVoiceCore/LocalVoiceCore.swift`
- Modify: `Tests/LocalVoiceCoreTests/SessionStateTests.swift`
- Modify: `Tests/LocalVoiceCoreTests/TextInsertionTests.swift`

**Steps:**
- 先写状态转换、中文选区识别和英文输出保护测试。
- 运行目标测试，确认因缺少功能而失败。
- 实现最小核心类型和状态事件。
- 重跑目标测试并确认通过。

### Task 2: 捕获并验证 macOS 选区

**Files:**
- Create: `Sources/LocalVoiceApp/SelectedTextService.swift`
- Modify: `Sources/LocalVoiceApp/TextInsertionService.swift`

**Steps:**
- 用 AX 获取 focused element、selected text、selected range 和 PID。
- 替换前验证 focused element、PID、selected range 和 selected text 未变化。
- 任一 AX 操作失败或选区变化时拒绝粘贴，不强制恢复旧选区。
- 保留现有剪贴板快照与恢复逻辑。

### Task 3: 快捷键与预览流程

**Files:**
- Modify: `Sources/LocalVoiceApp/AppModel.swift`
- Modify: `Sources/LocalVoiceApp/FloatingPanelController.swift`

**Steps:**
- 英文快捷键在空闲状态优先分流中文选区。
- 进入选区翻译状态，显示原文并启动本地英文处理。
- 校验英文输出和原选区状态，执行单次替换。
- 取消、失败、完成时清理捕获对象和任务。
- 选区翻译时预览框显示翻译状态，不显示录音波形。

### Task 4: 回归与端到端验证

**Files:**
- Modify: `README.md`

**Steps:**
- 更新快捷键行为说明。
- 运行全量单测。
- 生成 Xcode 工程并构建 App。
- 启动签名 App，在 TextEdit 执行验收清单。
