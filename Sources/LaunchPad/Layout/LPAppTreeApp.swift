import Foundation

/// A leaf of the app tree: one app, named after its bundle.
@objc(LPAppTreeApp)
final class LPAppTreeApp: LPAppTreeNode, @unchecked Sendable {
    @objc let app: LPLayoutItem

    @objc(initWithApp:)
    init(app: LPLayoutItem) {
        self.app = app
        super.init(name: (Self._path(forApp: app) as NSString?)?.lastPathComponent)
    }

    @objc override var isLeaf: Bool { true }

    /// The components of the app's directory, starting with the empty one before `/`.
    @objc var pathComponents: [String]? {
        ((Self._path(forApp: app) as NSString?)?.deletingLastPathComponent as NSString?)?.components(separatedBy: "/")
    }

    /// Where the app is. The original also places downloading apps by their likely install path
    /// (phase 6).
    @objc(_pathForApp:)
    class func _path(forApp app: LPLayoutItem) -> String? {
        (app as? LPRunnable)?.lastURL?.path
    }
}
