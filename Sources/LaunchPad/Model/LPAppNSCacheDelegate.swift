import Foundation
import os

/// The delegate of the process-wide icon caches when debug logging is on: it logs evictions
/// (REF-GRID-012).
@objc(LPAppNSCacheDelegate)
final class LPAppNSCacheDelegate: NSObject, NSCacheDelegate, @unchecked Sendable {
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        Logger().debug("\(cache.name) will evict \(String(describing: obj))")
    }
}
