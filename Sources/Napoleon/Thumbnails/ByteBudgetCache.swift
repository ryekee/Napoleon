/// 字节预算 LRU 缓存：按「值的近似字节数」做预算，超预算时从最久未用的一端开始淘汰，
/// 不是按「条数」限制——缩略图这种大小差异很大的值（不同窗口尺寸/DPI 下 `bytesPerRow *
/// height` 可以差好几倍），按字节预算比按条数预算更贴近真实内存占用。`ThumbnailService`
/// 用它限制所有窗口缩略图的总内存（`cost = { image in image.bytesPerRow * image.height }`）。
///
/// **实现**：跟 `NapoleonCore.MRUTracker` 同一套思路——`order` 数组记录 key 的使用顺序
/// （下标 0 = 最近使用 MRU，末尾 = 最久未用 LRU），配合 `storage`/`costs` 两个字典做 O(1)
/// 查值/查 cost。`order.removeAll(where:)` 是 O(n)，但切换器场景下同时存在的窗口数量是
/// 个位数到低两位数，换成双向链表拿到的「O(1) 移动」收益在这个规模下可以忽略，数组实现
/// 更简单、更不容易出 bug。
///
/// **单个超预算 value 的语义**：`set` 的淘汰循环遇到「只剩最后一项」时会停手，即便那一项
/// 自己的 cost 已经超过 `maxBytes`——不然会陷入「插入唯一一个大 value 就把它自己也淘汰掉，
/// 缓存永远是空的」的怪状态。调用方应确保单个值的 cost 远小于 `maxBytes`（典型窗口缩略图
/// 远小于默认的 32MB 预算），这条只是兜底，不是鼓励塞超预算的值。
///
/// **线程**：不是 `Sendable`，也不加锁——调用方需自行保证单线程访问。`ThumbnailService`
/// 用 `@MainActor` 做到这一点。
final class ByteBudgetCache<Key: Hashable, Value> {
    private(set) var maxBytes: Int
    private let cost: (Value) -> Int

    private var storage: [Key: Value] = [:]
    private var costs: [Key: Int] = [:]
    /// 使用顺序：`order[0]` 是最近使用（MRU），最后一个是最久未用（LRU，淘汰从这里开始）。
    private var order: [Key] = []

    private(set) var currentBytes: Int = 0

    init(maxBytes: Int, cost: @escaping (Value) -> Int) {
        self.maxBytes = maxBytes
        self.cost = cost
    }

    var count: Int { storage.count }

    /// 命中则把 key 移到 MRU 头部（刷新 recency）；未命中返回 nil，不改变任何状态。
    func get(_ key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    /// 插入/覆盖一个值并移到 MRU 头部；若这次插入让 `currentBytes` 超过 `maxBytes`，从
    /// LRU 尾部开始淘汰，直到不超预算或只剩这一项为止（见类型头注释「单个超预算 value 的语义」）。
    func set(_ key: Key, _ value: Value) {
        if let oldCost = costs[key] {
            currentBytes -= oldCost
            order.removeAll { $0 == key }
        }

        let newCost = cost(value)
        storage[key] = value
        costs[key] = newCost
        currentBytes += newCost
        order.insert(key, at: 0)

        evictIfNeeded()
    }

    /// Task 21：运行时改预算（设置界面的「缩略图缓存上限」）。调小后立刻按 LRU 淘汰到新预算之内，
    /// 不必等下一次 `set` 才收敛——否则用户把上限从 128MB 调到 16MB 后，内存要等到下次抓图才降下来，
    /// 与「改了就生效」的直觉不符。调大只是抬高上限，不动现有内容。
    func setMaxBytes(_ newValue: Int) {
        guard newValue != maxBytes else { return }
        maxBytes = newValue
        evictIfNeeded()
    }

    func removeAll() {
        storage.removeAll()
        costs.removeAll()
        order.removeAll()
        currentBytes = 0
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
    }

    private func evictIfNeeded() {
        while currentBytes > maxBytes, order.count > 1, let lruKey = order.last {
            order.removeLast()
            storage.removeValue(forKey: lruKey)
            if let evictedCost = costs.removeValue(forKey: lruKey) {
                currentBytes -= evictedCost
            }
        }
    }
}
