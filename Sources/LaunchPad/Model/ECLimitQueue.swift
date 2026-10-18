import Darwin
import Dispatch
import Foundation

/// Runs blocks on a concurrent queue, at most a fixed number at a time; the rest wait in order.
/// The app scan uses one (REF-LAYOUT-003).
///
/// Thread safety: `waitingWork` and `activeWork` are only touched on `serialQueue`.
@objc(ECLimitQueue)
final class ECLimitQueue: NSObject, @unchecked Sendable {
    private let workQueue: DispatchQueue
    private let serialQueue: DispatchQueue
    private var waitingWork: NSMutableArray?
    private var activeWork: UInt32 = 0

    /// The number of blocks that may run at once, read once per process: `hw.logicalcpu_max`, or 4
    /// when it cannot be read (REF-LAYOUT-003). The original sets it in `+initialize`.
    private static let limit: UInt32 = {
        var value: Int32 = 1
        var size = 4
        guard sysctlbyname("hw.logicalcpu_max", &value, &size, nil, 0) == 0 else { return 4 }
        return UInt32(bitPattern: value)
    }()

    @objc(initWithName:)
    init(name: UnsafePointer<CChar>) {
        workQueue = DispatchQueue(label: String(cString: name), attributes: .concurrent)
        serialQueue = DispatchQueue(label: "")
        super.init()
    }

    @objc(async:)
    func async(_ block: @escaping @convention(block) () -> Void) {
        serialQueue.sync { self._async(block) }
    }

    @objc(_async:)
    func _async(_ block: @escaping @convention(block) () -> Void) {
        if activeWork < Self.limit {
            activeWork += 1
            let work = UncheckedBox(block)
            workQueue.async {
                work.value()
                self.serialQueue.sync {
                    self.activeWork -= 1
                    guard let waiting = self.waitingWork else { return }
                    let next = waiting.object(at: 0)
                    waiting.removeObject(at: 0)
                    if waiting.count == 0 {
                        self.waitingWork = nil
                    }
                    self._async(unsafeBitCast(next as AnyObject, to: (@convention(block) () -> Void).self))
                }
            }
        } else {
            if waitingWork == nil {
                waitingWork = NSMutableArray(capacity: 0)
            }
            waitingWork?.add(block as AnyObject)
        }
    }
}
