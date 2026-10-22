import AppKit

/// Dock's record of the current drag (REF-ARCH-010).
@MainActor
@objc(DragController)
final class DragController: NSObject {
    /// The kinds of contents of the current drag. Only bit 0x10 is read by Launchpad: a Dock icon is
    /// being dragged, which the drag pasteboard shows with the type `owensdock` (REF-DEV-007).
    @objc var currentDragContents: UInt64 {
        guard NSEvent.pressedMouseButtons != 0 else { return 0 }
        let types = NSPasteboard(name: .drag).types ?? []
        return types.contains(NSPasteboard.PasteboardType("owensdock")) ? 0x10 : 0
    }
}

@MainActor let dragController = DragController()
