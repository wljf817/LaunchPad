import CoreServices
import Foundation
import Testing
@testable import LaunchPad

/// App scanning (task 6.1, REF-LAYOUT-003), on bundles made in a temporary directory.
///
/// The test database records the FSEvents UUID of every source's volume, so at startup the
/// original's own check finds the volumes unchanged and does not scan the real system (the Preboot
/// volume of the cryptex source has no UUID and is always scanned). The tests then scan their own
/// directories with `scanForApplicationsAtPath:fromSource:options:completion:`.
@MainActor
final class ScanFixture {
    let directory = TemporaryDirectory()
    var manager: LPAppManager!

    var apps: String { directory.path("apps") }

    /// Sources 1 to 5 with their paths (REF-LAYOUT-003).
    static let recordedSources = [
        ("read only system", "/System/Applications"), ("system", "/Applications"),
        ("user", NSHomeDirectory() + "/Applications"), ("shared user", "/Users/Shared"),
        ("internal", "/AppleInternal/Applications"),
    ]

    static func volumeUUID(_ path: String) -> String? {
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return nil }
        defer { close(fd) }
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0, let uuid = FSEventsCopyUUIDForDevice(volume.f_fsid.val.0) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Creates the database with the sources recorded, starts the manager and waits until every
    /// source has completed its first bring-up.
    func start() async throws {
        launchPadBundle = testResources
        try FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: true)
        let path = directory.path("db")
        let (storage, _, _, _) = await openStorage(at: path)
        await waitForDatabase(storage)
        var sql = "DELETE FROM dbinfo WHERE key = 'setup_incomplete';"
        for (name, sourcePath) in Self.recordedSources {
            let uuid = Self.volumeUUID(sourcePath).map { "'\($0)'" } ?? "NULL"
            sql += "INSERT INTO app_sources (uuid, flags, last_fsevent_id, fsevent_uuid) VALUES ('\(name)', 0, \(FSEventsGetCurrentEventId()), \(uuid));"
        }
        #expect(execute(path, sql) == 0)

        manager = LPAppManager(atPath: path, readOnly: false)
        var scanningWhenRootsArrived: Bool?
        manager.roots { [manager] _, _ in
            scanningWhenRootsArrived = manager?.sourcesStillScanning
        }
        let deadline = Date().addingTimeInterval(60)
        while manager.lproot == nil || manager.sourcesStillScanning {
            try #require(Date() < deadline, "sources did not come online")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scanningWhenRootsArrived == true)
    }

    /// Scans `path` the way a source does and waits for the completion and the database writes.
    func scan(_ path: String, options: UInt = 9) async {
        await withCheckedContinuation { continuation in
            manager.scanForApplications(atPath: path, fromSource: nil, options: options) { _ in
                continuation.resume()
            }
        }
        if let storage = manager.storage {
            await waitForDatabase(storage)
        }
    }

    /// The apps under this fixture's directory in a root's hidden page.
    func found(in root: LPRoot?) -> [LPApp] {
        (root?.allPurgatoryItems ?? []).compactMap { $0 as? LPApp }.filter {
            $0.lastURL?.path.hasPrefix(directory.url.path) ?? false
        }
    }
}

@MainActor
struct ScanTests {
    @Test("扫描未完成、卷没有变")
    func recordedVolumesAreNotScanned() async throws {
        let fixture = ScanFixture()
        try await fixture.start()
        let manager = try #require(fixture.manager)
        #expect(manager.sources.map(\.location) == [1, 2, 6, 3, 4, 5])
        #expect(manager.sources.allSatisfy { $0.initialBringupComplete })
        // Only the cryptex source, whose volume has no FSEvents UUID, was scanned.
        let cryptexes = "/System/Volumes/Preboot/Cryptexes/App/System/Applications"
        for case let app as LPApp in manager.lproot?.allPurgatoryItems ?? [] {
            #expect(app.lastURL?.path.hasPrefix(cryptexes) == true, "\(app.lastURL?.path ?? "")")
        }
    }

    @Test("每个应用一项")
    func everyAppOnce() async throws {
        let fixture = ScanFixture()
        try await fixture.start()
        let apps = fixture.apps
        try makeAppBundle(at: apps + "/Top.app", bundleID: "com.example.top")
        try makeAppBundle(at: apps + "/Sub/Inner.app", bundleID: "com.example.inner")
        try makeAppBundle(at: apps + "/Sub/Deeper/Deepest.app", bundleID: "com.example.deepest", info: ["LSApplicationCategoryType": "public.app-category.games"])
        try makeAppBundle(at: apps + "/NoIdentifier.app", bundleID: nil)
        await fixture.scan(apps)
        await fixture.scan(apps)

        let found = fixture.found(in: fixture.manager.lproot)
        #expect(Set(found.compactMap(\.bundleIdentifier)) == ["com.example.top", "com.example.inner", "com.example.deepest", "NoIdentifier"])
        #expect(found.count == 4)
        let deepest = try #require(found.first { $0.bundleIdentifier == "com.example.deepest" })
        #expect(deepest.title == "Deepest")
        #expect(deepest.categoryUTI == "public.app-category.games")
        #expect(deepest.isGame())
        #expect(deepest.lastURL?.path == apps + "/Sub/Deeper/Deepest.app")
        #expect(deepest.bookmarkData != nil)
        #expect(fixture.found(in: fixture.manager.lpversroot).isEmpty)
    }

