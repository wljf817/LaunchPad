// Records one screen with ScreenCaptureKit for frame-by-frame comparison, and
// prepares the comparison scene. The same binary runs in the macOS 15
// reference VM and in the macOS 26 comparison VM, copied there over SSH.
//
// Needs the Screen Recording permission of the process that launches it: over
// SSH that is /usr/libexec/sshd-keygen-wrapper. Never needs sudo.

import AppKit
import CoreMedia
import FrameCompare
import Foundation
import ScreenCaptureKit

let usage = """
    usage: frame-record record --out <take.mov> --expect <WxH@Sx<Hz>> --pre-roll <s> --duration <s>
                               [--display <id>] [--match-scene <reference.json>]
                               [--git-commit <sha> [--git-dirty]] [--dock-gadget-loaded true|false]
                               -- <trigger command> [args...]
           frame-record displays
           frame-record wallpaper generate --size <WxH pixels> <out.png>
           frame-record wallpaper set <image.png> [--display <id>]
    record: records the whole screen (default: the main display) from the first frame,
    runs the trigger after --pre-roll seconds, stops --duration seconds after the trigger,
    and writes <take>.mov plus <take>.json. While recording, a 1 x 1 point window in the
    display's top right corner changes color in every refresh (the pacer); frames where only
    the pacer changed are not saved. Refuses when the display mode differs from
    --expect or the scene differs from --match-scene. Exits 1 if any frame was dropped.
    """

let version = "frame-record 5" // 2: the scene records the preferred languages; 3: half-period minimum frame interval; 4: the pacer; 5: frames where only the pacer changed left out

@MainActor
func listDisplays() {
    for info in screens() {
        print("display \(info.displayID): \(info.name), \(info.mode) (\(info.mode.pixelWidth)x\(info.mode.pixelHeight) px), \(info.colorSpaceName)\(info.isMain ? ", main" : "")")
    }
    let scene = sceneInfo()
    let auto = UserDefaults.standard.bool(forKey: "AppleInterfaceStyleSwitchesAutomatically") ? " (switches automatically)" : ""
    print("scene: \(scene.appearance)\(auto), languages \(scene.languagesDescription), reduceTransparency \(scene.reduceTransparency), reduceMotion \(scene.reduceMotion), increaseContrast \(scene.increaseContrast)")
}

func parseSize(_ text: String) -> (Int, Int)? {
    let parts = text.split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
    return (w, h)
}

@MainActor
func wallpaper(_ arguments: [String]) {
    switch arguments.first {
    case "generate":
        guard arguments.count == 4, arguments[1] == "--size", let (w, h) = parseSize(arguments[2]) else { fail(usage, status: 2) }
        do {
            // 72 dpi: one image pixel per point (and per pixel) on REF-ENV-004's 1x display.
            try PNGFile.write(Wallpaper.make(width: w, height: h), to: URL(fileURLWithPath: arguments[3]), dotsPerInch: 72)
        } catch {
            fail("\(error)")
        }
        print(arguments[3])
    case "set":
        guard arguments.count == 2 || (arguments.count == 4 && arguments[2] == "--display") else { fail(usage, status: 2) }
        let id = arguments.count == 4 ? CGDirectDisplayID(arguments[3]) : CGMainDisplayID()
        guard let id, let target = screen(id) else { fail("no display \(arguments.count == 4 ? arguments[3] : "main")") }
        let url = URL(fileURLWithPath: arguments[1])
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: target, options: [
                .imageScaling: NSNumber(value: NSImageScaling.scaleNone.rawValue),
                .allowClipping: NSNumber(value: true),
            ])
        } catch {
            fail("cannot set the wallpaper: \(error)")
        }
        print("display \(id): set \(url.path)")
    default:
        fail(usage, status: 2)
    }
}

struct RecordOptions {
    var out: URL?
    var expect: DisplayMode?
    var preRoll: Double?
    var duration: Double?
    var display: CGDirectDisplayID?
    var matchScene: URL?
    var gitCommit: String?
    var gitDirty = false
    var dockGadgetLoaded: Bool?
    var trigger: [String] = []
}

func parseRecord(_ arguments: [String]) -> RecordOptions {
    var options = RecordOptions()
    var rest = arguments[...]
    func value() -> String {
        guard let v = rest.popFirst() else { fail(usage, status: 2) }
        return v
    }
    while let argument = rest.popFirst() {
        switch argument {
        case "--out": options.out = URL(fileURLWithPath: value())
        case "--expect":
            guard let mode = DisplayMode(value()) else { fail("bad --expect; expected WxH@Sx<Hz>", status: 2) }
            options.expect = mode
        case "--pre-roll": options.preRoll = Double(value())
        case "--duration": options.duration = Double(value())
        case "--display": options.display = CGDirectDisplayID(value())
        case "--match-scene": options.matchScene = URL(fileURLWithPath: value())
        case "--git-commit": options.gitCommit = value()
        case "--git-dirty": options.gitDirty = true
        case "--dock-gadget-loaded":
            switch value() {
            case "true": options.dockGadgetLoaded = true
            case "false": options.dockGadgetLoaded = false
            default: fail("--dock-gadget-loaded takes true or false", status: 2)
            }
        case "--":
            options.trigger = Array(rest)
            rest = []
        default:
            fail("unknown argument \(argument)\n\(usage)", status: 2)
        }
    }
    guard options.out != nil, options.expect != nil, let preRoll = options.preRoll, let duration = options.duration,
          preRoll > 0, duration > 0, !options.trigger.isEmpty
    else { fail(usage, status: 2) }
    return options
}

