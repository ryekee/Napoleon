public struct ScopeOptions: Equatable, Sendable {
    public var includeOtherSpaces, includeMinimized, includeHiddenApps: Bool
    public init(includeOtherSpaces: Bool = false, includeMinimized: Bool = false, includeHiddenApps: Bool = false) {
        self.includeOtherSpaces = includeOtherSpaces
        self.includeMinimized = includeMinimized
        self.includeHiddenApps = includeHiddenApps
    }
}

public enum SwitchMode: Equatable, Sendable {
    case allWindows
    case currentApp(ProcessID)
}

public enum WindowFilter {
    /// - Parameter currentSpaceIsFullscreen: 用户此刻所在的 Space 本身是不是一个全屏 Space。
    ///   为 `true` 时（人被「困」在某个全屏 App 里）放开跨 Space 过滤，让普通桌面窗口重新
    ///   进入列表——否则全屏 Space 的「当前 Space」只有那一扇全屏窗口，用户无法借切换器
    ///   逃回桌面。为 `false`（在普通桌面上）时行为一字不变：只显当前 Space + 全屏 + 可选的
    ///   其它 Space。这是一个每次刷新的环境事实（由 `SpaceClassifier` 从 CGS 读当前 Space 的
    ///   `type==4` 得出），不是用户可持久化的设置，所以作为独立入参而非塞进 `ScopeOptions`。
    public static func apply(
        _ windows: [WindowInfo],
        mode: SwitchMode,
        scope: ScopeOptions,
        currentSpaceIsFullscreen: Bool = false
    ) -> [WindowInfo] {
        // First filter by mode
        let modeFiltered: [WindowInfo]
        switch mode {
        case .allWindows:
            modeFiltered = windows
        case .currentApp(let pid):
            modeFiltered = windows.filter { $0.pid == pid }
        }

        // Then filter by scope
        return modeFiltered.filter { window in
            // Exclude minimized unless includeMinimized
            if window.isMinimized && !scope.includeMinimized {
                return false
            }
            // Exclude hidden apps unless includeHiddenApps
            if window.isHiddenApp && !scope.includeHiddenApps {
                return false
            }
            // Task X4：跨 Space 窗口默认只显「当前 Space + 全屏」——保留窗口当且仅当
            // isOnCurrentSpace || isFullscreen || scope.includeOtherSpaces || currentSpaceIsFullscreen。
            // 全屏跨 Space 窗口（isFullscreen）即使 includeOtherSpaces=false 也保留；普通跨 Space
            // （既非当前 Space 也非全屏）窗口默认排除。全屏逃生：当用户所在 Space 本身是全屏
            // （currentSpaceIsFullscreen）时，额外放开这类普通跨 Space 窗口——等价于「困在全屏里
            // 时自动临时开启 includeOtherSpaces」，好让用户能切回桌面。
            if !window.isOnCurrentSpace
                && !window.isFullscreen
                && !scope.includeOtherSpaces
                && !currentSpaceIsFullscreen {
                return false
            }
            return true
        }
    }

    /// - Parameter includePinyin: 是否让拼音参与匹配（设置项「拼音匹配中文标题」，默认开）。
    ///   关掉时只按 App 名 + 窗口标题匹配——拼音仍在枚举时生成好放在 `WindowInfo.pinyinTitle`
    ///   里，这里只是不看它，所以开关**下一次按键就生效**，不需要重新枚举窗口。
    public static func search(_ windows: [WindowInfo], query: String, includePinyin: Bool = true) -> [WindowInfo] {
        if query.isEmpty {
            return windows
        }
        let needle = query.lowercased()
        return windows.filter {
            let haystack = includePinyin ? $0.searchHaystack : $0.searchHaystackWithoutPinyin
            return haystack.contains(needle)
        }
    }
}
