import ApplicationServices
import Carbon
import Foundation
import os

/// Task 9 安全网：secure input 查询 + Accessibility 授权吊销监听（事件驱动，非轮询）。
///
/// 这两者都不属于 tap 线程的 session 状态机——`isSecureInputEnabled` 是纯查询（HotkeyManager 在
/// `beginSession` 时读一次用于日志告警），`onAccessibilityChanged` 的回调来自
/// `DistributedNotificationCenter`，后者本就在主线程投递通知，所以这里的回调只做主线程安全的事
/// （重查 `AXIsProcessTrusted()` + os_log + 转发闭包），绝不触碰 tap 线程上的 `sessionActive` 等状态。
final class InputSafetyMonitor {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "InputSafetyMonitor")

    /// 当前系统是否处于 secure input 模式（密码框、Terminal "Secure Keyboard Entry" 等）。此时系统可能
    /// 抑制部分按键事件传递给非前台 App 的 event tap —— 调用方只用它做日志告警，不做任何行为分支。
    static var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    /// Accessibility 授权状态变化时触发，`trusted` 是重新查询 `AXIsProcessTrusted()` 后的结果。
    /// 始终在主线程被调用。供 Task 20 菜单栏 UI 使用；本任务的调用方目前只 os_log。
    var onAccessibilityChanged: ((_ trusted: Bool) -> Void)?

    private var isObserving = false

    /// Fix Y6 debounce delay: `"com.apple.accessibility.api"` can arrive before this process's own
    /// TCC cache has updated, so an immediate `AXIsProcessTrusted()` re-check can read a stale value.
    /// Waiting a beat lets the cache catch up before we re-check and notify.
    private static let debounceInterval: TimeInterval = 0.5
    private var pendingRecheck: DispatchWorkItem?

    /// 订阅 `"com.apple.accessibility.api"` distributed notification——事件驱动，不是轮询，
    /// 系统在辅助功能授权状态变化时才会广播它。
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityStatusChanged),
            name: Notification.Name("com.apple.accessibility.api"),
            object: nil
        )
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: Notification.Name("com.apple.accessibility.api"),
            object: nil
        )
        pendingRecheck?.cancel()
        pendingRecheck = nil
    }

    /// Fix Y6: debounce ~0.5s on main before re-checking `AXIsProcessTrusted()`, and coalesce rapid
    /// repeats (e.g. the notification firing more than once in quick succession) into a single
    /// re-check + callback instead of one per notification.
    @objc private func accessibilityStatusChanged(_ notification: Notification) {
        pendingRecheck?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performDebouncedRecheck()
        }
        pendingRecheck = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    private func performDebouncedRecheck() {
        pendingRecheck = nil
        let trusted = AXIsProcessTrusted()
        if trusted {
            Self.logger.info("Accessibility trusted (re-checked after com.apple.accessibility.api)")
        } else {
            Self.logger.warning("Accessibility revoked — tap is dead")
        }
        onAccessibilityChanged?(trusted)
    }

    deinit {
        stopObserving()
    }
}
