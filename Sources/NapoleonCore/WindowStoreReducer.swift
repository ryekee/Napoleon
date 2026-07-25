public struct WindowState: Equatable, Sendable {
    public var windows: [WindowInfo]
    public var mru: MRUTracker

    public init(windows: [WindowInfo] = [], mru: MRUTracker = .init()) {
        self.windows = windows
        self.mru = mru
    }
}

public enum WindowEvent: Sendable {
    case fullRefresh([WindowInfo])
    case created(WindowInfo)
    case destroyed(WindowID)
    case focused(WindowID)
    case minimizedChanged(WindowID, Bool)
    case titleChanged(WindowID, String, pinyin: String?)
    case appTerminated(ProcessID)
    /// 某个 App 被隐藏/取消隐藏（⌘H）。`isHiddenApp` 原本只在枚举那一刻写入，而隐藏 App
    /// 不触发任何刷新，标记会一直停在旧值——「包含已隐藏应用的窗口」关掉后隐藏的窗口依然
    /// 显示在浮层里，正是这个原因。
    case appHiddenChanged(ProcessID, Bool)
    case spaceChanged(onCurrentSpaceIDs: Set<WindowID>)
}

public enum WindowStoreReducer {
    public static func reduce(_ state: WindowState, _ event: WindowEvent) -> WindowState {
        var state = state
        switch event {
        case .created(let window):
            if let index = state.windows.firstIndex(where: { $0.id == window.id }) {
                state.windows[index] = window
            } else {
                state.windows.append(window)
                state.mru.insert(window.id)
            }

        case .destroyed(let id):
            state.windows.removeAll { $0.id == id }
            state.mru.remove(id)

        case .focused(let id):
            if state.windows.contains(where: { $0.id == id }) {
                state.mru.recordFocus(id)
            }

        case .minimizedChanged(let id, let isMinimized):
            if let index = state.windows.firstIndex(where: { $0.id == id }) {
                state.windows[index].isMinimized = isMinimized
            }

        case .titleChanged(let id, let title, let pinyin):
            if let index = state.windows.firstIndex(where: { $0.id == id }) {
                state.windows[index].title = title
                state.windows[index].pinyinTitle = pinyin
            }

        case .appTerminated(let pid):
            let terminatedIDs = state.windows.filter { $0.pid == pid }.map(\.id)
            state.windows.removeAll { $0.pid == pid }
            for id in terminatedIDs {
                state.mru.remove(id)
            }

        case .appHiddenChanged(let pid, let isHidden):
            // 原地更新该 App 名下所有窗口的标记；窗口集合本身不变（隐藏不等于关闭）。
            for index in state.windows.indices where state.windows[index].pid == pid {
                state.windows[index].isHiddenApp = isHidden
            }

        case .spaceChanged(let onCurrentSpaceIDs):
            for index in state.windows.indices {
                state.windows[index].isOnCurrentSpace = onCurrentSpaceIDs.contains(state.windows[index].id)
            }

        case .fullRefresh(let newWindows):
            let survivingIDs = Set(newWindows.map(\.id))
            state.windows = newWindows
            state.mru = MRUTracker(order: state.mru.order.filter { survivingIDs.contains($0) })
        }
        return state
    }
}
