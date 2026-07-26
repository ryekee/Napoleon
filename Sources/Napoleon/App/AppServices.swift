import AppKit
import NapoleonCore
import ServiceManagement
import SwiftUI
import os

/// Task 20/21：App 全生命周期对象的唯一持有者与接线处。
///
/// 在此之前这些对象散在 `AppDelegate.applicationDidFinishLaunching` 的局部变量 + 可选属性里，
/// 只有 `AppDelegate` 够得着；设置界面（SwiftUI `Settings` 场景，不在 `AppDelegate` 的作用域内）
/// 需要读写同一批对象——改快捷键要通知 `HotkeyManager`、录制期间要挂起它、权限面板要读
/// `PermissionsManager`。用一个 `@MainActor` 单例把它们收拢，`AppDelegate` 负责在启动时
/// `start()`，SwiftUI 场景直接读 `AppServices.shared`。
///
/// **单例的理由**：SwiftUI 的 `App` 结构体是值类型、会被反复重建，没法在里面持有需要活到进程
/// 结束的引用类型；而这些对象天然就是「每进程一份」（一个事件 tap、一个窗口热态、一个浮层）。
/// 测试不走这条路径（`AppDelegate` 在测试进程里直接短路返回，见 `applicationDidFinishLaunching`），
/// 所以单例不会污染单测。
@MainActor
final class AppServices {
    static let shared = AppServices()

    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "AppServices")

    let settings = SettingsStore()
    let permissions = PermissionsManager()
    let loginItem = LoginItemController()
    let updateChecker = UpdateChecker()

    let hotkey: HotkeyManager
    /// 用持久化的缓存上限构造（而不是先吃 `ThumbnailService` 的 32MB 默认值再等设置界面
    /// `onChange` 才回灌）——否则用户设成 128MB 后重启，界面显示 128MB 但实际按 32MB 运行，
    /// 缩略图被提前淘汰、反复重抓，设置项形同虚设。跟 chord 一样：启动即用用户的值。
    let thumbnails: ThumbnailService
    let windowStore: WindowStore
    let overlay = OverlayPanel()
    let switcherController: SwitcherController

    /// 菜单栏图标与菜单、设置窗口——都在 `start()` 里建（测试进程不会走到那里，见 `AppDelegate`），
    /// 建好后由本单例持有到进程结束。
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?

    private let inputSafetyMonitor = InputSafetyMonitor()
    private var isStarted = false

    private init() {
        // 用持久化设置里的 chord 建 tap（而不是先硬编码默认值再 update 一次）——用户改过绑定时
        // 启动即生效，不存在「启动后短暂用着默认绑定」的窗口。
        hotkey = HotkeyManager(
            allWindowsChord: settings.allWindowsChord,
            currentAppChord: settings.currentAppChord
        )
        thumbnails = ThumbnailService(maxCacheBytes: settings.thumbnailMaxCacheBytes)
        // `includesOtherSpaces` 每次刷新现读设置——用户在设置里打开「包含其他桌面的窗口」后，
        // 全屏逃生的收窄会自动让路（见 `WindowStore.escapeAwareAdditions`），不需要重启或通知。
        let settings = settings
        windowStore = WindowStore(
            thumbnails: thumbnails,
            includesOtherSpaces: { settings.scope.includeOtherSpaces }
        )
        switcherController = SwitcherController(
            windowStore: windowStore,
            thumbnails: thumbnails,
            settings: settings,
            overlay: overlay
        )
    }

    /// 启动全部子系统。`AppDelegate.applicationDidFinishLaunching` 调用一次；重复调用 no-op。
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // R1：首次触达 `KeyTranslator.shared` 必须在主线程，让它的 init（TIS 首次刷新 + 订阅输入法
        // 切换通知）跑在主线程上——之后 tap 线程调用 `character(...)` 就只读缓存快照、不再触发任何
        // TIS API。
        _ = KeyTranslator.shared

        // Task 20：辅助功能授权被吊销/重新授予时，除了原有的日志，还要把状态同步给
        // `PermissionsManager`——菜单栏图标的警示与设置界面的权限区都读它。
        inputSafetyMonitor.onAccessibilityChanged = { [weak self] trusted in
            Self.logger.warning("Accessibility trust changed: \(trusted, privacy: .public)")
            self?.permissions.accessibilityTrustDidChange(trusted)
        }
        inputSafetyMonitor.startObserving()
        permissions.start()

        // `warmUp()` 把 SCK 首调 ~163ms 的冷启动成本挪到 App 启动阶段付掉。起独立 `Task`
        // （不 block 启动流程），跟 `windowStore.start()` 谁先跑完没有先后依赖。
        Task { [thumbnails] in await thumbnails.warmUp() }

        windowStore.start()
        hotkey.delegate = switcherController
        hotkey.start()

        // 设置窗口内容延迟到真正打开时才构造（`makeContent` 是闭包）——绝大多数启动用户根本
        // 不会打开设置，没必要在启动路径上付 SwiftUI 首次布局的成本。
        let settingsWindow = SettingsWindowController { [settings, permissions, loginItem, updateChecker] navigation in
            AnyView(
                SettingsView(
                    navigation: navigation,
                    settings: settings,
                    permissions: permissions,
                    loginItem: loginItem,
                    updateChecker: updateChecker
                )
            )
        }
        // 设置窗口开/关时窗口列表会多出或少掉 Napoleon 自己的窗口，而这件事不发任何系统通知
        // （自身进程的窗口销毁通知也走不到 `AXObserver`），必须显式告诉 store。
        //
        // 关闭要**同步**摘除而不只是排一次刷新：刷新是 200ms debounce，那段空窗期里窗口还在列表
        // 中、AX 句柄也还有效，被切中就会把 Napoleon 提到一扇已经关掉的窗口上。摘完照旧再刷一次
        // 兜底（列表里别的东西可能也变了）。
        settingsWindow.onVisibilityChanged = { [weak self] _, closingWindowID in
            guard let self else { return }
            if let closingWindowID {
                self.windowStore.forget(windowID: closingWindowID)
            }
            self.windowStore.requestRefresh()
        }
        self.settingsWindow = settingsWindow

        menuBar = MenuBarController(
            permissions: permissions,
            settings: settings,
            onOpenSettings: { settingsWindow.show() }
        )
    }

    /// 打开设置窗口。菜单栏菜单与主菜单的 ⌘, 都走这里；`start()` 之前调用是 no-op
    /// （窗口还没建，也不该在启动完成前弹窗）。
    func showSettings() {
        settingsWindow?.show()
    }

    /// 设置界面改了快捷键后调用：把新绑定推给 tap 线程（`HotkeyManager` 内部用锁交接，见
    /// `updateChords`）。绑定本身的持久化由 `SettingsStore` 的 `didSet` 完成，这里只负责让运行中的
    /// tap 立刻改用新值，不必重启 App。
    func applyChords() {
        hotkey.updateChords(allWindows: settings.allWindowsChord, currentApp: settings.currentAppChord)
    }

    /// 设置界面开始/结束录制快捷键：挂起或恢复 tap 的拦截（见 `HotkeyManager.setSuspended`）。
    ///
    /// **C1 兜底**：挂起期间 Napoleon 的所有快捷键都失效，所以「忘了恢复」是本 App 最坏的故障
    /// 形态（用户只能重启才能救回来，且界面上没有任何线索）。`HotkeyRecorderNSView` 已经把
    /// resign/关窗/失去 key/移出视图层级几条路径都接上了，这里再加一道与 UI 完全无关的超时：
    /// 挂起超过 `recordingTimeout` 一律自动恢复。录制一个组合键是秒级操作，60s 不可能是正常
    /// 录制中的状态，因此这道兜底不会打断真实使用，却能兜住任何将来新增的、忘了收尾的路径。
    func setHotkeyRecording(_ recording: Bool) {
        hotkey.setSuspended(recording)

        recordingTimeoutTimer?.invalidate()
        recordingTimeoutTimer = nil
        guard recording else { return }

        recordingTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.recordingTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.logger.warning("hotkey recording timed out — force-resuming the event tap")
                self.hotkey.setSuspended(false)
                self.recordingTimeoutTimer = nil
            }
        }
    }

    /// 录制挂起的最长容忍时间，见 `setHotkeyRecording`。
    private static let recordingTimeout: TimeInterval = 60
    private var recordingTimeoutTimer: Timer?
}

