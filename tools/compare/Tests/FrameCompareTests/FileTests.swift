import Foundation
import Testing
@testable import FrameCompare

/// Tests that write and read real files: movies, reports, PNGs and the CLI.
struct FileTests {
    /// A frame with gradients and saturated colours, so the round trip is not
    /// only tested on grey.
    func colourful(_ seed: Int) -> FrameImage {
        var image = solid(0)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let r = UInt8((x * 16 + seed * 7) % 256)
                let g = UInt8((y * 25 + seed * 13) % 256)
                let b = UInt8(((x + y) * 9 + seed * 31) % 256)
                image.setPixel(x: x, y: y, blue: b, green: g, red: r)
            }
        }
        image.setPixel(x: 0, y: 0, blue: 0, green: 0, red: 255)
        image.setPixel(x: 1, y: 0, blue: 255, green: 255, red: 255)
        return image
    }

    @Test func proResRoundTripIsNearlyLossless() async throws {
        let directory = try temporaryDirectory()
        let frames = (0..<4).map(colourful)
        let times = [0.0, 1.1, 1.1 + period, 1.1 + 3 * period]
        let original = recording(frames, metadata(frameTimes: times))
        let url = directory.appendingPathComponent("roundtrip.mov")
        try await writeMovie(original, to: url)
        let decoded = try await MovieReader.readFrames(url)
        #expect(decoded.count == 4)
        for (i, frame) in decoded.enumerated() {
            #expect(abs(frame.time - (times[i] - times[0])) < 1e-6)
            let m = PixelDiff.measure(frame.image, frames[i], threshold: 1, mask: nil, scale: 2)
            #expect(m.maxDelta <= 1, "frame \(i): max difference \(m.maxDelta)")
        }
        let loaded = try await Recording.load(url)
        #expect(loaded.metadata == original.metadata)
        #expect(loaded.sha256.count == 64)
    }

    @Test func reportFilesAndDiffColours() throws {
        let directory = try temporaryDirectory()
        let reference = animation(start: 1.1, levels: [10, 20])
        var candidate = reference
        candidate.frames[1].setPixel(x: 0, y: 3, blue: 255, green: 255, red: 255)
        let parameters = CompareParameters(pixelThreshold: 2, maxRatio: 0, masks: [PointRect(x: 6, y: 0, width: 2, height: 1)])
        var report = try Comparison.compare(reference, candidate, parameters: parameters)
        #expect(!report.pass)
        try report.write(to: directory, reference: reference, candidate: candidate, allFrames: false)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("report.json"))) as! [String: Any]
        for key in ["mode", "reference", "candidate", "parameters", "referenceTimeline", "candidateTimeline", "samples", "warnings", "pass"] {
            #expect(json[key] != nil, "missing \(key)")
        }
        let samples = json["samples"] as! [[String: Any]]
        let failing = samples.filter { ($0["pass"] as! Bool) == false }
        #expect(failing.count == 1)
        #expect((failing[0]["images"] as! [String]) == ["frames/+000-reference.png", "frames/+000-candidate.png", "frames/+000-diff.png"])
        let summary = try String(contentsOf: directory.appendingPathComponent("summary.txt"), encoding: .utf8)
        #expect(summary.hasPrefix("compare: FAIL"))

        let diff = try PNGFile.read(directory.appendingPathComponent("frames/+000-diff.png"))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * diff.width + x) * 4
            return Array(diff.pixels[i..<i + 3])
        }
        #expect(pixel(0, 3) == [0, 0, 255])    // over threshold: red
        #expect(pixel(12, 0) == [255, 0, 0])   // masked: blue
        #expect(pixel(5, 5) == [0, 0, 0])      // equal: black
        // Existing reports are never replaced.
        #expect(throws: (any Error).self) {
            try report.write(to: directory, reference: reference, candidate: candidate, allFrames: false)
        }
    }

    @Test func wallpaperIsDeterministic() throws {
        let directory = try temporaryDirectory()
        let a = directory.appendingPathComponent("a.png")
        let b = directory.appendingPathComponent("b.png")
        try PNGFile.write(Wallpaper.make(width: 360, height: 226), to: a, dotsPerInch: 144)
        try PNGFile.write(Wallpaper.make(width: 360, height: 226), to: b, dotsPerInch: 144)
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
        let image = try PNGFile.read(a)
        #expect(image.width == 360 && image.height == 226)
        #expect(image == Wallpaper.make(width: 360, height: 226))
    }

    @Test func commandExitStatuses() async throws {
        let directory = try temporaryDirectory()
        let reference = animation(start: 1.1, levels: [10, 20, 30])
        let late = animation(start: 1.1 + 3 * period, levels: [10, 20, 30])
        var off = reference
        off.frames[2] = solid(60)
        let otherSize = animation(start: 1.1, levels: [10, 20, 30], mode: DisplayMode(pointWidth: 8, pointHeight: 6, scale: 2, refreshRate: 60))
        var paths: [String: String] = [:]
        for (name, r) in [("reference", reference), ("late", late), ("off", off), ("size", otherSize)] {
            let url = directory.appendingPathComponent("\(name).mov")
            try await writeMovie(r, to: url)
            paths[name] = url.path
        }
        var output = ""
        func run(_ arguments: [String]) async -> CompareCommand.ExitStatus {
            await CompareCommand.run(arguments) { output += $0 + "\n" }
        }
        let common = ["--pixel-threshold", "2", "--max-ratio", "0"]
        #expect(await run(["compare", paths["reference"]!, paths["late"]!] + common + ["--out", directory.appendingPathComponent("r1").path]) == .pass)
        #expect(await run(["compare", paths["reference"]!, paths["off"]!] + common + ["--out", directory.appendingPathComponent("r2").path]) == .fail)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("r2/frames/+001-diff.png").path))
        #expect(await run(["compare", paths["reference"]!, paths["size"]!] + common + ["--out", directory.appendingPathComponent("r3").path]) == .invalid)
        #expect(await run(["compare", paths["reference"]!, paths["late"]!, "--max-ratio", "0", "--out", directory.path]) == .invalid)
        #expect(await run(["compare", paths["reference"]!, paths["late"]!, "--pixel-threshold", "256", "--max-ratio", "0", "--out", directory.path]) == .invalid)
        #expect(await run(["still", paths["reference"]!, paths["off"]!] + common + ["--out", directory.appendingPathComponent("r4").path]) == .pass)
        output = ""
        #expect(await run(["inspect", paths["late"]!, "--pixel-threshold", "2"]) == .pass)
        #expect(output.contains("anchor: frame 1"))
        #expect(output.contains("1T: 2"))
    }

    @Test func parseRequiresThresholdRatioAndOut() throws {
        #expect(throws: InvalidInput.self) { try CompareCommand.parse(["compare", "a", "b", "--max-ratio", "0", "--out", "o"]) }
        #expect(throws: InvalidInput.self) { try CompareCommand.parse(["compare", "a", "b", "--pixel-threshold", "0", "--out", "o"]) }
        #expect(throws: InvalidInput.self) { try CompareCommand.parse(["compare", "a", "b", "--pixel-threshold", "0", "--max-ratio", "0"]) }
        #expect(throws: InvalidInput.self) { try CompareCommand.parse(["compare", "a", "--pixel-threshold", "0", "--max-ratio", "0", "--out", "o"]) }
        #expect(throws: InvalidInput.self) { try CompareCommand.parse(["frobnicate"]) }
        #expect(throws: InvalidInput.self) { try CompareCommand.parse(["inspect", "a", "--pixel-threshold", "0", "--mask", "1,2,3"]) }
        #expect(try CompareCommand.parse(["inspect", "a", "--pixel-threshold", "3", "--mask", "0,0,10,24"]).masks == [PointRect(x: 0, y: 0, width: 10, height: 24)])
    }

    @Test func recordedDisplayIdentity() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var m = metadata(frameTimes: [0, 1])
        m.display = .init(mode: testMode, colorSpaceName: "Test", id: 3, name: "LaunchPad Virtual Display")
        try m.write(to: url)
        let loaded = try RecordingMetadata.load(from: url)
        #expect(loaded.display.id == 3)
        #expect(loaded.display.name == "LaunchPad Virtual Display")
        // Takes recorded before the field existed have neither.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var display = json["display"] as! [String: Any]
        display["id"] = nil
        display["name"] = nil
        json["display"] = display
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let old = try RecordingMetadata.load(from: url)
        #expect(old.display.id == nil)
        #expect(old.display.name == nil)
    }
}
