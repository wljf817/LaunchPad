import Testing
@testable import FrameCompare

struct TimingTests {
    @Test func frameOnScreenIsTheLastOneDisplayed() {
        let times = [0.0, 1.0, 1.0 + 10 * period]
        // Ten periods without a saved frame: the frame before the gap stays on screen.
        for k in 0..<10 {
            #expect(Timing.frameIndex(at: 1.0 + Double(k) * period, frameTimes: times, period: period) == 1)
        }
        #expect(Timing.frameIndex(at: 1.0 + 10 * period, frameTimes: times, period: period) == 2)
        #expect(Timing.frameIndex(at: -1, frameTimes: times, period: period) == nil)
    }

    @Test func jitterWithinHalfAPeriodDoesNotChangeTheSample() {
        let times = [0.0, 1.0 + 0.4 * period, 1.0 + period - 0.4 * period]
        #expect(Timing.frameIndex(at: 1.0, frameTimes: times, period: period) == 1)
        #expect(Timing.frameIndex(at: 1.0 + period, frameTimes: times, period: period) == 2)
    }

    @Test func timelineFindsAnchorAndLastChange() throws {
        let times = [0.0, 1.1, 1.1 + period, 1.1 + 2 * period]
        let t = try Timing.timeline(
            frameTimes: times,
            differsFromBaseline: [false, true, false, false],
            differsFromPrevious: [false, true, true, false],
            triggerTime: 1.0, stopTime: 3.0
        )
        #expect(t.anchorFrame == 1)
        #expect(t.lastChangeFrame == 2)
        #expect(abs(t.latency - 0.1) < 1e-9)
    }

    @Test func invalidTimelines() {
        let times = [0.0, 1.1]
        #expect(throws: InvalidInput.self) {
            try Timing.timeline(frameTimes: times, differsFromBaseline: [false, true], differsFromPrevious: [false, true], triggerTime: 0, stopTime: 3)
        }
        #expect(throws: InvalidInput.self) {
            try Timing.timeline(frameTimes: times, differsFromBaseline: [false, false], differsFromPrevious: [false, false], triggerTime: 1, stopTime: 3)
        }
        #expect(throws: InvalidInput.self) {
            try Timing.timeline(frameTimes: times, differsFromBaseline: [false, true], differsFromPrevious: [false, true], triggerTime: 1, stopTime: 1.1 + 0.499)
        }
    }

    @Test func samplesRunToOnePeriodAfterTheLaterLastChange() {
        #expect(Timing.sampleRange(referenceSpan: 15 * period, candidateSpan: 10 * period, period: period) == -1...16)
        #expect(Timing.sampleRange(referenceSpan: 0, candidateSpan: 0, period: period) == -1...1)
    }

    @Test func intervalWarnings() {
        let times = [0.0, 1.0, 1.0 + period, 1.0 + 3 * period, 1.0 + 3.5 * period]
        let timeline = Timeline(anchorFrame: 1, anchorTime: 1, lastChangeFrame: 4, lastChangeTime: times[4], latency: 0, tail: 1)
        let warnings = Timing.intervalWarnings(frameTimes: times, timeline: timeline, period: period, label: "x")
        #expect(warnings.count == 2)
        #expect(warnings[0].contains("frame 3") && warnings[0].contains("1 refresh periods"))
        #expect(warnings[1].contains("frame 4") && warnings[1].contains("off the refresh grid"))
    }

    @Test func anchorBeforeTriggerWarns() {
        let early = Timeline(anchorFrame: 1, anchorTime: 0.9, lastChangeFrame: 1, lastChangeTime: 0.9, latency: -0.1, tail: 1)
        #expect(Timing.anchorWarning(timeline: early, label: "x").count == 1)
        let late = Timeline(anchorFrame: 1, anchorTime: 1.1, lastChangeFrame: 1, lastChangeTime: 1.1, latency: 0.1, tail: 1)
        #expect(Timing.anchorWarning(timeline: late, label: "x").isEmpty)
    }

    @Test func displayModeParsing() {
        #expect(DisplayMode("1800x1130@2x60") == DisplayMode(pointWidth: 1800, pointHeight: 1130, scale: 2, refreshRate: 60))
        #expect(DisplayMode("1800x1130@2x60")?.description == "1800x1130@2x60")
        #expect(DisplayMode("1800x1130") == nil)
        #expect(DisplayMode("1800x1130@0x60") == nil)
    }

    @Test func secondDisplayModeCheck() {
        // REF-ENV-004 is what --expect asks for; the second display's alternate mode
        // (REF-ENV-009) must not pass the check frame-record makes before recording.
        let expected = DisplayMode("1536x960@1x60")
        #expect(DisplayMode(pointWidth: 1536, pointHeight: 960, scale: 1, refreshRate: 60) == expected)
        #expect(DisplayMode(pointWidth: 1280, pointHeight: 800, scale: 1, refreshRate: 60) != expected)
    }

}
