public struct MRUTracker: Equatable, Sendable {
    public private(set) var order: [WindowID]

    public init(order: [WindowID] = []) {
        self.order = order
    }

    public mutating func recordFocus(_ id: WindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// 注册一个尚未产生焦点事件的语义窗口。它可以被展示，但不能冒充最近使用。
    public mutating func register(_ id: WindowID) {
        guard !order.contains(id) else { return }
        order.append(id)
    }

    public mutating func remove(_ id: WindowID) {
        order.removeAll { $0 == id }
    }

    public func ordered(_ windows: [WindowInfo]) -> [WindowInfo] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return windows.sorted { a, b in
            (rank[a.id] ?? .max) < (rank[b.id] ?? .max)
        }
    }
}
