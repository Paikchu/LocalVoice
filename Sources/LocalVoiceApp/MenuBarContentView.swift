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
