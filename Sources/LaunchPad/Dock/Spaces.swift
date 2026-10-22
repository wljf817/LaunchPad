import AppKit
import LaunchPadPrivate

/// Dock's record of the spaces (REF-ARCH-010). Here it reads the window server's (REF-DEV-007,
/// REF-DEV-015).
@MainActor
@objc(Spaces)
final class Spaces: NSObject {
    /// Whether a space switch is animating on any display (REF-DEV-007).
    @objc var anySwitchingOccurring: Bool {
        let connection = CGSMainConnectionID()
        return displaySpaces().contains { display in
            guard let uuid = display["Display Identifier"] as? String else { return false }
            return CGSManagedDisplayIsAnimating(connection, uuid as CFString)
        }
    }

    /// The current space of a display (REF-DEV-015).
    @objc(currentSpaceForDisplay:)
    func currentSpace(forDisplay display: UInt32) -> ManagedSpace? {
        let identifier = Self.displayIdentifier(display)
        for info in displaySpaces() {
            let name = info["Display Identifier"] as? String
            guard name == identifier || (name == "Main" && CGDisplayIsMain(display) != 0),
                  let current = info["Current Space"] as? [String: Any],
                  let uuid = current["uuid"] as? String,
                  let spid = current["ManagedSpaceID"] as? NSNumber else { continue }
            return ManagedSpace(uuid: uuid, spid: spid.uint64Value)
        }
        return nil
    }

    func displaySpaces() -> [[String: Any]] {
        CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
    }

    static func displayIdentifier(_ display: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

@MainActor let spaces = Spaces()
