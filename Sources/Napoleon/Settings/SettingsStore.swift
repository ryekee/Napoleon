import CoreGraphics
import Foundation
import NapoleonCore

/// Task 21：卡片缩略图尺寸档位（spec §8「缩略图尺寸」选择）。存进 `UserDefaults` 的是
/// `rawValue` 字符串，新增档位不会让旧存值失效（读不出来就回落 `.medium`）。
/// `thumbnailSize` 是每档缩略图区的点尺寸，卡片外框尺寸由 `SwitcherMetrics` 据此派生。
enum CardSizeOption: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }

    var thumbnailSize: CGSize {
        switch self {
        case .small: return CGSize(width: 120, height: 75)
        case .medium: return CGSize(width: 160, height: 100)   // Phase 5 起的既有尺寸 = 默认档
        case .large: return CGSize(width: 220, height: 138)
        }
    }

    var displayName: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        }
    }
}

/// 界面语言。`system` 表示跟随系统语言偏好（默认），其余为强制指定。
///
/// **实现方式**：写 `UserDefaults.standard` 的 `AppleLanguages`——这是 Foundation 在**进程启动时**
/// 读取、用来决定 bundle 加载哪个 `.lproj` 的键。因此改语言必须重启 App 才生效（界面上明说，并
/// 提供「立即重启」按钮），不存在不重启就换语言的正经做法：已经加载的字符串目录不会重新协商。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"

    var id: String { rawValue }

    /// 语言名一律用该语言自己的写法（English / 简体中文 / 日本語），不随界面语言翻译——这是
    /// 语言选择器的通行做法：用户看得懂的一定是自己那门语言的名字。`system` 例外，要翻译。
    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        }
    }
}

