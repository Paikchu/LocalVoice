import AppKit
import LocalVoiceCore
import SwiftUI

@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?
    private weak var model: AppModel?

    func bind(to model: AppModel) {
        self.model = model
    }

    func show(mode: VoiceMode) {
        guard let model else { return }
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    func showError() {
        guard let model else { return }
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval = 0) {
        guard let panel else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            }
        }
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: FloatingBarLayout.width,
                height: FloatingBarLayout.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: FloatingBarView(model: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - panel.frame.width / 2,
                y: visibleFrame.minY + 36
            )
        )
    }
}

private struct FloatingBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            preview

            HStack(spacing: 9) {
                circleButton(
                    icon: "xmark",
                    foreground: .white,
                    background: Color.white.opacity(0.12),
                    action: model.cancel
                )

                WaveformView(
                    level: model.audioLevel,
                    isEnglish: activeMode == .english
                )
                .frame(maxWidth: .infinity)

                circleButton(
                    icon: "checkmark",
                    foreground: .black,
                    background: Color.white.opacity(0.9),
                    action: model.finish
                )
            }
            .padding(6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay(
                        Capsule()
                            .fill(.black.opacity(0.32))
                    )
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.18), lineWidth: 0.75)
                    )
            )
            .frame(
                width: 196,
                height: FloatingBarLayout.controlsHeight
            )
        }
        .frame(
            width: FloatingBarLayout.width,
            height: FloatingBarLayout.height
        )
    }

    private var preview: some View {
        Text(model.transcript.isEmpty ? "正在聆听…" : model.transcript)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(
                model.transcript.isEmpty
                    ? Color.white.opacity(0.55)
                    : Color.white.opacity(0.96)
            )
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(
                maxWidth: .infinity,
                minHeight: FloatingBarLayout.previewHeight,
                maxHeight: FloatingBarLayout.previewHeight,
                alignment: .leading
            )
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.black.opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 0.75)
                    )
            )
    }

    private var activeMode: VoiceMode? {
        switch model.state {
        case .listening(let mode), .finalizing(let mode):
            return mode
        default:
            return nil
        }
    }

    private func circleButton(
        icon: String,
        foreground: Color,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(
                    width: FloatingBarLayout.buttonDiameter,
                    height: FloatingBarLayout.buttonDiameter
                )
                .background(Circle().fill(background))
        }
        .buttonStyle(.plain)
    }
}

private struct WaveformView: View {
    let level: Float
    let isEnglish: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let heights = WaveformDynamics.heights(
                level: level,
                phase: phase
            )

            HStack(spacing: 2.5) {
                ForEach(heights.indices, id: \.self) { index in
                    Capsule()
                        .fill(barColor(index))
                        .frame(width: 2.5, height: heights[index])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 28)
            .animation(.easeOut(duration: 0.1), value: level)
        }
    }

    private func barColor(_ index: Int) -> Color {
        if isEnglish && (5...7).contains(index) {
            return Color(red: 0.68, green: 0.56, blue: 0.95)
        }
        return .white.opacity(0.94)
    }
}
