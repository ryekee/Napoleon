import AppKit
import CoreServices
import os

/// 把 **Napoleon 自己**提到前台。
///
/// **为什么需要私有 API**：macOS 14 起的协作式激活禁止「一个不在前台的进程把自己提到前台」
/// （防 App 抢焦点）。Napoleon 的切换器恰恰总是在后台完成聚焦——浮层是非激活面板，拿不到
/// 用户交互授权——所以当切换目标是 Napoleon 自己的设置窗口时，公开 API 全部失效：
/// `NSApp.activate(ignoringOtherApps:)`、无参 `NSApplication.activate()`、macOS 14 的
/// `NSRunningApplication.current.activate(from:)` 都试过，窗口只被 `AXRaise` 抬到「次前台」，
/// 前台 App 纹丝不动。`spikes/frontprocess` 逐项实测记录了这个结论，也验证了这里用的私有
/// SkyLight 调用确实有效。
///
/// **只用于自己**：切换到**别的** App 不受这条限制（`.accessory` 后台代理被豁免），继续走公开
/// 的 `NSRunningApplication.activate()`。因此这里不需要 pid → `ProcessSerialNumber` 的转换
/// （`GetProcessForPID` 已经从 Swift 中移除），当前进程的 PSN 是一个常量：`kCurrentProcess`。
///
/// **降级**：符号缺失（系统版本变化）时 `bringToFront()` 返回 `false`，调用方退回公开 API——
/// 那条路在某些时机下仍然有效（比如刚刚有过用户交互），只是不可靠；绝不崩溃。
enum SelfFrontProcess {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "SelfFrontProcess")

    /// `SLPSSetFrontProcessWithOptions(psn, windowID, mode)`。
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32

    /// **符号名不带前导下划线**，这一点很关键。`dlsym` 的 key 是 C 函数名，链接器为 C 符号补的
    /// 那个前导下划线不算在内；生态里通行写法 `@_silgen_name("_SLPSSetFrontProcessWithOptions")`
    /// 里的下划线正是那个 mangling 前缀，对应的 C 名字就是这里写的这个。
    ///
    /// 曾经写成两个候选名依次探测（`_SLPS…` 在前、`SLPS…` 兜底），以为只是同一个函数在不同系统
    /// 版本上的两种拼法。实测（`dlsym` 逐个查地址）证明**两个名字都能命中，但指向 SkyLight 里
    /// 两个不同地址的函数**——带下划线的那个是另一个未公开的内部符号，签名未知。也就是说旧代码
    /// 一直在调错的那一个。只保留这一个名字，宁可降级也不要拿一个签名不明的函数当替补。
    private static let symbolName = "SLPSSetFrontProcessWithOptions"

    /// mode 位：`kCPSUserGenerated` 表示「这次前置源于用户操作」，正是切换器的语义
    /// （用户按了快捷键），也是让系统按真实前台切换处理它的关键。
    private static let userGenerated: UInt32 = 0x200

    /// dlsym 探测一次并缓存（探测不便宜，且结果在进程生命周期内不会变）。
    private static let setFrontProcess: SetFrontProcessFn? = {
        guard let pointer = symbolName.withCString({ dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) })
        else { return nil }
        return unsafeBitCast(pointer, to: SetFrontProcessFn.self)
    }()

    /// 把当前进程提到前台。返回的是**这次调用本身是否成功**（`status == 0`），不是「已经确实
    /// 成为前台」。
    ///
    /// 这里曾经在调用后立刻读 `NSRunningApplication.current.isActive` 当返回值，理由写的是
    /// 「spike 观察到 `isActive` 是即时准确的」——那个理由不成立：spike
    /// （`spikes/frontprocess/main.swift`）是在 `usleep(600_000)` **之后**才读的 `isActive`，
    /// 从没测过「调用后立刻读」。而前台切换要经 WindowServer 往返、本进程再从 run loop 上收到
    /// 激活消息才会翻转状态，而这个方法自始至终跑在一次 run loop 回调内部的同步块里，返回前
    /// 根本没有转机。结果就是它几乎必然返回 `false`：调用其实成功了，调用方却以为失败、白白
    /// 再叠一次公开激活，日志也永远报错——「符号缺失才降级」的设计意图从未真正成立过。
    @discardableResult
    static func bringToFront() -> Bool {
        guard let setFrontProcess else {
            logger.warning("\(symbolName, privacy: .public) unavailable — falling back to public activation")
            return false
        }

        // 用 Carbon 的 `ProcessSerialNumber` 而不是手写一个「两个 UInt32」的 Swift struct：
        // 原生 Swift 结构体的字段顺序在语言层面未指定（编译器保留重排权），一旦重排就是静默传
        // 错 PSN；C 导入类型的布局是有保证的。`(high: 0, low: 2)` 即 `kCurrentProcess`。
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        // C 侧参数是 `ProcessSerialNumber *`（非 const），所以用 mutable 指针——用只读指针等于
        // 向 Swift 保证 callee 不会写，与 C 声明不符。
        let status = withUnsafeMutablePointer(to: &psn) { pointer in
            setFrontProcess(UnsafeMutableRawPointer(pointer), 0, userGenerated)
        }
        guard status == 0 else {
            logger.error("\(symbolName, privacy: .public) failed: \(status, privacy: .public)")
            return false
        }
        return true
    }
}
