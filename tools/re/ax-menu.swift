// Prints an application's menu bar as the Accessibility API exposes it, as one JSON object: per
// menu its title and items, per item its title, command character, command modifiers (AX bits:
// 1 shift, 2 option, 4 control, 8 no command), virtual key, enabled and submenu. Used on the text
// input service, whose menu is never shown, to compare the items AppKit adds at run time in the
// reference VM and the comparison VM. Items AppKit hides are not exposed.
//
// Needs the Accessibility permission of the process that launches it: over SSH that is
// /usr/libexec/sshd-keygen-wrapper, which vm-input already needs.
//
// With "value" it prints the value of the application's focused element instead (the service's
// text field editor), as a JSON string.
//
// Build: swiftc -O -target arm64-apple-macos15 tools/re/ax-menu.swift -o ax-menu
// Usage: ax-menu <pid> [value]

import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func menu(_ element: AXUIElement) -> [String: Any] {
    var items: [[String: Any]] = []
    for item in children(element) {
        var entry: [String: Any] = [
            "title": attribute(item, kAXTitleAttribute) as? String ?? "",
            "cmdChar": attribute(item, kAXMenuItemCmdCharAttribute) as? String ?? NSNull(),
            "cmdModifiers": attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int ?? NSNull(),
            "cmdVirtualKey": attribute(item, kAXMenuItemCmdVirtualKeyAttribute) as? Int ?? NSNull(),
            "enabled": attribute(item, kAXEnabledAttribute) as? Bool ?? NSNull(),
        ]
        if let submenu = children(item).first {
            entry["submenu"] = menu(submenu)
        }
        items.append(entry)
    }
    return ["title": attribute(element, kAXTitleAttribute) as? String ?? "", "items": items]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard (1...2).contains(arguments.count), let pid = pid_t(arguments[0]), arguments.count == 1 || arguments[1] == "value" else {
    FileHandle.standardError.write(Data("usage: ax-menu <pid> [value]\n".utf8))
    exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("no Accessibility permission\n".utf8))
    exit(1)
}
let app = AXUIElementCreateApplication(pid)
if arguments.count == 2 {
    let focused = attribute(app, kAXFocusedUIElementAttribute)
    let value = focused.map { attribute($0 as! AXUIElement, kAXValueAttribute) as? String } ?? nil
    let data = try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}
guard let bar = attribute(app, kAXMenuBarAttribute) else {
    FileHandle.standardError.write(Data("no menu bar\n".utf8))
    exit(1)
}
let data = try JSONSerialization.data(withJSONObject: menu(bar as! AXUIElement), options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
