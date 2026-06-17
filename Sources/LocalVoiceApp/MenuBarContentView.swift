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
            modelRow
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

    private var modelRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text("模型")
                .font(.system(size: 13))
            Spacer()
            Picker(
                "模型",
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
            .frame(maxWidth: 76)
            .disabled(!model.canChangeLanguageModelBackend)
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
    @State private var showsModelRemovalConfirmation = false

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
                modelAction
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
