import Foundation

/// The start of the string, ignoring case.
@objc(_LPLayoutPrefixRule)
final class _LPLayoutPrefixRule: _LPLayoutRule, @unchecked Sendable {
    @objc(match:)
    override func match(_ string: String?) -> Bool {
        guard let string else { return false }
        let range = (string as NSString).range(of: stringToMatch, options: .caseInsensitive)
        return range.length != 0 && range.location == 0
    }
}
