import AppKit
import LocalVoiceCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            modeRow(
                title: "听写模式",
                icon: "mic",
                mode: .dictation,
                shortcut: model.dictationShortcut
            )
            separator
            modeRow(
                title: "英文模式",
                icon: "translate",
                mode: .english,
                shortcut: model.englishShortcut
            )
            separator
            ModelSettingsView(model: model)
            separator
            footer
        }
        .frame(width: MenuLayout.width)
    }

    private var header: some View {
        HStack {
            Text("LocalVoice")
                .font(.system(size: 22, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, MenuLayout.horizontalPadding)
        .frame(height: MenuLayout.headerHeight)
    }

    private var separator: some View {
        Divider()
            .padding(.horizontal, MenuLayout.horizontalPadding)
    }

    private func modeRow(
        title: String,
        icon: String,
        mode: VoiceMode,
        shortcut: LocalVoiceCore.KeyboardShortcut
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                model.toggle(mode)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .regular))
                        .frame(width: 22)
                    Text(title)
                        .font(.system(size: 16, weight: .regular))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.beginRecordingShortcut(mode)
            } label: {
                Text(
                    model.recordingShortcut == mode
                        ? "请按键…"
                        : shortcut.displayString
                )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.quaternary.opacity(0.55))
                )
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, MenuLayout.horizontalPadding)
        .frame(height: MenuLayout.modeRowHeight)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, MenuLayout.horizontalPadding)
        .frame(height: MenuLayout.footerHeight)
    }
}

private struct ModelSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var manager: LocalModelManager
    @State private var showsClearConfirmation = false
    @State private var showsModelRemovalConfirmation = false

    init(model: AppModel) {
        self.model = model
        manager = model.modelManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("整理模型")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Picker(
                    "整理模型",
                    selection: Binding(
                        get: { manager.selectedBackend },
                        set: { model.selectLanguageModelBackend($0) }
                    )
                ) {
                    ForEach(LanguageModelBackendKind.allCases, id: \.self) {
                        backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(!model.canChangeLanguageModelBackend)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.descriptor.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(manager.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                modelAction
            }

            TextField("邮件签名，例如 Max", text: $model.signature)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            Text("本地画像会保存常用术语、领域、音译纠错和历史记录。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Text(manager.descriptor.detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Button("清除全部本地数据", role: .destructive) {
                showsClearConfirmation = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.red)
        }
        .padding(.horizontal, MenuLayout.horizontalPadding)
        .padding(.vertical, 12)
        .confirmationDialog(
            "清除全部本地数据？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                model.clearAllLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("画像、模型、邮件签名和快捷键设置都会被删除。系统权限需在系统设置中单独撤销。")
        }
        .confirmationDialog(
            "移除 Qwen 模型？",
            isPresented: $showsModelRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除模型", role: .destructive) {
                manager.remove()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将释放约 2.3 GB 空间。之后可随时重新下载。")
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        if manager.managesDownload {
            switch manager.state {
            case .notInstalled, .failed, .unavailable:
                Button("下载") {
                    manager.download()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .downloading, .loading:
                ProgressView()
                    .controlSize(.small)
            case .ready:
                Button("移除", role: .destructive) {
                    showsModelRemovalConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canChangeLanguageModelBackend)
            case .removing:
                ProgressView()
                    .controlSize(.small)
            }
        } else {
            switch manager.state {
            case .loading, .removing:
                ProgressView()
                    .controlSize(.small)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notInstalled, .downloading, .unavailable, .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
