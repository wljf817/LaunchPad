import Foundation

/// The database blocks collected while a transaction is open; `LPStorage` runs them together on
/// its database queue when the transaction is committed.
@objc(LPStorageTransaction)
final class LPStorageTransaction: NSObject, @unchecked Sendable {
    private let _blocks: NSMutableArray
    @objc let uuid: String
    @objc let dbref: Int32

    @objc var blocks: NSArray { _blocks }

    @objc(initWithDatabaseReference:)
    init(databaseReference: Int32) {
        _blocks = NSMutableArray(capacity: 0)
        uuid = newUUIDString()
        dbref = databaseReference
        super.init()
    }

    @objc(addBlock:)
    func addBlock(_ block: @escaping @convention(block) () -> Void) {
        _blocks.add(block as AnyObject)
    }
}

/// A new random UUID in upper-case hexadecimal, as the original generates for items and transactions.
func newUUIDString() -> String {
    var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    uuid_generate_random(&uuid.0)
    var text = [CChar](repeating: 0, count: 37)
    uuid_unparse_upper(&uuid.0, &text)
    return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
