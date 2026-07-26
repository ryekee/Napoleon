import AppKit
import os

/// 把 **Napoleon 自己**提到前台。
///
/// **为什么需要私有 API**：macOS 14 起的协作式激活禁止「一个不在前台的进程把自己提到前台」
/// （防 App 抢焦点）。Napoleon 的切换器恰恰总是在后台完成聚焦——浮层是非激活面板，拿不到
/// 用户交互授权——所以当切换目标是 Napoleon 自己的设置窗口时，公开 API 全部失效：
/// `NSApp.activate(ignoringOtherApps:)`、无参 `NSApplication.activate()`、macOS 14 的
/// `NSRunningApplication.current.activate(from:)` 都试过，窗口只被 `AXRaise` 抬到「次前台」，
/// 前台 App 纹丝不动。`spikes/frontprocess` 逐项实测记录了这个结论，也验证了这里用的私有
/// SkyLight 调用确实有效（`status=0` 且随后 `NSRunningApplication.current.isActive == true`）。
///
/// **只用于自己**：切换到**别的** App 不受这条限制（`.accessory` 后台代理被豁免），继续走公开
/// 的 `NSRunningApplication.activate()`。因此这里不需要 pid → `ProcessSerialNumber` 的转换
/// （`GetProcessForPID` 已经从 Swift 中移除），当前进程的 PSN 是一个常量：`kCurrentProcess`。
///
/// **降级**：符号缺失（系统版本变化）时 `bringToFront()` 返回 `false`，调用方退回公开 API——
/// 那条路在某些时机下仍然有效（比如刚刚有过用户交互），只是不可靠；绝不崩溃。
enum SelfFrontProcess {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "SelfFrontProcess")

    /// `_SLPSSetFrontProcessWithOptions(psn, windowID, mode)`。
    private typealias SetFrontProcessFn = @convention(c) (UnsafeRawPointer, UInt32, UInt32) -> Int32

    /// Carbon `ProcessSerialNumber` 的内存布局就是两个 `UInt32`。
    /// `(high: 0, low: 2)` 即 `kCurrentProcess`——指代当前进程的常量 PSN。
    private struct ProcessSerialNumber {
        var high: UInt32 = 0
        var low: UInt32 = 2
    }

    /// mode 位：`kCPSUserGenerated` 表示「这次前置源于用户操作」，正是切换器的语义
    /// （用户按了快捷键），也是让系统按真实前台切换处理它的关键。
    private static let userGenerated: UInt32 = 0x200

    /// dlsym 探测一次并缓存（探测不便宜，且结果在进程生命周期内不会变）。带下划线和不带的
    /// 两个符号名都试——不同系统版本上导出的名字不一致。
    private static let setFrontProcess: SetFrontProcessFn? = {
        for name in ["_SLPSSetFrontProcessWithOptions", "SLPSSetFrontProcessWithOptions"] {
            if let pointer = name.withCString({ dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) }) {
                return unsafeBitCast(pointer, to: SetFrontProcessFn.self)
            }
        }
        return nil
    }()

    /// 把当前进程提到前台。返回是否**确实**成为了前台——不只看调用的返回码，还要看
    /// `NSRunningApplication.current.isActive`，因为 spike 里观察到调用成功（`status == 0`）
    /// 时 `NSWorkspace.frontmostApplication` 还会短暂滞后，而 `isActive` 是即时准确的。
    @discardableResult
    static func bringToFront() -> Bool {
        guard let setFrontProcess else {
            logger.warning("_SLPSSetFrontProcessWithOptions unavailable — falling back to public activation")
            return false
        }

        var psn = ProcessSerialNumber()
        let status = withUnsafePointer(to: &psn) { pointer in
            setFrontProcess(UnsafeRawPointer(pointer), 0, userGenerated)
        }
        guard status == 0 else {
            logger.error("_SLPSSetFrontProcessWithOptions failed: \(status, privacy: .public)")
            return false
        }
        return NSRunningApplication.current.isActive
    }
}
