import CoreGraphics
import NapoleonCore

/// 纯合并逻辑（无 AX/SC 调用，可单测）：把 `ScreenWindowLister.list()` 抓到的跨 Space/
/// 全屏窗口，与 AX 当前 Space 枚举出的 windowID 集合去重后，转成待追加进热态的
/// `WindowInfo` 列表——AX 那份是当前 Space 的权威（有句柄），这里只处理 AX **看不到**
/// 的那部分（`isOnCurrentSpace = false`，没有 AXUIElement 句柄，聚焦留给 Task X3）。
enum CrossSpaceMerge {
    /// - Parameters:
    ///   - axWindowIDs: 本次全量刷新里 AX 枚举到的 windowID 集合（当前 Space、权威）。
    ///   - screenWindows: `ScreenWindowLister.list()` 抓到的全部真实 App 窗口（含当前
    ///     Space + 跨 Space + 全屏）。
    ///   - keepApp: 按 pid 查「这个窗口的 owning App 是否值得作为跨 Space 追加项保留」，
    ///     注入以便单测打桩（生产环境传
    ///     `NSRunningApplication(processIdentifier:)?.activationPolicy == .regular`）。
    ///     O1/Y1：`SCShareableContent` 不像 AX 侧那样只看 `.regular` App——accessory/
    ///     `LSUIElement` App、已经 ordered-out/隐藏的窗口，甚至枚举这一刻正在退出、
    ///     `NSRunningApplication(processIdentifier:)` 已经拿不到的 App，都可能出现在
    ///     `screenWindows` 里，不过滤的话会在热态里产生一堆 `isOnCurrentSpace = false`
    ///     的「幽灵」条目。pid 查不到对应 `NSRunningApplication`（App 已退出）时闭包应
    ///     返回 `false`，同时也顺带修掉 Y1（正在终止的 App 留下的幽灵窗口）。
    ///   - isHiddenApp: 按 pid 查「该 App 是否隐藏」，注入以便单测打桩
    ///     （生产环境传 `NSRunningApplication(processIdentifier:)?.isHidden ?? false`）。
    ///   - pinyin: 标题 → 拼音，注入以便单测打桩（生产环境传 `PinyinTransformer.pinyin`）。
    ///   - isFullscreen: Task X4：按 windowID 查「该窗口是否位于一个全屏 Space」，注入以便
    ///     单测打桩（生产环境传 `SpaceClassifier.isOnFullscreenSpace`）。所有 `keepApp` 通过
    ///     的跨 Space 窗口都会全部并入结果（不因为非全屏就被这里过滤掉）——是否显示交给
    ///     `WindowFilter` 决定，这里只负责打好 `isFullscreen` 标签，保持热态完整。
    /// - Returns: 需要追加进热态的跨 Space `WindowInfo` 列表，顺序保持 `screenWindows`
    ///   的相对序。已经在 `axWindowIDs` 里的 windowID 会被跳过（AX 当前 Space 权威、
    ///   避免重复）；`screenWindows` 内部若对同一 windowID 重复出现，也只保留第一次；
    ///   `keepApp(sw.pid) == false` 的窗口整体跳过，不出现在结果里。
    static func crossSpaceAdditions(
        axWindowIDs: Set<WindowID>,
        suppressedWindowIDs: Set<WindowID> = [],
        screenWindows: [ScreenWindow],
        keepApp: (ProcessID) -> Bool,
        isHiddenApp: (ProcessID) -> Bool,
        pinyin: (String) -> String?,
        isFullscreen: (WindowID) -> Bool
    ) -> [WindowInfo] {
        var seen = axWindowIDs.union(suppressedWindowIDs)
        var additions: [WindowInfo] = []

        for screenWindow in screenWindows {
            guard !seen.contains(screenWindow.windowID) else { continue }
            guard keepApp(screenWindow.pid) else { continue }
            seen.insert(screenWindow.windowID)

            additions.append(WindowInfo(
                id: screenWindow.windowID,
                pid: screenWindow.pid,
                appName: screenWindow.appName,
                appBundleID: screenWindow.appBundleID,
                title: screenWindow.title,
                isMinimized: false,
                isHiddenApp: isHiddenApp(screenWindow.pid),
                isOnCurrentSpace: false,
                pinyinAppName: pinyin(screenWindow.appName),
                pinyinTitle: pinyin(screenWindow.title),
                isFullscreen: isFullscreen(screenWindow.windowID)
            ))
        }

        return additions
    }
}
