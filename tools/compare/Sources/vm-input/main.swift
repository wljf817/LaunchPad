// Posts a mouse click, a key press, scroll wheel events or a recorded trackpad
// gesture to the HID event tap, as a trigger for recordings of scenes that start
// with input (for example a click or Escape that closes Launchpad). The window
// server routes these events as it routes hardware input. The same binary runs in the macOS 15 reference VM and in the
// macOS 26 comparison VM, copied there over SSH.
//
// Needs the Accessibility permission of the process that launches it: over
// SSH that is /usr/libexec/sshd-keygen-wrapper. Never needs sudo.

import CoreGraphics
import Foundation

let usage = """
    usage: vm-input click <x> <y>
           vm-input rclick <x> <y>
           vm-input move <x> <y>
           vm-input down <x> <y>
           vm-input up <x> <y>
           vm-input dragmove <x> <y>
           vm-input drag <x1> <y1> <x2> <y2> [<steps> <interval-ms> [<hold-ms>]]
           vm-input key <keycode> [cmd|shift|opt|ctrl ...]
           vm-input keys <interval-ms> <keycode>[+cmd|+shift|+opt|+ctrl ...] ...
           vm-input wheel <x> <y> <dy> [<dx> [<count> <interval-ms>]] [shift]
           vm-input trackpad <x> <y> <sample-file> [<time-scale>]
    click: moves the pointer to (x, y) in global points (origin at the top left of the
    main display), then presses and releases the left button. rclick: the same with the
    right button. move: moves the pointer to (x, y), with the movement from where it was as
    the event's delta, as a mouse does. down: moves the pointer to (x, y) and presses the
    left button only. up: releases the left button at (x, y). dragmove: moves the pointer to
    (x, y) with the left button held (one left-dragged event). drag: presses the left button
    at (x1, y1), waits 80 ms, moves to (x2, y2) in <steps> equal steps (10), waiting
    <interval-ms> (16) after each, waits <hold-ms> (0) more and releases it there.
    key: presses the modifier keys, presses and releases the key, then releases the
    modifier keys in reverse order. keys: presses each key as key does, the first at once and
    each next one <interval-ms> after the previous one started, timed on the monotonic clock
    from the first, so that the presses keep their spacing however long each takes. wheel: moves the pointer to (x, y), waits 150 ms and posts
    <count> (1) scroll wheel events of <dy> lines vertically and <dx> (0) horizontally, as a
    mouse wheel does (not continuous, no phases), waiting <interval-ms> (16) after each but the
    last; with shift, the Shift key is held down around them. trackpad: moves the pointer to
    (x, y), waits 150 ms and posts the events of a recorded trackpad gesture (trackpad-*.txt):
    each line is "<delay-ns> <type> <field>=<integer>[/<double>] ...", a scroll wheel event (22)
    or a gesture event (29) with those fields set, posted at (x, y) after the delay times
    <time-scale> (1). Lines starting with # are skipped. Exits 1 without the permission to post
    events.
    """

/// Modifier keys: flag and virtual key code.
let modifiers: [String: (flag: CGEventFlags, keyCode: CGKeyCode)] = [
    "cmd": (.maskCommand, 55),
    "shift": (.maskShift, 56),
    "opt": (.maskAlternate, 58),
    "ctrl": (.maskControl, 59),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func requirePermission() {
    guard CGPreflightPostEventAccess() else {
        FileHandle.standardError.write(Data("vm-input: no permission to post events; grant Accessibility to the launching process (over SSH: /usr/libexec/sshd-keygen-wrapper)\n".utf8))
        exit(1)
    }
}

func pause(_ milliseconds: UInt32) {
    usleep(milliseconds * 1000)
}

func click(at point: CGPoint, button: CGMouseButton) {
    let (down, up): (CGEventType, CGEventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
    for (type, delay) in [(CGEventType.mouseMoved, 150), (down, 80), (up, 0)] as [(CGEventType, UInt32)] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        pause(delay)
    }
}

func move(to point: CGPoint) {
    let from = CGEvent(source: nil)?.location ?? point
    let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - from.x).rounded()))
    event?.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - from.y).rounded()))
    event?.post(tap: .cghidEventTap)
}

func down(at point: CGPoint) {
    for (type, delay) in [(CGEventType.mouseMoved, 150), (.leftMouseDown, 0)] as [(CGEventType, UInt32)] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        pause(delay)
    }
}

func up(at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func dragMove(to point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func drag(from start: CGPoint, to end: CGPoint, steps: Int, interval: UInt32, hold: UInt32) {
    func post(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    post(.mouseMoved, start)
    pause(150)
    post(.leftMouseDown, start)
    pause(80)
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        pause(interval)
    }
    pause(hold)
    post(.leftMouseUp, end)
}

func press(_ keyCode: CGKeyCode, _ names: [String]) {
    var flags: CGEventFlags = []
    func post(_ code: CGKeyCode, down: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        pause(60)
    }
    for name in names {
        flags.insert(modifiers[name]!.flag)
        post(modifiers[name]!.keyCode, down: true)
    }
    post(keyCode, down: true)
    post(keyCode, down: false)
    for name in names.reversed() {
        flags.remove(modifiers[name]!.flag)
        post(modifiers[name]!.keyCode, down: false)
    }
}

func wheel(at point: CGPoint, dy: Int32, dx: Int32, count: Int, interval: UInt32, shift: Bool) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    pause(150)
    let flags: CGEventFlags = shift ? .maskShift : []
    func shiftKey(down: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: modifiers["shift"]!.keyCode, keyDown: down)
        event?.flags = down ? .maskShift : []
        event?.post(tap: .cghidEventTap)
        pause(60)
    }
    if shift {
        shiftKey(down: true)
    }
    for index in 0..<count {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        event?.location = point
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        if index < count - 1 {
            pause(interval)
        }
    }
    if shift {
        pause(60)
        shiftKey(down: false)
    }
}

