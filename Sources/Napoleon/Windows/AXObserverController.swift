import ApplicationServices
import AppKit
import NapoleonCore
import os

/// AXObserverController 产出的原始 AX 通知事件——只做「AX 通知 → Swift 事件」的转译，不解析
/// CGWindowID、不建 WindowInfo（那是 Task 12b `WindowStore` 的事）。`element` 对
/// `.windowDestroyed` 而言此刻已经是死对象，消费方只能拿它当反查 key（比如映射回之前枚举时
/// 记下的 WindowID），不能再对它发起 AX 调用。
enum AXWindowNotification {
    case windowCreated(pid: ProcessID, element: AXUIElement)
    case windowDestroyed(pid: ProcessID, element: AXUIElement)
    case minimizedChanged(pid: ProcessID, element: AXUIElement, isMinimized: Bool)
    case titleChanged(pid: ProcessID, element: AXUIElement)
    case focusedWindowChanged(pid: ProcessID, element: AXUIElement?)
}

/// 给每个「常规」（`.regular` activation policy）App 挂一个 `AXObserver`，把窗口创建/销毁/
/// 最小化/标题/焦点变化的 AX 通知转成 `AXWindowNotification` 回调；同时监听 App 启动/退出，
/// 动态建立/拆除对应 App 的 observer。这是热态维护链路里最容易踩坑的一环，规则见下。
///
/// **生命周期规则**：
/// - 每个常规 App 一个 `AXObserver`（`AXObserverCreate(pid, callback, ...)`），其 run loop
///   source 必须挂在**主 run loop**（`CFRunLoopGetMain()`）——不是任意线程/dispatch queue，
///   因为 AXObserver 的通知只会在挂载了它的 run loop 所在线程上触发回调，而 Task 12b 的
///   `WindowStore` 是 `@MainActor`，必须在主线程消费这些事件。
/// - App 级通知（`kAXWindowCreatedNotification`、`kAXFocusedWindowChangedNotification`）挂在
///   App 本身的 `AXUIElement` 上；窗口级通知（`kAXUIElementDestroyedNotification`、
///   `kAXWindowMiniaturizedNotification`、`kAXWindowDeminiaturizedNotification`、
///   `kAXTitleChangedNotification`）挂在每个窗口自己的 `AXUIElement` 上。
/// - `start()` 时，对每个 App **现有**的窗口只注册窗口级通知、不发 `windowCreated`——它们已经
///   存在，12b 的初始窗口列表来自一次独立的全量枚举（Task 11 `WindowEnumerator`）。此后每次
///   收到 `kAXWindowCreatedNotification`（真正的新窗口），才对新窗口元素注册窗口级通知 **并**
///   发 `windowCreated`。App 启动（`didLaunchApplicationNotification`）走同一条「只注册不发」
///   路径处理该 App 当时已存在的窗口——因为 `onAppAppeared` 本身就是在告诉调用方「该 App 需要
///   一次全量补枚举」，補枚举会覆盖这些窗口，不需要重复发 `windowCreated`。
/// - `kAXUIElementDestroyedNotification` 触发时元素已经是死对象：只用来发
///   `windowDestroyed(element)` 当反查 key，并把它从本类自己的簿记（`registeredWindows`）里
///   摘除——不会也不能对一个已经销毁的元素再调用 `AXObserverRemoveNotification`。
///
/// **线程模型**：整个类型 `@MainActor`。C 回调（`axObserverCallback`，`@convention(c)`，不能
/// 捕获 `self`）通过 `AXObserverAddNotification` 的 `refcon` 传入一个非隔离的簿记对象
/// （`AppObserverState`，见文件底部），回调内部用 `Unmanaged.fromOpaque(...)
/// .takeUnretainedValue()` 取回它，再用 `MainActor.assumeIsolated { ... }` 同步进入主 actor——
/// 之所以能这样断言，是因为 run loop source 只挂在 `CFRunLoopGetMain()`，AXObserver 的回调
/// 天然只会在挂载线程（这里就是主线程）上触发，不需要 `DispatchQueue.main.async` 这种异步跳转。
///
/// **退避重试**：App 刚启动时其 AX server 常常还没就绪，`AXObserverAddNotification` 和
/// `AXUIElementCopyAttributeValue(kAXWindowsAttribute)`（读现有窗口列表）都可能返回
/// `kAXErrorCannotComplete`。两者共用同一套 `DispatchQueue.main.asyncAfter` 指数退避重试
/// （0.1 → 0.2 → 0.4 → 0.8 → 1.6s，总预算约 3.1s，覆盖 Electron/JVM 等慢启动 App）与同一个
/// `pendingRetries` 簿记，几次后放弃并 log error；绝不忙等（不会阻塞主线程/轮询）。
///
/// **`deinit` 安全网**：拥有方一旦忘记调用 `stop()` 就直接释放本实例，所有已挂在主 run loop 上的
/// per-app run loop source、指向 `AppObserverState` 的 `refcon`，都会变成悬挂指针——`deinit` 兜底
/// 补一次 `stop()`（`isolated deinit`：本类型是 `@MainActor`，Swift 保证 deinit 体在真正执行前会
/// 先跳回主 actor，因此可以直接同步调用 `stop()` 这个 `@MainActor` 方法，不需要另起一套
/// non-isolated 的兜底清理逻辑）。与手动 `stop()` 天然幂等——两者共用同一个 `isObservingWorkspace`
/// 门槛判断。
@MainActor
final class AXObserverController {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "AXObserverController")

    /// `AXObserverAddNotification` 遇到 `kAXErrorCannotComplete` 时的重试延迟序列（指数退避）；
    /// 用完这几次还失败就放弃并 log error，不再无限重试。
    ///
    /// O3：总预算约 3.1s（0.1+0.2+0.4+0.8+1.6）——原先 `[0.1, 0.2, 0.4]` 只给约 0.7s，
    /// Electron/JVM 这类启动重的 App，其 AX server 在负载下经常来不及在 1s 内就绪，导致
    /// 注册被永久放弃（该 App 的窗口再也拿不到 destroy/minimize/title 通知）。延长到 ~3-5s
    /// 覆盖这类慢启动场景，不改变重试机制本身（`pendingRetries` 的取消/清理逻辑不变）。
    private static let retryDelays: [TimeInterval] = [0.1, 0.2, 0.4, 0.8, 1.6]

    /// 挂在每个窗口自己的 `AXUIElement` 上的通知集合。
    private static let windowLevelNotifications: [CFString] = [
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
        kAXTitleChangedNotification as CFString,
    ]

    var onNotification: ((AXWindowNotification) -> Void)?
    /// App 启动 → 12b 会对该 App 全量补枚举。注意：无论这个 App 的 `AXObserver` 是否建立成功
    /// （比如 `AXObserverCreate` 本身失败——极其罕见），只要 App 确实是一个新出现的常规 App，
    /// 这个回调就会触发，因为「需不需要补枚举」不取决于「观察者建没建成功」。只在 pid **首次**
    /// 出现时触发一次（`appearedPIDs` 去重），不会因为重复的 launch 通知或 `registerApp` 的
    /// no-op 而重复触发。
    var onAppAppeared: ((ProcessID) -> Void)?
    /// App 退出 → 12b 清该 pid 窗口。与 `onAppAppeared` 严格对称：只要这个 pid 曾经让
    /// `onAppAppeared` 触发过（即在 `appearedPIDs` 里），退出时就一定会触发一次，跟这个 App 的
    /// `AXObserver` 是否建立成功无关——否则一个 `AXObserverCreate` 失败的 App 会让 12b 永远留着
    /// 它的 pid（`onAppAppeared` 已经触发过、但从没有对应的 `onAppTerminated`）。
    var onAppTerminated: ((ProcessID) -> Void)?

    /// 每个已知常规 App 的簿记：observer + AXUIElement + 已注册窗口级通知的窗口集合 + 待执行的
    /// 退避重试。stop() / App 退出时用它来做精确清理。只有 `AXObserverCreate` 成功的 App 才有
    /// 这里的条目——跟「App 是否已经 appeared」（见 `appearedPIDs`）是两回事，后者不依赖前者。
    private var appStates: [ProcessID: AppObserverState] = [:]
    /// 已经触发过 `onAppAppeared` 记账的 pid 集合，独立于 `appStates`（`AXObserverCreate` 失败时
    /// 这个 pid 不会进 `appStates`，但仍然要进这里）——`onAppAppeared`/`onAppTerminated` 的对称性
    /// 由它保证，而不是由 `appStates` 是否有条目保证。
    private var appearedPIDs: Set<ProcessID> = []
    private var isObservingWorkspace = false

    /// 给当前所有常规 App 建 observer（现有窗口只注册、不发 `windowCreated`），并订阅
    /// `NSWorkspace` 的启动/退出通知以便动态跟踪之后的 App 生命周期。重复调用是 no-op。
    func start() {
        guard !isObservingWorkspace else { return }
        isObservingWorkspace = true

        // 判据与窗口枚举同口径（`isRegularOrSelf`）——Napoleon 自己也要观察。设置窗口既然会
        // 出现在切换器里，它的最小化/改标题/关闭就必须像别的窗口一样有增量通知；只放开枚举、
        // 不放开观察者的话，它的 `isMinimized`/`title` 会一直停在上次审计的值：用户 ⌘M
        // 最小化设置窗口后，「不显示最小化窗口」的设置会对它失效，而且没有自愈路径。
        for app in NSWorkspace.shared.runningApplications where app.isRegularOrSelf {
            registerApp(pid: app.processIdentifier)
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    /// O2（Important）：`registerExistingWindows` 只在每个 App 首次出现（`registerApp`）时跑
    /// 一次，而它读的 `kAXWindowsAttribute` 只能看到**当前 Space**的窗口——一个 App 在别的
    /// Space 上还有的窗口，在这个 App 启动那一刻根本不在结果里，永远不会被注册窗口级通知
    /// （尤其是 `kAXUIElementDestroyedNotification`）。等用户切到那个 Space、再关掉这些窗口，
    /// `WindowStore` 收不到 destroy 通知，会永久留着这些窗口的状态（ghost）+ 泄漏它们的句柄
    /// （`handles`/`reverse` 里的条目永远不会被摘除）。
    ///
    /// 调用方（`WindowStore` 的 Space 切换处理）在每次切 Space 时都应该调这个方法，对所有
    /// 已知常规 App 重新跑一遍 `registerExistingWindows`——`registerWindowLevelNotifications`
    /// 内部的 `registeredWindows` 去重让这对已经注册过的窗口是零成本 no-op，只有这次刚刚进入
    /// 当前 Space、之前从未在任何一次 `kAXWindowsAttribute` 结果里出现过的窗口，才会真正补上
    /// 注册。跟 `registerExistingWindows` 本身一样，也会走同一套 `.cannotComplete` 退避重试
    /// （该 App 的 AX server 恰好在这次调用时还没就绪的话）。
    @MainActor
    func reRegisterExistingWindows() {
        for appState in appStates.values {
            registerExistingWindows(appState: appState)
        }
    }

    /// 移除所有 observer（run loop source + 簿记）、取消所有待执行的退避重试、退订
    /// `NSWorkspace`。重复调用 / 从未 `start()` 过时都是安全的 no-op。
    func stop() {
        guard isObservingWorkspace else { return }
        isObservingWorkspace = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)

        for appState in appStates.values {
            tearDown(appState)
        }
        appStates.removeAll()
        appearedPIDs.removeAll()
    }

    /// 安全网：拥有方忘记调用 `stop()` 就释放本实例时兜底做同样的清理，避免每个 App 挂在主
    /// run loop 上的 source 变成永久泄漏、`refcon` 变成指向已释放 `AppObserverState` 的悬挂指针。
    /// `isolated deinit`——本类型是 `@MainActor`，Swift 保证 deinit 体真正执行前已经跳回主 actor
    /// 的 executor，因此这里可以直接同步调用 `stop()` 这个 `@MainActor` 方法（不需要另写一套
    /// non-isolated 的兜底清理路径）。直接复用 `stop()` 也顺带保证了幂等——`stop()` 已经手动调用
    /// 过的话，`isObservingWorkspace` 已经是 `false`，这里再调用是纯 no-op。
    isolated deinit {
        stop()
    }

    // MARK: - NSWorkspace app lifecycle

    @objc private func handleAppLaunched(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.isRegularOrSelf
        else { return }

        let pid = app.processIdentifier
        let isFirstAppearance = !appearedPIDs.contains(pid)
        registerApp(pid: pid)
        if isFirstAppearance {
            onAppAppeared?(pid)
        }
    }

    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        let pid = app.processIdentifier
        if let appState = appStates.removeValue(forKey: pid) {
            tearDown(appState)
        }
        // 对称性核心：不管这个 App 的 observer 是否建立成功（`appStates` 是否有条目），只要它
        // 曾经让 `onAppAppeared` 触发过（在 `appearedPIDs` 里），退出时就一定要发一次
        // `onAppTerminated`，否则 12b 会永远留着这个 pid 的窗口。
        guard appearedPIDs.remove(pid) != nil else { return }
        onAppTerminated?(pid)
    }

    /// `WindowStore` 自愈时调用：某个 pid 的进程已经不在了，但系统**没有**发终止通知（真机实测
    /// 确有这类 App，见 `WindowStore.pruneTerminatedApps`）。这里做与 `handleAppTerminated` 相同的
    /// 拆解——销毁该 App 的 `AXObserver`、摘掉 run loop source、取消未执行的重试、从簿记里移除——
    /// 否则这些资源会随每个这样的 App 永久泄漏，`appearedPIDs` 也会越攒越多。
    ///
    /// 不回调 `onAppTerminated`：调用方就是发现它已死的那一方，自己会做窗口清理，再回调会重复。
    func forgetTerminatedApp(_ pid: ProcessID) {
        if let appState = appStates.removeValue(forKey: pid) {
            tearDown(appState)
        }
        appearedPIDs.remove(pid)
    }

    // MARK: - Per-app observer setup

    /// 给一个 pid 建 `AXObserver`（若已存在簿记则 no-op——幂等），挂主 run loop source，注册
    /// App 级通知，并对该 App **现有**窗口逐个注册窗口级通知（不发 `windowCreated`）。
    ///
    /// 无条件把 pid 记进 `appearedPIDs`（哪怕下面 `AXObserverCreate` 马上失败要 early return）——
    /// 「这个 pid 出现过、以后退出需要通知 12b」跟「observer 建没建成功」是两件事，调用方
    /// （`handleAppLaunched`）在调用前后比较 `appearedPIDs` 的差异来决定要不要触发
    /// `onAppAppeared`，所以这里的插入本身必须无条件、且对重复调用天然幂等（`Set.insert`）。
    private func registerApp(pid: ProcessID) {
        appearedPIDs.insert(pid)
        guard appStates[pid] == nil else { return }

        var observerRef: AXObserver?
        let createError = AXObserverCreate(pid, axObserverCallback, &observerRef)
        guard createError == .success, let observer = observerRef else {
            Self.logger.error("AXObserverCreate failed pid=\(pid, privacy: .public) error=\(createError.rawValue, privacy: .public)")
            return
        }

        let axApp = AXUIElementCreateApplication(pid)
        let appState = AppObserverState(pid: pid, axApp: axApp, observer: observer, controller: self)
        appStates[pid] = appState

        // 主 run loop——AXObserver 回调只会在挂了它的 source 的那个 run loop/线程上触发，
        // WindowStore（12b）是 @MainActor，必须挂主 run loop 才能让回调天然落在主线程上。
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        addNotification(kAXWindowCreatedNotification as CFString, to: axApp, appState: appState)
        addNotification(kAXFocusedWindowChangedNotification as CFString, to: axApp, appState: appState)

        registerExistingWindows(appState: appState)
    }

    /// 读该 App 当前的 `kAXWindowsAttribute`，对每个已存在的窗口注册窗口级通知——刻意不发
    /// `windowCreated`（它们不是「新」窗口，12b 的初始列表来自全量枚举）。
    ///
    /// 这次读取跟 `AXObserverAddNotification` 共享同一个「App 刚启动、AX server 还没就绪」的失败
    /// 模式（`kAXErrorCannotComplete`）——如果放弃不重试，这批已存在窗口永远拿不到窗口级通知
    /// （尤其是 `kAXUIElementDestroyedNotification`），它们之后被关掉也不会发 `windowDestroyed`，
    /// 12b 会永久留着这些早就不存在的窗口。单靠重试 `AddNotification` 补不了这个洞——这些窗口本来
    /// 就不是「新建」的，不会再触发 `kAXWindowCreatedNotification`。所以这里用跟
    /// `addNotification` 完全相同的 `retryDelays` 退避序列，重试 work item 同样记在
    /// `appState.pendingRetries` 里，`tearDown`/`stop()` 能一并取消。
    ///
    /// 非 `.cannotComplete` 的其它失败原因（该 App 本就不支持 `kAXWindowsAttribute` 之类）直接放弃
    /// 这批，不重试、不 log——维持原有行为。
    private func registerExistingWindows(appState: AppObserverState, attempt: Int = 0) {
        var windowsRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appState.axApp, kAXWindowsAttribute as CFString, &windowsRef)

        switch error {
        case .success:
            guard let windows = windowsRef as? [AXUIElement] else { return }
            for window in windows {
                registerWindowLevelNotifications(for: window, appState: appState)
                for child in Self.children(of: window) where Self.role(of: child) == kAXSheetRole {
                    registerSheetDestruction(for: child, appState: appState)
                }
            }
        case .cannotComplete where attempt < Self.retryDelays.count:
            let delay = Self.retryDelays[attempt]
            let token = UUID()
            let workItem = DispatchWorkItem { [weak self, weak appState] in
                // Minor 2：先把自己从 pendingRetries 里摘掉（不管后面 self/appState 是否还活着），
                // 避免长寿命 App 无限攒积已经跑完的 work item。
                appState?.pendingRetries.removeValue(forKey: token)
                guard let self, let appState else { return }
                self.registerExistingWindows(appState: appState, attempt: attempt + 1)
            }
            appState.pendingRetries[token] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        case .cannotComplete:
            Self.logger.error("""
            registerExistingWindows giving up pid=\(appState.pid, privacy: .public) \
            attempt=\(attempt, privacy: .public) error=\(error.rawValue, privacy: .public)
            """)
        default:
            return
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    /// 对单个窗口元素注册全部窗口级通知；用 `registeredWindows` 做去重，避免同一个窗口（比如
    /// `kAXWindowCreatedNotification` 和 start() 时的枚举撞上同一个元素的极端情况）被重复注册。
    private func registerWindowLevelNotifications(for window: AXUIElement, appState: AppObserverState) {
        let key = AXUIElementKey(element: window)
        guard !appState.registeredWindows.contains(key) else { return }
        appState.registeredWindows.insert(key)

        for notification in Self.windowLevelNotifications {
            addNotification(notification, to: window, appState: appState)
        }
    }

    private func registerSheetDestruction(for sheet: AXUIElement, appState: AppObserverState) {
        let key = AXUIElementKey(element: sheet)
        guard !appState.registeredWindows.contains(key) else { return }
        appState.registeredWindows.insert(key)
        addNotification(kAXUIElementDestroyedNotification as CFString, to: sheet, appState: appState)
    }

    /// `AXObserverAddNotification` 的统一入口，带退避重试：
    /// - `.success` / `.notificationAlreadyRegistered`：视为完成。
    /// - `.notificationUnsupported` / `.actionUnsupported` / `.invalidUIElement` /
    ///   `.invalidUIElementObserver`：该 App/窗口本就不支持这个通知，或元素在注册前已经失效
    ///   （比如窗口在退避等待期间被关掉了）——这些是预期内会发生的正常情况，静默放弃，不 log
    ///   error 刷屏。
    /// - `.cannotComplete`：AX server 未就绪，按 `retryDelays` 指数退避重试；重试次数用尽后放弃
    ///   并 log error。
    /// - 其它错误：直接 log error，不重试。
    private func addNotification(_ notification: CFString, to element: AXUIElement, appState: AppObserverState, attempt: Int = 0) {
        let refcon = Unmanaged.passUnretained(appState).toOpaque()
        let error = AXObserverAddNotification(appState.observer, element, notification, refcon)

        switch error {
        case .success, .notificationAlreadyRegistered:
            return
        case .notificationUnsupported, .actionUnsupported, .invalidUIElement, .invalidUIElementObserver:
            return
        case .cannotComplete where attempt < Self.retryDelays.count:
            let delay = Self.retryDelays[attempt]
            let token = UUID()
            let workItem = DispatchWorkItem { [weak self, weak appState] in
                // Minor 2：先把自己从 pendingRetries 里摘掉（不管后面 self/appState 是否还活着），
                // 避免长寿命 App 无限攒积已经跑完的 work item。
                appState?.pendingRetries.removeValue(forKey: token)
                guard let self, let appState else { return }
                self.addNotification(notification, to: element, appState: appState, attempt: attempt + 1)
            }
            appState.pendingRetries[token] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        default:
            Self.logger.error("""
            AXObserverAddNotification giving up pid=\(appState.pid, privacy: .public) \
            notification=\(notification as String, privacy: .public) attempt=\(attempt, privacy: .public) \
            error=\(error.rawValue, privacy: .public)
            """)
        }
    }

    // MARK: - Callback dispatch (invoked from axObserverCallback, already proven to be on main)

    /// C 回调（`axObserverCallback`）在确认已经身处主 actor 之后调用这里。把 AX 通知名字转成
    /// `AXWindowNotification`，`kAXWindowCreatedNotification` 额外负责给新窗口挂窗口级通知，
    /// `kAXUIElementDestroyedNotification` 额外负责把死元素从簿记里摘除。
    fileprivate func handle(notificationName: String, element: AXUIElement, appState: AppObserverState) {
        switch notificationName {
        case kAXWindowCreatedNotification:
            if Self.role(of: element) == kAXSheetRole {
                registerSheetDestruction(for: element, appState: appState)
            } else {
                registerWindowLevelNotifications(for: element, appState: appState)
            }
            onNotification?(.windowCreated(pid: appState.pid, element: element))
        case kAXUIElementDestroyedNotification:
            appState.registeredWindows.remove(AXUIElementKey(element: element))
            onNotification?(.windowDestroyed(pid: appState.pid, element: element))
        case kAXWindowMiniaturizedNotification:
            onNotification?(.minimizedChanged(pid: appState.pid, element: element, isMinimized: true))
        case kAXWindowDeminiaturizedNotification:
            onNotification?(.minimizedChanged(pid: appState.pid, element: element, isMinimized: false))
        case kAXTitleChangedNotification:
            onNotification?(.titleChanged(pid: appState.pid, element: element))
        case kAXFocusedWindowChangedNotification:
            // AX 会把新聚焦的窗口元素作为 element 传回来（而不是 app 元素本身）——这是文档化的
            // 系统行为，AltTab/yabai 等同类工具都依赖同一条规则。
            onNotification?(.focusedWindowChanged(pid: appState.pid, element: element))
        default:
            break
        }
    }

    // MARK: - Teardown

    /// 取消该 App 所有待执行的退避重试、把它的 run loop source 从主 run loop 上摘掉、清空窗口
    /// 簿记。调用方（`stop()` / `handleAppTerminated`）负责把它从 `appStates` 里摘除。
    private func tearDown(_ appState: AppObserverState) {
        for workItem in appState.pendingRetries.values {
            workItem.cancel()
        }
        appState.pendingRetries.removeAll()

        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appState.observer), .commonModes)
        appState.registeredWindows.removeAll()
    }
}

