import Foundation
@testable import LaunchPad

/// The model side of the controller's startup, in the order of `-[Springboard
/// _setupApplicationSources:]`, its root callback, its `sourcesStillScanning` observer and
/// `-_handleInitialSourceScanCompletion` (research paper §12.14, REF-LAYOUT-007). It moves into the
/// controller in 1.3.
@MainActor
final class StartupHelper: NSObject {
    /// Columns × rows with the default preferences (REF-LAYOUT-006).
    static let itemsPerPage: UInt = 7 * 5

    let manager: LPAppManager
    var layout: LPLayout?
    var rootPage: LPRoot?
    var scanningComplete = false
    /// Called with the root before the scan results arrive, standing in for apps the scan finds.
    var rootsArrived: ((LPAppManager, LPRoot) -> Void)?

    nonisolated(unsafe) private static var scanningContext = 0

    init(databasePath: String, rootsArrived: ((LPAppManager, LPRoot) -> Void)? = nil) {
        manager = LPAppManager(atPath: databasePath, readOnly: false)!
        self.rootsArrived = rootsArrived
        super.init()
        manager.roots { [self] root, _ in
            guard let root else { return }
            rootPage = root
            rootsArrived?(manager, root)
            let paths = (manager.sources as NSArray).value(forKey: "path") as! [Any]
            layout = LPLayout(rootPage: root, sources: paths, maxItemsPerPage: Self.itemsPerPage, maxItemsPerGroup: Self.itemsPerPage)
            if !manager.sourcesStillScanning {
                handleInitialSourceScanCompletion()
            }
        }
        manager.addObserver(self, forKeyPath: "sourcesStillScanning", options: [.initial], context: &Self.scanningContext)
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                           context: UnsafeMutableRawPointer?) {
        guard context == &Self.scanningContext else { return }
        MainActor.assumeIsolated {
            if keyPath == "sourcesStillScanning", !manager.sourcesStillScanning, !scanningComplete {
                handleInitialSourceScanCompletion()
                scanningComplete = true
            }
        }
    }

    func handleInitialSourceScanCompletion() {
        guard let rootPage, let layout, let storage = manager.storage else { return }
        let items = rootPage.allPurgatoryItems
        if rootPage.children.count == 0 {
            layout.layoutForInitial(items)
        } else {
            layout.layoutItemsToNextAvailableSpace(items, withOptions: 0)
            let info = storage.dbInfo
            let excludeVersion = (info?["excludeListVersionLP"] as AnyObject?)?.integerValue ?? 0
            let gameVersion = (info?["includeAsGameListVersionLP"] as AnyObject?)?.integerValue ?? 0
            let curationVersion = (info?["curateListVersionLP"] as AnyObject?)?.integerValue ?? 0
            var gameGroup: LPGroup?
            let manager = manager
            layout.fixupLayout(
                withExcludeListVersion: UInt(bitPattern: excludeVersion), includeAsGameListVersion: UInt(bitPattern: gameVersion),
                curationVersion: UInt(bitPattern: curationVersion),
                itemExcluded: { item in
                    let parent = item.parentContainer
                    if let runnable = item as? LPRunnable {
                        manager.forgetRunnable(runnable)
                    }
                    parent?.children.remove(item)
                },
                itemIncludedAsGame: { item in
                    if gameGroup == nil {
                        gameGroup = layout.groupForKind(1)
                    }
                    guard let gameGroup,
                          let page = gameGroup.firstAvailablePage(withMaxCount: layout.maxPerGroupPage, createIfNecessary: true),
                          item.parentGroup !== gameGroup else { return }
                    let parent = item.parentContainer
                    page.children.add(item)
                    parent?.children.remove(item)
                },
                changesMade: { excludeChanged, gameChanged, curated in
                    if excludeChanged {
                        storage.setDBInfoValue(NSNumber(value: layout.excludeListVersion), forKey: "excludeListVersionLP")
                    }
                    if gameChanged {
                        storage.setDBInfoValue(NSNumber(value: layout.includeAsGameListVerison), forKey: "includeAsGameListVersionLP")
                    }
                    if curated {
                        storage.setDBInfoValue(NSNumber(value: layout.curationVerison), forKey: "curateListVersionLP")
                    }
                })
        }
        rootPage.purgePurgatory()
        storage.markInitialSetupComplete()
        // Icons, observers and the layout's added/moved/removed blocks are set up here (1.3).
        scanningComplete = true
    }

    /// Waits until the startup has been handled and the database has written it.
    func waitUntilComplete() async throws {
        let deadline = Date().addingTimeInterval(60)
        while !scanningComplete {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Let the main queue run what the startup queued (dbinfo writes of completion blocks).
        try await Task.sleep(for: .milliseconds(50))
        if let storage = manager.storage {
            await waitForDatabase(storage)
        }
    }
}
