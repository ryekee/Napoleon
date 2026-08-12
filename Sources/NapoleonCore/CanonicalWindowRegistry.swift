public struct WindowState: Equatable, Sendable {
    public var windows: [WindowInfo]
    public var mru: MRUTracker

    public init(windows: [WindowInfo] = [], mru: MRUTracker = .init()) {
        self.windows = windows
        self.mru = mru
    }
}

/// 用户可切换窗口的唯一语义状态。
///
/// 只有 AX 语义证据可以创建目标；Window Server / ScreenCaptureKit 只能更新已知目标。
/// 完整 AX 审计也不会直接删除：第一次确定缺失先隔离，下一次独立完整审计仍缺失才移除。
public struct CanonicalWindowRegistry: Equatable, Sendable {
    private enum Lifecycle: Equatable, Sendable {
        case active
        case quarantined
    }

    private struct Target: Equatable, Sendable {
        var info: WindowInfo
        var lifecycle: Lifecycle
        var confirmedAbsences: Int
    }

    private var targets: [WindowID: Target]
    private var insertionOrder: [WindowID]
    private var mru: MRUTracker

    public init(initialState: WindowState = .init()) {
        targets = Dictionary(
            initialState.windows.map {
                ($0.id, Target(info: $0, lifecycle: .active, confirmedAbsences: 0))
            },
            uniquingKeysWith: { first, _ in first }
        )
        insertionOrder = []
        for window in initialState.windows where !insertionOrder.contains(window.id) {
            insertionOrder.append(window.id)
        }
        let validIDs = Set(initialState.windows.map(\.id))
        mru = MRUTracker(order: initialState.mru.order.filter { validIDs.contains($0) })
        for id in insertionOrder {
            mru.register(id)
        }
    }

    /// 隔离目标不参与展示，但仍保留 MRU 排名，避免瞬态漏枚举破坏历史。
    public var state: WindowState {
        WindowState(
            windows: insertionOrder.compactMap { id in
                guard let target = targets[id], target.lifecycle == .active else { return nil }
                return target.info
            },
            mru: mru
        )
    }

    public var allWindows: [WindowInfo] {
        insertionOrder.compactMap { targets[$0]?.info }
    }

    public var allWindowIDs: Set<WindowID> {
        Set(targets.keys)
    }

    public func window(_ id: WindowID) -> WindowInfo? {
        targets[id]?.info
    }

    public func contains(_ id: WindowID, pid: ProcessID) -> Bool {
        targets[id]?.info.pid == pid
    }

    public func isQuarantined(_ id: WindowID) -> Bool {
        targets[id]?.lifecycle == .quarantined
    }

    public mutating func observeSemanticWindow(_ window: WindowInfo) {
        if let existing = targets[window.id], existing.info.pid != window.pid {
            remove(window.id)
        }

        if targets[window.id] == nil {
            insertionOrder.append(window.id)
            mru.register(window.id)
        }
        targets[window.id] = Target(info: window, lifecycle: .active, confirmedAbsences: 0)
    }

    /// 弱来源只能丰富已由 AX 建立的身份；同一 WindowID 被其它进程复用时也不会命中。
    public mutating func observeSurface(
        windowID: WindowID,
        pid: ProcessID,
        isOnCurrentSpace: Bool? = nil,
        isFullscreen: Bool? = nil
    ) {
        guard var target = targets[windowID], target.info.pid == pid else { return }
        if let isOnCurrentSpace {
            target.info.isOnCurrentSpace = isOnCurrentSpace
            if isOnCurrentSpace {
                target.info.isMinimized = false
                target.info.isHiddenApp = false
            }
        }
        if let isFullscreen { target.info.isFullscreen = isFullscreen }
        target.lifecycle = .active
        target.confirmedAbsences = 0
        targets[windowID] = target
    }

    /// `existingWindows == nil` 表示弱来源失败；失败永远不能产生负面结论。
    public mutating func applySemanticAudit(
        pid: ProcessID,
        windows: [WindowInfo],
        isComplete: Bool,
        existingWindows: [WindowID: ProcessID]?
    ) {
        let semanticWindows = windows.filter { $0.pid == pid }
        let observedIDs = Set(semanticWindows.map(\.id))
        for window in semanticWindows {
            observeSemanticWindow(window)
        }

        guard isComplete, let existingWindows else { return }
        let missingIDs = insertionOrder.filter {
            targets[$0]?.info.pid == pid && !observedIDs.contains($0)
        }

        for id in missingIDs {
            guard var target = targets[id] else { continue }
            if existingWindows[id] == pid {
                target.info.isOnCurrentSpace = false
                target.lifecycle = .active
                target.confirmedAbsences = 0
                targets[id] = target
            } else {
                target.confirmedAbsences += 1
                if target.confirmedAbsences == 1 {
                    target.lifecycle = .quarantined
                    targets[id] = target
                } else {
                    remove(id)
                }
            }
        }
    }

    public mutating func recordFocus(_ id: WindowID) {
        guard var target = targets[id] else { return }
        target.info.isMinimized = false
        target.info.isHiddenApp = false
        target.info.isOnCurrentSpace = true
        target.lifecycle = .active
        target.confirmedAbsences = 0
        targets[id] = target
        mru.recordFocus(id)
    }

    public mutating func updateMinimized(_ id: WindowID, isMinimized: Bool) {
        guard var target = targets[id] else { return }
        target.info.isMinimized = isMinimized
        targets[id] = target
    }

    public mutating func updateTitle(_ id: WindowID, title: String, pinyin: String?) {
        guard var target = targets[id] else { return }
        target.info.title = title
        target.info.pinyinTitle = pinyin
        targets[id] = target
    }

    public mutating func updateAppHidden(pid: ProcessID, isHidden: Bool) {
        for id in insertionOrder where targets[id]?.info.pid == pid {
            guard var target = targets[id] else { continue }
            target.info.isHiddenApp = isHidden
            targets[id] = target
        }
    }

    public mutating func remove(_ id: WindowID) {
        targets.removeValue(forKey: id)
        insertionOrder.removeAll { $0 == id }
        mru.remove(id)
    }

    public mutating func terminateApp(pid: ProcessID) {
        let ids = insertionOrder.filter { targets[$0]?.info.pid == pid }
        for id in ids {
            remove(id)
        }
    }
}