// MARK: - AXUIElement Hashable wrapper

/// `AXUIElement`（`AXUIElementRef` = `CFTypeRef`）本身不是 `Hashable`——它是一个 Core Foundation
/// 对象，相等性/哈希要用 `CFEqual`/`CFHash`，不能用默认的对象身份比较。用来在
/// `Set<AXUIElementKey>` 里记录「已经注册过窗口级通知的窗口」。
private struct AXUIElementKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AXUIElementKey, rhs: AXUIElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

// MARK: - Per-app bookkeeping

/// 单个 App 的簿记，也是 C 回调 `refcon` 里传递的对象（`Unmanaged.passUnretained`）。不是
/// `@MainActor`——它本身只是纯数据，真正的隔离保证来自「只有 `AXObserverController` 的
/// `@MainActor` 方法，以及已经 `MainActor.assumeIsolated` 过的 C 回调，才会碰它的可变字段」这一
/// 约定（与本文件其它非 actor 化的 C-boundary 簿记类型是同一套约定）。
/// `controller` 用 `weak`——`AXObserverController` 才是拥有方（通过 `appStates` 字典持有它），
/// 反向持有必须弱引用，否则会形成引用环。
private final class AppObserverState {
    let pid: ProcessID
    let axApp: AXUIElement
    let observer: AXObserver
    weak var controller: AXObserverController?

