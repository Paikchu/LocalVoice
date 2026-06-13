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

private struct PreviewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FloatingBarView: View {
    @ObservedObject var model: AppModel
    @State private var measuredTextHeight: CGFloat = 0

    private static let bottomAnchor = "preview-bottom-anchor"

    var body: some View {
        // No GlassEffectContainer: the preview and capsule are only 8pt apart,
        // so the container would merge their glass shapes into one blob and
        // draw a faint enclosing hull around the preview. Rendering each glass
        // independently keeps a single, clean border per element.
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            preview
            capsule
        }
        .padding(FloatingBarLayout.glowPadding)
        .frame(
            width: FloatingBarLayout.width,
            height: FloatingBarLayout.height,
            alignment: .bottom
        )
        .opacity(0.88)
    }

    private var capsule: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(
            width: FloatingBarLayout.capsuleWidth,
            height: FloatingBarLayout.controlsHeight
        )
        .glassEffect(
            .clear.tint(.black.opacity(0.08)).interactive(),
            in: .capsule
        )
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.75))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            scrollingText
        }
        .padding(.horizontal, FloatingBarLayout.previewHorizontalPadding)
        .padding(.vertical, FloatingBarLayout.previewVerticalPadding)
        .frame(width: FloatingBarLayout.contentWidth, alignment: .leading)
        // Frosted-glass material instead of `.glassEffect`: Liquid Glass `.clear`
        // always paints a bright specular rim around its plate, which read as a
        // second "white frame" outside the GlowBorder. A material fill is a
        // translucent blur with no rim, so the GlowBorder is the only edge.
        .background(
            RoundedRectangle(cornerRadius: FloatingBarLayout.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(
                    RoundedRectangle(cornerRadius: FloatingBarLayout.cornerRadius, style: .continuous)
                        .fill(.black.opacity(0.12))
                )
        )
        .background(measuringText)
        .overlay(
            GlowBorder(
                cornerRadius: FloatingBarLayout.cornerRadius,
                isEnglish: activeMode == .english,
                isProcessing: isProcessing
            )
        )
        .onPreferenceChange(PreviewHeightKey.self) { height in
            measuredTextHeight = height
        }
    }

    private var scrollingText: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Text(displayText)
                        .font(.system(
                            size: FloatingBarLayout.previewFontSize,
                            weight: .medium
                        ))
                        .lineSpacing(FloatingBarLayout.previewLineSpacing)
                        .foregroundStyle(displayColor)
                        .frame(
                            width: FloatingBarLayout.previewTextWidth,
                            alignment: .leading
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
            }
            .frame(
                width: FloatingBarLayout.previewTextWidth,
                height: FloatingBarLayout.clampedTextAreaHeight(measuredTextHeight),
                alignment: .topLeading
            )
            .onChange(of: model.transcript) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private var measuringText: some View {
        Text(displayText)
            .font(.system(
                size: FloatingBarLayout.previewFontSize,
                weight: .medium
            ))
            .lineSpacing(FloatingBarLayout.previewLineSpacing)
            .frame(
                width: FloatingBarLayout.previewTextWidth,
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PreviewHeightKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .hidden()
            .allowsHitTesting(false)
    }

    private var displayText: String {
        model.transcript.isEmpty ? "正在聆听…" : model.transcript
    }

    private var displayColor: Color {
        model.transcript.isEmpty
            ? Color.white.opacity(0.5)
            : Color.white.opacity(0.95)
    }

    private var activeMode: VoiceMode? {
        switch model.state {
        case .listening(let mode),
             .finalizing(let mode),
             .processing(let mode),
             .inserting(let mode):
            return mode
        default:
            return nil
        }
    }

    // The voice capture is finished and the model is organizing the text.
    private var isProcessing: Bool {
        switch model.state {
        case .finalizing, .processing, .inserting:
            return true
        default:
            return false
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
                .font(.system(size: 12, weight: .semibold))
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

private struct GlowBorder: View {
    let cornerRadius: CGFloat
    let isEnglish: Bool
    let isProcessing: Bool

    var body: some View {
        // The angular gradient is fixed in place (no rotation), so the border
        // reads as a steady rainbow glow rather than a flowing highlight. While
        // the model is organizing text we gently brighten and breathe the glow.
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !isProcessing)) { context in
            let pulse = isProcessing ? breathe(context.date) : 0
            let shape = RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            let gradient = AngularGradient(
                gradient: Gradient(colors: ringColors),
                center: .center
            )

            ZStack {
                // Soft outer halo that bleeds beyond the border.
                shape
                    .stroke(gradient, lineWidth: 2.6)
                    .blur(radius: 7 + pulse * 3)
                    .opacity(0.78 + pulse * 0.22)
                // Crisp glow on the border itself.
                shape
                    .stroke(gradient, lineWidth: 1.3)
                    .opacity(0.85 + pulse * 0.15)
            }
            .brightness(isProcessing ? 0.12 + pulse * 0.12 : 0)
        }
    }

    // Slow 0...1 breathing curve (~2.9s period) used only while processing.
    private func breathe(_ date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return (sin(t * 2.2) + 1) / 2
    }

    // A seamless colorful ring: first and last colors match so the angular
    // gradient wraps without a visible seam.
    private var ringColors: [Color] {
        let primary = isEnglish
            ? Color(red: 0.66, green: 0.55, blue: 0.98)
            : Color(red: 0.36, green: 0.78, blue: 0.99)
        let secondary = isEnglish
            ? Color(red: 0.42, green: 0.62, blue: 1.0)
            : Color(red: 0.55, green: 0.64, blue: 0.99)
        let tertiary = isEnglish
            ? Color(red: 0.80, green: 0.55, blue: 1.0)
            : Color(red: 0.40, green: 0.92, blue: 0.95)
        return [primary, secondary, tertiary, secondary, primary]
    }
}

private struct WaveformView: View {
    let level: Float
    let isEnglish: Bool

    private static let cyanPalette: [Color] = [
        Color(red: 0.21, green: 0.78, blue: 0.99),
        Color(red: 0.29, green: 0.55, blue: 1.0),
        Color(red: 0.60, green: 0.48, blue: 1.0)
    ]
    private static let purplePalette: [Color] = [
        Color(red: 0.65, green: 0.55, blue: 1.0),
        Color(red: 0.49, green: 0.42, blue: 1.0),
        Color(red: 0.75, green: 0.38, blue: 0.94)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { graphics, size in
                draw(in: &graphics, size: size, time: time)
            }
            .frame(maxWidth: .infinity, maxHeight: 34)
        }
    }

    private func draw(
        in graphics: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        let palette = isEnglish ? Self.purplePalette : Self.cyanPalette
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: palette),
            startPoint: CGPoint(x: 0, y: size.height / 2),
            endPoint: CGPoint(x: size.width, y: size.height / 2)
        )
        let normalized = CGFloat(min(max(level, 0), 1))
        let glowRadius = 2.5 + normalized * 9

        var glowing = graphics
        glowing.addFilter(
            .shadow(color: palette[1].opacity(0.9), radius: glowRadius)
        )

        let steps = 48
        for index in WaveformDynamics.lines.indices {
            let line = WaveformDynamics.lines[index]
            var path = Path()
            for step in 0...steps {
                let p = Double(step) / Double(steps)
                let x = CGFloat(p) * size.width
                let y = size.height / 2 + WaveformDynamics.lineOffset(
                    lineIndex: index,
                    p: p,
                    time: time,
                    level: level,
                    height: size.height
                )
                if step == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            glowing.stroke(
                path,
                with: shading,
                style: StrokeStyle(
                    lineWidth: line.width,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }
}
