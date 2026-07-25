import AppKit
import ApplicationServices
import CoreGraphics
import os

/// Task 20：两项 TCC 权限的实时状态 + 跳转系统设置的入口，供菜单栏图标警示与设置界面共用。
///
/// **两项权限的地位不同**：
/// - **辅助功能**（`AXIsProcessTrusted`）是硬依赖——没有它 CGEventTap 装不上、窗口枚举/聚焦全废，
///   Napoleon 完全不能用。
/// - **屏幕录制**（`CGPreflightScreenCaptureAccess`）是软依赖——没有它只是拿不到
///   `SCShareableContent`：缩略图与跨 Space 窗口列表退化（`WindowStore.fetchShareableContent`
///   已有降级路径，见那里），切换器本身仍然可用，卡片退回只显 App 图标。
///
/// **为什么要轮询**：辅助功能有系统通知（`kAXTrustedCheckOptionPrompt` 体系下的
/// `com.apple.accessibility.api` 分发，`InputSafetyMonitor` 已在监听并回调 `onAccessibilityChanged`），
/// 但**屏幕录制没有任何变更通知**——用户在系统设置里勾上开关后，进程内只能靠再查一次
/// `CGPreflightScreenCaptureAccess()` 才知道。所以这里：① App 重新激活时（用户从系统设置切回来）
/// 立刻复查一次；② 只要还有权限缺失就每 `pollInterval` 轮询一次，**全部齐了就停表**——稳态下
/// （权限都给了）零轮询开销，符合项目「极致低占用」的要求。
///
/// **Sequoia/Tahoe 现实**：macOS 15 起系统会周期性（约每月）重新征询屏幕录制授权，用户可能在
/// 某天早上发现缩略图没了——这正是菜单栏图标警示存在的意义：不弹自己的窗口打扰用户，只在图标上
/// 标出来，用户点开菜单能看到是哪一项掉了并一键跳设置。
@MainActor
final class PermissionsManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "PermissionsManager")

    /// 有权限缺失时的复查间隔。2s 足够让「切到系统设置勾选 → 切回来」感觉是即时的，又不会在
    /// 未授权状态下造成可观的空转（两个调用都是本地的、无 IPC 的进程内查询）。
    private static let pollInterval: TimeInterval = 2.0

    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var screenRecordingGranted: Bool

    /// 硬依赖是否满足——菜单栏图标是否要挂警示以这个为准。
    var isFullyOperational: Bool { accessibilityTrusted }
    /// 两项都齐（缩略图也正常）——决定是否还需要继续轮询。
    var allGranted: Bool { accessibilityTrusted && screenRecordingGranted }

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init() {
        accessibilityTrusted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    /// 开始跟踪：订阅「App 重新激活」+ 按需启动轮询。重复调用安全（订阅只装一次，轮询由
    /// `syncPolling()` 幂等管理）。
    func start() {
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // `addObserver(forName:...:using:)` 的闭包没有 actor 隔离信息，但 queue 指定了
                // `.main`，所以这里确实在主线程——用 `assumeIsolated` 把这个事实告诉类型系统，
                // 跟 `SwitcherController` 处理 delegate 回调是同一套手法。
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    /// 停止跟踪：退订 + 停表。`isolated deinit` 兜底调用（本类型 `@MainActor`，deinit 体执行前
    /// Swift 保证已回到主 actor），拥有方忘记调用也不会泄漏计时器/观察者。
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    isolated deinit {
        stop()
    }

    /// 立刻重查两项权限。值真的变了才写 `@Published`（避免每 2s 一次无谓的 SwiftUI 失效重绘），
    /// 变化时记一条 log 便于真机排查，最后按当前状态决定要不要继续轮询。
    func refresh() {
        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()

        if ax != accessibilityTrusted {
            accessibilityTrusted = ax
            Self.logger.notice("accessibility trust changed: \(ax, privacy: .public)")
        }
        if screen != screenRecordingGranted {
            screenRecordingGranted = screen
            Self.logger.notice("screen recording permission changed: \(screen, privacy: .public)")
        }

        syncPolling()
    }

    /// 外部事件源（`InputSafetyMonitor.onAccessibilityChanged`）推来的辅助功能变更——统一走
    /// `refresh()` 重查一遍，而不是直接采信参数：两个来源看到的是同一个系统状态，重查一次能顺带
    /// 把屏幕录制也刷新了，也避免两条路径写同一个 `@Published` 造成不一致。
    func accessibilityTrustDidChange(_ trusted: Bool) {
        refresh()
    }

    /// 权限齐了就停表、缺了就开表——`start()`/`refresh()` 之后调用，幂等。
    private func syncPolling() {
        if allGranted {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // `.common` 而不是默认的 `.default`：菜单栏菜单展开期间 run loop 处于 `eventTracking`
        // 模式，`.default` 的 timer 完全不走——用户正对着菜单里那行「⚠️ 需要屏幕录制权限」
        // 等它消失时，它永远不会消失（必须收起菜单再打开）。
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - 跳转系统设置

    /// 打开「隐私与安全性 › 辅助功能」。用 `x-apple.systempreferences:` scheme——从 Ventura 起
    /// 这是官方支持的深链方式（旧的 `Security` prefPane 路径在新系统上会打不开或落到错误面板）。
    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// 打开「隐私与安全性 › 屏幕录制」。
    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// 触发系统的屏幕录制授权弹窗（只有从未做过选择时系统才会弹；已拒绝过则无反应，那种情况要靠
    /// 上面的跳转让用户手动改）。返回值即调用后系统报告的授权结果，这里不用它——一律走 `refresh()`
    /// 统一更新状态。
    func requestScreenRecordingAccess() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