@MainActor final class SettingsStore: ObservableObject {
    @Published var allWindowsChord: Chord {
        didSet { persist(.allWindowsChord, chord: allWindowsChord) }
    }
    @Published var currentAppChord: Chord {
        didSet { persist(.currentAppChord, chord: currentAppChord) }
    }
    @Published var scope: ScopeOptions {
        didSet { persistScope(scope) }
    }
    @Published var showDelayMs: Int {
        didSet { defaults.set(showDelayMs, forKey: Key.showDelayMs.rawValue) }
    }
    @Published var thumbnailMaxCacheBytes: Int {
        didSet { defaults.set(thumbnailMaxCacheBytes, forKey: Key.thumbnailMaxCacheBytes.rawValue) }
    }
    @Published var pinyinSearchEnabled: Bool {
        didSet { defaults.set(pinyinSearchEnabled, forKey: Key.pinyinSearchEnabled.rawValue) }
    }
    /// 全窗口切换器是否按 App 聚合。当前 App 窗口快捷键始终逐窗口显示，否则聚合后只剩一个 App、
    /// 该快捷键将失去意义。switcher 顶部快捷按钮与设置页共用并持久化这一值。
    @Published var groupWindowsByApplication: Bool {
        didSet { defaults.set(groupWindowsByApplication, forKey: Key.groupWindowsByApplication.rawValue) }
    }
    /// 卡片上是否显示第二行的窗口标题（用户需求：可开关，默认显示）。关掉后卡片只留 App 名一行，
    /// 卡片更矮、一屏能放下更多——`SwitcherMetrics` 会据此改变卡片高度，不是简单地留白。
    @Published var showWindowTitle: Bool {
        didSet { defaults.set(showWindowTitle, forKey: Key.showWindowTitle.rawValue) }
    }
    /// 卡片缩略图尺寸档位（spec §8）。
    @Published var cardSize: CardSizeOption {
        didSet { defaults.set(cardSize.rawValue, forKey: Key.cardSize.rawValue) }
    }
    /// 浮层是否跟随系统明暗（spec §8「明暗跟随」）。默认 `false` = 始终深色——Phase 5 起真机验证
    /// 过的既有观感（深色毛玻璃 + 亮色文字），打开后浅色模式下浮层改用浅色底 + 深色文字。
    @Published var followSystemAppearance: Bool {
        didSet { defaults.set(followSystemAppearance, forKey: Key.followSystemAppearance.rawValue) }
    }
    /// 界面语言（见 `AppLanguage`）。`didSet` 除了记住选择，还要把 `AppleLanguages` 一并写掉——
    /// 那是 Foundation 启动时读的键，决定下次启动加载哪个 `.lproj`（见 `applyLanguageOverride`）。
    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Key.appLanguage.rawValue)
            Self.applyLanguageOverride(appLanguage, into: defaults)
        }
    }

    /// 本进程**启动那一刻**的语言选择。界面据此判断「所选语言是否已经生效」——不一致就说明改过
    /// 但还没重启，要提示（见 `SettingsView.languageNeedsRestart`）。
    ///
    /// 之前是拿 `Bundle.main.preferredLocalizations.first`（bundle 协商结果，只可能是我们支持的
    /// 四种语言之一）去比 `Locale.preferredLanguages.first`（系统语言标签，可能是 ko-KR/fr-FR
    /// 等任何值）——两者语义不同，在非四语系统上恒不相等，导致**法语/韩语等系统的用户一打开设置
    /// 就看到一条永远消不掉、点了也没用的「需要重启」横幅**。改成跟启动时的取值比：语义明确
    /// （「你改过设置吗」），且重启后天然相等、提示自然消失，不依赖任何语言协商细节。
    let launchLanguage: AppLanguage

    /// 把语言选择写进 `AppleLanguages`：`system` 时移除这个键（回到系统语言偏好），否则置成
    /// 只含所选语言的数组。下次启动生效。
    ///
    /// **写进注入的 `defaults`，而不是硬写 `UserDefaults.standard`**：生产环境这两者本来就是同一个
    /// （App 的 `.standard` 域就是 `com.napoleon.Napoleon`，正是 per-app 语言覆盖该写的地方）；
    /// 而单测注入的是临时 suite，硬写 standard 会让**每跑一次测试就抹掉用户真实的语言设置**。
    static func applyLanguageOverride(_ language: AppLanguage, into defaults: UserDefaults) {
        let key = "AppleLanguages"
        switch language {
        case .system:
            defaults.removeObject(forKey: key)
        default:
            defaults.set([language.rawValue], forKey: key)
        }
    }

    private let defaults: UserDefaults

    private enum Key: String {
        case allWindowsChord = "napoleon.allWindowsChord"
        case currentAppChord = "napoleon.currentAppChord"
        case scopeIncludeOtherSpaces = "napoleon.scope.includeOtherSpaces"
        case scopeIncludeMinimized = "napoleon.scope.includeMinimized"
        case scopeIncludeHiddenApps = "napoleon.scope.includeHiddenApps"
        case showDelayMs = "napoleon.showDelayMs"
        case thumbnailMaxCacheBytes = "napoleon.thumbnailMaxCacheBytes"
        case pinyinSearchEnabled = "napoleon.pinyinSearchEnabled"
        case groupWindowsByApplication = "napoleon.groupWindowsByApplication"
        case showWindowTitle = "napoleon.showWindowTitle"
        case cardSize = "napoleon.cardSize"
        case followSystemAppearance = "napoleon.followSystemAppearance"
        case appLanguage = "napoleon.appLanguage"
    }

    static let defaultAllWindowsChord = Chord(keyCode: 48, modifiers: UInt(CGEventFlags.maskCommand.rawValue))
    static let defaultCurrentAppChord = Chord(keyCode: 50, modifiers: UInt(CGEventFlags.maskCommand.rawValue))
    static let defaultShowDelayMs = 100
    static let defaultThumbnailMaxCacheBytes = 32 * 1024 * 1024
    static let defaultPinyinSearchEnabled = true
    static let defaultGroupWindowsByApplication = false
    static let defaultShowWindowTitle = true
    static let defaultCardSize = CardSizeOption.medium
    static let defaultFollowSystemAppearance = false
    static let defaultAppLanguage = AppLanguage.system

    var hotkeysAreDefault: Bool {
        allWindowsChord == Self.defaultAllWindowsChord
            && currentAppChord == Self.defaultCurrentAppChord
    }

    func resetHotkeysToDefaults() {
        allWindowsChord = Self.defaultAllWindowsChord
        currentAppChord = Self.defaultCurrentAppChord
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        allWindowsChord = Self.loadChord(from: defaults, key: .allWindowsChord) ?? Self.defaultAllWindowsChord
        currentAppChord = Self.loadChord(from: defaults, key: .currentAppChord) ?? Self.defaultCurrentAppChord

        if defaults.object(forKey: Key.scopeIncludeOtherSpaces.rawValue) != nil {
            scope = ScopeOptions(
                includeOtherSpaces: defaults.bool(forKey: Key.scopeIncludeOtherSpaces.rawValue),
                includeMinimized: defaults.bool(forKey: Key.scopeIncludeMinimized.rawValue),
                includeHiddenApps: defaults.bool(forKey: Key.scopeIncludeHiddenApps.rawValue)
            )
        } else {
            // 默认 false——显示范围 =「当前 Space + 全屏」。真机验证发现：改成 true（所有真实
            // 窗口）会把「其他桌面」的一大堆窗口（onCur=false 且 fs=false）也放进来（用户实测
            // 主桌面 6 个却涌进 20+ 个别的桌面窗口，且这些跨 Space 无句柄窗口聚焦不可靠）。
            // WindowFilter 的保留条件是 `isOnCurrentSpace || isFullscreen || includeOtherSpaces`，
            // 所以 includeOtherSpaces=false 时：当前 Space 窗口（AX 枚举、有句柄）保留、全屏
            // App 窗口（`isFullscreen==true`，由 SpaceClassifier 判定）仍然保留、其他桌面的
            // 普通窗口被过滤掉——正是用户要的干净列表。想看其他桌面的窗口可在设置里打开这个
            // 开关。UserDefaults 里已有存值（上面的分支）仍以存值为准。
            scope = ScopeOptions(includeOtherSpaces: false)
        }

        showDelayMs = defaults.object(forKey: Key.showDelayMs.rawValue) as? Int ?? Self.defaultShowDelayMs
        thumbnailMaxCacheBytes = defaults.object(forKey: Key.thumbnailMaxCacheBytes.rawValue) as? Int
            ?? Self.defaultThumbnailMaxCacheBytes
        pinyinSearchEnabled = defaults.object(forKey: Key.pinyinSearchEnabled.rawValue) as? Bool
            ?? Self.defaultPinyinSearchEnabled
        groupWindowsByApplication = defaults.object(forKey: Key.groupWindowsByApplication.rawValue) as? Bool
            ?? Self.defaultGroupWindowsByApplication
        showWindowTitle = defaults.object(forKey: Key.showWindowTitle.rawValue) as? Bool
            ?? Self.defaultShowWindowTitle
        // 存的是 rawValue 字符串：读不出来/是未知档位（降级安装、手改 plist）都回落默认档，
        // 不会因为一个坏值让卡片尺寸崩坏。
        cardSize = (defaults.string(forKey: Key.cardSize.rawValue).flatMap(CardSizeOption.init(rawValue:)))
            ?? Self.defaultCardSize
        followSystemAppearance = defaults.object(forKey: Key.followSystemAppearance.rawValue) as? Bool
            ?? Self.defaultFollowSystemAppearance
        // 未知/损坏的语言值回落 `system`，不会因为一个坏值让界面语言错乱。
        let storedLanguage = (defaults.string(forKey: Key.appLanguage.rawValue).flatMap(AppLanguage.init(rawValue:)))
            ?? Self.defaultAppLanguage
        appLanguage = storedLanguage
        launchLanguage = storedLanguage

        // 启动时重新断言一次语言覆盖：`appLanguage` 与 `AppleLanguages` 是两份独立状态，用户
        // 可能在「系统设置 › 语言与地区 › 应用程序」里直接改掉或移除 Napoleon 的条目（写的是同
        // 一个键），两边就此分叉——picker 显示日本語、App 实际跑英文，且因为 `init` 里的赋值
        // 不触发 `didSet`，重启也修不回来。这里补一次同步，让我们记录的选择始终是权威。
        Self.applyLanguageOverride(storedLanguage, into: defaults)
    }

    private func persist(_ key: Key, chord: Chord) {
        guard let data = try? JSONEncoder().encode(chord) else { return }
        defaults.set(data, forKey: key.rawValue)
    }

    private func persistScope(_ scope: ScopeOptions) {
        defaults.set(scope.includeOtherSpaces, forKey: Key.scopeIncludeOtherSpaces.rawValue)
        defaults.set(scope.includeMinimized, forKey: Key.scopeIncludeMinimized.rawValue)
        defaults.set(scope.includeHiddenApps, forKey: Key.scopeIncludeHiddenApps.rawValue)
    }

    private static func loadChord(from defaults: UserDefaults, key: Key) -> Chord? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(Chord.self, from: data)
    }
}
