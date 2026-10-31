import CryptoKit
import Foundation

/// A recording loaded for comparison: its metadata and every decoded frame.
/// Recordings hold only the frames whose content changed, so even a few
/// seconds of animation fit in memory.
public struct Recording: Sendable {
    public var path: String
    public var sha256: String
    public var metadata: RecordingMetadata
    public var frames: [FrameImage]

    public init(path: String, sha256: String, metadata: RecordingMetadata, frames: [FrameImage]) {
        self.path = path
        self.sha256 = sha256
        self.metadata = metadata
        self.frames = frames
    }

    /// Loads `<name>.mov` and its `<name>.json`.
    public static func load(_ movie: URL) async throws -> Recording {
        let metadataURL = RecordingMetadata.url(forMovie: movie)
        let metadata: RecordingMetadata
        do {
            metadata = try RecordingMetadata.load(from: metadataURL)
        } catch {
            throw InvalidInput("cannot read \(metadataURL.path): \(error)")
        }
        let frames = try await MovieReader.readFrames(movie)
        guard frames.count == metadata.frameTimes.count else {
            throw InvalidInput("\(movie.path) has \(frames.count) frames but its metadata lists \(metadata.frameTimes.count)")
        }
        for frame in frames where frame.image.width != metadata.display.pixelWidth || frame.image.height != metadata.display.pixelHeight {
            throw InvalidInput("\(movie.path) has a \(frame.image.width)x\(frame.image.height) frame; metadata says \(metadata.display.pixelWidth)x\(metadata.display.pixelHeight)")
        }
        return Recording(path: movie.path, sha256: try sha256(of: movie), metadata: metadata, frames: frames.map(\.image))
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 24), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Timeline of this recording for the given threshold and mask.
    public func timeline(threshold: Int, mask: PixelMask?) throws(InvalidInput) -> Timeline {
        var fromBaseline = [Bool](repeating: false, count: frames.count)
        var fromPrevious = [Bool](repeating: false, count: frames.count)
        var anchorFound = false
        for i in 1..<max(1, frames.count) {
            fromPrevious[i] = PixelDiff.differs(frames[i], frames[i - 1], threshold: threshold, mask: mask)
            if !anchorFound {
                fromBaseline[i] = PixelDiff.differs(frames[i], frames[0], threshold: threshold, mask: mask)
                anchorFound = fromBaseline[i]
            }
        }
        return try Timing.timeline(
            frameTimes: metadata.frameTimes,
            differsFromBaseline: fromBaseline,
            differsFromPrevious: fromPrevious,
            triggerTime: metadata.trigger.time,
            stopTime: metadata.stopTime
        )
    }
}

public struct CompareParameters: Codable, Equatable, Sendable {
    public var pixelThreshold: Int
    public var maxRatio: Double
    public var masks: [PointRect]

    public init(pixelThreshold: Int, maxRatio: Double, masks: [PointRect]) {
        self.pixelThreshold = pixelThreshold
        self.maxRatio = maxRatio
        self.masks = masks
    }
}

public enum Comparison {
    /// Checks that two recordings can be compared at all.
    public static func validate(_ reference: Recording, _ candidate: Recording) throws(InvalidInput) {
        for recording in [reference, candidate] {
            if recording.metadata.droppedFrames > 0 {
                throw InvalidInput("\(recording.path) dropped \(recording.metadata.droppedFrames) frames")
            }
            if recording.frames.isEmpty {
                throw InvalidInput("\(recording.path) has no frames")
            }
        }
        let r = reference.metadata
        let c = candidate.metadata
        if r.display.pixelWidth != c.display.pixelWidth || r.display.pixelHeight != c.display.pixelHeight {
            throw InvalidInput("pixel sizes differ: \(r.display.pixelWidth)x\(r.display.pixelHeight) vs \(c.display.pixelWidth)x\(c.display.pixelHeight)")
        }
        if r.display.mode.scale != c.display.mode.scale {
            throw InvalidInput("scales differ: \(r.display.mode.scale) vs \(c.display.mode.scale)")
        }
        if r.display.mode.refreshRate != c.display.mode.refreshRate {
            throw InvalidInput("refresh rates differ: \(r.display.mode.refreshRate) vs \(c.display.mode.refreshRate)")
        }
        if r.capture.colorSpace != c.capture.colorSpace {
            throw InvalidInput("capture colour spaces differ: \(r.capture.colorSpace) vs \(c.capture.colorSpace)")
        }
        let scene = r.scene.differences(from: c.scene)
        if !scene.isEmpty {
            throw InvalidInput("scene conditions differ: \(scene.joined(separator: ", "))")
        }
    }

