import NapoleonCore
import Testing
@testable import Napoleon

@MainActor
@Suite struct WindowStoreRegistryTests {
    @Test func snapshotIsAPureRead() {
        let initial = WindowState(
            windows: [window(1, pid: 10), window(2, pid: 20)],
            mru: MRUTracker(order: [2, 1])
        )
        let store = WindowStore(initialState: initial)

        _ = store.snapshot()
        _ = store.snapshot()

        #expect(store.diagnosticState() == initial)
    }

    @Test func committedExactFocusUpdatesMRUImmediately() {
        let store = WindowStore(initialState: WindowState(
            windows: [window(1, pid: 10), window(2, pid: 20, onCurrentSpace: false)],
            mru: MRUTracker(order: [1, 2])
        ))

        store.recordCommittedFocus(2)

        #expect(store.diagnosticState().mru.order == [2, 1])
        #expect(store.diagnosticState().windows.first { $0.id == 2 }?.isOnCurrentSpace == true)
    }

    @Test func anAuditIsRejectedWhenOnlyItsProcessChanged() {
        #expect(WindowStore.auditResultIsCurrent(
            capturedEnvironment: 7,
            currentEnvironment: 7,
            capturedPID: 3,
            currentPID: 4
        ) == false)
        #expect(WindowStore.auditResultIsCurrent(
            capturedEnvironment: 7,
            currentEnvironment: 7,
            capturedPID: 3,
            currentPID: 3
        ))
    }

    private func window(
        _ id: WindowID,
        pid: ProcessID,
        onCurrentSpace: Bool = true
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid,
            appName: "App \(pid)",
            appBundleID: nil,
            title: "Window \(id)",
            isOnCurrentSpace: onCurrentSpace
        )
    }
}
