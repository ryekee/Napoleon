import Testing
@testable import NapoleonCore

@Suite struct WindowFilterTests {
    @Test func currentAppModeKeepsOnlyThatPid() {
        #expect(WindowFilter.apply([w(1, pid: 10), w(2, pid: 20)], mode: .currentApp(10), scope: .init()).map(\.id) == [1])
    }
    @Test func scopeExcludesMinimizedByDefault() {
        let ws = [w(1, minimized: true), w(2)]
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init()).map(\.id) == [2])
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init(includeMinimized: true)).map(\.id) == [1, 2])
    }
    @Test func scopeExcludesHiddenAppsByDefault() {
        let ws = [w(1, hidden: true), w(2)]
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init()).map(\.id) == [2])
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init(includeHiddenApps: true)).map(\.id) == [1, 2])
    }
    @Test func scopeExcludesOtherSpacesByDefault() {
        let ws = [w(1, onCurrentSpace: false), w(2)]
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init()).map(\.id) == [2])
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init(includeOtherSpaces: true)).map(\.id) == [1, 2])
    }
    @Test func searchMatchesPinyin() {
        let m = WindowInfo(id: 1, pid: 1, appName: "备忘录", appBundleID: nil, title: "购物清单", pinyinTitle: "gouwu qingdan")
        #expect(WindowFilter.search([m], query: "gouwu").map(\.id) == [1])
    }

    @Test func searchMatchesLocalizedAppNameByPinyin() {
        // 中文系统下 Finder 的 localizedName 是“访达”；只给窗口标题做拼音会让 `f` 搜不到它。
        let finder = WindowInfo(
            id: 1,
            pid: 1,
            appName: "访达",
            appBundleID: "com.apple.finder",
            title: "下载",
            pinyinAppName: "fang da",
            pinyinTitle: "xia zai"
        )
        #expect(WindowFilter.search([finder], query: "f").map(\.id) == [1])
        #expect(WindowFilter.search([finder], query: "fang").map(\.id) == [1])
    }

    @Test func searchIgnoresPinyinWhenDisabled() {
        // 设置项「拼音匹配中文名称」关掉后拼音不参与匹配——但 App 名/标题本身照常能搜。
        let m = WindowInfo(id: 1, pid: 1, appName: "备忘录", appBundleID: nil, title: "购物清单", pinyinTitle: "gouwu qingdan")
        #expect(WindowFilter.search([m], query: "gouwu", includePinyin: false).isEmpty)
        #expect(WindowFilter.search([m], query: "购物", includePinyin: false).map(\.id) == [1])
    }

    @Test func searchWithLatinTitleUnaffectedByPinyinToggle() {
        let m = WindowInfo(id: 1, pid: 1, appName: "Safari", appBundleID: nil, title: "GitHub")
        #expect(WindowFilter.search([m], query: "github", includePinyin: true).map(\.id) == [1])
        #expect(WindowFilter.search([m], query: "github", includePinyin: false).map(\.id) == [1])
    }

    // MARK: - Task X4: cross-space windows classified by fullscreen space

    @Test func nonFullscreenCrossSpaceWindowExcludedByDefaultIncludedWhenScopeAllows() {
        let ws = [w(1, onCurrentSpace: false, fullscreen: false), w(2)]
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init()).map(\.id) == [2])
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init(includeOtherSpaces: true)).map(\.id) == [1, 2])
    }

    @Test func fullscreenCrossSpaceWindowAlwaysIncludedRegardlessOfScope() {
        let ws = [w(1, onCurrentSpace: false, fullscreen: true), w(2)]
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init()).map(\.id) == [1, 2])
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init(includeOtherSpaces: false)).map(\.id) == [1, 2])
    }

    @Test func currentSpaceWindowAlwaysIncludedRegardlessOfFullscreenOrScope() {
        let ws = [w(1, onCurrentSpace: true, fullscreen: false)]
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init()).map(\.id) == [1])
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init(includeOtherSpaces: false)).map(\.id) == [1])
    }

    // MARK: - Fullscreen escape: currentSpaceIsFullscreen relaxes cross-space filtering

    @Test func currentSpaceIsFullscreenDefaultsFalseAndKeepsCleanDesktopBehavior() {
        // 默认参数 false（在普通桌面）：普通跨 Space 窗口仍被排除，行为跟改动前一字不变。
        let ws = [w(1, onCurrentSpace: false, fullscreen: false), w(2)]
        #expect(WindowFilter.apply(ws, mode: .allWindows, scope: .init()).map(\.id) == [2])
    }

    @Test func currentSpaceIsFullscreenIncludesDesktopWindowsForEscape() {
        // 人被困在全屏 Space：普通跨 Space（桌面）窗口重新进入列表，才能切回桌面。
        let ws = [w(1, onCurrentSpace: false, fullscreen: false), w(2, onCurrentSpace: true)]
        #expect(
            WindowFilter.apply(ws, mode: .allWindows, scope: .init(), currentSpaceIsFullscreen: true).map(\.id) == [1, 2]
        )
    }

    @Test func currentSpaceIsFullscreenStillHonorsMinimizedAndHiddenFilters() {
        // 全屏逃生只放开「跨 Space」这一维，不覆盖最小化/隐藏 App 过滤。
        let ws = [w(1, minimized: true, onCurrentSpace: false), w(2, hidden: true, onCurrentSpace: false), w(3)]
        #expect(
            WindowFilter.apply(ws, mode: .allWindows, scope: .init(), currentSpaceIsFullscreen: true).map(\.id) == [3]
        )
    }
}