@MainActor
func record(_ options: RecordOptions) async {
    let out = options.out!
    let metadataURL = RecordingMetadata.url(forMovie: out)
    let displayID = options.display ?? CGMainDisplayID()
    guard let info = screens().first(where: { $0.displayID == displayID }) else { fail("no display \(displayID)") }
    guard info.mode == options.expect! else {
        fail("display \(displayID) mode \(info.mode) does not match the expected \(options.expect!)")
    }
    // With automatic switching the appearance cannot be read reliably (the
    // default and the screen can disagree), so the scene would not be fixed.
    guard !UserDefaults.standard.bool(forKey: "AppleInterfaceStyleSwitchesAutomatically") else {
        fail("the appearance switches automatically; set it to Light or Dark in System Settings → Appearance")
    }
    let scene = sceneInfo()
    if let matchScene = options.matchScene {
        let reference: RecordingMetadata
        do {
            reference = try RecordingMetadata.load(from: matchScene)
        } catch {
            fail("cannot read \(matchScene.path): \(error)")
        }
        let differences = scene.differences(from: reference.scene)
        guard differences.isEmpty else {
            fail("scene differs from \(matchScene.path): \(differences.joined(separator: ", "))")
        }
    }
    guard !FileManager.default.fileExists(atPath: metadataURL.path) else { fail("\(metadataURL.path) already exists") }
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        fail("cannot list shareable content (Screen Recording permission?): \(error)")
    }
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        fail("ScreenCaptureKit does not list display \(displayID)")
    }
    let writer: MovieWriter
    do {
        writer = try MovieWriter(url: out, width: info.mode.pixelWidth, height: info.mode.pixelHeight)
    } catch {
        fail("\(error)")
    }
    // Shown before the stream starts, so that every frame has it (REF-ENV-005).
    guard let pacer = Pacer(display: displayID) else { fail("no display \(displayID)") }
    let configuration = SCStreamConfiguration()
    configuration.width = info.mode.pixelWidth
    configuration.height = info.mode.pixelHeight
    configuration.captureResolution = .best
    configuration.scalesToFit = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.colorSpaceName = CGColorSpace.sRGB
    // Half a refresh period. With exactly one period, ScreenCaptureKit skips a refresh every few
    // hundred milliseconds while the screen changes in every refresh (REF-ENV-005). Frames still come
    // at most once per refresh.
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(2 * info.mode.refreshRate))
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.queueDepth = 8
    // The pacer's point in pixels: the top right corner of the captured display.
    let scale = CGFloat(info.mode.scale)
    let recorder = Recorder(writer: writer, pacerRect: CGRect(x: CGFloat(info.mode.pixelWidth) - scale, y: 0, width: scale, height: scale))
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: recorder)
    do {
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
    } catch {
        fail("cannot start capturing: \(error)")
    }
    let startTime = now()

    // The first frame is the baseline; wait for it before the pre-roll.
    let deadline = Date().addingTimeInterval(5)
    while recorder.queue.sync(execute: { recorder.frameTimes.isEmpty }) {
        guard Date() < deadline else { fail("no frame within 5 s") }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    try? await Task.sleep(nanoseconds: UInt64(options.preRoll! * 1e9))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = options.trigger
    let triggerTime = now()
    do {
        try process.run()
    } catch {
        fail("cannot run the trigger: \(error)")
    }
    try? await Task.sleep(nanoseconds: UInt64(options.duration! * 1e9))
    let stopTime = now()
    recorder.queue.sync { recorder.stop() }
    do {
        try await stream.stopCapture()
    } catch {
        fail("cannot stop capturing: \(error)")
    }
    pacer.stop()
    let (frameTimes, dropped, streamError) = recorder.queue.sync { (recorder.frameTimes, recorder.dropped, recorder.streamError) }
    do {
        try await writer.finish()
    } catch {
        fail("\(error)")
    }
    process.waitUntilExit()

    let metadata = RecordingMetadata(
        tool: version,
        system: systemInfo(),
        display: .init(mode: info.mode, colorSpaceName: info.colorSpaceName, id: info.displayID, name: info.name),
        capture: .standard,
        scene: scene,
        trigger: .init(command: options.trigger, time: triggerTime),
        startTime: startTime,
        stopTime: stopTime,
        frameTimes: frameTimes,
        droppedFrames: dropped,
        git: options.gitCommit.map { RecordingMetadata.Git(commit: $0, dirty: options.gitDirty) },
        dockFridaGadgetLoaded: options.dockGadgetLoaded
    )
    do {
        try metadata.write(to: metadataURL)
    } catch {
        fail("cannot write \(metadataURL.path): \(error)")
    }
    print(out.path)
    if let streamError { fail("the stream stopped with an error: \(streamError)") }
    if dropped > 0 { fail("dropped \(dropped) frames; do not use this take") }
    if process.terminationStatus != 0 { fail("the trigger exited with status \(process.terminationStatus)") }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "record": await record(parseRecord(Array(arguments.dropFirst())))
case "displays": listDisplays()
case "wallpaper": wallpaper(Array(arguments.dropFirst()))
default: fail(usage, status: 2)
}
