import ApplicationServices
import NapoleonCore
import Testing
@testable import Napoleon

@Suite struct WindowEnumeratorAggregationTests {
    private func window(_ id: WindowID, pid: ProcessID) -> WindowInfo {
        WindowInfo(id: id, pid: pid, appName: "App \(pid)", appBundleID: nil, title: "Window \(id)")
    }

    @Test func oneFailedApplicationDoesNotDiscardAnotherApplicationsWindows() {
        let success = WindowEnumerator.AppEnumerationResult(
            windows: [window(1, pid: 100)],
            handles: [:],
            failure: nil
        )
        let failure = WindowEnumerator.ApplicationFailure(
            pid: 200,
            appName: "Stuck App",
            axErrorRawValue: -25204
        )
        let failed = WindowEnumerator.AppEnumerationResult(
            windows: [],
            handles: [:],
            failure: failure
        )

        let result = WindowEnumerator.merge(
            appResults: [success, failed],
            windowLayerSnapshot: nil
        )

        #expect(result.windows.map(\.id) == [1])
        #expect(result.failedApplications == [failure])
    }

    @Test func successfulLayerSnapshotFiltersWindowsAndHandlesTogether() {
        let keptHandle = AXUIElementCreateSystemWide()
        let droppedHandle = AXUIElementCreateSystemWide()
        let appResult = WindowEnumerator.AppEnumerationResult(
            windows: [window(1, pid: 100), window(2, pid: 100)],
            handles: [1: keptHandle, 2: droppedHandle],
            failure: nil
        )
        let layerSnapshot = WindowLayerSnapshot(
            switchableWindowIDs: [1],
            onScreenWindows: []
        )

        let result = WindowEnumerator.merge(
            appResults: [appResult],
            windowLayerSnapshot: layerSnapshot
        )

        #expect(result.windows.map(\.id) == [1])
        #expect(Set(result.handles.keys) == [1])
        #expect(result.windowLayerSnapshot == layerSnapshot)
    }

    @Test func missingLayerSnapshotFailsOpen() {
        let appResult = WindowEnumerator.AppEnumerationResult(
            windows: [window(1, pid: 100), window(2, pid: 100)],
            handles: [:],
            failure: nil
        )

        let result = WindowEnumerator.merge(appResults: [appResult], windowLayerSnapshot: nil)

        #expect(result.windows.map(\.id) == [1, 2])
    }
}
