import AppKit
import LocalVoiceCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var manager: LocalModelManager
    @State private var showsSettings = false

    init(model: AppModel) {
        self.model = model
        manager = model.modelManager
    }

    var body: some View {
        VStack(spacing: 0) {
            actionRow(
                title: "听写",
                icon: "mic",
                mode: .dictation,
                shortcut: model.dictationShortcut
            )
            separator
            actionRow(
                title: "英文",
                icon: "translate",
                mode: .english,
                shortcut: model.englishShortcut
            )
            separator
            settingsRow
            if showsSettings {
                separator
                NativeSettingsView(model: model)
            }
            separator
            quitRow
        }
        .frame(width: MenuLayout.width)
    }

    private var separator: some View {
        Divider()
            .padding(.horizontal, MenuLayout.horizontalPadding)
    }

    private func actionRow(
        title: String,
        icon: String,
        mode: VoiceMode,
        shortcut: LocalVoiceCore.KeyboardShortcut
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                model.toggle(mode)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 16)
                    Text(title)
                        .font(.system(size: 13))
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
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .monospaced()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MenuLayout.horizontalPadding)
        .frame(height: MenuLayout.nativeRowHeight)
    }

    private var settingsRow: some View {
        Button {
            showsSettings.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text("设置…")
                    .font(.system(size: 13))
                Spacer()
                Image(systemName: showsSettings ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MenuLayout.horizontalPadding)
        .frame(height: MenuLayout.nativeRowHeight)
    }

    private var quitRow: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text("退出")
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, MenuLayout.horizontalPadding)
        .frame(height: MenuLayout.footerHeight)
    }
}

private struct NativeSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var manager: LocalModelManager
    @State private var showsClearConfirmation = false

    init(model: AppModel) {
        self.model = model
        manager = model.modelManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MenuLayout.settingsSectionSpacing) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.descriptor.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(manager.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                modelStatusIcon
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper ASR")
                        .font(.system(size: 12, weight: .medium))
                    Text(model.asrModelReady ? "已就绪" : "正在加载…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.asrModelReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            TextField("邮件签名，例如 Max", text: $model.signature)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            Toggle(
                "快捷键音效",
                isOn: Binding(
                    get: { model.activationSoundEnabled },
                    set: { model.setActivationSoundEnabled($0) }
                )
            )
            .font(.system(size: 12))
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 8) {
                Text("音色")
                    .font(.system(size: 12))
                Spacer()
                Picker(
                    "音色",
                    selection: Binding(
                        get: { model.activationSoundOption },
                        set: { model.selectActivationSoundOption($0) }
                    )
                ) {
                    ForEach(DictationActivationSoundOption.allCases, id: \.self) {
                        option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 82)

                Button {
                    model.previewActivationSound()
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .disabled(!model.activationSoundEnabled)
            }

            Text(manager.descriptor.detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            Button("清除全部本地数据", role: .destructive) {
                showsClearConfirmation = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.red)
        }
        .padding(.horizontal, MenuLayout.horizontalPadding)
        .padding(.vertical, MenuLayout.settingsSectionVerticalPadding)
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
            Text("画像、邮件签名和快捷键设置都会被删除。系统权限需在系统设置中单独撤销。")
        }
    }

    @ViewBuilder
    private var modelStatusIcon: some View {
        switch manager.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unavailable, .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}