func trackpad(at point: CGPoint, sample: String, scale: Double) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    pause(150)
    for line in sample.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let delay = Double(parts[0]), let type = UInt32(parts[1]),
              let event = type == 22
                ? CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)
                : CGEvent(source: nil) else { continue }
        event.type = CGEventType(rawValue: type)!
        for field in parts.dropFirst(2) {
            let pair = field.split(separator: "=")
            let values = pair[1].split(separator: "/")
            guard let number = UInt32(pair[0]), let key = CGEventField(rawValue: number) else { continue }
            if values.count > 1, let double = Double(values[1]) {
                event.setDoubleValueField(key, value: double)
            } else if let integer = Int64(values[0]) {
                event.setIntegerValueField(key, value: integer)
            }
        }
        event.location = point
        usleep(UInt32(delay * scale / 1000))
        event.post(tap: .cghidEventTap)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(2)
}

switch command {
case "click", "rclick":
    guard arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else { fail(usage) }
    requirePermission()
    click(at: CGPoint(x: x, y: y), button: command == "click" ? .left : .right)
case "move":
    guard arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else { fail(usage) }
    requirePermission()
    move(to: CGPoint(x: x, y: y))
case "down", "up", "dragmove":
    guard arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else { fail(usage) }
    requirePermission()
    if command == "down" {
        down(at: CGPoint(x: x, y: y))
    } else if command == "up" {
        up(at: CGPoint(x: x, y: y))
    } else {
        dragMove(to: CGPoint(x: x, y: y))
    }
case "drag":
    let values = arguments.dropFirst().prefix(4).compactMap(Double.init)
    let timing = arguments.dropFirst(5).compactMap { UInt32($0) }
    guard [5, 7, 8].contains(arguments.count), values.count == 4, timing.count == arguments.count - 5,
          timing.first ?? 1 > 0 else { fail(usage) }
    requirePermission()
    drag(from: CGPoint(x: values[0], y: values[1]), to: CGPoint(x: values[2], y: values[3]),
         steps: Int(timing.first ?? 10), interval: timing.count > 1 ? timing[1] : 16,
         hold: timing.count > 2 ? timing[2] : 0)
case "key":
    guard arguments.count >= 2, let code = UInt16(arguments[1]),
          arguments.dropFirst(2).allSatisfy({ modifiers[$0] != nil }) else { fail(usage) }
    requirePermission()
    press(code, Array(arguments.dropFirst(2)))
case "keys":
    let presses = arguments.dropFirst(2).map { $0.split(separator: "+").map(String.init) }
    guard arguments.count >= 3, let interval = UInt64(arguments[1]), interval > 0,
          presses.allSatisfy({ UInt16($0[0]) != nil && $0.dropFirst().allSatisfy { modifiers[$0] != nil } })
    else { fail(usage) }
    requirePermission()
    let start = DispatchTime.now().uptimeNanoseconds
    for (index, keys) in presses.enumerated() {
        let due = start + UInt64(index) * interval * 1_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        if due > now {
            usleep(useconds_t((due - now) / 1000))
        }
        press(UInt16(keys[0])!, Array(keys.dropFirst()))
    }
case "wheel":
    let shift = arguments.last == "shift"
    let values = Array(arguments.dropFirst().dropLast(shift ? 1 : 0))
    let numbers = values.dropFirst(2).compactMap { Int32($0) }
    guard [3, 4, 6].contains(values.count), let x = Double(values[0]), let y = Double(values[1]),
          numbers.count == values.count - 2, numbers.count < 3 || (numbers[2] > 0 && numbers[3] >= 0) else { fail(usage) }
    requirePermission()
    wheel(at: CGPoint(x: x, y: y), dy: numbers[0], dx: numbers.count > 1 ? numbers[1] : 0,
          count: numbers.count > 2 ? Int(numbers[2]) : 1, interval: numbers.count > 3 ? UInt32(numbers[3]) : 16,
          shift: shift)
case "trackpad":
    guard [4, 5].contains(arguments.count), let x = Double(arguments[1]), let y = Double(arguments[2]),
          let sample = try? String(contentsOfFile: arguments[3], encoding: .utf8),
          let scale = arguments.count == 5 ? Double(arguments[4]) : 1, scale > 0 else { fail(usage) }
    requirePermission()
    trackpad(at: CGPoint(x: x, y: y), sample: sample, scale: scale)
default:
    fail(usage)
}
