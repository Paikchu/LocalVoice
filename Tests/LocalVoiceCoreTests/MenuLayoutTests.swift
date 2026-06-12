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
    #expect(FloatingBarLayout.width == 196)
    #expect(FloatingBarLayout.height == 46)
    #expect(FloatingBarLayout.buttonDiameter == 34)
    #expect(FloatingBarLayout.barCount == 13)
}

@Test func waveformRespondsToVoiceLevelWithoutIdleJitter() {
    let idle = WaveformDynamics.heights(level: 0.01, phase: 1)
    let voice = WaveformDynamics.heights(level: 0.8, phase: 1)

    #expect(Set(idle).count == 1)
    #expect(voice.max()! > idle.max()!)
    #expect(Set(voice).count > 4)
}
