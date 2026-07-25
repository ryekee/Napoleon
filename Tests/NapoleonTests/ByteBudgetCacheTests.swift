import Testing
@testable import Napoleon

// `ByteBudgetCache` 是纯逻辑（跟 `CGImage`/ScreenCaptureKit 无关），全部行为可单测——
// 用 `ByteBudgetCache<String, Int>` + `cost = { $0 }`（值本身即字节数）即可覆盖所有分支，
// 不需要构造真的缩略图。`ThumbnailService` 的 SCK 抓图部分需运行时权限，不在这里测。
@Suite struct ByteBudgetCacheTests {
    private func makeCache(maxBytes: Int) -> ByteBudgetCache<String, Int> {
        ByteBudgetCache(maxBytes: maxBytes, cost: { $0 })
    }

    @Test func underBudgetKeepsAllEntries() {
        let cache = makeCache(maxBytes: 100)
        cache.set("a", 10)
        cache.set("b", 20)
        cache.set("c", 30)

        #expect(cache.count == 3)
        #expect(cache.currentBytes == 60)
        #expect(cache.get("a") == 10)
        #expect(cache.get("b") == 20)
        #expect(cache.get("c") == 30)
    }

    @Test func overBudgetEvictsLeastRecentlyUsed() {
        let cache = makeCache(maxBytes: 50)
        cache.set("a", 10) // 最早插入 → 没被 touch 过就是 LRU 尾
        cache.set("b", 20)
        cache.set("c", 30) // 总量 60 > 50 → 应淘汰最早的 "a"

        #expect(cache.get("a") == nil)
        #expect(cache.get("b") == 20)
        #expect(cache.get("c") == 30)
        #expect(cache.currentBytes == 50)
        #expect(cache.currentBytes <= 50)
        #expect(cache.count == 2)
    }

    @Test func getRefreshesRecencySoOnlyTheUntouchedEntryIsEvicted() {
        let cache = makeCache(maxBytes: 50)
        cache.set("a", 10)
        cache.set("b", 20)
        _ = cache.get("a") // 刷新 a 的 recency，现在 b 才是真正的 LRU
        cache.set("c", 30) // 总量 60 > 50 → 应淘汰 b，不是 a

        #expect(cache.get("a") == 10)
        #expect(cache.get("b") == nil)
        #expect(cache.get("c") == 30)
        #expect(cache.currentBytes == 40)
    }

    @Test func getMissReturnsNil() {
        let cache = makeCache(maxBytes: 100)
        #expect(cache.get("missing") == nil)

        cache.set("a", 10)
        #expect(cache.get("nonexistent") == nil)
    }

    @Test func singleOverBudgetValueIsStoredAloneWithoutInfiniteEviction() {
        let cache = makeCache(maxBytes: 10)
        cache.set("a", 5)
        cache.set("big", 100) // 单个 value 本身就超预算，仍应存入并成为唯一项

        #expect(cache.get("a") == nil)
        #expect(cache.get("big") == 100)
        #expect(cache.count == 1)
        #expect(cache.currentBytes == 100)
    }

    @Test func removeAllClearsCacheAndByteCount() {
        let cache = makeCache(maxBytes: 100)
        cache.set("a", 10)
        cache.set("b", 20)
        cache.removeAll()

        #expect(cache.count == 0)
        #expect(cache.currentBytes == 0)
        #expect(cache.get("a") == nil)
    }
}
