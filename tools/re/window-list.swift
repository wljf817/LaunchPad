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
//   window-list processes <seconds> <hz> <name>
//     Samples at <hz> for <seconds> and writes one JSON line per sample with t
//     and, for every running process whose name (proc_name) is <name>, its pid (proc_name gives at
//     most 31 characters: a longer <name> matches a process whose name is its first 31)
//     and every window it owns in the full list (kCGWindowListOptionAll): its
//     number, layer, alpha, bounds and whether it is on screen.
//
// t is CACurrentMediaTime() in seconds, the clock the Frida scripts in
// tools/re/frida/ record in the target process.

import AppKit
import CoreGraphics
import Darwin
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
    FileHandle.standardError.write("usage: window-list list [label] | sample <seconds> <hz> <pid> | processes <seconds> <hz> <name>\n".data(using: .utf8)!)
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
case "processes":
    guard args.count == 5, let seconds = Double(args[2]), let hz = Double(args[3]) else {
        FileHandle.standardError.write("usage: window-list processes <seconds> <hz> <name>\n".data(using: .utf8)!)
        exit(2)
    }
    let name = args[4]
    func pids() -> [Int32] {
        var buffer = [Int32](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var out: [Int32] = []
        var nameBuffer = [CChar](repeating: 0, count: 256)
        for pid in buffer.prefix(Int(max(count, 0))) where pid > 0 {
            if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0, String(cString: nameBuffer) == String(name.prefix(31)) {
                out.append(pid)
            }
        }
        return out.sorted()
    }
    let start = CACurrentMediaTime()
    var next = start
    while true {
        let t = CACurrentMediaTime()
        if t - start > seconds { break }
        let found = pids()
        let list = found.isEmpty ? [] : windows(.optionAll)
        var processes: [[String: Any]] = []
        for pid in found {
            var owned: [[String: Any]] = []
            for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
                owned.append([
                    "wid": w[kCGWindowNumber as String] ?? NSNull(),
                    "layer": w[kCGWindowLayer as String] ?? NSNull(),
                    "alpha": w[kCGWindowAlpha as String] ?? NSNull(),
                    "bounds": plain(w[kCGWindowBounds as String] ?? NSNull()),
                    "onScreen": w[kCGWindowIsOnscreen as String] ?? false,
                ])
            }
            processes.append(["pid": pid, "windows": owned])
        }
        print(json(["type": "processes", "t": t, "processes": processes]))
        fflush(stdout)
        next += 1.0 / hz
        let wait = next - CACurrentMediaTime()
        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
    }
default:
    FileHandle.standardError.write("unknown mode \(args[1])\n".data(using: .utf8)!)
    exit(2)
}
