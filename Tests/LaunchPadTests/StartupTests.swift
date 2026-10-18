import CoreServices
import Foundation
import Testing
@testable import LaunchPad

/// Three startups on one database (task 7.2): the initial layout, the correction at the second
/// startup, and no correction at the third (REF-LAYOUT-007, REF-LAYOUT-008).
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

    func launch(injecting apps: [LPApp] = []) async throws -> StartupHelper {
        let helper = StartupHelper(databasePath: databasePath) { manager, _ in
            for app in apps {
                manager._addNewRunnable(app)
            }
        }
        try await helper.waitUntilComplete()
        return helper
    }

    @Test("布局只生成一次、启动时修正布局")
    func threeStartups() async throws {
        let golden = GoldenLayout.shared
        await makeDatabase()

        let first = try await launch(injecting: Self.goldenApps())
        let firstRoot = try #require(first.rootPage)
        #expect(pageLines(firstRoot) == golden.pages("firstLaunch"))
        #expect(firstRoot.allPurgatoryItems.isEmpty)
        let afterFirst = dbinfo()
        for (key, value) in golden.dbinfo("firstLaunch") {
            #expect(afterFirst[key] == value, "\(key)")
        }
        #expect(afterFirst["setup_incomplete"] == nil)

        let second = try await launch()
        let secondRoot = try #require(second.rootPage)
        #expect(pageLines(secondRoot) == golden.pages("secondLaunch"))
        let afterSecond = dbinfo()
        for (key, value) in golden.dbinfo("secondLaunch") {
            #expect(afterSecond[key] == value, "\(key)")
        }

        let third = try await launch()
        let thirdRoot = try #require(third.rootPage)
        #expect(pageLines(thirdRoot) == golden.pages("secondLaunch"))
        #expect(dbinfo() == afterSecond)
    }
}
