import Dispatch
import Foundation

/// Calls its block on the main queue, with its identifier, when the last reference to it goes away:
/// work that keeps a reference until it finishes signals completion by releasing it.
@objc(LPCompletionBlock)
final class LPCompletionBlock: NSObject, @unchecked Sendable {
    private var block: (@convention(block) (UInt32) -> Void)?
    @objc var userinfo: NSDictionary?
    @objc var identifier: UInt32 = 0

    @objc(initCompletionBlock:)
    init(completionBlock: (@convention(block) (UInt32) -> Void)?) {
        super.init()
        if let completionBlock {
            block = completionBlock
        }
    }

    deinit {
        if let block {
            let identifier = self.identifier
            let call = UncheckedBox(block)
            DispatchQueue.main.async { call.value(identifier) }
            invalidate()
        }
    }

    @objc func invalidate() {
        if block != nil {
            block = nil
        }
    }
}

/// Carries a value across a dispatch boundary where the original passes it unchecked.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
