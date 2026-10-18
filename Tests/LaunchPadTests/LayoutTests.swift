import Foundation
import Testing
@testable import LaunchPad

/// The golden data of REF-LAYOUT-008: the apps the original found in the reference VM, in the order
/// they reached its hidden page, and the layouts it built from them.
struct GoldenLayout: @unchecked Sendable {
    let json: [String: Any]

    static let shared: GoldenLayout = {
        let url = Bundle.module.url(forResource: "golden-layout-24G90", withExtension: "json", subdirectory: "Fixtures")!
        return GoldenLayout(json: try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])
    }()

    var sourcePaths: [String] { json["sourcePaths"] as! [String] }
    var maxPerPage: UInt { json["maxPerPage"] as! UInt }
    var maxPerGroupPage: UInt { json["maxPerGroupPage"] as! UInt }
    var apps: [[String: Any]] { (json["apps"] as! [[String: Any]]).sorted { ($0["order"] as! Int) < ($1["order"] as! Int) } }

    func pages(_ launch: String) -> [String] {
        ((json[launch] as! [String: Any])["pages"] as! [[Any]]).enumerated().flatMap { index, page in
            ["page \(index)"] + page.flatMap { entry -> [String] in
                let entry = entry as! [String: Any]
                if let bundleID = entry["app"] as? String {
                    return ["  \(bundleID)"]
                }
                let folderPages = (entry["pages"] as! [[String]]).enumerated().flatMap { index, ids in
                    ["    page \(index)"] + ids.map { "      \($0)" }
                }
                return ["  folder \(entry["folder"]!) flags \(entry["flags"]!)"] + folderPages
            }
        }
    }

    func dbinfo(_ launch: String) -> [String: String] {
        (json[launch] as! [String: Any])["dbinfo"] as! [String: String]
    }

    /// Unscanned app items with what the layout reads from them.
    func makeApps() -> [LPApp] {
        apps.map { entry in
            let app = makeTestApp(entry["title"] as! String, bundleID: entry["bundleID"] as? String)
            app._lastURL = URL(fileURLWithPath: entry["path"] as! String)
            app._categoryUTI = entry["category"] as? String
            app._flags = UInt64(entry["flags"] as! Int)
            return app
        }
    }
}

/// The pages of a root in the golden data's notation.
func pageLines(_ root: LPRoot) -> [String] {
    (root.children as! [LPPage]).enumerated().flatMap { index, page in
        ["page \(index)"] + (page.children as! [LPItem]).flatMap { item -> [String] in
            guard let folder = item as? LPGroup else {
                return ["  \((item as! LPApp).bundleIdentifier!)"]
            }
            let folderPages = (folder.children as! [LPPage]).enumerated().flatMap { index, folderPage in
                ["    page \(index)"] + (folderPage.children as! [LPApp]).map { "      \($0.bundleIdentifier!)" }
            }
            return ["  folder \(folder.title!) flags \(folder.flags)"] + folderPages
        }
    }
}

/// The initial layout (task 7.1, REF-LAYOUT-005).
@MainActor
struct LayoutTests {
    init() {
        launchPadBundle = testResources
    }

    func layout(_ root: LPRoot, sources: [String] = GoldenLayout.shared.sourcePaths, maxPerPage: UInt = 35) -> LPLayout {
        LPLayout(rootPage: root, sources: sources, maxItemsPerPage: maxPerPage, maxItemsPerGroup: maxPerPage)
    }

    @Test("与原版生成的布局一致")
    func matchesTheOriginal() {
        let golden = GoldenLayout.shared
        let root = LPRoot()
        for app in golden.makeApps() {
            root.addItemToPurgatory(app)
        }
        let layout = LPLayout(rootPage: root, sources: golden.sourcePaths, maxItemsPerPage: golden.maxPerPage, maxItemsPerGroup: golden.maxPerGroupPage)
        #expect(layout.layoutForInitial(root.allPurgatoryItems))
        #expect(pageLines(root) == golden.pages("firstLaunch"))
    }

