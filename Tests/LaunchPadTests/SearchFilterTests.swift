import Foundation
import Testing
@testable import LaunchPad

/// Searching the model: the results and the search pages the data source gives the grid while
/// searching (REF-SEARCH-009).
@MainActor
struct SearchFilterTests {
    /// A controller that records the titles it tries to match.
    final class RecordingSpringboard: Springboard {
        var triedTitles: [String] = []

        override func _wordFromTitle(_ title: String, matchesTerm term: String) -> UInt {
            triedTitles.append(title)
            return super._wordFromTitle(title, matchesTerm: term)
        }
    }

    func makeApp(_ title: String, file: String? = nil) -> LPApp {
        let app = makeTestApp(title)
        if let file {
            app._lastURL = URL(fileURLWithPath: "/Applications/\(file)", isDirectory: true)
        }
        return app
    }

    func titles(_ items: AnyObject?) -> [String] {
        ((items as? NSArray) as? [LPItem])?.map { $0.title ?? "" } ?? []
    }

    /// The cases the original's `-_wordFromTitle:matchesTerm:` gave at runtime (REF-SEARCH-009): title,
    /// term, whether it matches.
    nonisolated static let matchCases: [(String, String, Bool)] = [
        ("Safari", "Saf", true),
        ("Safari", "saf", true),
        ("Safari", "SAFARI", true),
        ("Safari", "Safarix", false),
        ("Safari", "fari", false),
        ("Photo Booth", "Booth", true),
        ("Photo Booth", "boo", true),
        ("Photo Booth", "oth", false),
        ("Activity Monitor", "Mon", true),
        ("FaceTime", "Time", true),
        ("FaceTime", "time", true),
        ("FaceTime", "ime", false),
        ("TextEdit", "Edit", true),
        ("iMovie", "Movie", true),
        ("XCode", "Code", false),
        ("A B C Tool", "AT", true),
        ("A B C Tool", "ABC", true),
        ("A B C Tool", "C", true),
        ("Photo Booth", "PB", true),
        ("Photo Booth", "pb", true),
        ("Photo Booth", "P B", true),
        ("Photo Booth", "BP", false),
        ("Photo Booth", "PBX", false),
        ("Final Cut Pro", "FCP", true),
        ("Final Cut Pro", "FC", true),
        ("Final Cut Pro", "CP", false),
        ("FaceTime", "FT", true),
        ("iMovie", "IM", true),
        ("DVD Player", "DP", true),
        ("Wi-Fi Explorer", "WFE", true),
        ("Photo Booth", "PhotoB", true),
        ("App Store", "apps", true),
        ("Photo Booth", "Photo  Booth", true),
        ("App Store", "Ap St", false),
        ("Photo Booth", " Booth", false),
        ("Photo Booth", "Booth ", false),
        ("Photo Booth", "Photo ", true),
        ("Café Rouge", "cafe", true),
        ("Cafe", "café", true),
        ("Ångström", "angs", true),
        ("Über App", "uber", true),
        ("Résumé Builder", "RB", true),
        ("系统设置", "系统", true),
        ("系统设置", "设置", true),
        ("系统设置", "统", false),
        ("计算器", "算", false),
        ("QQ音乐", "音乐", true),
        ("微信WeChat", "WeChat", true),
        ("测试应用", "应用", true),
        ("Wi-Fi Explorer", "Fi", true),
        ("Wi-Fi Explorer", "wifi", false),
        ("1Password 7", "7", true),
        ("1Password 7", "pass", false),
    ]

    @Test("名称与搜索词匹配与否与原版的用例表相同", arguments: matchCases)
    func wordMatch(title: String, term: String, matches: Bool) {
        #expect((Springboard()._wordFromTitle(title, matchesTerm: term) != UInt(NSNotFound)) == matches)
    }

    @Test("结果按模型深度优先的顺序，含文件夹里的应用，文件夹本身和找不到文件的应用不算")
    func resultOrder() {
        let controller = Springboard()
        let root = LPRoot()
        let first = LPPage(items: nil)
        let second = LPPage(items: nil)
        root.children.add(first)
        root.children.add(second)
        let folder = LPGroup(groupWithTitle: "Alps", andChildren: nil)
        let folderPage = LPPage(items: nil)
        folder.children.add(folderPage)
        folderPage.children.add(makeApp("Alpine"))
        let missing = makeApp("Alder")
        missing.notFound = true
        first.children.add(makeApp("Alpha"))
        first.children.add(folder)
        first.children.add(makeApp("Beta"))
        first.children.add(missing)
        first.children.add(makeApp("Alto"))
        second.children.add(makeApp("Alpha Two"))
        controller.rootPage = root

        #expect(titles(controller.searchResults(forTerm: "al")) == ["Alpha", "Alpine", "Alto", "Alpha Two"])
    }

    @Test("名称不匹配时按文件名匹配，文件名与名称相同时不再试")
    func fileNameMatch() {
        let controller = RecordingSpringboard()
        let root = LPRoot()
        let page = LPPage(items: nil)
        root.children.add(page)
        page.children.add(makeApp("照片", file: "Photos.app"))
        page.children.add(makeApp("Zed", file: "Zed.app"))
        page.children.add(makeApp("Phone", file: "Dialer.app"))
        controller.rootPage = root

        #expect(titles(controller.searchResults(forTerm: "pho")) == ["照片", "Phone"])
        #expect(controller.triedTitles == ["照片", "Photos", "Zed", "Phone"])
    }

    @Test("搜索时根的 items 是搜索页，36 个结果在 5 × 7 下切成 35 和 1 两页；清空后回到模型的页")
    func searchPages() throws {
        let controller = Springboard()
        let root = LPRoot()
        let page = LPPage(items: nil)
        root.children.add(page)
        let folder = LPGroup(groupWithTitle: "Folder", andChildren: nil)
        let folderPage = LPPage(items: nil)
        folder.children.add(folderPage)
        page.children.add(folder)
        for index in 1...36 {
            folderPage.children.add(makeApp("App \(index)"))
        }
        controller.rootPage = root

        controller.searchTextChanged("app")
        #expect(controller.searching)
        let pages = try #require(controller.value(forKey: "items", ofItem: nil, withInfo: nil) as? [SBSearchPage])
        #expect(pages.count == 2)
        #expect(titles(controller.value(forKey: "items", ofItem: pages[0], withInfo: nil)) == (1...35).map { "App \($0)" })
        #expect(titles(controller.value(forKey: "items", ofItem: pages[1], withInfo: nil)) == ["App 36"])
        #expect(controller.value(forKey: "items", ofItem: folder, withInfo: nil) == nil)
        #expect(controller.value(forKey: "items", ofItem: page, withInfo: nil) == nil)

        controller.searchTextCleared()
        #expect(!controller.searching)
        #expect(controller.value(forKey: "items", ofItem: nil, withInfo: nil) === root.children)
        #expect(controller.value(forKey: "items", ofItem: folder, withInfo: nil) === folder.children)
    }
}
