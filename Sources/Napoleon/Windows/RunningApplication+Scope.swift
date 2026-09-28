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

/// LaunchServices can return a live application whose processIdentifier is -1.
/// WindowServer supplies candidate PIDs only; AX still decides which windows become targets.
enum WindowApplicationIdentity {
    static func resolve(reportedPID: ProcessID, matchingOwnerPIDs: [ProcessID]) -> ProcessID? {
        if reportedPID > 0 { return reportedPID }
        let candidates = Set(matchingOwnerPIDs.filter { $0 > 0 })
        return candidates.count == 1 ? candidates.first : nil
    }

    static func ownerPIDs() -> Set<ProcessID> {
        let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0)
            as? [[String: Any]] ?? []
        return Set(raw.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
            .filter { $0 > 0 })
    }

    static func applications() -> [(pid: ProcessID, app: NSRunningApplication)] {
        var result: [ProcessID: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications
            where app.canOwnApplicationWindows && app.processIdentifier > 0 {
            result[app.processIdentifier] = app
        }
        // Use the queried PID, never round-trip it through the broken application property.
        for pid in ownerPIDs() where result[pid] == nil {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.canOwnApplicationWindows, !app.isTerminated else { continue }
            result[pid] = app
        }
        return result.map { (pid: $0.key, app: $0.value) }
    }

    static func isConfirmedTerminated(_ pid: ProcessID) -> Bool {
        guard pid > 0 else { return true }
        // Missing LaunchServices entries and EPERM are not proof of process death.
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}

extension NSRunningApplication {
    var windowOwnerPID: ProcessID? {
        if processIdentifier > 0 { return processIdentifier }
        let matches = WindowApplicationIdentity.ownerPIDs().filter { pid in
            guard let candidate = NSRunningApplication(processIdentifier: pid) else { return false }
            // Compare application identity, not name/bundle ID (multiple instances may share those).
            return candidate == self
        }
        return WindowApplicationIdentity.resolve(reportedPID: processIdentifier, matchingOwnerPIDs: Array(matches))
    }
}
