import AppKit
import NapoleonCore

extension NSRunningApplication {
    /// 本进程的 pid。取一次存下来——`ProcessInfo` 每次都要过一趟系统调用，而这个值终生不变，
    /// 却在下面这个判据里被高频调用（每次枚举、每条 App 生命周期通知）。
    static let ownProcessID: ProcessID = ProcessInfo.processInfo.processIdentifier

    /// **「这个进程是否可能拥有 Application Windows」的唯一 App 级判据**。
    ///
    /// `.accessory` 进程也可能临时打开系统 Application Windows（菜单栏 App 很常见），所以不能
    /// 用 activation policy 代替窗口语义。这里只排除明确禁止 UI 的 `.prohibited` 后台进程；
    /// 最终是否收录仍由 AX subrole + Window Server layer 的窗口级证据决定。
    ///
    /// **为什么必须是共用的一条**：这个判据用于三条入口——窗口枚举
    /// （`WindowEnumerator.snapshotRunningApplications`）、AX 观察者注册与 App 启动
    /// （`AXObserverController`）、前台切换记 MRU（`WindowStore.handleAppActivated`）。这些入口
    /// 口径不一致会导致窗口进得了列表，却收不到生命周期通知，所以收敛到这里。
    var canOwnApplicationWindows: Bool {
        activationPolicy != .prohibited
    }
}
