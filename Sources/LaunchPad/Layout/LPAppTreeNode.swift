import Foundation

/// A directory in the tree of app paths the layout works from.
@objc(LPAppTreeNode)
class LPAppTreeNode: NSObject, @unchecked Sendable {
    @objc let name: String?
    /// Despite the original's ivar name, this caches the node's path (`-path`).
    var _localizedName: String?
    var _children: NSMutableArray?
    @objc weak var parent: LPAppTreeNode?

    @objc(initWithName:)
    init(name: String?) {
        self.name = name
        super.init()
    }

    @objc var children: NSArray? { _children }

    /// The parent's path plus the name; the root's is its name.
    @objc var path: String? {
        if _localizedName == nil {
            if let parentPath = parent?.path {
                _localizedName = (parentPath as NSString).appendingPathComponent(name ?? "")
            } else {
                _localizedName = name
            }
        }
        return _localizedName
    }

    /// The display name of the directory, as Finder shows it.
    @objc var localizedName: String? {
        guard let path else { return name }
        return FileManager.default.displayName(atPath: path)
    }

    /// 1 for the root.
    @objc var depth: UInt { (parent?.depth ?? 0) + 1 }

    @objc var isLeaf: Bool { false }

    @objc(addChild:)
    func addChild(_ node: LPAppTreeNode) {
        guard !isLeaf else { return }
        if _children == nil {
            _children = NSMutableArray(capacity: 0)
        }
        node.parent?.removeChild(node)
        _children?.add(node)
        node.parent = self
    }

    @objc(removeChild:)
    func removeChild(_ node: LPAppTreeNode) {
        node.parent = nil
        _children?.remove(node)
    }

    @objc(_nodeAtPathComponents:createIfNecessary:)
    func _node(atPathComponents components: [String], createIfNecessary create: Bool) -> LPAppTreeNode? {
        guard let first = components.first else { return nil }
        guard !(self is LPAppTreeApp) else { return nil }
        var node: LPAppTreeNode?
        for case let child as LPAppTreeNode in children ?? [] where isEqualToString(child.name, first) {
            node = child
            break
        }
        if node == nil, create {
            let created = LPAppTreeNode(name: first)
            addChild(created)
            node = created
        }
        if components.count > 1 {
            return node?._node(atPathComponents: Array(components[1...]), createIfNecessary: create)
        }
        return node
    }

    @objc(_insertNode:atPathComponents:)
    func _insert(_ node: LPAppTreeNode, atPathComponents components: [String]) {
        guard !components.isEmpty else { return }
        _node(atPathComponents: components, createIfNecessary: true)?.addChild(node)
    }

    @objc(_deleteNodeAndPruneEmptyNodes:atPathComponents:)
    func _deleteNode(andPruneEmptyNodes prune: Bool, atPathComponents components: [String]) {
        guard let node = _node(atPathComponents: components, createIfNecessary: false) else { return }
        var parent = node.parent
        parent?.removeChild(node)
        guard prune else { return }
        while let current = parent, (current.children?.count ?? 0) == 0 {
            parent = current.parent
            parent?.removeChild(current)
        }
    }

    /// Calls `block` for every app below, depth first in child order; returns false once a call
    /// set `stop`.
    @objc(_apps:)
    func _apps(_ block: (LPAppTreeApp, UnsafeMutablePointer<ObjCBool>) -> Void) -> Bool {
        var stop: ObjCBool = false
        for case let child as LPAppTreeNode in children ?? [] {
            if let app = child as? LPAppTreeApp {
                block(app, &stop)
                if stop.boolValue {
                    return false
                }
            } else if !child._apps(block) {
                return false
            }
        }
        return true
    }
}
