public struct MRUTracker: Equatable, Sendable {
    public private(set) var order: [WindowID]

    public init(order: [WindowID] = []) {
        self.order = order
    }

    public mutating func recordFocus(_ id: WindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    public mutating func insert(_ id: WindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
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
