import CoreGraphics
import NapoleonCore
import Testing
@testable import Napoleon

@Suite struct WindowServerReconcilerFilterTests {
    /// `CGWindowListCopyWindowInfo` 一条目的最小构造器——只填本函数真正会读的键。
    private func entry(
        id: Int = 1,
        pid: Int = 100,
        layer: Int = 0,
        alpha: Double = 1,
        name: String? = "Title",
        bounds: [String: CGFloat]? = ["X": 0, "Y": 0, "Width": 800, "Height": 600]
    ) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha
        ]
        if let name { dict[kCGWindowName as String] = name }
        if let bounds { dict[kCGWindowBounds as String] = bounds }
        return dict
    }

    @Test func keepsOrdinaryAppWindows() {
        let result = WindowServerReconciler.realAppWindows(from: [entry()])
        #expect(result == [OnScreenWindow(windowID: 1, pid: 100, title: "Title",
                                          bounds: CGRect(x: 0, y: 0, width: 800, height: 600))])
    }

    /// 菜单、Dock、状态栏项、以及 Napoleon 自己的切换器浮层都在第 0 层之上。
    @Test func dropsEverythingAboveLayerZero() {
        #expect(WindowServerReconciler.realAppWindows(from: [entry(layer: 25)]).isEmpty)
    }

    @Test func dropsFullyTransparentWindows() {
        #expect(WindowServerReconciler.realAppWindows(from: [entry(alpha: 0)]).isEmpty)
    }

    @Test func dropsZeroAreaWindows() {
        let flat = ["X": 0, "Y": 0, "Width": 800, "Height": 0] as [String: CGFloat]
        #expect(WindowServerReconciler.realAppWindows(from: [entry(bounds: flat)]).isEmpty)
    }

    @Test func dropsEntriesMissingTheKeysWeDependOn() {
        #expect(WindowServerReconciler.realAppWindows(from: [entry(bounds: nil)]).isEmpty)
    }

    /// 无标题窗口是合法的（很多 App 的窗口就是没标题），不该因此被丢掉。
    @Test func keepsUntitledWindowsWithAnEmptyTitle() {
        let result = WindowServerReconciler.realAppWindows(from: [entry(name: nil)])
        #expect(result.map(\.title) == [""])
    }
}

@Suite struct WindowServerReconcilerMissingTests {
    private let anyApp: (ProcessID) -> WindowServerReconciler.AppIdentity? = { _ in
        .init(name: "App", bundleID: "com.example.app", isHidden: false)
    }
    private let noPinyin: (String) -> String? = { _ in nil }

