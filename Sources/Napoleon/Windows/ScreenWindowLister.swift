import CoreGraphics
import NapoleonCore
import ScreenCaptureKit
import os

/// 一个真实 App 窗口，来自 `SCShareableContent`——覆盖**所有 Space（含全屏）**，
/// 不像 `WindowEnumerator`（AX 枚举）只能看到当前 Space。
struct ScreenWindow: Equatable, Sendable {
    let windowID: WindowID
    let pid: ProcessID
    let appName: String
    let appBundleID: String?
    let title: String
    let frame: CGRect
    let isOnScreen: Bool // SCWindow.isOnScreen：当前屏可见（≈当前 Space）
}

/// 用公开 `SCShareableContent.current.windows` 枚举跨 Space/全屏窗口，过滤掉几百个
/// 系统 chrome 窗口（Control Center 菜单项、Dock 壁纸、Shield、Menubar、Notification
/// Center、Spotlight…），只留下真实 App 窗口。
///
/// 过滤谓词 `isRealAppWindow` 是纯逻辑，跟 `list()` 的 SCShareableContent 抓取拆开——
/// 后者需要屏幕录制权限 + 运行时窗口服务器，不可单测；前者可单测（见
/// `ScreenWindowListerTests`）。
final class ScreenWindowLister {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "ScreenWindowLister")

    /// 系统 chrome 拒绝名单：这些 bundleID 背后的窗口都是非 App 的系统 UI 组件
    /// （菜单栏项、Dock、Shield 等），即便偶尔满足其它规则也一律排除。
    private static let denylistedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.WindowManager",
        "com.apple.wallpaper",
        "com.apple.systemuiserver",
        "com.apple.WindowServer"
    ]

    /// 抓取 `SCShareableContent` 并过滤成真实 App 窗口。后台 async，需屏幕录制权限。
    ///
    /// O2：旧版本用 `try? await SCShareableContent.current`，未授权/运行时异常一律静默
    /// 吞掉——整个跨 Space 功能会悄无声息地消失，运维/自查时零诊断信息。现在改成两层：
    /// 1. 先 `CGPreflightScreenCaptureAccess()` 短路——未授权时这次 XPC 请求本就注定失败
    ///    （还可能弹系统权限提示/产生噪音），直接跳过并记一条 warning。
    /// 2. 真正发起请求后用 `do/catch` 替换 `try?`——授权了但仍然失败（比如用户在系统设置
    ///    里刚刚 revoke、`.userDeclined`、XPC 连接问题等）时记一条 error，而不是静默返回 `[]`。
    /// 两条路径都返回 `[]`（调用方对「这次没有跨 Space 窗口」和「这次抓取失败」一视同仁，
    /// 全屏/跨 Space 只是锦上添花的能力，不应该让主窗口列表跟着失败），区别只在于现在会
    /// 留下日志，方便定位「为什么看不到跨 Space 窗口」。
    ///
    /// R1：抓取（本方法，需权限 + XPC）与过滤（`windows(from:)`，纯同步）已经拆开——
    /// `WindowStore.refreshNow()` 现在自己抓一次 `SCShareableContent`（同时喂给
    /// `ThumbnailService`，见该方法注释），直接调 `windows(from:)` 复用这份过滤逻辑，不需要
    /// 再触发第二次 XPC。这里仍然保留 `list()` 独立可用（内部就是「抓取 + `windows(from:)`」
    /// 两步），供 `ScreenWindowListerTests` 之外任何还想要「一步到位」入口的调用方使用。
    func list() async -> [ScreenWindow] {
        guard CGPreflightScreenCaptureAccess() else {
            Self.logger.warning("screen recording not granted — cross-space windows unavailable")
            return []
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            Self.logger.error("SCShareableContent.current failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        return windows(from: content)
    }

    /// R1：纯同步过滤——把一份**已经抓到**的 `SCShareableContent` 过滤成真实 App 窗口列表，
    /// 不发起任何请求、不需要权限检查（抓取这份 content 时权限已经检查过）。跟 `isRealAppWindow`
    /// 一样只是逻辑搬运，供两处共用：`list()` 自己抓完之后调它；`WindowStore.refreshNow()`
    /// 把它统一抓的那一份 `SCShareableContent`（同时喂给 `ThumbnailService.setShareableContent`）
    /// 传进来复用，避免「AX 全量刷新时再单独抓一次 SC 内容」这第二次 XPC（spike 实测单次
    /// ~59ms）。
    func windows(from content: SCShareableContent) -> [ScreenWindow] {
        content.windows.compactMap { window -> ScreenWindow? in
            let bundleID = window.owningApplication?.bundleIdentifier
            let appName = window.owningApplication?.applicationName ?? ""
            let title = window.title ?? ""

            guard Self.isRealAppWindow(
                windowLayer: window.windowLayer,
                bundleID: bundleID,
                appName: appName,
                title: title,
                frame: window.frame
            ) else {
                return nil
            }

            guard let processID = window.owningApplication?.processID else {
                return nil
            }

            return ScreenWindow(
                windowID: WindowID(window.windowID),
                pid: ProcessID(processID),
                appName: appName,
                appBundleID: bundleID,
                title: title,
                frame: window.frame,
                isOnScreen: window.isOnScreen
            )
        }
    }

    /// 纯过滤谓词（可单测）：判断一个 SC 窗口是否是「真实 App 窗口」。全部满足才 true：
    /// 1. `windowLayer == 0`（正常窗口层；菜单栏项/Dock/Shield 等都在非 0 层）。
    /// 2. `!title.isEmpty`（真实 App 窗口基本都有标题；系统 chrome 多为空或占位）。
    /// 3. `!appName.isEmpty`。
    /// 4. `frame` 至少 50x50（滤掉 1x1 Shield、菜单栏小项）。
    /// 5. `bundleID` 不在系统 chrome 拒绝名单里，且不为 nil——spike 里 `owningApplication`
    ///    为空的那些 underbelly/Menubar/Shield/Backstop 都没有正常 bundleID，一律排除。
    static func isRealAppWindow(windowLayer: Int, bundleID: String?, appName: String, title: String, frame: CGRect) -> Bool {
        guard windowLayer == 0 else { return false }
        guard !title.isEmpty else { return false }
        guard !appName.isEmpty else { return false }
        guard frame.width >= 50, frame.height >= 50 else { return false }
        guard let bundleID, !denylistedBundleIDs.contains(bundleID) else { return false }
        return true
    }
}