    /// Aligns both recordings at their anchors and compares them on the refresh grid.
    public static func compare(_ reference: Recording, _ candidate: Recording, parameters: CompareParameters) throws(InvalidInput) -> Report {
        try validate(reference, candidate)
        let mask = makeMask(parameters, reference)
        let threshold = parameters.pixelThreshold
        let referenceTimeline = try labelled("reference") { () throws(InvalidInput) in try reference.timeline(threshold: threshold, mask: mask) }
        let candidateTimeline = try labelled("candidate") { () throws(InvalidInput) in try candidate.timeline(threshold: threshold, mask: mask) }
        let period = 1 / Double(reference.metadata.display.mode.refreshRate)
        let range = Timing.sampleRange(
            referenceSpan: referenceTimeline.lastChangeTime - referenceTimeline.anchorTime,
            candidateSpan: candidateTimeline.lastChangeTime - candidateTimeline.anchorTime,
            period: period
        )
        let scale = reference.metadata.display.mode.scale
        var samples: [Report.Sample] = []
        for k in range {
            let offset = Double(k) * period
            // Both indices exist: k >= -1 and the frame before each anchor is displayed then.
            let r = Timing.frameIndex(at: referenceTimeline.anchorTime + offset, frameTimes: reference.metadata.frameTimes, period: period) ?? 0
            let c = Timing.frameIndex(at: candidateTimeline.anchorTime + offset, frameTimes: candidate.metadata.frameTimes, period: period) ?? 0
            let metrics = PixelDiff.measure(reference.frames[r], candidate.frames[c], threshold: threshold, mask: mask, scale: scale)
            func shiftedRatio(_ shift: Double) -> Double {
                let s = Timing.frameIndex(at: candidateTimeline.anchorTime + offset + shift, frameTimes: candidate.metadata.frameTimes, period: period) ?? 0
                return PixelDiff.measure(reference.frames[r], candidate.frames[s], threshold: threshold, mask: mask, scale: scale).overThresholdRatio
            }
            samples.append(Report.Sample(
                offset: k, time: offset, referenceFrame: r, candidateFrame: c, metrics: metrics,
                pass: metrics.overThresholdRatio <= parameters.maxRatio,
                ratioCandidateOneEarlier: shiftedRatio(-period), ratioCandidateOneLater: shiftedRatio(period)
            ))
        }
        let warnings =
            Timing.anchorWarning(timeline: referenceTimeline, label: "reference")
            + Timing.anchorWarning(timeline: candidateTimeline, label: "candidate")
            + Timing.intervalWarnings(frameTimes: reference.metadata.frameTimes, timeline: referenceTimeline, period: period, label: "reference")
            + Timing.intervalWarnings(frameTimes: candidate.metadata.frameTimes, timeline: candidateTimeline, period: period, label: "candidate")
        return Report(
            mode: .compare, reference: .init(reference), candidate: .init(candidate), parameters: parameters,
            referenceTimeline: referenceTimeline, candidateTimeline: candidateTimeline,
            samples: samples, warnings: warnings, pass: samples.allSatisfy(\.pass)
        )
    }

    /// Compares only the baseline frames (frame 0) of both recordings.
    public static func still(_ reference: Recording, _ candidate: Recording, parameters: CompareParameters) throws(InvalidInput) -> Report {
        try validate(reference, candidate)
        let mask = makeMask(parameters, reference)
        let metrics = PixelDiff.measure(
            reference.frames[0], candidate.frames[0], threshold: parameters.pixelThreshold, mask: mask,
            scale: reference.metadata.display.mode.scale
        )
        let sample = Report.Sample(
            offset: 0, time: 0, referenceFrame: 0, candidateFrame: 0, metrics: metrics,
            pass: metrics.overThresholdRatio <= parameters.maxRatio,
            ratioCandidateOneEarlier: nil, ratioCandidateOneLater: nil
        )
        return Report(
            mode: .still, reference: .init(reference), candidate: .init(candidate), parameters: parameters,
            referenceTimeline: nil, candidateTimeline: nil, samples: [sample], warnings: [], pass: sample.pass
        )
    }

    static func makeMask(_ parameters: CompareParameters, _ recording: Recording) -> PixelMask? {
        guard !parameters.masks.isEmpty else { return nil }
        return PixelMask(
            rects: parameters.masks, scale: recording.metadata.display.mode.scale,
            width: recording.metadata.display.pixelWidth, height: recording.metadata.display.pixelHeight
        )
    }

    private static func labelled<T>(_ label: String, _ body: () throws(InvalidInput) -> T) throws(InvalidInput) -> T {
        do {
            return try body()
        } catch {
            throw InvalidInput("\(label): \(error.description)")
        }
    }
}
