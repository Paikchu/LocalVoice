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

    init(model: AppModel) {
        self.model = model
        manager = model.modelManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地整理模型")
                        .font(.system(size: 14, weight: .medium))
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

            Toggle(
                "允许本地个性化学习",
                isOn: $model.personalizationEnabled
            )
            .font(.system(size: 12))

            Text("开启后会在本机保存常用术语、领域和联系方式。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Text("Qwen3 4B · 约 2.3 GB · 内容不离开本机")
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
    }

    @ViewBuilder
    private var modelAction: some View {
        switch manager.state {
        case .notInstalled, .failed:
            Button("下载") {
                manager.download()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .downloading, .loading:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Button("移除") {
                manager.remove()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
