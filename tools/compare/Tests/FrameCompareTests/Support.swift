import Foundation
@testable import FrameCompare

let testMode = DisplayMode(pointWidth: 8, pointHeight: 5, scale: 2, refreshRate: 60)
let period = 1.0 / 60

func solid(_ level: UInt8, mode: DisplayMode = testMode) -> FrameImage {
    FrameImage(width: mode.pixelWidth, height: mode.pixelHeight, blue: level, green: level, red: level)
}

func metadata(
    frameTimes: [Double],
    trigger: Double = 1.0,
    stop: Double? = nil,
    mode: DisplayMode = testMode,
    appearance: String = "light",
    languages: [String]? = ["zh-Hans-US", "en-US"],
    dropped: Int = 0
) -> RecordingMetadata {
    RecordingMetadata(
        tool: "test",
        system: .init(productVersion: "15.6.1", buildVersion: "24G90", hardwareModel: "VirtualMac2,1"),
        display: .init(mode: mode, colorSpaceName: "Test"),
        capture: .standard,
        scene: .init(appearance: appearance, languages: languages, reduceTransparency: false, reduceMotion: false, increaseContrast: false),
        trigger: .init(command: ["true"], time: trigger),
        startTime: 0,
        stopTime: stop ?? (frameTimes.last ?? 0) + 1,
        frameTimes: frameTimes,
        droppedFrames: dropped
    )
}

func recording(_ frames: [FrameImage], _ metadata: RecordingMetadata) -> Recording {
    Recording(path: "test.mov", sha256: "0", metadata: metadata, frames: frames)
}

/// A baseline at t = 0 (level 0), then one frame per period starting at
/// `start` with the given levels.
func animation(start: Double, levels: [UInt8], trigger: Double = 1.0, mode: DisplayMode = testMode, appearance: String = "light") -> Recording {
    var frames = [solid(0, mode: mode)]
    var times = [0.0]
    for (i, level) in levels.enumerated() {
        frames.append(solid(level, mode: mode))
        times.append(start + Double(i) * period)
    }
    return recording(frames, metadata(frameTimes: times, trigger: trigger, mode: mode, appearance: appearance))
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("frame-compare-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes frames as a ProRes movie with its metadata beside it.
func writeMovie(_ recording: Recording, to url: URL) async throws {
    let writer = try MovieWriter(url: url, width: recording.frames[0].width, height: recording.frames[0].height)
    let first = recording.metadata.frameTimes[0]
    for (frame, time) in zip(recording.frames, recording.metadata.frameTimes) {
        while !writer.isReady { try await Task.sleep(nanoseconds: 1_000_000) }
        guard let buffer = frame.makePixelBuffer(), writer.append(buffer, at: time - first) else {
            throw InvalidInput("append failed")
        }
    }
    try await writer.finish()
    try recording.metadata.write(to: RecordingMetadata.url(forMovie: url))
}
