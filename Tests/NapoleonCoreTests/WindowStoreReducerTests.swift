import Testing
@testable import NapoleonCore

@Suite struct WindowStoreReducerTests {
    @Test func createdAppendsNewWindowAndInsertsIntoMRUFront() {
        let state = WindowState(windows: [w(1)], mru: MRUTracker(order: [1]))
        let result = WindowStoreReducer.reduce(state, .created(w(2)))
        #expect(result.windows.map(\.id) == [1, 2])
        #expect(result.mru.order == [2, 1])
    }

    @Test func createdReplacesFieldsInPlaceWhenIDAlreadyPresent() {
        let state = WindowState(windows: [w(1), w(2, minimized: false)], mru: MRUTracker(order: [2, 1]))
        let updated = w(2, minimized: true)
        let result = WindowStoreReducer.reduce(state, .created(updated))
        #expect(result.windows.map(\.id) == [1, 2])
        #expect(result.windows.first { $0.id == 2 }?.isMinimized == true)
        // must not duplicate and must not re-insert into mru
        #expect(result.mru.order == [2, 1])
    }

    @Test func destroyedRemovesFromWindowsAndMRU() {
        let state = WindowState(windows: [w(1), w(2)], mru: MRUTracker(order: [2, 1]))
        let result = WindowStoreReducer.reduce(state, .destroyed(1))
        #expect(result.windows.map(\.id) == [2])
        #expect(result.mru.order == [2])
    }

    @Test func focusedRecordsMRUButLeavesWindowsUnchanged() {
        let state = WindowState(windows: [w(1), w(2)], mru: MRUTracker(order: [1, 2]))
        let result = WindowStoreReducer.reduce(state, .focused(2))
        #expect(result.windows.map(\.id) == [1, 2])
        #expect(result.mru.order == [2, 1])
    }

    @Test func focusedOnUnknownIDLeavesMRUUnchanged() {
        let state = WindowState(windows: [w(1), w(2)], mru: MRUTracker(order: [1, 2]))
        let result = WindowStoreReducer.reduce(state, .focused(99))
        #expect(result.mru.order == [1, 2])
    }

    @Test func minimizedChangedUpdatesFieldInPlace() {
        let state = WindowState(windows: [w(1, minimized: false)], mru: MRUTracker(order: [1]))
        let result = WindowStoreReducer.reduce(state, .minimizedChanged(1, true))
        #expect(result.windows.first?.isMinimized == true)
        #expect(result.mru.order == [1])
    }

    @Test func titleChangedUpdatesTitleAndPinyinInPlace() {
        let state = WindowState(windows: [w(1)], mru: MRUTracker(order: [1]))
        let result = WindowStoreReducer.reduce(state, .titleChanged(1, "New Title", pinyin: "xin biaoti"))
        #expect(result.windows.first?.title == "New Title")
        #expect(result.windows.first?.pinyinTitle == "xin biaoti")
    }

    @Test func appTerminatedRemovesAllWindowsForPIDFromWindowsAndMRU() {
        let state = WindowState(
            windows: [w(1, pid: 100), w(2, pid: 200), w(3, pid: 100)],
            mru: MRUTracker(order: [3, 1, 2])
        )
        let result = WindowStoreReducer.reduce(state, .appTerminated(100))
        #expect(result.windows.map(\.id) == [2])
        #expect(result.mru.order == [2])
    }

    @Test func appHiddenChangedUpdatesEveryWindowOfThatPidOnly() {
        // ⌘H 隐藏 App：该 pid 名下所有窗口都要打上标记，别的 App 不受影响，窗口集合不变
        // （隐藏 ≠ 关闭）——否则「包含已隐藏应用的窗口」关掉后仍会显示隐藏窗口。
        let state = WindowState(windows: [w(1, pid: 10), w(2, pid: 10), w(3, pid: 20)])

        let hidden = WindowStoreReducer.reduce(state, .appHiddenChanged(10, true))
        #expect(hidden.windows.map(\.isHiddenApp) == [true, true, false])
        #expect(hidden.windows.count == 3)

        let unhidden = WindowStoreReducer.reduce(hidden, .appHiddenChanged(10, false))
        #expect(unhidden.windows.map(\.isHiddenApp) == [false, false, false])
    }

    @Test func appHiddenChangedForUnknownPidIsANoOp() {
        let state = WindowState(windows: [w(1, pid: 10)])
        #expect(WindowStoreReducer.reduce(state, .appHiddenChanged(99, true)) == state)
    }

    @Test func spaceChangedSetsOnCurrentSpaceFlagPerWindow() {
        let state = WindowState(
            windows: [w(1, onCurrentSpace: true), w(2, onCurrentSpace: false), w(3, onCurrentSpace: true)],
            mru: MRUTracker(order: [1, 2, 3])
        )
        let result = WindowStoreReducer.reduce(state, .spaceChanged(onCurrentSpaceIDs: [2]))
        #expect(result.windows.first { $0.id == 1 }?.isOnCurrentSpace == false)
        #expect(result.windows.first { $0.id == 2 }?.isOnCurrentSpace == true)
        #expect(result.windows.first { $0.id == 3 }?.isOnCurrentSpace == false)
    }

    @Test func fullRefreshReplacesWindowsAndKeepsOnlySurvivingIDsInMRUOrder() {
        let state = WindowState(
            windows: [w(1), w(2), w(3)],
            mru: MRUTracker(order: [3, 1, 2])
        )
        let result = WindowStoreReducer.reduce(state, .fullRefresh([w(1), w(4)]))
        #expect(result.windows.map(\.id) == [1, 4])
        // 3 and 2 no longer exist -> dropped; 1 survives; 4 is new -> not added to mru
        #expect(result.mru.order == [1])
    }
}

// MARK: - `.reconciled`（对账补回窗口）

@Suite struct WindowStoreReducerReconcileTests {
    @Test func reconciledAppendsMissingWindowsWithoutDisturbingMRUHead() {
        let state = WindowState(windows: [w(1)], mru: MRUTracker(order: [1]))
        let result = WindowStoreReducer.reduce(state, .reconciled([w(2), w(3)]))
        #expect(result.windows.map(\.id) == [1, 2, 3])
        // 1 必须仍在 MRU 头部——否则快速切换会切到一扇刚补回来的窗口上
        #expect(result.mru.order == [1, 2, 3])
    }

    @Test func reconciledCorrectsAnAlreadyKnownWindowWithoutMovingItsMRUPosition() {
        let known = w(1, minimized: true, hidden: true, onCurrentSpace: false, pinyin: "yuan biaoti")
        let state = WindowState(windows: [known], mru: MRUTracker(order: [1]))
        let observed = w(1, minimized: false, hidden: false, onCurrentSpace: true, pinyin: "yuan biaoti")

        let result = WindowStoreReducer.reduce(state, .reconciled([observed]))

        #expect(result.windows == [observed])
        #expect(result.mru.order == [1])
    }

    @Test func reconciledWithNothingMissingIsANoOp() {
        let state = WindowState(windows: [w(1), w(2)], mru: MRUTracker(order: [2, 1]))
        let result = WindowStoreReducer.reduce(state, .reconciled([]))
        #expect(result == state)
    }
}
