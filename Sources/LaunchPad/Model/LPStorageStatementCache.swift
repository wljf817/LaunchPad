import Dispatch
import Foundation
import SQLite3

/// Prepared statements kept by SQL text and reused; all of them are finalized 3 seconds after the
/// last use. Used only on the storage's database queue.
@objc(LPStorageStatementCache)
final class LPStorageStatementCache: NSObject, @unchecked Sendable {
    // The original keeps the statement pointers in an NSMapTable with opaque values; Swift
    // cannot pass non-object pointers through NSMapTable, so a dictionary holds them.
    private var statements: [String: OpaquePointer] = [:]
    private var clearTimer: DispatchSourceTimer?
    private let queue: DispatchQueue

    @objc(initWithQueue:)
    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    deinit {
        clearTimer?.cancel()
        clearTimer = nil
        clearStatements()
    }

    @objc(statementWithString:database:statement:)
    func statement(with string: UnsafePointer<CChar>, database: OpaquePointer?, statement: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
        statment(withNSString: String(cString: string), database: database, statement: statement)
    }

    // The selector's spelling is the original's.
    @objc(statmentWithNSString:database:statement:)
    func statment(withNSString string: String, database: OpaquePointer?, statement: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
        var prepared = statements[string]
        if let existing = prepared {
            sqlite3_reset(existing)
        } else {
            let result = sqlite3_prepare_v2(database, string, -1, &prepared, nil)
            if result != SQLITE_OK {
                return result
            }
            statements[string] = prepared
        }
        statement?.pointee = prepared
        if let clearTimer {
            clearTimer.schedule(deadline: .now() + .seconds(3), repeating: .never)
        } else {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [unowned self] in
                self.clearTimer?.cancel()
                self.clearTimer = nil
                self.clearStatements()
            }
            timer.schedule(deadline: .now() + .seconds(3), repeating: .never)
            timer.resume()
            clearTimer = timer
        }
        return SQLITE_OK
    }

    @objc func clearStatements() {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        statements.removeAll()
    }
}
