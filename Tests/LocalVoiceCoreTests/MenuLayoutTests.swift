import Foundation
import Testing
@testable import LocalVoiceCore

@Test func compactMenuUsesSelectedReferenceMetrics() {
    #expect(MenuLayout.width == 200)
    #expect(MenuLayout.nativeRowHeight == 34)
    #expect(MenuLayout.footerHeight == 32)
    #expect(MenuLayout.closedContentHeight == 168)
    #expect(MenuLayout.horizontalPadding == 14)
    #expect(MenuLayout.settingsSectionSpacing == 8)
    #expect(MenuLayout.settingsSectionVerticalPadding == 8)
}

@Test func floatingBarUsesCompactTranslucentMetrics() {
    #expect(FloatingBarLayout.width == 330)
    #expect(FloatingBarLayout.height == 184)
    #expect(FloatingBarLayout.contentWidth == 314)
    #expect(FloatingBarLayout.controlsHeight == 38)
    #expect(FloatingBarLayout.capsuleWidth == 184)
    #expect(FloatingBarLayout.buttonDiameter == 28)
    #expect(FloatingBarLayout.barCount == 13)
}

@Test func processingProgressUsesStablePhaseRanges() {
    #expect(ProcessingProgress.finalizing.fraction == 0.06)
    #expect(ProcessingProgress.preparing.fraction == 0.14)
    #expect(ProcessingProgress.validating.fraction == 0.92)
    #expect(ProcessingProgress.inserting.fraction == 0.97)
    #expect(ProcessingProgress.completed.fraction == 1)
}

@Test func generationProgressAdvancesWithoutCompletingEarly() {
    let start = ProcessingProgress.generating(
        outputCharacters: 0,
        estimatedCharacters: 200,
        attempt: 1
    )
    let midpoint = ProcessingProgress.generating(
        outputCharacters: 100,
        estimatedCharacters: 200,
        attempt: 1
    )
    let oversized = ProcessingProgress.generating(
        outputCharacters: 1_000,
        estimatedCharacters: 200,
        attempt: 1
    )
    let retry = ProcessingProgress.generating(
        outputCharacters: 0,
        estimatedCharacters: 200,
        attempt: 2
    )
    let completedRetry = ProcessingProgress.generating(
        outputCharacters: 1_000,
        estimatedCharacters: 200,
        attempt: 2
    )

    #expect(start.fraction == 0.18)
    #expect(midpoint.fraction > start.fraction)
    #expect(abs(oversized.fraction - 0.82) < 0.001)
    #expect(retry.fraction >= midpoint.fraction)
    #expect(abs(retry.fraction - oversized.fraction) < 0.001)
    #expect(abs(completedRetry.fraction - 0.88) < 0.001)
    #expect(completedRetry.fraction < ProcessingProgress.validating.fraction)
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

@Test func previewPaginationKeepsEveryCharacterAcrossPages() {
    let text = " " + String(repeating: "本次测试会持续输入较长内容", count: 8) + "\n"
    let pages = PreviewPagination.pages(for: text, charactersPerPage: 20)

    #expect(pages.count > 1)
    #expect(pages.joined() == text)
    #expect(pages.dropLast().allSatisfy { $0.count <= 20 })
}

@Test func previewPaginationFollowsLiveTailUnlessUserPagedBack() {
    let currentTail = PreviewPagination.pageIndexAfterTextChange(
        currentIndex: 1,
        previousPageCount: 2,
        newPageCount: 4
    )
    let userPagedBack = PreviewPagination.pageIndexAfterTextChange(
        currentIndex: 0,
        previousPageCount: 2,
        newPageCount: 4
    )

    #expect(currentTail == 3)
    #expect(userPagedBack == 0)
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
