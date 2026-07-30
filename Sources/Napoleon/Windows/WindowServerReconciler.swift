import CoreGraphics
import Foundation
import NapoleonCore

/// 窗口服务器眼中的一扇「此刻就在屏幕上」的窗口，来自 `CGWindowListCopyWindowInfo`。
///
/// 跟 `ScreenWindow`（`SCShareableContent`，覆盖所有 Space，要屏幕录制权限、走 XPC）不是
/// 一回事：这一路**不需要任何权限**、纯进程内查询（实测中位数 0.86ms、最坏 6.7ms），代价是
/// 只看得见当前可见的那些 Space——而这恰好就是对账要的范围（见 `WindowServerReconciler`）。
struct OnScreenWindow: Equatable, Sendable {
    let windowID: WindowID
    let pid: ProcessID
    let title: String
    let bounds: CGRect
}

/// 呼出切换器时，拿窗口服务器的实况给热态对一次账，把跟丢的窗口补回来。
///
/// **为什么需要它**：`WindowStore` 的窗口集合平时靠增量 AX 通知维护，全量刷新只在「App 启动 /
/// 切 Space / 开关设置窗口」三种时机发生。这意味着窗口集合是**单向衰减**的——任何一次丢失的
/// 通知、任何一次结果偏少的枚举，都会永久留在热态里，没有第二条路径会去纠正它。真机实测过最坏
/// 的样子：一个连续跑了 22.5 小时的进程，列表掉到只剩 2 扇窗口，连用户当时正在用的那个前台 App
/// 的窗口都不在里面，而同一时刻独立探针能正常枚举到 18 扇；启动任意一个 App 触发一次全量刷新，
/// 列表立刻全部恢复。缺的从来不是枚举能力，是**对账**。
///
/// **为什么用 `CGWindowList` 而不是补一次 AX 枚举**：这段代码跑在热键的同步路径上
/// （`WindowStore.snapshot()`）。AX 读取是同步 mach IPC，目标 App 卡死时会一直堵到 messaging
/// timeout；主线程被堵住的后果在本 App 里格外严重——系统会把无响应的 `CGEventTap` 直接禁用，
/// 热键从此彻底失灵（见 `WindowStore.configureSystemWideMessagingTimeout`）。`CGWindowList`
/// 是纯进程内查询，没有这个风险。
///
/// **补进来的窗口是「临时工」**：只有 `CGWindowList` 给得出的信息（id/pid/标题），没有 AX 句柄，
/// 也没有 subrole/最小化状态。所以对账在补窗口的同时一定会排一次全量刷新——几百毫秒后 AX 那份
/// 权威数据落地，会把这些临时条目替换成完整的（`.fullRefresh` 是整体替换语义），顺带纠正掉这里
/// 可能误收的窗口。用户这一次按键就能看到正确的列表，而不必按第二次。
enum WindowServerReconciler {
    /// App 侧的身份信息，由调用方按 pid 提供（`NSRunningApplication` 查表）。返回 `nil` 表示
    /// 「这个 pid 不该出现在列表里」——不是常规 App，或者已经退出了。
    struct AppIdentity: Equatable {
        let name: String
        let bundleID: String?
        let isHidden: Bool
    }

    // MARK: - 地面真相（不纯：读窗口服务器）

    /// 读一次窗口服务器，返回当前可见的真实 App 窗口。失败/读不到时返回空数组——调用方据此
    /// 完全跳过这次对账（见 `WindowStore.reconcileWithWindowServer`），绝不把空结果当成
    /// 「一扇窗口都没有」。
    static func onScreenWindows() -> [OnScreenWindow] {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return realAppWindows(from: raw)
    }

    // MARK: - 纯逻辑（可单测）

