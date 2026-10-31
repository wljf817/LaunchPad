// Prints the window server's managed spaces of every display (with the current and the active
// space) and, for every window on screen at or above <minLayer> (default 18), its number, owner,
// name, level, alpha, bounds and the spaces it belongs to (SLSCopySpacesForWindows, mask 7: every
// kind of space). One JSON line each. Used to record which space Launchpad's window, the menu bar
// and the status items belong to, on a desktop and in a full-screen app's space (REF-OVERLAY-006).
//
// Build on the host for a VM:
//   swiftc -O -target arm64-apple-macos15.0 -o window-spaces tools/re/window-spaces.swift
// Run in the VM over SSH: window-spaces [minLayer]
import AppKit
import CoreGraphics
import QuartzCore

typealias ConnFn = @convention(c) () -> Int32
typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64

let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
func sym<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(sl, name)!, to: T.self) }
let conn = sym("SLSMainConnectionID", ConnFn.self)()
let copyDisplaySpaces = sym("SLSCopyManagedDisplaySpaces", CopyDisplaySpacesFn.self)
let copySpacesForWindows = sym("SLSCopySpacesForWindows", CopySpacesForWindowsFn.self)
let activeSpace = sym("SLSGetActiveSpace", ActiveSpaceFn.self)

func json(_ obj: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
}

let minLayer = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 18 : 18
var displays: [[String: Any]] = []
for d in (copyDisplaySpaces(conn)?.takeRetainedValue() as? [[String: Any]]) ?? [] {
    let current = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] ?? NSNull()
    let spaces = ((d["Spaces"] as? [[String: Any]]) ?? []).map {
        ["id": $0["ManagedSpaceID"] ?? NSNull(), "type": $0["type"] ?? NSNull(), "uuid": $0["uuid"] ?? NSNull()]
    }
    displays.append(["display": d["Display Identifier"] ?? NSNull(), "current": current, "spaces": spaces])
}
print(json(["type": "spaces", "t": CACurrentMediaTime(), "active": activeSpace(conn), "displays": displays]))
let list = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
for (i, w) in list.enumerated() {
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    guard layer >= minLayer else { continue }
    let n = w[kCGWindowNumber as String] as? Int ?? 0
    let spaces = copySpacesForWindows(conn, 7, [n] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
    print(json([
        "type": "window", "onScreenIndex": i, "wid": n, "owner": w[kCGWindowOwnerName as String] ?? NSNull(),
        "pid": w[kCGWindowOwnerPID as String] ?? NSNull(), "name": w[kCGWindowName as String] ?? NSNull(),
        "layer": layer, "alpha": w[kCGWindowAlpha as String] ?? NSNull(),
        "bounds": (w[kCGWindowBounds as String] as? [String: Any]) ?? [:], "spaces": spaces,
    ]))
}
