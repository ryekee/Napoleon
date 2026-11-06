import NapoleonCore
import Testing
@testable import Napoleon

@Suite struct SwitcherItemTests {
    private func window(
        id: WindowID,
        pid: ProcessID,
        bundleID: String?,
        title: String = ""
    ) -> WindowInfo {
        WindowInfo(id: id, pid: pid, appName: "App", appBundleID: bundleID, title: title)
    }

    @Test func windowModeKeepsEveryWindowInMRUOrder() {
        let windows = [
            window(id: 1, pid: 10, bundleID: "a"),
            window(id: 2, pid: 10, bundleID: "a")
        ]
        #expect(SwitcherItem.make(from: windows, groupByApplication: false).map(\.id) == [1, 2])
    }

    @Test func applicationModeGroupsByBundleAndKeepsFirstWindowAsRepresentative() {
        let windows = [
            window(id: 1, pid: 10, bundleID: "a", title: "Newest A"),
            window(id: 2, pid: 20, bundleID: "b"),
            window(id: 3, pid: 11, bundleID: "a", title: "Older A")
        ]
        let items = SwitcherItem.make(from: windows, groupByApplication: true)
        #expect(items.map(\.id) == [1, 2])
        #expect(items[0].windows.map(\.id) == [1, 3])
    }

    @Test func missingBundleIDFallsBackToPid() {
        let windows = [
            window(id: 1, pid: 10, bundleID: nil),
            window(id: 2, pid: 10, bundleID: nil),
            window(id: 3, pid: 20, bundleID: nil)
        ]
        #expect(SwitcherItem.make(from: windows, groupByApplication: true).map(\.windows.count) == [2, 1])
    }

    @Test func closeOnAWindowRequiresBothWindowIDAndOwner() {
        let clicked = window(id: 1, pid: 10, bundleID: "a")
        let target = WindowCloseTarget(clicked, grouped: false)
        #expect(target.includes(clicked))
        #expect(!target.includes(window(id: 2, pid: 10, bundleID: "a")))
        #expect(!target.includes(window(id: 1, pid: 11, bundleID: "a")))
    }

    @Test func closingASearchedGroupIncludesWindowsOutsideTheResults() {
        var minimized = window(id: 3, pid: 11, bundleID: "a")
        minimized.isMinimized = true
        let all = [
            window(id: 1, pid: 10, bundleID: "a", title: "Match"),
            window(id: 2, pid: 20, bundleID: "b", title: "Match"),
            minimized
        ]
        let visible = WindowFilter.apply(all, mode: .allWindows, scope: .init())
        let results = WindowFilter.search(visible, query: "Match")
        let first = SwitcherItem.make(from: results, groupByApplication: true)[0]
        let target = WindowCloseTarget(first.primary, grouped: true)
        #expect(all.filter(target.includes).map(\.id) == [1, 3])
    }

    @Test func closingAnUnbundledGroupMatchesOnlyItsPID() {
        let target = WindowCloseTarget(window(id: 1, pid: 10, bundleID: nil), grouped: true)
        #expect(target.includes(window(id: 2, pid: 10, bundleID: "")))
        #expect(!target.includes(window(id: 3, pid: 20, bundleID: nil)))
    }

    @Test func cyclingPrimaryKeepsStableCardIdentityAndWraps() {
        let item = SwitcherItem([
            window(id: 1, pid: 10, bundleID: "a", title: "One"),
            window(id: 2, pid: 10, bundleID: "a", title: "Two"),
            window(id: 3, pid: 10, bundleID: "a", title: "Three")
        ])

        let second = item.steppingPrimary(backward: false)
        #expect(second.id == 1)
        #expect(second.primary.id == 2)
        #expect(second.secondaryWindows.map(\.id) == [1, 3])
        #expect(second.steppingPrimary(backward: true).primary.id == 1)
        #expect(item.steppingPrimary(backward: true).primary.id == 3)
    }
}
