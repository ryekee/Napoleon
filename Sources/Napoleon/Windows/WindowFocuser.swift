import AppKit
import ApplicationServices
import NapoleonCore

/// 把一个已知的 `AXUIElement` 窗口聚焦到前台。
///
/// **顺序很重要（Spike 2 实测结论）**：解最小化 → `AXRaise` → 设 `AXMain` → `NSRunningApplication.activate()`。
/// 这是公开 AX API 的组合，Spike 2 已在 macOS 26 上验证它能可靠触发跨 Space / 全屏窗口的桌面跳转——
/// v1 不使用私有 `_SLPSSetFrontProcessWithOptions`（更强但未公开、有拒审风险）。
///
/// - 解最小化必须在 raise 之前：一个仍处于最小化状态的窗口，`AXRaise` 不会把它显示出来。
/// - `AXRaise` 只是把这个窗口在其所属 App 内部前置；不保证该窗口成为 App 的 "main window"，
///   也不会激活整个 App（尤其当前台是另一个 App 时）。
/// - 设 `kAXMainAttribute = true` 是让部分应用（多窗口场景下 raise 不足以更新其内部前台窗口
///   状态的那些）把这个窗口标记为自己的主窗口——不是所有 App 都需要这步才生效，但设置它对
///   已经是主窗口的情况是无害的空操作，成本很低，所以总是做。
/// - 真正让系统跳转 Space / 退出其它全屏空间、把该 App 带到最前的是 `NSRunningApplication.activate()`
///   （配合前面的 raise）——Spike 2 验证了这一步是跨 Space/全屏生效的关键，且必须用 macOS 14+ 的
///   无参 `activate()`，不是已废弃的 `activate(options:)`/`ignoringOtherApps`。
/// - O5：成功与否**不**单看 `activate()` 的返回值——同一个 App 内切换窗口时（目标 App 已经是
///   前台），协作式激活下 `activate()` 经常返回 `false` 即使聚焦已经生效，所以额外看
///   `app.isActive` 兜底。窗口原本处于最小化状态时，解最小化是异步动画，紧跟着的 raise/AXMain
///   可能在动画结束前就已跑完而不生效，因此额外安排了一次 ~150ms 后的 fire-and-forget 补
///   raise（不影响本次调用的返回值，也不阻塞调用方）。
@MainActor
enum WindowFocuser {
    /// 把窗口聚焦到前台。返回是否成功——窗口已关闭（AX 元素失效）时返回 `false`；所属 App
    /// 已退出，或 `activate()` 失败且该 App 也没能变成前台（`app.isActive`）时同样返回
    /// `false`，调用方可以据此跳到 MRU 里的下一个候选窗口。若窗口原本是最小化状态，返回值只
    /// 反映本次调用内 raise/AXMain/activate 这一轮的即时结果，不等待/不反映上面提到的延迟
    /// 补 raise 是否命中。
    @discardableResult
    static func focus(windowID: WindowID, element: AXUIElement, pid: ProcessID) -> Bool {
        // 1. 解最小化——只在确实处于最小化状态时才写，避免对正常窗口发一次多余的 AX 调用。
        // 记下 wasMinimized：解最小化触发的是一个异步动画（见下面第 5 步），紧接着的
        // raise/AXMain 可能在动画结束前就跑完、对仍处于最小化状态的窗口不生效。
        let wasMinimized = boolAttribute(element, kAXMinimizedAttribute)
        if wasMinimized {
            let unminimizeError = AXUIElementSetAttributeValue(
                element, kAXMinimizedAttribute as CFString, kCFBooleanFalse
            )
            if unminimizeError == .invalidUIElement {
                return false // 窗口在这两次 AX 调用之间已经被关闭
            }
            // 其它错误（比如该 App 一时不响应）不是致命的——继续走后续步骤，最终仍以
            // 「能否 activate」为准判定整体成功与否。
        }

        // 2. 抬升——把窗口在其所属 App 内部前置。
        let raiseError = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if raiseError == .invalidUIElement {
            return false
        }

        // 3. 设为 App 内的主窗口——部分 App 需要这一步才会把该窗口当作真正的前台窗口。
        let mainError = AXUIElementSetAttributeValue(
            element, kAXMainAttribute as CFString, kCFBooleanTrue
        )
        if mainError == .invalidUIElement {
            return false
        }

        // 4. 激活所属 App——跨 Space / 全屏跳转靠这步 + 前面的 raise 触发（Spike 2 验证）。
        let success = activateApp(pid: pid)

        // 5. Minimized 异步动画兜底：第 1 步只是发起了解最小化，系统用一个异步动画完成它，
        // 上面第 2/3 步的 AXRaise/AXMain 有可能在动画结束前就已经跑完、对仍处于视觉最小化
        // 状态的窗口不起作用。这里 best-effort 地在动画大概率已结束后（~150ms）再补一次
        // AXRaise + AXMain。Fire-and-forget——不阻塞、不改变本次调用已经决定好的返回值，
        // 只用来兜底动画结束后的状态；元素在这段延迟期间失效（比如窗口被关掉）时用
        // `.invalidUIElement` 判断并直接放弃，不再尝试设置 AXMain。
        if wasMinimized {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let reRaiseError = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                guard reRaiseError != .invalidUIElement else { return }
                _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        }

        return success
    }