    private func onScreen(_ id: WindowID, pid: ProcessID = 100, title: String = "T") -> OnScreenWindow {
        OnScreenWindow(windowID: id, pid: pid, title: title,
                       bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func returnsOnlyWindowsTheStoreDoesNotKnowAbout() {
        let result = WindowServerReconciler.missingWindows(
            knownIDs: [1, 2],
            onScreen: [onScreen(1), onScreen(2), onScreen(3)],
            appInfo: anyApp,
            pinyin: noPinyin
        )
        #expect(result.map(\.id) == [3])
    }

    @Test func returnsNothingWhenTheStoreIsAlreadyComplete() {
        let result = WindowServerReconciler.missingWindows(
            knownIDs: [1, 2],
            onScreen: [onScreen(1), onScreen(2)],
            appInfo: anyApp,
            pinyin: noPinyin
        )
        #expect(result.isEmpty)
    }

    /// 非常规 App（accessory/LSUIElement）和已经退出的进程：`appInfo` 返回 nil，整条跳过。
    @Test func skipsWindowsWhoseAppShouldNotBeListed() {
        let result = WindowServerReconciler.missingWindows(
            knownIDs: [],
            onScreen: [onScreen(1, pid: 100), onScreen(2, pid: 200)],
            appInfo: { $0 == 100 ? .init(name: "Keep", bundleID: nil, isHidden: false) : nil },
            pinyin: noPinyin
        )
        #expect(result.map(\.id) == [1])
    }

    @Test func dedupesRepeatedWindowIDs() {
        let result = WindowServerReconciler.missingWindows(
            knownIDs: [],
            onScreen: [onScreen(1), onScreen(1)],
            appInfo: anyApp,
            pinyin: noPinyin
        )
        #expect(result.map(\.id) == [1])
    }

    /// 补回来的窗口按定义就在当前可见的 Space 上，且不可能是最小化的
    /// （最小化窗口不在屏幕上，进不了 `onScreen`）。这两个字段错了会被 `WindowFilter` 直接滤掉，
    /// 等于白补。
    @Test func recoveredWindowsAreMarkedVisibleAndNotMinimized() {
        let result = WindowServerReconciler.missingWindows(
            knownIDs: [],
            onScreen: [onScreen(1)],
            appInfo: anyApp,
            pinyin: noPinyin
        )
        #expect(result.first?.isOnCurrentSpace == true)
        #expect(result.first?.isMinimized == false)
    }

    @Test func carriesAppIdentityAndPinyinThrough() {
        let result = WindowServerReconciler.missingWindows(
            knownIDs: [],
            onScreen: [onScreen(1, title: "购物清单")],
            appInfo: { _ in .init(name: "微信", bundleID: "com.tencent.xinWeChat", isHidden: true) },
            pinyin: { $0 == "购物清单" ? "gouwuqingdan" : nil }
        )
        let recovered = try? #require(result.first)
        #expect(recovered?.appName == "微信")
        #expect(recovered?.appBundleID == "com.tencent.xinWeChat")
        #expect(recovered?.isHiddenApp == true)
        #expect(recovered?.pinyinAppName == nil)
        #expect(recovered?.pinyinTitle == "gouwuqingdan")
    }
}

@Suite struct WindowServerReconcilerVisibilityTests {
    private let anyApp: (ProcessID) -> WindowServerReconciler.AppIdentity? = { _ in
        .init(name: "App", bundleID: "com.example.app", isHidden: false)
    }
    private let noPinyin: (String) -> String? = { _ in nil }

    private func onScreen(_ id: WindowID, pid: ProcessID = 100) -> OnScreenWindow {
        OnScreenWindow(windowID: id, pid: pid, title: "coarse CG title",
                       bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func correctsOnlyVisibilityFieldsOfAKnownOnScreenWindow() throws {
        let known = WindowInfo(
            id: 1,
            pid: 100,
            appName: "Original App",
            appBundleID: "com.example.original",
            title: "Rich AX title",
            isMinimized: true,
            isHiddenApp: true,
            isOnCurrentSpace: false,
            pinyinAppName: "original app",
            pinyinTitle: "rich ax title",
            isFullscreen: true
        )

        let result = WindowServerReconciler.reconcile(
            knownWindows: [known],
            onScreen: [onScreen(1)],
            appInfo: anyApp,
            pinyin: noPinyin
        )

        let corrected = try #require(result.observedWindows.first)
        #expect(result.correctedIDs == [1])
        #expect(result.recoveredIDs.isEmpty)
        #expect(corrected.id == 1)
        #expect(corrected.pid == 100)
        #expect(corrected.appName == "Original App")
        #expect(corrected.appBundleID == "com.example.original")
        #expect(corrected.title == "Rich AX title")
        #expect(corrected.pinyinAppName == "original app")
        #expect(corrected.pinyinTitle == "rich ax title")
        #expect(corrected.isFullscreen == true)
        #expect(corrected.isOnCurrentSpace == true)
        #expect(corrected.isMinimized == false)
        #expect(corrected.isHiddenApp == false)
    }

    @Test func leavesKnownWindowsAloneWithoutPositiveOnScreenEvidence() {
        let known = WindowInfo(
            id: 1, pid: 100, appName: "App", appBundleID: nil, title: "Title",
            isMinimized: true, isHiddenApp: true, isOnCurrentSpace: false
        )

        let result = WindowServerReconciler.reconcile(
            knownWindows: [known],
            onScreen: [onScreen(2)],
            appInfo: { _ in nil },
            pinyin: noPinyin
        )

        #expect(result.observedWindows.isEmpty)
        #expect(result.correctedIDs.isEmpty)
        #expect(result.recoveredIDs.isEmpty)
        #expect(result.changed == false)
    }

    @Test func alreadyCorrectKnownWindowProducesNoWrite() {
        let known = WindowInfo(id: 1, pid: 100, appName: "App", appBundleID: nil, title: "Title")

        let result = WindowServerReconciler.reconcile(
            knownWindows: [known],
            onScreen: [onScreen(1)],
            appInfo: anyApp,
            pinyin: noPinyin
        )

        #expect(result.observedWindows.isEmpty)
        #expect(result.changed == false)
    }

    @Test func fullRefreshAppliesPositiveVisibilityWithoutDroppingUnobservedWindows() {
        let stale = WindowInfo(
            id: 1, pid: 100, appName: "App", appBundleID: nil, title: "Visible",
            isMinimized: true, isHiddenApp: true, isOnCurrentSpace: false
        )
        let unobserved = WindowInfo(
            id: 2, pid: 100, appName: "App", appBundleID: nil, title: "Other Space",
            isMinimized: false, isHiddenApp: false, isOnCurrentSpace: false
        )

        let result = WindowServerReconciler.applyingPositiveVisibility(
            to: [stale, unobserved],
            onScreen: [onScreen(1)],
            appInfo: anyApp,
            pinyin: noPinyin
        )

        #expect(result.windows.map(\.id) == [1, 2])
        #expect(result.windows[0].isOnCurrentSpace == true)
        #expect(result.windows[0].isMinimized == false)
        #expect(result.windows[0].isHiddenApp == false)
        #expect(result.windows[1] == unobserved)
        #expect(result.invalidHandleIDs.isEmpty)
    }

    @Test func reusedWindowIDInvalidatesTheOldAXHandle() throws {
        let stale = WindowInfo(
            id: 1, pid: 100, appName: "Old App", appBundleID: nil, title: "Old Window"
        )

        let result = WindowServerReconciler.applyingPositiveVisibility(
            to: [stale],
            onScreen: [onScreen(1, pid: 200)],
            appInfo: { pid in
                pid == 200 ? .init(name: "New App", bundleID: nil, isHidden: false) : nil
            },
            pinyin: noPinyin
        )

        #expect(result.invalidHandleIDs == [1])
        #expect(try #require(result.windows.first).pid == 200)
    }
}
