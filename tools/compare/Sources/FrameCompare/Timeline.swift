import Foundation

/// Why two recordings cannot be compared. Maps to exit status 2.
public struct InvalidInput: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Where a recording's change starts and ends.
public struct Timeline: Codable, Equatable, Sendable {
    /// First frame that differs from the baseline (frame 0) outside the mask.
    public var anchorFrame: Int
    public var anchorTime: Double
    /// Last frame that differs from the frame before it outside the mask.
    public var lastChangeFrame: Int
    public var lastChangeTime: Double
    /// Anchor time minus trigger time. Reported only; never used to align.
    public var latency: Double
    /// Stop time minus last change time.
    public var tail: Double
}

public enum Timing {
    /// A recording must keep running at least this long after its last change,
    /// so that "the screen has settled" is part of the recording.
    public static let minimumTail = 0.5

    /// Builds the timeline from per-frame change flags. `differsFromBaseline[i]`
    /// and `differsFromPrevious[i]` describe frame i (index 0 is the baseline
    /// itself and is ignored).
    public static func timeline(
        frameTimes: [Double],
        differsFromBaseline: [Bool],
        differsFromPrevious: [Bool],
        triggerTime: Double,
        stopTime: Double
    ) throws(InvalidInput) -> Timeline {
        guard let first = frameTimes.first, first < triggerTime else {
            throw InvalidInput("no baseline frame before the trigger")
        }
        guard let anchor = (1..<frameTimes.count).first(where: { differsFromBaseline[$0] }) else {
            throw InvalidInput("no change after the trigger")
        }
        let last = (1..<frameTimes.count).last(where: { differsFromPrevious[$0] }) ?? anchor
        let tail = stopTime - frameTimes[last]
        guard tail >= minimumTail else {
            throw InvalidInput(String(
                format: "recording stops %.3f s after its last change, less than %.1f s; record longer",
                tail, minimumTail
            ))
        }
        return Timeline(
            anchorFrame: anchor,
            anchorTime: frameTimes[anchor],
            lastChangeFrame: last,
            lastChangeTime: frameTimes[last],
            latency: frameTimes[anchor] - triggerTime,
            tail: tail
        )
    }

    /// The frame on screen at time `t`: the last frame displayed no later than
    /// `t + period / 2` (half a period absorbs jitter in display times).
    public static func frameIndex(at t: Double, frameTimes: [Double], period: Double) -> Int? {
        let limit = t + period / 2
        var low = 0
        var high = frameTimes.count
        while low < high {
            let mid = (low + high) / 2
            if frameTimes[mid] <= limit { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Sample offsets k (sample time = anchor + k · period): from one period
    /// before the anchor to one period after the later of the two last changes.
    public static func sampleRange(referenceSpan: Double, candidateSpan: Double, period: Double) -> ClosedRange<Int> {
        let span = max(referenceSpan, candidateSpan)
        let periods = Int((span / period - 1e-6).rounded(.up))
        return -1...(max(0, periods) + 1)
    }

    /// A warning when the anchor comes before the trigger: something other than
    /// the scene changed (for example the menu bar's recording indicator) and
    /// should be masked.
    public static func anchorWarning(timeline: Timeline, label: String) -> [String] {
        guard timeline.latency < 0 else { return [] }
        return [String(format: "%@ anchor %.1f ms before the trigger: something else changes on screen; mask it", label, -timeline.latency * 1000)]
    }

    /// Warnings for frame intervals between the anchor and the last change that
    /// are off the refresh grid or skip periods.
    public static func intervalWarnings(frameTimes: [Double], timeline: Timeline, period: Double, label: String) -> [String] {
        guard timeline.lastChangeFrame > timeline.anchorFrame else { return [] }
        var warnings: [String] = []
        for i in (timeline.anchorFrame + 1)...timeline.lastChangeFrame {
            let interval = frameTimes[i] - frameTimes[i - 1]
            let periods = interval / period
            let whole = periods.rounded()
            let ms = interval * 1000
            if abs(periods - whole) > 0.25 || whole < 1 {
                warnings.append(String(format: "%@ frame %d: interval %.3f ms is off the refresh grid", label, i, ms))
            } else if whole > 1 {
                warnings.append(String(format: "%@ frame %d: interval %.3f ms, %d refresh periods without a saved frame", label, i, ms, Int(whole) - 1))
            }
        }
        return warnings
    }

    /// Histogram of frame intervals in whole refresh periods; key -1 counts
    /// intervals off the grid.
    public static func intervalHistogram(frameTimes: [Double], period: Double) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        guard frameTimes.count > 1 else { return counts }
        for i in 1..<frameTimes.count {
            let periods = (frameTimes[i] - frameTimes[i - 1]) / period
            let whole = periods.rounded()
            let key = abs(periods - whole) > 0.25 || whole < 1 ? -1 : Int(whole)
            counts[key, default: 0] += 1
        }
        return counts
    }
}
