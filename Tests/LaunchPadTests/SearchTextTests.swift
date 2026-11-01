import Foundation
import Testing
@testable import LaunchPad

/// The main grid layer's handling of the search field's text: the delay, the comparison with the text
/// last handled, and cancelling the timer (REF-SEARCH-008).
@MainActor
@Suite(.serialized)
struct SearchTextTests {
    /// A controller that records the search calls it gets, with when it got them, and handles them.
    final class RecordingController: Springboard {
        var calls: [String] = []
        var times: [DispatchTime] = []

        override func searchTextChanged(_ term: String) {
            calls.append("changed \(term)")
            times.append(.now())
            super.searchTextChanged(term)
        }

        override func searchTextCleared() {
            calls.append("cleared")
            times.append(.now())
            super.searchTextCleared()
        }
    }

    let controller = RecordingController()
    let field: ECTextInputLayer

    /// One page of two apps, one of which matches `Pro`.
    init() {
        let root = LPRoot()
        let page = LPPage(items: nil)
        page.children.add(makeTestApp("Prolific"))
        page.children.add(makeTestApp("Notes"))
        root.children.add(page)
        controller.rootPage = root
        controller.springboard.invalidate()
        field = controller.springboard.layer.searchTextInputLayer()!
    }

    /// Lets the main queue run for `milliseconds`.
    func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Sets `Pro` and waits for it to be handled.
    func filterPro() async throws {
        field.stringValue = "Pro"
        let deadline = Date().addingTimeInterval(5)
        while controller.calls.isEmpty {
            try #require(Date() < deadline)
            await wait(5)
        }
    }

    @Test("设 Pro 后过了 150 ms 才调一次 -searchTextChanged:")
    func delay() async throws {
        let start = DispatchTime.now()
        try await filterPro()
        await wait(400)
        #expect(controller.calls == ["changed Pro"])
        #expect(controller.times[0].uptimeNanoseconds - start.uptimeNanoseconds >= 150_000_000)
        #expect(controller.springboard.filtering)
    }

    @Test("依次设 P、Pr、Pro 只按 Pro 调一次")
    func typing() async {
        field.stringValue = "P"
        field.stringValue = "Pr"
        field.stringValue = "Pro"
        await wait(400)
        #expect(controller.calls == ["changed Pro"])
    }

    @Test("按 Pro 过滤后设 Pr 再设回 Pro，不再调")
    func changedBack() async throws {
        try await filterPro()
        field.stringValue = "Pr"
        field.stringValue = "Pro"
        await wait(400)
        #expect(controller.calls == ["changed Pro"])
    }

    @Test("设空时在设值当中调 -searchTextCleared，清空过滤设的空文字不再调")
    func cleared() async throws {
        try await filterPro()
        field.stringValue = ""
        #expect(controller.calls == ["changed Pro", "cleared"])
        #expect(!controller.springboard.filtering)
        await wait(400)
        #expect(controller.calls == ["changed Pro", "cleared"])
    }

    @Test("设 Pro 后 -cancelTimers，不调")
    func cancelTimers() async {
        field.stringValue = "Pro"
        controller.springboard.layer.cancelTimers()
        await wait(400)
        #expect(controller.calls == [])
    }

    @Test("设 Pro 后主网格变为不可见，不调")
    func hidden() async {
        controller.springboard.setVisible(true)
        field.stringValue = "Pro"
        controller.springboard.setVisible(false)
        await wait(400)
        #expect(controller.calls == [])
    }
}
