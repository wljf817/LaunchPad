import Foundation
import Testing
@testable import LaunchPad

/// Searching the model: the results and the search pages the data source gives the grid while
/// searching (REF-SEARCH-009).
@MainActor
struct SearchFilterTests {
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
}