    @Test("文件夹标题的语言")
    func folderTitlesUseTheStrings() {
        let root = LPRoot()
        let utility = makeTestApp("Util", bundleID: "com.example.util")
        utility._lastURL = URL(fileURLWithPath: "/Applications/Utilities/Util.app")
        let game = makeTestApp("Game", bundleID: "com.example.game")
        game._lastURL = URL(fileURLWithPath: "/Applications/Game.app")
        game._categoryUTI = "public.app-category.games"
        let nested = makeTestApp("Nested", bundleID: "com.example.nested")
        nested._lastURL = URL(fileURLWithPath: "/Applications/Top.app")
        let deeper = makeTestApp("Deeper", bundleID: "com.example.deeper")
        deeper._lastURL = URL(fileURLWithPath: "/Applications/Suite/Plugins/Deeper.app")
        for app in [utility, game, nested, deeper] {
            root.addItemToPurgatory(app)
        }
        layout(root).layoutForInitial(root.allPurgatoryItems)

        let titles = (root.children as! [LPPage]).flatMap { ($0.children as! [LPItem]).compactMap { ($0 as? LPGroup)?.title } }
        // REF-LAYOUT-009, zh_CN: Other, Games and "%@ (Other)".
        #expect(titles.contains("其他"))
        #expect(titles.contains("游戏"))
        #expect(titles.contains("Suite（其他）"))
    }

    @Test("排除的应用")
    func excludedApps() {
        let root = LPRoot()
        // From REF-LAYOUT-004 `exclude`: a bundle ID, a `match` rule (`setup`), a `prefix` rule on a
        // bundle ID (`com.adobe.estoolkit`), and a `contains` rule (`uninstall`).
        let cases: [(String, String, String)] = [
            ("Updater", "com.Adobe.Uninstall", "/Applications/Updater.app"),
            ("Setup", "com.example.setup", "/Applications/Setup.app"),
            ("Toolkit", "com.adobe.estoolkit.2024", "/Applications/Toolkit.app"),
            ("Remover", "com.example.remover", "/Applications/Remover Uninstall Tool.app"),
            ("Kept", "com.example.kept", "/Applications/Kept.app"),
        ]
        var notAdded: [String] = []
        for (title, bundleID, path) in cases {
            let app = makeTestApp(title, bundleID: bundleID)
            app._lastURL = URL(fileURLWithPath: path)
            root.addItemToPurgatory(app)
        }
        let store = makeTestApp("StoreSetup", bundleID: "com.example.storesetup")
        store._lastURL = URL(fileURLWithPath: "/Applications/Setup.app")
        store._flags = 0x1
        root.addItemToPurgatory(store)
        let layout = layout(root)
        layout.itemNotAddedBlock = { notAdded.append($0.title ?? "") }
        layout.layoutForInitial(root.allPurgatoryItems)

        let placed = Set((root.children as! [LPPage]).flatMap { ($0.children as! [LPItem]).compactMap { ($0 as? LPApp)?.title } })
        #expect(placed == ["Kept", "StoreSetup"])
        #expect(Set(notAdded) == ["Updater", "Setup", "Toolkit", "Remover"])
    }

    @Test("一页放不下")
    func overflowGoesToTheNextPage() {
        let root = LPRoot()
        let apps = (0..<12).map { index in
            let app = makeTestApp(String(format: "App %02d", index), bundleID: "com.example.app\(index)")
            app._lastURL = URL(fileURLWithPath: "/Applications/App \(index).app")
            return app
        }
        for app in apps {
            root.addItemToPurgatory(app)
        }
        layout(root, maxPerPage: 5).layoutForInitial(root.allPurgatoryItems)

        // The first page holds the `mainPage` folder (created even when none of its apps is there);
        // the rest is placed from the second page on (REF-LAYOUT-005 steps 3 and 7).
        let pages = (root.children as! [LPPage]).map { ($0.children as! [LPItem]).map { $0.title! } }
        #expect(pages == [["其他"], (0..<5).map { apps[$0].title! }, (5..<10).map { apps[$0].title! }, (10..<12).map { apps[$0].title! }])
    }

