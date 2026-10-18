import Foundation
import SQLite3

/// A database failure. Most storage methods record it in `LPStorage.commitException` instead of
/// raising it; loading raises it and nothing catches it (research paper §16).
@objc(LPDatabaseException)
final class LPDatabaseException: NSException, @unchecked Sendable {
    @objc let method: String?
    @objc let line: Int64
    @objc let dbError: Int64
    @objc let dbErrorStr: String?

    @objc(initExceptionInMethod:lineNumber:database:ret:)
    init(exceptionInMethod method: UnsafePointer<CChar>?, lineNumber line: Int64, database: OpaquePointer?, ret: Int32) {
        self.method = method.map { String(cString: $0) }
        self.line = line
        dbError = Int64(ret)
        dbErrorStr = sqlite3_errmsg(database).map { String(cString: $0) }
        super.init(name: NSExceptionName("LPDatabaseException"), reason: "DatabaseCorruption", userInfo: nil)
    }

    required init?(coder: NSCoder) {
        method = nil
        line = 0
        dbError = 0
        dbErrorStr = nil
        super.init(coder: coder)
    }

    override var description: String {
        String(format: "LPDatabaseException: %@:%ld %@ (%ld)", method ?? "(null)", line, dbErrorStr ?? "(null)", dbError)
    }
}
