import Foundation

/// The whole string, ignoring case.
@objc(_LPLayoutMatchRule)
final class _LPLayoutMatchRule: _LPLayoutRule, @unchecked Sendable {
    @objc(match:)
    override func match(_ string: String?) -> Bool {
        guard let string else { return false }
        return (stringToMatch as NSString).compare(string, options: .caseInsensitive) == .orderedSame
    }
}