    /// 从 `CGWindowListCopyWindowInfo` 的原始字典里挑出真实的 App 窗口。
    ///
    /// 三条判据，都是为了逼近 AX 侧 `subrole == AXStandardWindow || AXDialog` 的那批窗口
    /// （`CGWindowList` 给不出 subrole，只能用可观测的代理指标）：
    /// - `kCGWindowLayer == 0`：普通 App 窗口都在第 0 层。菜单、Dock、状态栏项、浮层面板
    ///   （含 Napoleon 自己的切换器浮层）都在更高层，这一条就全部排除掉了。
    /// - `kCGWindowAlpha > 0`：全透明窗口用户点不到也看不见，不该出现在切换器里。
    /// - 面积非零：跟 `WindowEnumerator.isZeroSize` 同一个理由，零尺寸的是辅助/装饰窗口。
    ///
    /// 实测校准（21 个常规 App、两块屏、两个桌面）：本函数留下 15 扇，同一时刻 AX 枚举留下 18 扇，
    /// 差的 3 扇正是三个**已隐藏** App 的窗口——隐藏 App 的窗口本就不在屏幕上，`CGWindowList`
    /// 看不见它们是正确行为，不是漏判。
    /// 数值一律经 `NSNumber` 读，不直接 `as? UInt32`/`as? Int32`：`CGWindowListCopyWindowInfo`
    /// 回来的是 `CFNumber`，它桥成 `NSNumber` 后可以取任意数值表示，而直接往具体定宽类型转会依赖
    /// 装箱时的原始类型——同一份键值换个来源（比如测试里直接写字面量）就会静默转不出来、整条被丢掉。
    static func realAppWindows(from raw: [[String: Any]]) -> [OnScreenWindow] {
        raw.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let alpha = entry[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowID = entry[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let width = (boundsDict["Width"] as? NSNumber)?.doubleValue, width > 0,
                  let height = (boundsDict["Height"] as? NSNumber)?.doubleValue, height > 0
            else {
                return nil
            }
            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            return OnScreenWindow(
                windowID: windowID.uint32Value,
                pid: pid.int32Value,
                title: entry[kCGWindowName as String] as? String ?? "",
                bounds: CGRect(x: x, y: y, width: width, height: height)
            )
        }
    }

    /// 算出「窗口服务器说在屏幕上、而热态里没有」的那些窗口，转成可以直接并进热态的 `WindowInfo`。
    ///
    /// - Parameters:
    ///   - knownIDs: 热态当前已知的全部 windowID（含跨 Space 的那些——它们虽然不在
    ///     `onScreen` 里，但列进 `knownIDs` 才能避免同一扇窗口被重复补一遍）。
    ///   - onScreen: `onScreenWindows()` 的结果。
    ///   - appInfo: 按 pid 查 App 身份，注入以便单测打桩。返回 `nil` 的 pid 整条跳过——生产环境
    ///     用它挡掉非常规 App（accessory/`LSUIElement`）和已经退出的进程，跟
    ///     `NSRunningApplication.isRegularOrSelf` 同一口径。
    ///   - pinyin: 标题 → 拼音，注入以便单测打桩（生产环境传 `PinyinTransformer.pinyin`）。
    /// - Returns: 待补进热态的窗口，保持 `onScreen` 的相对序。同一 windowID 重复出现时只取第一次。
    ///   `isOnCurrentSpace` 一律为 `true`：`.optionOnScreenOnly` 的语义就是「此刻可见」，跟这个
    ///   字段完全对应。`isMinimized` 一律为 `false`：最小化的窗口不在屏幕上，压根进不了 `onScreen`。
    static func missingWindows(
        knownIDs: Set<WindowID>,
        onScreen: [OnScreenWindow],
        appInfo: (ProcessID) -> AppIdentity?,
        pinyin: (String) -> String?
    ) -> [WindowInfo] {
        var seen = knownIDs
        var missing: [WindowInfo] = []

        for window in onScreen {
            guard !seen.contains(window.windowID) else { continue }
            guard let identity = appInfo(window.pid) else { continue }
            seen.insert(window.windowID)

            missing.append(WindowInfo(
                id: window.windowID,
                pid: window.pid,
                appName: identity.name,
                appBundleID: identity.bundleID,
                title: window.title,
                isMinimized: false,
                isHiddenApp: identity.isHidden,
                isOnCurrentSpace: true,
                pinyinAppName: pinyin(identity.name),
                pinyinTitle: pinyin(window.title),
                isFullscreen: false
            ))
        }

        return missing
    }
}
