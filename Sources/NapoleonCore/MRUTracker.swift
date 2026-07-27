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

    /// 把一扇**此前无从知晓**的窗口排到 MRU 末尾。
    ///
    /// 跟 `insert` 的区别就是位置，而这个区别是关键的：`insert` 用于「刚刚被创建的窗口」，
    /// 新窗口天然就是最近使用的，排在第 0 位正确。而 `.reconciled`（对账补回，见
    /// `WindowStoreReducer`）补的是「本来就一直开着、只是热态把它跟丢了」的窗口——它们的
    /// 真实使用时间早已不可考，用 `insert` 会让它们冒充成最近使用，直接顶掉 `order[0]`/
    /// `order[1]`，而 `order[1]` 正是快速切换（点按热键立刻切到上一扇窗口）的目标：一次
    /// 对账补回十几扇窗口，用户的「上一个窗口」就会变成一扇他根本没在用的窗口。
    ///
    /// 排到末尾是保守且诚实的选择：不谎称任何使用时间，也绝不扰动已知的 MRU 顺序。已经
    /// 在 `order` 里的 id 直接跳过（幂等），不会把它从原位挪到末尾。
    public mutating func appendUnknown(_ id: WindowID) {
        guard !order.contains(id) else { return }
        order.append(id)
    }

    public func ordered(_ windows: [WindowInfo]) -> [WindowInfo] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return windows.sorted { a, b in
            (rank[a.id] ?? .max) < (rank[b.id] ?? .max)
        }
    }
}
