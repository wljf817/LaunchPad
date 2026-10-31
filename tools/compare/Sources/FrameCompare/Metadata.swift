import Foundation

/// A display mode written as `<points wide>x<points high>@<scale>x<refresh Hz>`,
/// for example `1536x960@1x60`.
public struct DisplayMode: Codable, Equatable, Sendable, CustomStringConvertible {
    public var pointWidth: Int
    public var pointHeight: Int
    public var scale: Int
    public var refreshRate: Int

    public init(pointWidth: Int, pointHeight: Int, scale: Int, refreshRate: Int) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scale = scale
        self.refreshRate = refreshRate
    }

    public init?(_ text: String) {
        let size = text.split(separator: "@", omittingEmptySubsequences: false)
        guard size.count == 2 else { return nil }
        let points = size[0].split(separator: "x", omittingEmptySubsequences: false)
        let timing = size[1].split(separator: "x", omittingEmptySubsequences: false)
        guard points.count == 2, timing.count == 2,
              let w = Int(points[0]), let h = Int(points[1]),
              let s = Int(timing[0]), let r = Int(timing[1]),
              w > 0, h > 0, s > 0, r > 0
        else { return nil }
        self.init(pointWidth: w, pointHeight: h, scale: s, refreshRate: r)
    }

    public var pixelWidth: Int { pointWidth * scale }
    public var pixelHeight: Int { pointHeight * scale }
    public var description: String { "\(pointWidth)x\(pointHeight)@\(scale)x\(refreshRate)" }
}

/// The sidecar JSON written next to each recording (`<name>.mov` → `<name>.json`).
/// All times are seconds on the recording machine's monotonic clock (`CLOCK_UPTIME_RAW`,
/// the clock ScreenCaptureKit's display times use).
public struct RecordingMetadata: Codable, Equatable, Sendable {
    public struct System: Codable, Equatable, Sendable {
        public var productVersion: String
        public var buildVersion: String
        public var hardwareModel: String
        public init(productVersion: String, buildVersion: String, hardwareModel: String) {
            self.productVersion = productVersion
            self.buildVersion = buildVersion
            self.hardwareModel = hardwareModel
        }
    }

    public struct Display: Codable, Equatable, Sendable {
        public var mode: DisplayMode
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var colorSpaceName: String
        /// The recorded display's number and name; absent in takes recorded before the
        /// multi-display scenes.
        public var id: UInt32?
        public var name: String?
        public init(mode: DisplayMode, colorSpaceName: String, id: UInt32? = nil, name: String? = nil) {
            self.mode = mode
            self.pixelWidth = mode.pixelWidth
            self.pixelHeight = mode.pixelHeight
            self.colorSpaceName = colorSpaceName
            self.id = id
            self.name = name
        }
    }

    public struct Capture: Codable, Equatable, Sendable {
        public var colorSpace: String
        public var pixelFormat: String
        public var codec: String
        public init(colorSpace: String, pixelFormat: String, codec: String) {
            self.colorSpace = colorSpace
            self.pixelFormat = pixelFormat
            self.codec = codec
        }
    }

    /// Desktop conditions that must match between the two recordings of a scene.
    public struct Scene: Codable, Equatable, Sendable {
        public var appearance: String
        /// The user's preferred languages (`AppleLanguages`), as stored. Nil in
        /// recordings made before this field existed.
        public var languages: [String]?
        public var reduceTransparency: Bool
        public var reduceMotion: Bool
        public var increaseContrast: Bool
        public init(appearance: String, languages: [String]?, reduceTransparency: Bool, reduceMotion: Bool, increaseContrast: Bool) {
            self.appearance = appearance
            self.languages = languages
            self.reduceTransparency = reduceTransparency
            self.reduceMotion = reduceMotion
            self.increaseContrast = increaseContrast
        }

        /// The preferred languages as shown in messages.
        public var languagesDescription: String {
            languages.map { $0.joined(separator: ", ") } ?? "not recorded"
        }

        /// Names of the fields that differ from `other`. A recording without
        /// languages differs from one with them.
        public func differences(from other: Scene) -> [String] {
            var names: [String] = []
            if appearance != other.appearance { names.append("appearance (\(appearance) vs \(other.appearance))") }
            if languages != other.languages { names.append("languages (\(languagesDescription) vs \(other.languagesDescription))") }
            if reduceTransparency != other.reduceTransparency { names.append("reduceTransparency") }
            if reduceMotion != other.reduceMotion { names.append("reduceMotion") }
            if increaseContrast != other.increaseContrast { names.append("increaseContrast") }
            return names
        }
    }

    public struct Trigger: Codable, Equatable, Sendable {
        public var command: [String]
        public var time: Double
        public init(command: [String], time: Double) {
            self.command = command
            self.time = time
        }
    }

    public struct Git: Codable, Equatable, Sendable {
        public var commit: String
        public var dirty: Bool
        public init(commit: String, dirty: Bool) {
            self.commit = commit
            self.dirty = dirty
        }
    }

    public var tool: String
    public var system: System
    public var display: Display
    public var capture: Capture
    public var scene: Scene
    public var trigger: Trigger
    public var startTime: Double
    public var stopTime: Double
    /// Display time of every saved frame, in order. The movie's presentation
    /// times are these minus the first one.
    public var frameTimes: [Double]
    public var droppedFrames: Int
    /// Recordings of this project only.
    public var git: Git?
    /// Reference VM recordings only: whether Dock has frida-gadget mapped.
    public var dockFridaGadgetLoaded: Bool?

    public init(
        tool: String, system: System, display: Display, capture: Capture, scene: Scene,
        trigger: Trigger, startTime: Double, stopTime: Double, frameTimes: [Double],
        droppedFrames: Int, git: Git? = nil, dockFridaGadgetLoaded: Bool? = nil
    ) {
        self.tool = tool
        self.system = system
        self.display = display
        self.capture = capture
        self.scene = scene
        self.trigger = trigger
        self.startTime = startTime
        self.stopTime = stopTime
        self.frameTimes = frameTimes
        self.droppedFrames = droppedFrames
        self.git = git
        self.dockFridaGadgetLoaded = dockFridaGadgetLoaded
    }

    /// The metadata file that belongs to a movie.
    public static func url(forMovie movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("json")
    }

    public static func load(from url: URL) throws -> RecordingMetadata {
        try JSONDecoder().decode(RecordingMetadata.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .withoutOverwriting)
    }
}

public extension RecordingMetadata.Capture {
    /// What frame-record produces.
    static let standard = RecordingMetadata.Capture(colorSpace: "sRGB", pixelFormat: "BGRA8", codec: "ProRes 4444")
}