    /// 已经注册过窗口级通知的窗口集合，用于去重 + `kAXUIElementDestroyed` 时精确摘除。
    var registeredWindows: Set<AXUIElementKey> = []
    /// 尚未执行/尚未取消的退避重试 work item（`addNotification` 和 `registerExistingWindows`
    /// 共用同一份簿记）——App 退出或 `stop()`/`deinit` 时要整批 `cancel()`，防止一个已经被拆掉的
    /// App 在几百毫秒后还打进一次 AX 调用。用 `UUID` 做 key 而不是数组，是为了让每个重试闭包能在
    /// 自己执行完之后把自己摘掉（Minor 2：避免长寿命 App 无限攒积已经跑完的 work item）——不能让
    /// 闭包直接捕获自己那个 `DispatchWorkItem` 变量来做自摘除，那样闭包→变量→`DispatchWorkItem`
    /// 会形成引用环。
    var pendingRetries: [UUID: DispatchWorkItem] = [:]

    init(pid: ProcessID, axApp: AXUIElement, observer: AXObserver, controller: AXObserverController) {
        self.pid = pid
        self.axApp = axApp
        self.observer = observer
        self.controller = controller
    }
}

// MARK: - C callback trampoline
//
// 必须是无捕获的全局函数（或 static 方法）才能满足 `AXObserverCallback` 的 `@convention(c)` 签名。
// `AXObserverController` 实例通过 `refcon` 里的 `AppObserverState`（本身用 `Unmanaged.passUnretained`
// 传入）间接拿到——不能直接把 `self` 塞进 refcon 后在这里跨 actor 边界解引用它的方法。
//
// `MainActor.assumeIsolated` 而不是 `DispatchQueue.main.async`：run loop source 只挂在
// `CFRunLoopGetMain()`，AXObserver 的回调天然只会在挂载线程（主线程）上同步触发，`assumeIsolated`
// 只是把这个「已经在主线程」的事实告诉类型系统，不引入任何调度延迟。

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let appState = Unmanaged<AppObserverState>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        appState.controller?.handle(notificationName: notification as String, element: element, appState: appState)
    }
}
