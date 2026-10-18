import Foundation

/// Anywhere in the string, ignoring case.
@objc(_LPLayoutContainsRule)
final class _LPLayoutContainsRule: _LPLayoutRule, @unchecked Sendable {
    @objc(match:)
    override func match(_ string: String?) -> Bool {
        guard let string else { return false }
        return (string as NSString).range(of: stringToMatch, options: .caseInsensitive).length != 0
    }
}
