import Foundation

/// A space, as Dock records it (REF-ARCH-010). Here made from the window server's record
/// (REF-DEV-015).
@objc(ManagedSpace)
final class ManagedSpace: NSObject {
    @objc let uuid: String
    @objc let spid: UInt64

    @objc(initWithUUID:spid:)
    init(uuid: String, spid: UInt64) {
        self.uuid = uuid
        self.spid = spid
        super.init()
    }
}