    @Test func gameList() {
        let root = LPRoot()
        // com.blizzard.diablo3 is in `includeAsGame` (REF-LAYOUT-004); its category says nothing.
        let listed = makeTestApp("Diablo", bundleID: "com.blizzard.diablo3")
        listed._lastURL = URL(fileURLWithPath: "/Applications/Diablo.app")
        let byCategory = makeTestApp("Board", bundleID: "com.example.board")
        byCategory._lastURL = URL(fileURLWithPath: "/Applications/Board.app")
        byCategory._categoryUTI = "public.app-category.board-games"
        let other = makeTestApp("Notes", bundleID: "com.example.notes")
        other._lastURL = URL(fileURLWithPath: "/Applications/Notes.app")
        for app in [listed, byCategory, other] {
            root.addItemToPurgatory(app)
        }
        let layout = layout(root)
        layout.layoutForInitial(root.allPurgatoryItems)

        let games = try? #require(layout.groupForKind(1))
        #expect(games?.title == "游戏")
        #expect(((games?.children.firstObject as? LPPage)?.children as? [LPItem])?.map(\.title) == ["Board", "Diablo"])
        #expect(other.parentPage?.parentContainer === root)
    }

    @Test func correctionRemovesExcludedAppsAndEmptyFolders() {
        let root = LPRoot()
        let page = LPPage(items: nil)
        let second = LPPage(items: nil)
        root.children.addObjects(from: [page, second])
        let kept = makeTestApp("Kept", bundleID: "com.example.kept")
        let setup = makeTestApp("Setup", bundleID: "com.example.setup")
        let uninstaller = makeTestApp("Uninstaller", bundleID: "com.Adobe.Uninstall")
        let folder = LPGroup(groupWithTitle: "F", andChildren: [LPPage(items: [uninstaller])])
        page.children.addObjects(from: [kept, setup, folder])
        second.children.add(makeTestApp("Alone", bundleID: "com.example.alone-uninstall"))
        let alone = second.children[0] as! LPApp
        alone._lastURL = URL(fileURLWithPath: "/Applications/Alone Uninstall.app")

        var changes: (Bool, Bool, Bool)?
        layout(root).fixupLayout(withExcludeListVersion: 0, includeAsGameListVersion: 2, curationVersion: 8,
                                 itemExcluded: { $0.parentContainer?.children.remove($0) },
                                 itemIncludedAsGame: { _ in },
                                 changesMade: { changes = ($0, $1, $2) })

        #expect(changes.map { [$0.0, $0.1, $0.2] } == [true, false, false])
        // The folder's page counts as an emptied page, not as an emptied folder, so the folder
        // stays with an empty page (research paper §12.13).
        #expect((page.children as! [LPItem]).map(\.title) == ["Kept", "F"])
        #expect(folder.children.count == 1 && (folder.children[0] as! LPPage).children.count == 0)
        // The emptied root page goes; the root keeps at least one.
        #expect(root.children as NSArray == [page] as NSArray)
    }

    @Test func correctionMovesListedGamesIntoTheGamesFolder() throws {
        let root = LPRoot()
        let page = LPPage(items: nil)
        root.children.add(page)
        let games = LPGroup(groupWithTitle: "游戏", andChildren: [LPPage(items: nil)])
        games.kind = 1
        let diablo = makeTestApp("Diablo", bundleID: "com.blizzard.diablo3")
        page.children.addObjects(from: [games, diablo])
        let layout = layout(root)
        var moved: [LPItem] = []
        layout.fixupLayout(withExcludeListVersion: 5, includeAsGameListVersion: 0, curationVersion: 8,
                           itemExcluded: { _ in },
                           itemIncludedAsGame: { item in
                               moved.append(item)
                               let target = layout.groupForKind(1)?.firstAvailablePage(withMaxCount: layout.maxPerGroupPage, createIfNecessary: true)
                               target?.children.add(item)
                           },
                           changesMade: { _, _, _ in })

        #expect(moved.map(\.title) == ["Diablo"])
        #expect(diablo.parentGroup === games)
        #expect((page.children as! [LPItem]).map(\.title) == ["游戏"])
    }
}

