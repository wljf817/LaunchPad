// Print what a process other than Dock can read about the Dock: the CoreDock
// functions of HIServices (looked up with dlsym; private), the Dock's windows in
// the window list, and the main screen's frame, visible frame, safe area and
// auxiliary areas. Used to compare with the Dock state Launchpad reads inside
// Dock (REF-DEV-019, REF-DEV-020).
//
// Build on the host for the VMs:
//   swiftc -O -target arm64-apple-macos15.0 -o dock-probe tools/re/dock-probe.swift
// Run in a VM over SSH: ./dock-probe
//
// Signatures assumed for the private functions: float CoreDockGetTileSize(void),
// void CoreDockGetOrientationAndPinning(int32_t *, int32_t *),
// Boolean CoreDockGetAutoHideEnabled(void), void CoreDockGetRect(CGRect *).
// Verified to run on macOS 15.6.1 (24G90) and 26.6.2 (25G83).

import AppKit
import Darwin

// Prints what a separate process can read about the Dock: CoreDock functions of
// HIServices (found with dlsym) and the Dock's windows in the window list.
let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
for name in ["CoreDockGetTileSize", "CoreDockGetOrientationAndPinning", "CoreDockGetAutoHideEnabled",
             "CoreDockGetRect", "CoreDockGetBounds", "CoreDockGetMagnificationSize", "CoreDockIsMagnificationEnabled",
             "_CoreDockGetTileSize", "CoreDockGetWorkspacesCount"] {
    print(name, dlsym(h, name) != nil ? "found" : "-")
}
if let p = dlsym(h, "CoreDockGetTileSize") {
    typealias F = @convention(c) () -> Float
    print("CoreDockGetTileSize()", unsafeBitCast(p, to: F.self)())
}
if let p = dlsym(h, "CoreDockGetOrientationAndPinning") {
    typealias F = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
    var o: Int32 = -1, pin: Int32 = -1
    unsafeBitCast(p, to: F.self)(&o, &pin)
    print("CoreDockGetOrientationAndPinning", o, pin)
}
if let p = dlsym(h, "CoreDockGetAutoHideEnabled") {
    typealias F = @convention(c) () -> DarwinBoolean
    print("CoreDockGetAutoHideEnabled", unsafeBitCast(p, to: F.self)())
}
if let p = dlsym(h, "CoreDockGetRect") {
    typealias F = @convention(c) (UnsafeMutablePointer<CGRect>) -> Void
    var r = CGRect(x: -1, y: -1, width: -1, height: -1)
    unsafeBitCast(p, to: F.self)(&r)
    print("CoreDockGetRect", r)
}
// The Dock's rectangle as the window server has it, as this project's DockBar reads it (REF-DEV-019).
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
if let connection = dlsym(skyLight, "CGSMainConnectionID"), let getRect = dlsym(skyLight, "SLSGetDockRectWithOrientation") {
    typealias Connection = @convention(c) () -> Int32
    typealias GetRect = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>,
                                        UnsafeMutablePointer<Int32>) -> Int32
    var r = CGRect.zero, reason: Int32 = 0, orientation: Int32 = 0
    _ = unsafeBitCast(getRect, to: GetRect.self)(unsafeBitCast(connection, to: Connection.self)(), &r, &reason, &orientation)
    print("SLSGetDockRectWithOrientation", r, orientation)
}
let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? -1
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == dockPid {
    print("window", w[kCGWindowNumber as String] ?? "", w[kCGWindowName as String] ?? "", "layer", w[kCGWindowLayer as String] ?? "",
          "bounds", w[kCGWindowBounds as String] ?? "", "onscreen", w[kCGWindowIsOnscreen as String] ?? "")
}
if let s = NSScreen.main {
    print("screen frame", s.frame, "visibleFrame", s.visibleFrame, "safeAreaInsets", s.safeAreaInsets,
          "auxTopLeft", s.auxiliaryTopLeftArea as Any, "auxTopRight", s.auxiliaryTopRightArea as Any)
}
