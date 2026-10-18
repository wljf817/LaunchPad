import Foundation

/// A folder the layout will create, or merge into a folder of the same title, when it is placed.
@objc(_LPGroupPromise)
final class _LPGroupPromise: NSObject, @unchecked Sendable {
    @objc let children: NSMutableArray
    @objc let title: String?
    @objc let kind: UInt

    @objc(initWithTitle:kind:)
    init(title: String?, kind: UInt) {
        self.title = title
        children = NSMutableArray(capacity: 0)
        self.kind = kind
        super.init()
    }

}
