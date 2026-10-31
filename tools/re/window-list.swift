// List and sample the window server's window list, to record how the macOS 15
// Launchpad's window, the Dock and the menu bar are stacked (reference VM).
// Uses only public API: CGWindowListCopyWindowInfo and NSWorkspace.
//
// Build on the host for the VM:
//   swiftc -O -target arm64-apple-macos15.0 -o window-list tools/re/window-list.swift
// Run in the VM over SSH (the SSH session can talk to the window server).
//
// Usage:
//   window-list list [label]
//     One JSON line "header" (t, label, frontmost and menu-bar-owning
//     application), then one JSON line per window of the full list
//     (kCGWindowListOptionAll) in the window server's order, front to back,
//     with index, onScreenIndex (position in the on-screen list, front to
//     back, or null) and every key of the window's dictionary.
//   window-list sample <seconds> <hz> <pid>
//     Samples the on-screen list at <hz> for <seconds> and writes one JSON
//     line per sample with t and, for every on-screen window owned by <pid>,
//     its number, layer, alpha, bounds and on-screen index.
//
// t is CACurrentMediaTime() in seconds, the clock the Frida scripts in
// tools/re/frida/ record in the target process.

import AppKit
import CoreGraphics
import QuartzCore

func json(_ obj: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func plain(_ v: Any) -> Any {
    if let d = v as? [String: Any] { return d.mapValues(plain) }
    if let a = v as? [Any] { return a.map(plain) }
    if let n = v as? NSNumber { return n }
    if let s = v as? String { return s }
    return String(describing: v)
}

func windows(_ option: CGWindowListOption) -> [[String: Any]] {
    (CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]]) ?? []
}

func app(_ a: NSRunningApplication?) -> Any {
    guard let a else { return NSNull() }
    return [
        "pid": a.processIdentifier,
        "bundleIdentifier": a.bundleIdentifier.map { $0 as Any } ?? NSNull(),
        "name": a.localizedName.map { $0 as Any } ?? NSNull(),
    ] as [String: Any]
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: window-list list [label] | sample <seconds> <hz> <pid>\n".data(using: .utf8)!)
    exit(2)
}

switch args[1] {
case "list":
    let t = CACurrentMediaTime()
    let all = windows(.optionAll)
    let onScreen = windows(.optionOnScreenOnly).compactMap { $0[kCGWindowNumber as String] as? Int }
    let ws = NSWorkspace.shared
    print(json([
        "type": "header", "t": t, "label": args.count > 2 ? args[2] as Any : NSNull() as Any,
        "frontmostApplication": app(ws.frontmostApplication),
        "menuBarOwningApplication": app(ws.menuBarOwningApplication),
        "count": all.count,
    ]))
    for (i, w) in all.enumerated() {
        var rec = w.mapValues(plain)
        rec["type"] = "window"
        rec["index"] = i
        let n = w[kCGWindowNumber as String] as? Int ?? -1
        rec["onScreenIndex"] = onScreen.firstIndex(of: n) ?? NSNull()
        print(json(rec))
    }
case "sample":
    guard args.count == 5, let seconds = Double(args[2]), let hz = Double(args[3]), let pid = Int(args[4]) else {
        FileHandle.standardError.write("usage: window-list sample <seconds> <hz> <pid>\n".data(using: .utf8)!)
        exit(2)
    }
    let start = CACurrentMediaTime()
    var next = start
    while true {
        let t = CACurrentMediaTime()
        if t - start > seconds { break }
        let list = windows(.optionOnScreenOnly)
        var out: [[String: Any]] = []
        for (i, w) in list.enumerated() where (w[kCGWindowOwnerPID as String] as? Int) == pid {
            out.append([
                "wid": w[kCGWindowNumber as String] ?? NSNull(),
                "layer": w[kCGWindowLayer as String] ?? NSNull(),
                "alpha": w[kCGWindowAlpha as String] ?? NSNull(),
                "bounds": plain(w[kCGWindowBounds as String] ?? NSNull()),
                "onScreenIndex": i,
            ])
        }
        print(json(["type": "sample", "t": t, "windows": out]))
        next += 1.0 / hz
        let wait = next - CACurrentMediaTime()
        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
    }
default:
    FileHandle.standardError.write("unknown mode \(args[1])\n".data(using: .utf8)!)
    exit(2)
}
