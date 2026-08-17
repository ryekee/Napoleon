import NapoleonCore
import CoreGraphics
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

    @Test func strongSurfaceCandidatesRequireExactCurrentSpaceEvidence() {
        let frame = CGRect(x: 0, y: 40, width: 1_426, height: 912)
        let candidates = [
            screenWindow(6091, title: "2026.08", frame: frame),
            screenWindow(7329, title: "Downloads", frame: frame),
            screenWindow(8001, title: "Background Tab", frame: frame),
            screenWindow(8002, title: "Offscreen", frame: frame, isOnScreen: false),
            screenWindow(8003, title: "Suppressed", frame: frame),
            screenWindow(8004, title: "Floating", frame: frame)
        ]
        let layers = WindowLayerSnapshot(
            switchableWindows: [6091: 651, 7329: 651, 8001: 651, 8002: 651, 8003: 651],
            nonSwitchableWindows: [8004: 651],
            onScreenWindowIDs: [6091, 7329, 8001, 8003]
        )

        let result = WindowStore.strongSurfaceCandidates(
            screenWindows: candidates,
            layerSnapshot: layers,
            knownWindowIDs: [7329],
            suppressedWindowIDs: [8003],
            isAssignedToSpace: { id in id == 8001 ? false : true }
        )

        #expect(result.map(\.windowID) == [6091])
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

    private func screenWindow(
        _ id: WindowID,
        title: String,
        frame: CGRect,
        isOnScreen: Bool = true
    ) -> ScreenWindow {
        ScreenWindow(
            windowID: id,
            pid: 651,
            appName: "Finder",
            appBundleID: "com.apple.finder",
            title: title,
            frame: frame,
            isOnScreen: isOnScreen
        )
    }
}
