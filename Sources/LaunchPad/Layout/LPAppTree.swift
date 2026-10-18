import Foundation

/// The apps of a layout run arranged by the directories they are in. The root is `/`.
@objc(LPAppTree)
final class LPAppTree: LPAppTreeNode, @unchecked Sendable {
    /// Bundle ID → set of leaves.
    let nodesByBundleIdentifier: NSMutableDictionary

    @objc init() {
        nodesByBundleIdentifier = NSMutableDictionary(capacity: 0)
        super.init(name: "/")
    }

    /// Path components without the empty first one.
    private static func components(_ path: String?) -> [String] {
        let components = (path as NSString?)?.components(separatedBy: "/") ?? []
        return components.count > 1 ? Array(components[1...]) : components
    }

    @objc(addApp:)
    @discardableResult
    func addApp(_ app: LPLayoutItem) -> LPAppTreeApp {
        let node = LPAppTreeApp(app: app)
        var components = node.pathComponents ?? []
        if components.count > 1 {
            components = Array(components[1...])
        }
        _insert(node, atPathComponents: components)
        if let bundleID = app.bundleIdentifier {
            var nodes = nodesByBundleIdentifier[bundleID] as? NSMutableSet
            if nodes == nil {
                nodes = NSMutableSet()
                nodesByBundleIdentifier[bundleID] = nodes
            }
            nodes?.add(node)
        }
        return node
    }

    /// The apps of a folder, from all of its pages.
    @objc(addAppsFromGroup:)
    func addApps(fromGroup group: LPGroup) {
        group.iterateChildren { item, _ in
            if let app = item as? LPLayoutItem {
                addApp(app)
            }
        }
    }

    @objc(addApps:)
    func addApps(_ items: [Any]) {
        for item in items {
            if let group = item as? LPGroup {
                addApps(fromGroup: group)
            } else if let app = item as? LPLayoutItem {
                addApp(app)
            }
        }
    }

    /// Removes the app's leaf and the directories left empty. The original then removes the app
    /// itself, not its leaf, from the bundle ID's set, so the leaf stays listed there.
    @objc(removeApp:)
    func removeApp(_ app: LPLayoutItem) {
        _deleteNode(andPruneEmptyNodes: true, atPathComponents: Self.components(LPAppTreeApp._path(forApp: app)))
        if let bundleID = app.bundleIdentifier {
            let nodes = nodesByBundleIdentifier[bundleID] as? NSMutableSet
            nodes?.remove(app)
            if let nodes, nodes.count == 0 {
                nodesByBundleIdentifier.removeObject(forKey: bundleID)
            }
        }
    }

    @objc(removeApps:)
    func removeApps(_ apps: [LPLayoutItem]) {
        for app in apps {
            removeApp(app)
        }
    }

    /// Moves the node at `path`, with the directories above it, into a tree of its own.
    @objc(splitOutTreeAtPath:)
    func splitOutTree(atPath path: String) -> LPAppTree? {
        let components = Self.components(path)
        guard let node = _node(atPathComponents: components, createIfNecessary: false) else { return nil }
        let tree = LPAppTree()
        if components.count < 2 {
            tree.addChild(node)
        } else {
            tree._insert(node, atPathComponents: Array(components[0..<(components.count - 1)]))
        }
        return tree
    }

    @objc(subNodeAtPath:)
    func subNode(atPath path: String) -> LPAppTreeNode? {
        path == "/" ? self : _node(atPathComponents: Self.components(path), createIfNecessary: false)
    }

    /// Calls `block` for each app leaf under `path` until it sets `stop`.
    @objc(iterateAllAppsAtPath:matching:)
    func iterateAllApps(atPath path: String, matching block: (LPAppTreeApp, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let node: LPAppTreeNode? = path == "/" ? self : _node(atPathComponents: Self.components(path), createIfNecessary: false)
        _ = node?._apps { app, stop in
            var innerStop: ObjCBool = false
            block(app, &innerStop)
            if innerStop.boolValue {
                stop.pointee = true
            }
        }
    }

    @objc(nodesForBundleIdentifier:)
    func nodes(forBundleIdentifier bundleID: String?) -> NSMutableSet? {
        bundleID.flatMap { nodesByBundleIdentifier[$0] as? NSMutableSet }
    }
}
