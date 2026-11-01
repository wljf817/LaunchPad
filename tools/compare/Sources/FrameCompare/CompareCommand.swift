import Foundation

/// The `frame-compare` command line. Lives in the library so tests can run it.
public enum CompareCommand {
    public enum ExitStatus: Int32, Sendable {
        case pass = 0
        case fail = 1
        case invalid = 2
    }

    public static let usage = """
        usage: frame-compare compare <reference.mov> <candidate.mov> --pixel-threshold <0-255> --max-ratio <0-1> [--mask x,y,w,h]... [--timeline-mask x,y,w,h]... --out <dir> [--all-frames]
               frame-compare still   <reference.mov> <candidate.mov> --pixel-threshold <0-255> --max-ratio <0-1> [--mask x,y,w,h]... --out <dir> [--all-frames]
               frame-compare inspect <recording.mov> --pixel-threshold <0-255> [--mask x,y,w,h]...
        Masks are rectangles in points, origin at the top left. A timeline mask is masked only when finding
        the anchor and the last change, not when comparing. Each .mov needs its .json beside it.
        Exit status: 0 pass, 1 fail, 2 invalid input.
        """

    struct Options: Equatable {
        var subcommand: String
        var paths: [String] = []
        var pixelThreshold: Int?
        var maxRatio: Double?
        var masks: [PointRect] = []
        var timelineMasks: [PointRect] = []
        var out: String?
        var allFrames = false
    }

