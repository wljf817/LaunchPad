import Testing
@testable import FrameCompare

struct ComparisonTests {
    let loose = CompareParameters(pixelThreshold: 0, maxRatio: 0, masks: [])

    @Test func comparingARecordingWithItselfPasses() throws {
        let r = animation(start: 1.1, levels: [10, 20, 30, 40])
        let report = try Comparison.compare(r, r, parameters: loose)
        #expect(report.pass)
        #expect(report.samples.allSatisfy { $0.metrics.maxDelta == 0 })
        #expect(report.samples.first?.offset == -1)
        #expect(report.samples.last?.offset == 4)
    }

    @Test func differentTriggerLatencyAlignsToZeroDifference() throws {
        let reference = animation(start: 1.1, levels: [10, 20, 30, 40])
        let candidate = animation(start: 1.1 + 3 * period, levels: [10, 20, 30, 40])
        let report = try Comparison.compare(reference, candidate, parameters: loose)
        #expect(report.pass)
        #expect(report.samples.allSatisfy { $0.metrics.maxDelta == 0 })
        let latency = report.candidateTimeline!.latency - report.referenceTimeline!.latency
        #expect(abs(latency - 3 * period) < 1e-9)
    }

    @Test func unsavedFramesRepeatThePreviousFrame() throws {
        // The reference holds level 20 for 10 periods without saving frames;
        // the candidate saves every one of them.
        var frames = [solid(0), solid(10), solid(20), solid(30)]
        var times = [0.0, 1.1, 1.1 + period, 1.1 + 12 * period]
        let reference = recording(frames, metadata(frameTimes: times))
        frames = [solid(0), solid(10)] + Array(repeating: solid(20), count: 11) + [solid(30)]
        times = [0.0] + (0...12).map { 1.1 + Double($0) * period }
        let candidate = recording(frames, metadata(frameTimes: times))
        let report = try Comparison.compare(reference, candidate, parameters: loose)
        #expect(report.pass)
        #expect(report.samples.count == 15)
    }

    @Test func shorterCandidateIsSampledUntilTheReferenceSettles() throws {
        let reference = animation(start: 1.1, levels: [10, 20, 30, 40, 50, 60, 70, 80])
        let candidate = animation(start: 1.1, levels: [10, 20, 30, 80])
        let report = try Comparison.compare(reference, candidate, parameters: loose)
        #expect(report.samples.last?.offset == 8)
        #expect(!report.pass)
        // k = 3...6: the candidate already shows its end state, the reference does not.
        let failing = report.samples.filter { !$0.pass }.map(\.offset)
        #expect(failing == [3, 4, 5, 6])
    }

    @Test func maskedChangesAffectNeitherMetricsNorAnchor() throws {
        // A clock-like change inside the masked rect before the trigger.
        var clock = solid(0)
        clock.setPixel(x: 0, y: 0, blue: 255, green: 255, red: 255)
        let frames = [solid(0), clock, solid(10), solid(20)]
        let times = [0.0, 0.5, 1.1, 1.1 + period]
        let reference = recording(frames, metadata(frameTimes: times))
        let candidate = animation(start: 1.1, levels: [10, 20])
        let parameters = CompareParameters(pixelThreshold: 0, maxRatio: 0, masks: [PointRect(x: 0, y: 0, width: 1, height: 1)])
        let report = try Comparison.compare(reference, candidate, parameters: parameters)
        #expect(report.referenceTimeline?.anchorFrame == 2)
        #expect(report.pass)
    }

    @Test func timelineMasksFindTheTimelineButAreCompared() throws {
        // Levels 10, 20 from 1.1 s, then a pixel at (0, 0) that blinks until the end.
        func blinking(_ blinkOn: [Bool]) -> Recording {
            var frames = [solid(0), solid(10), solid(20)]
            var times = [0.0, 1.1, 1.1 + period]
            for (i, on) in blinkOn.enumerated() {
                var frame = solid(20)
                if on { frame.setPixel(x: 0, y: 0, blue: 255, green: 255, red: 255) }
                frames.append(frame)
                times.append(1.1 + Double(2 + i) * period)
            }
            return recording(frames, metadata(frameTimes: times, stop: times.last! + 0.4))
        }
        let reference = blinking([true, false, true, false, true, false, true, false])
        let candidate = blinking([false, true, false, true, false, true, false, true])
        let plain = CompareParameters(pixelThreshold: 0, maxRatio: 0, masks: [])
        #expect(throws: InvalidInput.self) { try Comparison.compare(reference, candidate, parameters: plain) }
        let timeline = [PointRect(x: 0, y: 0, width: 1, height: 1)]
        let parameters = CompareParameters(pixelThreshold: 0, maxRatio: 0, masks: [], timelineMasks: timeline)
        let report = try Comparison.compare(reference, candidate, parameters: parameters)
        #expect(report.referenceTimeline?.lastChangeFrame == 2)
        #expect(report.samples.map(\.offset) == [-1, 0, 1, 2])
        #expect(report.samples.map(\.metrics.overThresholdCount) == [0, 0, 0, 1])
        #expect(!report.pass)
    }

    @Test func oneSampleOverToleranceFails() throws {
        let reference = animation(start: 1.1, levels: [10, 20, 30])
        var candidate = reference
        candidate.frames[2].setPixel(x: 5, y: 5, blue: 0, green: 0, red: 0)
        let parameters = CompareParameters(pixelThreshold: 5, maxRatio: 0.5 / 160, masks: [])
        let report = try Comparison.compare(reference, candidate, parameters: parameters)
        #expect(!report.pass)
        #expect(report.samples.filter { !$0.pass }.map(\.offset) == [1])
        let tolerant = CompareParameters(pixelThreshold: 5, maxRatio: 1.0 / 160, masks: [])
        #expect(try Comparison.compare(reference, candidate, parameters: tolerant).pass)
    }

    @Test func invalidPairs() {
        let good = animation(start: 1.1, levels: [10])
        let otherSize = animation(start: 1.1, levels: [10], mode: DisplayMode(pointWidth: 8, pointHeight: 6, scale: 2, refreshRate: 60))
        let otherRate = animation(start: 1.1, levels: [10], mode: DisplayMode(pointWidth: 8, pointHeight: 5, scale: 2, refreshRate: 120))
        let dark = animation(start: 1.1, levels: [10], appearance: "dark")
        var dropped = good
        dropped.metadata.droppedFrames = 1
        let tooShort = recording(good.frames, metadata(frameTimes: good.metadata.frameTimes, stop: 1.5))
        let noChange = recording([solid(0), solid(0)], metadata(frameTimes: [0, 1.1]))
        for bad in [otherSize, otherRate, dark, dropped, tooShort, noChange] {
            #expect(throws: InvalidInput.self) { try Comparison.compare(good, bad, parameters: loose) }
        }
    }

    @Test func stillComparesOnlyBaselines() throws {
        let a = recording([solid(0)], metadata(frameTimes: [0]))
        var bFrame = solid(0)
        bFrame.setPixel(x: 1, y: 1, blue: 9, green: 9, red: 9)
        let b = recording([bFrame], metadata(frameTimes: [0]))
        let report = try Comparison.still(a, b, parameters: CompareParameters(pixelThreshold: 0, maxRatio: 1, masks: []))
        #expect(report.samples.count == 1)
        #expect(report.samples[0].metrics.boundingBox == PointRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(report.referenceTimeline == nil)
    }
}