/// Task 21：开机自动启动（`SMAppService`，macOS 13+）。
///
/// **系统才是唯一事实来源**——注册状态存在系统的登录项数据库里，不是我们的 `UserDefaults`：用户
/// 可能在「系统设置 › 通用 › 登录项」里直接关掉它。所以这里不缓存布尔值，`isEnabled` 每次都现读
/// `SMAppService.mainApp.status`，设置界面每次显示时再 `refresh()` 一次让 SwiftUI 重新取值。
@MainActor
final class LoginItemController: ObservableObject {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "LoginItem")

    /// 最近一次操作失败的原因（`nil` = 正常）。注册可能失败：未签名/未公证的构建、被系统策略拒绝
    /// 等——失败必须让用户看见，而不是界面上开关跳回去却不说为什么。
    @Published private(set) var lastError: String?
    /// 纯粹用于触发 SwiftUI 重新读取 `isEnabled` 的版本号（`isEnabled` 是现读系统状态的计算属性，
    /// 本身不是 `@Published`）。
    @Published private var revision = 0

    private var activationObserver: NSObjectProtocol?

    init() {
        // M1：用户可能在「系统设置 › 通用 › 登录项」里直接关掉 Napoleon。SwiftUI 的 `Settings`
        // 场景关窗后内容视图仍保持挂载，所以 `.onAppear` 在同一进程内的第二次开窗不会再触发，
        // 光靠它刷新会让开关长期显示过期状态。跟 `PermissionsManager` 一样挂 App 激活钩子：
        // 用户从系统设置切回来时自动重读。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    var isEnabled: Bool {
        _ = revision // 建立依赖：revision 变化时 SwiftUI 重新求值本属性
        return SMAppService.mainApp.status == .enabled
    }

    /// 系统是否要求用户去「登录项」里手动批准（`.requiresApproval`）——这种状态下 `register()`
    /// 不会报错但也不会真的生效，界面要给出提示。
    var requiresApproval: Bool {
        _ = revision
        return SMAppService.mainApp.status == .requiresApproval
    }

    func refresh() {
        revision &+= 1
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