    static func parse(_ arguments: [String]) throws(InvalidInput) -> Options {
        guard let subcommand = arguments.first, ["compare", "still", "inspect"].contains(subcommand) else {
            throw InvalidInput("missing or unknown subcommand")
        }
        var options = Options(subcommand: subcommand)
        var rest = arguments.dropFirst()
        func value(_ flag: String) throws(InvalidInput) -> String {
            guard let v = rest.popFirst() else { throw InvalidInput("\(flag) needs a value") }
            return v
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--pixel-threshold":
                guard let n = Int(try value(argument)), (0...255).contains(n) else {
                    throw InvalidInput("--pixel-threshold must be an integer from 0 to 255")
                }
                options.pixelThreshold = n
            case "--max-ratio":
                guard let r = Double(try value(argument)), (0...1).contains(r) else {
                    throw InvalidInput("--max-ratio must be a number from 0 to 1")
                }
                options.maxRatio = r
            case "--mask":
                let text = try value(argument)
                guard let rect = PointRect(text) else { throw InvalidInput("bad --mask \(text); expected x,y,w,h") }
                options.masks.append(rect)
            case "--timeline-mask":
                let text = try value(argument)
                guard let rect = PointRect(text) else { throw InvalidInput("bad --timeline-mask \(text); expected x,y,w,h") }
                options.timelineMasks.append(rect)
            case "--out":
                options.out = try value(argument)
            case "--all-frames":
                options.allFrames = true
            default:
                if argument.hasPrefix("--") { throw InvalidInput("unknown option \(argument)") }
                options.paths.append(argument)
            }
        }
        let pathCount = subcommand == "inspect" ? 1 : 2
        guard options.paths.count == pathCount else { throw InvalidInput("\(subcommand) takes \(pathCount) recording(s)") }
        guard options.pixelThreshold != nil else { throw InvalidInput("--pixel-threshold is required") }
        if subcommand != "inspect" {
            guard options.maxRatio != nil else { throw InvalidInput("--max-ratio is required") }
            guard options.out != nil else { throw InvalidInput("--out is required") }
        }
        return options
    }

    /// Runs the command and returns its exit status. Output goes to `print`.
    public static func run(_ arguments: [String], print: (String) -> Void = { Swift.print($0) }) async -> ExitStatus {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            print("frame-compare: \(error.description)\n\(usage)")
            return .invalid
        }
        do {
            if options.subcommand == "inspect" {
                let recording = try await Recording.load(URL(fileURLWithPath: options.paths[0]))
                print(inspect(recording, threshold: options.pixelThreshold!, masks: options.masks))
                return .pass
            }
            let reference = try await Recording.load(URL(fileURLWithPath: options.paths[0]))
            let candidate = try await Recording.load(URL(fileURLWithPath: options.paths[1]))
            let parameters = CompareParameters(
                pixelThreshold: options.pixelThreshold!, maxRatio: options.maxRatio!, masks: options.masks,
                timelineMasks: options.timelineMasks
            )
            var report = options.subcommand == "compare"
                ? try Comparison.compare(reference, candidate, parameters: parameters)
                : try Comparison.still(reference, candidate, parameters: parameters)
            try report.write(to: URL(fileURLWithPath: options.out!), reference: reference, candidate: candidate, allFrames: options.allFrames)
            print(report.summary())
            return report.pass ? .pass : .fail
        } catch let error as InvalidInput {
            print("frame-compare: invalid input: \(error.description)")
            return .invalid
        } catch {
            print("frame-compare: invalid input: \(error)")
            return .invalid
        }
    }

    static func inspect(_ recording: Recording, threshold: Int, masks: [PointRect]) -> String {
        let m = recording.metadata
        let period = 1 / Double(m.display.mode.refreshRate)
        var lines = [
            "recording: \(recording.path)",
            "sha256: \(recording.sha256)",
            "tool: \(m.tool)",
            "system: macOS \(m.system.productVersion) (\(m.system.buildVersion)), \(m.system.hardwareModel)",
            "display: \(m.display.mode) (\(m.display.pixelWidth)x\(m.display.pixelHeight) px), \(m.display.colorSpaceName)"
                + (m.display.id.map { ", display \($0) \(m.display.name ?? "")" } ?? ""),
            "capture: \(m.capture.colorSpace), \(m.capture.pixelFormat), \(m.capture.codec)",
            "scene: \(m.scene.appearance), languages \(m.scene.languagesDescription), reduceTransparency \(m.scene.reduceTransparency), reduceMotion \(m.scene.reduceMotion), increaseContrast \(m.scene.increaseContrast)",
            "trigger: \(m.trigger.command.joined(separator: " ")) at +\(String(format: "%.3f", m.trigger.time - m.startTime)) s",
            "duration: \(String(format: "%.3f", m.stopTime - m.startTime)) s",
            "frames: \(recording.frames.count), dropped \(m.droppedFrames)",
        ]
        if let git = m.git { lines.append("git: \(git.commit)\(git.dirty ? " (dirty)" : "")") }
        if let loaded = m.dockFridaGadgetLoaded { lines.append("Dock has frida-gadget loaded: \(loaded)") }
        let histogram = Timing.intervalHistogram(frameTimes: m.frameTimes, period: period)
        let intervals = histogram.keys.sorted().map { key in
            "\(key == -1 ? "off-grid" : "\(key)T"): \(histogram[key]!)"
        }
        lines.append("frame intervals (T = \(String(format: "%.3f", period * 1000)) ms): \(intervals.isEmpty ? "none" : intervals.joined(separator: ", "))")
        let mask = masks.isEmpty ? nil : PixelMask(rects: masks, scale: m.display.mode.scale, width: m.display.pixelWidth, height: m.display.pixelHeight)
        lines.append("changes from the previous frame (time from the first frame; box in points):")
        for i in 1..<max(1, recording.frames.count) {
            let metrics = PixelDiff.measure(recording.frames[i], recording.frames[i - 1], threshold: threshold, mask: mask, scale: m.display.mode.scale)
            let box = metrics.boundingBox.map { String(format: "%.1f,%.1f,%.1f,%.1f", $0.x, $0.y, $0.width, $0.height) } ?? "none"
            lines.append(String(
                format: "  frame %d +%.1f ms: %d px over threshold, max %d, box %@",
                i, (m.frameTimes[i] - m.frameTimes[0]) * 1000, metrics.overThresholdCount, metrics.maxDelta, box
            ))
        }
        do {
            let t = try recording.timeline(threshold: threshold, mask: mask)
            lines.append(String(
                format: "anchor: frame %d, latency %.1f ms; last change: frame %d, %.1f ms after the anchor; tail %.1f ms",
                t.anchorFrame, t.latency * 1000, t.lastChangeFrame, (t.lastChangeTime - t.anchorTime) * 1000, t.tail * 1000
            ))
            lines.append(contentsOf: Timing.anchorWarning(timeline: t, label: "warning:"))
            lines.append(contentsOf: Timing.intervalWarnings(frameTimes: m.frameTimes, timeline: t, period: period, label: "warning:"))
        } catch {
            lines.append("not usable for compare: \(error.description)")
        }
        return lines.joined(separator: "\n")
    }
}
