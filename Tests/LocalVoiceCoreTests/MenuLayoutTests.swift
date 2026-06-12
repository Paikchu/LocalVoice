import Foundation
import Testing
@testable import LocalVoiceCore

@Test func compactMenuUsesSelectedReferenceMetrics() {
    #expect(MenuLayout.width == 300)
    #expect(MenuLayout.headerHeight == 58)
    #expect(MenuLayout.modeRowHeight == 55)
    #expect(MenuLayout.footerHeight == 38)
    #expect(MenuLayout.horizontalPadding == 16)
}

@Test func floatingBarUsesCompactTranslucentMetrics() {
    #expect(FloatingBarLayout.width == 330)
    #expect(FloatingBarLayout.height == 184)
    #expect(FloatingBarLayout.contentWidth == 314)
    #expect(FloatingBarLayout.controlsHeight == 38)
    #expect(FloatingBarLayout.capsuleWidth == 168)
    #expect(FloatingBarLayout.buttonDiameter == 28)
    #expect(FloatingBarLayout.barCount == 13)
}

@Test func previewTextAreaClampsBetweenTwoAndFiveLines() {
    let twoLines = FloatingBarLayout.textAreaHeight(forLines: 2)
    let fiveLines = FloatingBarLayout.textAreaHeight(forLines: 5)

    let midpoint = (twoLines + fiveLines) / 2

    #expect(abs(FloatingBarLayout.clampedTextAreaHeight(0) - twoLines) < 0.001)
    #expect(abs(FloatingBarLayout.clampedTextAreaHeight(midpoint) - midpoint) < 0.001)
    #expect(abs(FloatingBarLayout.clampedTextAreaHeight(9_999) - fiveLines) < 0.001)
    #expect(twoLines < fiveLines)
}

@Test func waveformLinesStayFlatWhenIdleAndSwellWithVoice() {
    let height: CGFloat = 26

    #expect(WaveformDynamics.activeAmplitude(level: 0, height: height) == 0)
    #expect(
        WaveformDynamics.activeAmplitude(level: 0.8, height: height)
            > WaveformDynamics.activeAmplitude(level: 0.2, height: height)
    )

    let samples = stride(from: 0.0, through: 1.0, by: 0.05)
    let idlePeak = samples.map { p in
        abs(WaveformDynamics.lineOffset(
            lineIndex: 0, p: p, time: 1, level: 0, height: height
        ))
    }.max() ?? 0
    let voicePeak = samples.map { p in
        abs(WaveformDynamics.lineOffset(
            lineIndex: 0, p: p, time: 1, level: 0.9, height: height
        ))
    }.max() ?? 0

    // Idle stays within the small shimmer band; voice swings well beyond it.
    #expect(idlePeak <= WaveformDynamics.idleAmplitude + 0.001)
    #expect(voicePeak > 4)

    // Lines interleave: different lines diverge at the same horizontal point.
    let first = WaveformDynamics.lineOffset(
        lineIndex: 0, p: 0.5, time: 1, level: 0.9, height: height
    )
    let second = WaveformDynamics.lineOffset(
        lineIndex: 1, p: 0.5, time: 1, level: 0.9, height: height
    )
    #expect(first != second)
}