    @Test func skippedEntries() async throws {
        let fixture = ScanFixture()
        try await fixture.start()
        let apps = fixture.apps
        try makeAppBundle(at: apps + "/Kept.app", bundleID: "com.example.kept")
        try makeAppBundle(at: apps + "/.Invisible/InInvisible.app", bundleID: "com.example.invisible")
        try makeAppBundle(at: apps + "/.Dotted.app", bundleID: "com.example.dotted")
        try makeAppBundle(at: apps + "/Kept.app/Contents/Nested.app", bundleID: "com.example.nested")
        try FileManager.default.createDirectory(atPath: apps + "/Plugin.bundle", withIntermediateDirectories: true)
        try makeAppBundle(at: apps + "/Plugin.bundle/InBundle.app", bundleID: "com.example.inbundle")
        FileManager.default.createFile(atPath: apps + "/File.app", contents: Data())
        await fixture.scan(apps)

        #expect(fixture.found(in: fixture.manager.lproot).compactMap(\.bundleIdentifier) == ["com.example.kept"])
    }

    @Test func flags() async throws {
        let fixture = ScanFixture()
        try await fixture.start()
        let apps = fixture.apps
        try makeAppBundle(at: apps + "/Agent.app", bundleID: "com.example.agent", info: ["LSUIElement": true])
        try makeAppBundle(at: apps + "/Tile.app", bundleID: "com.example.tile", info: ["NSDockTilePlugIn": "Tile.docktileplugin"])
        try makeAppBundle(at: apps + "/MenuTile.app", bundleID: "com.example.menutile", info: ["NSDockTilePlugIn": "Tile.docktileplugin", "NSDockTilePlugInMenuOnly": true])
        try makeAppBundle(at: apps + "/Store.app", bundleID: "com.example.store")
        try FileManager.default.createDirectory(atPath: apps + "/Store.app/Contents/_MASReceipt", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: apps + "/Store.app/Contents/_MASReceipt/receipt", contents: Data([1]))
        await fixture.scan(apps)

        let flags = Dictionary(uniqueKeysWithValues: fixture.found(in: fixture.manager.lproot).map { ($0.bundleIdentifier!, $0.flags) })
        #expect(flags == ["com.example.agent": 0x8, "com.example.tile": 0x80, "com.example.menutile": 0, "com.example.store": 0x1])
    }

    @Test func aliasesAndSymbolicLinks() async throws {
        let fixture = ScanFixture()
        try await fixture.start()
        let apps = fixture.apps
        let elsewhere = fixture.directory.path("elsewhere")
        let aliased = try makeAppBundle(at: elsewhere + "/Aliased.app", bundleID: "com.example.aliased")
        try makeAppBundle(at: elsewhere + "/Linked.app", bundleID: "com.example.linked")
        try makeAppBundle(at: elsewhere + "/Folder/InLinkedFolder.app", bundleID: "com.example.inlinkedfolder")
        let bookmark = try aliased.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: URL(fileURLWithPath: apps + "/Aliased alias"))
        try FileManager.default.createSymbolicLink(atPath: apps + "/Link.app", withDestinationPath: elsewhere + "/Linked.app")
        try FileManager.default.createSymbolicLink(atPath: apps + "/LinkedFolder", withDestinationPath: elsewhere + "/Folder")
        await fixture.scan(apps)

