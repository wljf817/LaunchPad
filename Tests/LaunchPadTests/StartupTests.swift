import CoreServices
import Foundation
import Testing
@testable import LaunchPad

/// Startups of the controller (REF-GRID-001): three on one database (the initial layout, the
/// correction at the second startup, none at the third; REF-LAYOUT-007, REF-LAYOUT-008), one without
/// a database, and one where the scan has completed before the roots arrive.
///
/// The database records the sources' volumes, so only the cryptex source is scanned (its Safari
/// joins the injected one by path). The golden apps stand in for the reference VM's scan: they are
/// added the way the scan adds a new app, before its results arrive.
@MainActor
struct StartupTests {
    let directory = TemporaryDirectory()

    init() {
        launchPadBundle = testResources
    }

    var databasePath: String { directory.path("db") }

    /// A new database whose sources are recorded (as in `ScanFixture`).
    func makeDatabase() async {
        let (storage, _, _, _) = await openStorage(at: databasePath)
        await waitForDatabase(storage)
        var sql = "DELETE FROM dbinfo WHERE key = 'setup_incomplete';"
        for (name, sourcePath) in ScanFixture.recordedSources {
            let uuid = ScanFixture.volumeUUID(sourcePath).map { "'\($0)'" } ?? "NULL"
            sql += "INSERT INTO app_sources (uuid, flags, last_fsevent_id, fsevent_uuid) VALUES ('\(name)', 0, \(FSEventsGetCurrentEventId()), \(uuid));"
        }
        #expect(execute(databasePath, sql) == 0)
    }

    /// The golden apps, with a bookmark where the path exists on this Mac.
    static func goldenApps() -> [LPApp] {
        GoldenLayout.shared.makeApps().map { app in
            if let url = app.lastURL, FileManager.default.fileExists(atPath: url.path) {
                app._bookmarkData = try? url.bookmarkData(options: URL.BookmarkCreationOptions(rawValue: 0x2000_0200),
                                                          includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            return app
        }
    }

    func dbinfo() -> [String: String] {
        Dictionary(uniqueKeysWithValues: queryRows(databasePath, "SELECT key, value FROM dbinfo").map {
            ($0["key"]! as! String, $0["value"]! as! String)
        })
    }

    /// Starts a controller on the database the way the background process does (REF-GRID-001).
    func launch(injecting apps: [LPApp] = []) async throws -> LPSpringboard {
        let manager = try #require(LPAppManager(atPath: databasePath, readOnly: false))
        LPAppManager.shared = manager
        // Runs before the controller's own roots block, which was not registered yet.
        manager.roots { _, _ in
            for app in apps {
                manager._addNewRunnable(app)
            }
        }
        let springboard = LPSpringboard()
        springboard.activate()
        springboard.start()
        try await waitUntilStarted(springboard)
        return springboard
    }

    @Test("布局只生成一次、启动时修正布局")
    func threeStartups() async throws {
        let golden = GoldenLayout.shared
        await makeDatabase()

        let first = try await launch(injecting: Self.goldenApps())
        let firstRoot = try #require(first.rootPage)
        #expect(pageLines(firstRoot) == golden.pages("firstLaunch"))
        expectItemTree(first)
        #expect(firstRoot.allPurgatoryItems.isEmpty)
        let afterFirst = dbinfo()
        for (key, value) in golden.dbinfo("firstLaunch") {
            #expect(afterFirst[key] == value, "\(key)")
        }
        #expect(afterFirst["setup_incomplete"] == nil)

        let second = try await launch()
        let secondRoot = try #require(second.rootPage)
        #expect(pageLines(secondRoot) == golden.pages("secondLaunch"))
        expectItemTree(second)
        let afterSecond = dbinfo()
        for (key, value) in golden.dbinfo("secondLaunch") {
            #expect(afterSecond[key] == value, "\(key)")
        }

        let third = try await launch()
        let thirdRoot = try #require(third.rootPage)
        #expect(pageLines(thirdRoot) == golden.pages("secondLaunch"))
        #expect(dbinfo() == afterSecond)
    }

    @Test("没有数据库时启动：扫描以后生成初始布局")
    func withoutDatabase() async throws {
        #expect(!FileManager.default.fileExists(atPath: databasePath))
        let springboard = try await launch()
        let root = try #require(springboard.rootPage)
        #expect(root.children.count > 0)
        #expect(root.allPurgatoryItems.isEmpty)
        #expect(dbinfo()["setup_incomplete"] == nil)
        expectItemTree(springboard)
    }

    @Test("扫描在根到达以前完成：先空跑一次，根到达后生成布局")
    func scanCompleteBeforeRoots() async throws {
        await makeDatabase()
        let manager = try #require(LPAppManager(atPath: databasePath, readOnly: false))
        let apps = Self.goldenApps()
        manager.roots { _, _ in
            for app in apps {
                manager._addNewRunnable(app)
            }
        }
        let deadline = Date().addingTimeInterval(60)
        while manager.lproot == nil || manager.sourcesStillScanning {
            try #require(Date() < deadline, "sources did not come online")
            try await Task.sleep(for: .milliseconds(10))
        }
        LPAppManager.shared = manager
        let springboard = LPSpringboard()
        springboard.activate()
        // The observer's initial call handled the scan before the roots' block ran.
        #expect(springboard.scanningComplete)
        #expect(springboard.rootPage == nil)
        #expect(springboard.springboard.item.items == nil)
        springboard.start()
        try await waitUntilStarted(springboard)
        let root = try #require(springboard.rootPage)
        #expect(pageLines(root) == GoldenLayout.shared.pages("firstLaunch"))
        #expect(dbinfo()["setup_incomplete"] == nil)
        expectItemTree(springboard)
    }
}
