import Testing
@testable import NapoleonCore

@Suite struct MRUTrackerTests {
    @Test func recordFocusMovesToFront() {
        var m = MRUTracker(order: [1, 2, 3])
        m.recordFocus(3)
        #expect(m.order == [3, 1, 2])
    }

    @Test func orderedSortsByMRU() {
        let m = MRUTracker(order: [2, 1])
        #expect(m.ordered([w(1), w(2), w(3)]).map(\.id) == [2, 1, 3])
    }

    @Test func orderedKeepsMultipleUnknownsInInputOrder() {
        let m = MRUTracker(order: [2])
        #expect(m.ordered([w(3), w(4), w(2), w(5)]).map(\.id) == [2, 3, 4, 5])
    }

    @Test func insertOnAlreadyPresentIDDedupesAndMovesToFront() {
        var m = MRUTracker(order: [1, 2, 3])
        m.insert(2)
        #expect(m.order == [2, 1, 3])
    }

    @Test func orderedToleratesDuplicateIDsInOrderWithoutCrashing() {
        let m = MRUTracker(order: [1, 1, 2])
        #expect(m.ordered([w(1), w(2)]).map(\.id) == [1, 2])
    }
}

// MARK: - 对账补回的窗口（见 `MRUTracker.appendUnknown`）

@Suite struct MRUTrackerAppendUnknownTests {
    @Test func appendUnknownGoesToTheTailSoQuickSwitchKeepsWorking() {
        var mru = MRUTracker(order: [7, 3])
        mru.appendUnknown(99)
        // 关键：7 仍是当前窗口、3 仍是「上一个窗口」——补回来的窗口不许插队
        #expect(mru.order == [7, 3, 99])
    }

    @Test func appendUnknownIsANoOpForAWindowAlreadyRanked() {
        var mru = MRUTracker(order: [7, 3])
        mru.appendUnknown(3)
        #expect(mru.order == [7, 3])
    }
}