        let found = fixture.found(in: fixture.manager.lproot)
        #expect(Set(found.compactMap(\.bundleIdentifier)) == ["com.example.aliased", "com.example.linked"])
        let alias = try #require(found.first { $0.bundleIdentifier == "com.example.aliased" })
        #expect(alias.title == "Aliased alias")
        #expect(alias.isAlias && alias.flags == 0x20)
        #expect(alias.lastURL?.path == apps + "/Aliased alias")
        let link = try #require(found.first { $0.bundleIdentifier == "com.example.linked" })
        #expect(link.title == "Link")
        // A symbolic link also reports itself as an alias file, so both bits are set.
        #expect(link.isSymlink && link.flags == 0x30)
        #expect(link.lastURL?.path == apps + "/Link.app")
    }

    @Test func olderCopyIsKeptAsOldVersion() async throws {
        let fixture = ScanFixture()
        try await fixture.start()
        let newer = fixture.apps + "/newer"
        let older = fixture.apps + "/older"
        try makeAppBundle(at: newer + "/Multi.app", bundleID: "com.example.multi", version: "2.0")
        try makeAppBundle(at: older + "/Multi.app", bundleID: "com.example.multi", version: "1.0")
        await fixture.scan(newer)
        await fixture.scan(older)

        #expect(fixture.found(in: fixture.manager.lproot).map { $0.lastURL!.path } == [newer + "/Multi.app"])
        #expect(fixture.found(in: fixture.manager.lpversroot).map { $0.lastURL!.path } == [older + "/Multi.app"])
    }

    @Test func newerCopyReplacesTheKnownOne() async throws {
        let fixture = ScanFixture()
        try await fixture.start()
        let newer = fixture.apps + "/newer"
        let older = fixture.apps + "/older"
        try makeAppBundle(at: older + "/Multi.app", bundleID: "com.example.multi", version: "1.0")
        try makeAppBundle(at: newer + "/Multi.app", bundleID: "com.example.multi", version: "2.0")
        await fixture.scan(older)
        let known = try #require(fixture.found(in: fixture.manager.lproot).first)
        await fixture.scan(newer)

        let shown = fixture.found(in: fixture.manager.lproot)
        #expect(shown.count == 1)
        #expect(shown.first === known)
        #expect(known.lastURL?.path == newer + "/Multi.app")
        let stashed = fixture.found(in: fixture.manager.lpversroot)
        #expect(stashed.map { $0.lastURL!.path } == [older + "/Multi.app"])
        #expect(stashed.first?.uuid != known.uuid)
    }

    @Test func versionExceptionsKeepEveryCopy() async throws {
        let fixture = ScanFixture()
        try await fixture.start()
        let first = fixture.apps + "/first"
        let second = fixture.apps + "/second"
        // org.eclipse.eclipse is in version_exceptions (REF-LAYOUT-004). Copies with an Apple bundle
        // ID are avoided: LaunchServices reports some of their versions as unsupported.
        try makeAppBundle(at: first + "/Eclipse.app", bundleID: "org.eclipse.eclipse", version: "2.0")
        try makeAppBundle(at: second + "/Eclipse.app", bundleID: "org.eclipse.eclipse", version: "1.0")
        await fixture.scan(first)
        await fixture.scan(second)

        #expect(Set(fixture.found(in: fixture.manager.lproot).map { $0.lastURL!.path }) == [first + "/Eclipse.app", second + "/Eclipse.app"])
        #expect(fixture.found(in: fixture.manager.lpversroot).isEmpty)
    }

    @Test func pathsInsidePackagesOrInvisibleFolders() async throws {
        let fixture = ScanFixture()
        try await fixture.start()
        let manager = try #require(fixture.manager)
        let apps = fixture.apps
        try makeAppBundle(at: apps + "/A.app", bundleID: "com.example.a")
        try FileManager.default.createDirectory(atPath: apps + "/.hidden/sub", withIntermediateDirectories: true)
        #expect(manager.pathValidForApplications("/"))
        #expect(manager.pathValidForApplications(apps))
        #expect(!manager.pathValidForApplications(apps + "/A.app/Contents"))
        #expect(!manager.pathValidForApplications(apps + "/.hidden/sub"))
        #expect(!manager.pathValidForApplications(""))
    }
}

/// A full scan of this Mac's sources with a new database (task 6.2). `LAUNCHPAD_SCAN_SYSTEM` names
/// the file the list of apps found is written to (tab-separated: root, order, title, bundle ID,
/// flags, path).
let systemScanOutput = ProcessInfo.processInfo.environment["LAUNCHPAD_SCAN_SYSTEM"]

@MainActor
struct SystemScanTests {
    @Test(.enabled(if: systemScanOutput != nil))
    func scanThisMac() async throws {
        let directory = TemporaryDirectory()
        launchPadBundle = testResources
        let manager: LPAppManager = try #require(LPAppManager(atPath: directory.path("db"), readOnly: false))
        let deadline = Date().addingTimeInterval(300)
        while manager.lproot == nil || manager.sourcesStillScanning {
            try #require(Date() < deadline, "sources did not come online")
            try await Task.sleep(for: .milliseconds(50))
        }
        var lines = ["root\torder\ttitle\tbundleID\tflags\tpath"]
        for (name, root) in [("layout", manager.lproot), ("old version", manager.lpversroot)] {
            for (order, item) in (root?.allPurgatoryItems ?? []).enumerated() {
                guard let app = item as? LPApp else { continue }
                lines.append("\(name)\t\(order)\t\(app.title ?? "")\t\(app.bundleIdentifier ?? "")\t0x\(String(app.flags, radix: 16))\t\(app.lastURL?.path ?? "")")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: try #require(systemScanOutput), atomically: true, encoding: .utf8)
        #expect(lines.count > 1)
    }
}
