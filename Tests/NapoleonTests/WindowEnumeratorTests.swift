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
            pid: 100,
            windows: [window(1, pid: 100)],
            handles: [:],
            suppressedWindows: [],
            suppressionIsComplete: true,
            failure: nil
        )
        let failure = WindowEnumerator.ApplicationFailure(
            pid: 200,
            appName: "Stuck App",
            axErrorRawValue: -25204
        )
        let failed = WindowEnumerator.AppEnumerationResult(
            pid: 200,
            windows: [],
            handles: [:],
            suppressedWindows: [],
            suppressionIsComplete: true,
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
            pid: 100,
            windows: [window(1, pid: 100), window(2, pid: 100)],
            handles: [1: keptHandle, 2: droppedHandle],
            suppressedWindows: [],
            suppressionIsComplete: true,
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
            pid: 100,
            windows: [window(1, pid: 100), window(2, pid: 100)],
            handles: [:],
            suppressedWindows: [],
            suppressionIsComplete: true,
            failure: nil
        )

        let result = WindowEnumerator.merge(appResults: [appResult], windowLayerSnapshot: nil)

        #expect(result.windows.map(\.id) == [1, 2])
    }

    @Test func mergesAttachedSheetsIntoTheSuppressionSetWithoutListingThem() {
        let sheet = WindowEnumerator.SuppressedWindow(
            id: 9,
            pid: 100,
            ownerID: 1,
            element: AXUIElementCreateSystemWide()
        )
        let appResult = WindowEnumerator.AppEnumerationResult(
            pid: 100,
            windows: [window(1, pid: 100)],
            handles: [:],
            suppressedWindows: [sheet],
            suppressionIsComplete: true,
            failure: nil
        )

        let result = WindowEnumerator.merge(appResults: [appResult], windowLayerSnapshot: nil)

        #expect(result.windows.map(\.id) == [1])
        #expect(result.suppressedWindows.map(\.id) == [9])
        #expect(result.suppressedWindows.map(\.ownerID) == [1])
    }

    @Test func reportsAppsWhoseAttachedSheetLookupWasIncomplete() {
        let appResult = WindowEnumerator.AppEnumerationResult(
            pid: 100,
            windows: [window(1, pid: 100)],
            handles: [:],
            suppressedWindows: [],
            suppressionIsComplete: false,
            failure: nil
        )

        let result = WindowEnumerator.merge(appResults: [appResult], windowLayerSnapshot: nil)

        #expect(result.suppressionIncompletePIDs == [100])
    }
}

@Suite struct WindowFocusIdentityTests {
    @Test func focusedAttachedSheetResolvesToItsOwnerWindow() {
        let target = WindowStore.canonicalFocusID(
            resolvedID: 9,
            knownWindowIDs: [1, 2],
            suppressedOwnerIDs: [9: 1]
        )

        #expect(target == 1)
    }
}

@Suite struct ModalDialogSuppressionTests {
    @Test func modalDialogUsesTheSoleExistingWindowAsItsOwner() {
        let ownerID = WindowEnumerator.modalDialogOwnerID(
            subrole: kAXDialogSubrole,
            isModal: true,
            ownerCandidateIDs: [112]
        )

        #expect(ownerID == 112)
    }

    @Test func ambiguousModalDialogIsNotSuppressed() {
        let ownerID = WindowEnumerator.modalDialogOwnerID(
            subrole: kAXDialogSubrole,
            isModal: true,
            ownerCandidateIDs: [112, 113]
        )

        #expect(ownerID == nil)
    }
}
