import Foundation

public struct Report: Codable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case compare
        case still
    }

    public struct Input: Codable, Sendable {
        public var path: String
        public var sha256: String
        public var metadata: RecordingMetadata

        init(_ recording: Recording) {
            path = recording.path
            sha256 = recording.sha256
            metadata = recording.metadata
        }
    }

    public struct Sample: Codable, Sendable {
        /// k: the sample is taken k refresh periods after each anchor.
        public var offset: Int
        /// k · period, seconds.
        public var time: Double
        public var referenceFrame: Int
        public var candidateFrame: Int
        public var metrics: FrameMetrics
        public var pass: Bool
        /// Diagnostics only: the ratio with the candidate taken one period earlier / later.
        public var ratioCandidateOneEarlier: Double?
        public var ratioCandidateOneLater: Double?
        /// PNGs written for this sample, relative to the report directory.
        public var images: [String]?
    }

    public var mode: Mode
    public var reference: Input
    public var candidate: Input
    public var parameters: CompareParameters
    public var referenceTimeline: Timeline?
    public var candidateTimeline: Timeline?
    public var samples: [Sample]
    public var warnings: [String]
    public var pass: Bool

    static func sampleName(_ offset: Int) -> String {
        String(format: "%+04d", offset)
    }

    /// Writes `report.json`, `summary.txt` and, for every failing sample (every
    /// sample with `allFrames`), the reference frame, the candidate frame and
    /// the difference image under `frames/`. Existing files are never replaced.
    public mutating func write(to directory: URL, reference: Recording, candidate: Recording, allFrames: Bool) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let mask = Comparison.makeMask(parameters, reference)
        let framesDirectory = directory.appendingPathComponent("frames")
        for index in samples.indices where allFrames || !samples[index].pass {
            try fileManager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
            let sample = samples[index]
            let name = Report.sampleName(sample.offset)
            let a = reference.frames[sample.referenceFrame]
            let b = candidate.frames[sample.candidateFrame]
            let files = ["\(name)-reference.png", "\(name)-candidate.png", "\(name)-diff.png"]
            try PNGFile.write(a, to: framesDirectory.appendingPathComponent(files[0]))
            try PNGFile.write(b, to: framesDirectory.appendingPathComponent(files[1]))
            try PNGFile.write(
                DiffImage.make(a, b, threshold: parameters.pixelThreshold, mask: mask),
                to: framesDirectory.appendingPathComponent(files[2])
            )
            samples[index].images = files.map { "frames/\($0)" }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("report.json"), options: .withoutOverwriting)
        try Data(summary().utf8).write(to: directory.appendingPathComponent("summary.txt"), options: .withoutOverwriting)
    }

    public func summary() -> String {
        var lines: [String] = []
        lines.append("\(mode.rawValue): \(pass ? "PASS" : "FAIL")")
        lines.append("reference: \(reference.path)")
        lines.append("candidate: \(candidate.path)")
        let masks = parameters.masks.isEmpty ? "none" : parameters.masks.map(\.description).joined(separator: " ")
        lines.append("pixel threshold \(parameters.pixelThreshold), max ratio \(parameters.maxRatio), masks \(masks)")
        if !parameters.timelineMasks.isEmpty {
            lines.append("timeline masks \(parameters.timelineMasks.map(\.description).joined(separator: " "))")
        }
        for (label, timeline) in [("reference", referenceTimeline), ("candidate", candidateTimeline)] {
            guard let timeline else { continue }
            lines.append(String(
                format: "%@: anchor frame %d, latency %.1f ms, last change frame %d at +%.1f ms, tail %.1f ms",
                label, timeline.anchorFrame, timeline.latency * 1000, timeline.lastChangeFrame,
                (timeline.lastChangeTime - timeline.anchorTime) * 1000, timeline.tail * 1000
            ))
        }
        lines.append("")
        lines.append("    k   ref  cand     ratio    max    mean  result")
        for sample in samples {
            lines.append(String(
                format: "%5d %5d %5d  %8.6f  %5d  %6.3f  %@",
                sample.offset, sample.referenceFrame, sample.candidateFrame, sample.metrics.overThresholdRatio,
                sample.metrics.maxDelta, sample.metrics.meanDelta, sample.pass ? "pass" : "FAIL"
            ))
        }
        if !warnings.isEmpty {
            lines.append("")
            lines.append("warnings:")
            lines.append(contentsOf: warnings.map { "  \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
