public typealias WindowID = UInt32
public typealias ProcessID = Int32

public struct WindowInfo: Identifiable, Equatable, Sendable {
    public let id: WindowID
    public let pid: ProcessID
    public let appName: String
    public let appBundleID: String?
    public var title: String
    public var isMinimized: Bool
    public var isHiddenApp: Bool
    public var isOnCurrentSpace: Bool
    /// 本地化 App 名的拼音。中文系统下 Finder 的 `localizedName` 是“访达”，搜索 `f`
    /// 需要靠这一份别名命中；它与窗口标题拼音分开保存，标题变化时不会把 App 名别名冲掉。
    public var pinyinAppName: String?
    public var pinyinTitle: String?
    /// Task X4：该窗口是否位于一个全屏 Space（type==4，见 `SpaceClassifier`）。默认 `false`——
    /// AX 枚举的当前 Space 窗口不关心这个字段（它们本来就靠 `isOnCurrentSpace` 保证可见）；
    /// Registry 已知的跨 Space 窗口会用 `SpaceClassifier` 的分类结果覆盖它。
    /// `searchHaystack` 不含它——纯展示/过滤用途，不参与搜索匹配。
    public var isFullscreen: Bool

    public init(id: WindowID, pid: ProcessID, appName: String, appBundleID: String?, title: String,
                isMinimized: Bool = false, isHiddenApp: Bool = false, isOnCurrentSpace: Bool = true,
                pinyinAppName: String? = nil, pinyinTitle: String? = nil,
                isFullscreen: Bool = false) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.appBundleID = appBundleID
        self.title = title
        self.isMinimized = isMinimized
        self.isHiddenApp = isHiddenApp
        self.isOnCurrentSpace = isOnCurrentSpace
        self.pinyinAppName = pinyinAppName
        self.pinyinTitle = pinyinTitle
        self.isFullscreen = isFullscreen
    }

    public var searchHaystack: String {
        [appName, title, pinyinAppName ?? "", pinyinTitle ?? ""].joined(separator: " ").lowercased()
    }

    /// 不含拼音的匹配串——用户在设置里关掉「拼音匹配中文名称」时用这个（见
    /// `WindowFilter.search(_:query:includePinyin:)`）。拼音仍然照常在枚举时生成并保存在
    /// `pinyinAppName` / `pinyinTitle` 里，只是搜索时不参与匹配：开关因此**立即生效**，
    /// 不需要重新枚举全部窗口。
    public var searchHaystackWithoutPinyin: String {
        [appName, title].joined(separator: " ").lowercased()
    }
}
