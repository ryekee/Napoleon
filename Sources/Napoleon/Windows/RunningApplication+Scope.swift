import AppKit
import NapoleonCore

extension NSRunningApplication {
    /// 本进程的 pid。取一次存下来——`ProcessInfo` 每次都要过一趟系统调用，而这个值终生不变，
    /// 却在下面这个判据里被高频调用（每次枚举、每条 App 生命周期通知）。
    static let ownProcessID: ProcessID = ProcessInfo.processInfo.processIdentifier

    /// **「这个 App 该不该进切换器的视野」的唯一判据**——常规 App，或者 Napoleon 自己。
    ///
    /// 平时只有 `.regular` 的 App 有资格：后台代理（`.accessory`）、UI 元素、守护进程都没有
    /// 用户意义上的窗口。唯一的例外是 Napoleon 自己：它平时是 `.accessory`（菜单栏 agent），
    /// 但设置窗口开着的时候那就是一扇普通窗口，理应和别的窗口一样出现在切换器里、能被切回来。
    ///
    /// **不能改用「把进程提升为 `.regular`」来满足这个条件**：`.regular` 会让 Napoleon 变成
    /// 普通 App，而普通 App 在自己不处于前台时无权激活别的 App（macOS 14 协作式激活的防抢焦点
    /// 规则），切换器的核心功能会整个失效——这正是修过一次的那个严重回归。所以身份留在
    /// `.accessory`，靠这条判据显式开一个口子。
    ///
    /// **为什么必须是共用的一条**：这个判据用于三条入口——窗口枚举
    /// （`WindowEnumerator.snapshotRunningApplications`）、AX 观察者注册与 App 启动
    /// （`AXObserverController`）、前台切换记 MRU（`WindowStore.handleAppActivated`）。这些入口
    /// 口径不一致会导致设置窗口进得了列表，却收不到自己的窗口生命周期通知（最小化/改标题都不会
    /// 更新），从切换器切回它时也记不进 MRU，所以收敛到这里。
    var isRegularOrSelf: Bool {
        activationPolicy == .regular || processIdentifier == Self.ownProcessID
    }
}