    /// 无句柄（跨 Space/全屏）时的聚焦：激活该 App。全屏 App 会跳到其全屏 Space（Spike 2 已验）；
    /// 多窗口 App 在其他桌面时，激活会把 App 带到前台（v1 不保证 raise 到具体那一个窗口——
    /// 用私有 API 才能按 windowID 精确聚焦，本 v1 有意不引入）。返回是否成功激活——
    /// 与 `focus` 同样的成功判据：`activate()` 为 `true`，或该 App 本来就/最终已经是前台
    /// （`app.isActive`），都算成功；App 已退出则返回 `false`。
    @discardableResult
    static func focusApp(pid: ProcessID) -> Bool {
        activateApp(pid: pid)
    }

    // MARK: - Activation

    /// 把 `pid` 对应的 App 带到前台。
    ///
    /// **目标是 Napoleon 自己时必须走另一条路**：`NSRunningApplication.activate()` 是 macOS 14+
    /// 的协作式激活，而「一个当前不在前台的进程请求把**自己**提到前台」正是这套机制要禁止的
    /// 行为（防 App 抢焦点）——系统会照常抬升窗口、却不改变前台 App。症状就是用户报的那个：
    /// 目标窗口跑到了「次前台」，原来的 App 仍然占着最前台。自 Napoleon 的设置窗口成为切换器
    /// 里可选的一项之后，这条路径才真正可达。
    ///
    /// 进程把自己带到前台要用 `NSApplication.activate(ignoringOtherApps:)`——设置窗口从菜单栏
    /// 打开时用的就是它，已验证有效。它在 macOS 14 标记为废弃，但替代的无参 `activate()` 同样
    /// 受协作式激活约束、在这里正是不管用的那个，所以继续用这一个。
    ///
    /// O5（同 App 内切换的假失败）：macOS 14+ 协作式激活下，如果目标窗口所属的 App 已经是前台
    /// （很常见——比如同一个 App 内用 Cmd+` 循环窗口），`activate()` 经常返回 `false`，即使
    /// raise/AXMain 已经生效、窗口确实前置成功。所以只要 `activate()` 返回 true，**或者**该 App
    /// 本来就已经/最终是前台（`app.isActive`），就算成功；两者都不满足才是真失败。
    private static func activateApp(pid: ProcessID) -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            // 自我激活：公开 API 在 macOS 14+ 协作式激活下全部失效（实测见 `SelfFrontProcess`
            // 与 `spikes/frontprocess`），走私有 SkyLight 调用；符号缺失时退回公开 API——
            // 那条路不可靠但偶尔有效，且绝不崩溃。
            if SelfFrontProcess.bringToFront() {
                return true
            }
            NSApp.activate(ignoringOtherApps: true)
            return NSRunningApplication.current.isActive
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return false // App 已退出
        }

        // 切到**别的** App 之前先确保自己不是 `.regular`。协作式激活只豁免后台代理
        // （`.accessory`）——一个不在前台的普通 App 无权把别的 App 提到前台，系统会照常执行
        // 前面的 AXRaise、却不改变前台 App：目标窗口停在「次前台」，原来的 App 仍占着最前。
        // 设置窗口在前台时进程是 `.regular`（为了 Dock 图标），所以这里顺手降回来——反正这次
        // 操作的结果就是切走、我们本来就要退到后台。用户切回设置窗口时
        // `SettingsWindowController` 会在它重新成为 key window 时再提升回去。
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }

        return app.activate() || app.isActive
    }

    // MARK: - AX attribute helpers

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return false }
        return (value as? Bool) ?? false
    }
}
