import AppKit
import CoreGraphics
import NapoleonCore
import Testing
@testable import Napoleon

/// `WindowStore.snapshot()` 的自愈接线（见 `WindowStore.reconcileWithWindowServer`）。
///
/// 这里测的是**接线**而不是判断逻辑——后者已经在 `WindowServerReconcilerTests` 里逐条覆盖。
/// 单独测接线的理由：这个 bug 的本体就是「没人在正确的时刻去对账」，纯逻辑再对，没接在
/// `snapshot()` 上也一样救不了用户。
///
/// 全部用**没有 `start()` 过**的 `WindowStore`：这样 `state` 天然是空的，正好等价于「热态把窗口
/// 全跟丢了」这个最坏情形，不需要为了造初始状态去开测试专用的后门。也因此不会装任何 AX 观察者。
@MainActor
@Suite struct WindowStoreReconcileTests {
    /// 用测试进程自己的 pid——`isRegularOrSelf` 对自身进程恒为真，于是不必依赖测试机上恰好
    /// 开着哪个 App。
    private var ownPID: ProcessID { NSRunningApplication.ownProcessID }

    private func onScreen(_ id: WindowID, title: String = "Recovered") -> OnScreenWindow {
        OnScreenWindow(windowID: id, pid: ownPID, title: title,
                       bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    @Test func snapshotRecoversWindowsTheStoreHadLost() {
        let store = WindowStore(onScreenWindows: { [self.onScreen(4242), self.onScreen(4243)] })
        let recovered = store.snapshot().state.windows
        #expect(recovered.map(\.id).sorted() == [4242, 4243])
    }

    /// 补回来的窗口必须是「可见、未最小化」的，否则 `WindowFilter` 会当场把它们滤掉，等于白补。
    @Test func recoveredWindowsSurviveTheDefaultScopeFilter() {
        let store = WindowStore(onScreenWindows: { [self.onScreen(4242)] })
        let visible = WindowFilter.apply(store.snapshot().state.windows, mode: .allWindows, scope: ScopeOptions())
        #expect(visible.map(\.id) == [4242])
    }

    /// 窗口服务器读不到东西（返回空）时绝不能把它当成「一扇窗口都没有」——只补不删，且整个跳过。
    @Test func anEmptyGroundTruthChangesNothing() {
        let store = WindowStore(onScreenWindows: { [] })
        #expect(store.snapshot().state.windows.isEmpty)
    }

    /// 连续呼出两次不该把同一扇窗口补两遍。
    @Test func repeatedSnapshotsDoNotDuplicateRecoveredWindows() {
        let store = WindowStore(onScreenWindows: { [self.onScreen(4242)] })
        _ = store.snapshot()
        let second = store.snapshot().state.windows
        #expect(second.map(\.id) == [4242])
    }
}
