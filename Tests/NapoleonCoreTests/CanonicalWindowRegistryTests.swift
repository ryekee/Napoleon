import Testing
@testable import NapoleonCore

@Suite struct CanonicalWindowRegistryTests {
    @Test func incompleteAuditPreservesExistingTargetsAndMRU() {
        var registry = registry(windows: [w(1, pid: 10), w(2, pid: 20)], mru: [2, 1])

        registry.applySemanticAudit(pid: 10, windows: [], isComplete: false, existingWindows: [:])

        #expect(registry.state.windows.map(\.id) == [1, 2])
        #expect(registry.state.mru.order == [2, 1])
    }

    @Test func failedWeakSnapshotCannotQuarantineAnything() {
        var registry = registry(windows: [w(1, pid: 10)], mru: [1])

        registry.applySemanticAudit(pid: 10, windows: [], isComplete: true, existingWindows: nil)

        #expect(registry.state.windows.map(\.id) == [1])
        #expect(!registry.isQuarantined(1))
    }

    @Test func firstConfirmedAbsenceQuarantinesWithoutForgettingMRU() {
        var registry = registry(windows: [w(1, pid: 10), w(2, pid: 20)], mru: [1, 2])

        registry.applySemanticAudit(pid: 10, windows: [], isComplete: true, existingWindows: [:])

        #expect(registry.state.windows.map(\.id) == [2])
        #expect(registry.state.mru.order == [1, 2])
        #expect(registry.isQuarantined(1))
    }

    @Test func secondConfirmedAbsenceRemovesTargetAndMRUEntry() {
        var registry = registry(windows: [w(1, pid: 10), w(2, pid: 20)], mru: [1, 2])

        for _ in 0..<2 {
            registry.applySemanticAudit(pid: 10, windows: [], isComplete: true, existingWindows: [:])
        }

        #expect(registry.allWindows.map(\.id) == [2])
        #expect(registry.state.mru.order == [2])
    }

    @Test func semanticObservationRestoresQuarantinedTargetAtItsPreviousRank() {
        var registry = registry(windows: [w(1, pid: 10), w(2, pid: 20)], mru: [1, 2])
        registry.applySemanticAudit(pid: 10, windows: [], isComplete: true, existingWindows: [:])

        registry.observeSemanticWindow(w(1, pid: 10))

        #expect(registry.state.windows.map(\.id) == [1, 2])
        #expect(registry.state.mru.order == [1, 2])
        #expect(!registry.isQuarantined(1))
    }

    @Test func surfaceObservationUpdatesKnownTargetButCannotCreateOne() {
        var registry = registry(windows: [w(1, pid: 10)])

        registry.observeSurface(windowID: 1, pid: 10, isOnCurrentSpace: false, isFullscreen: true)
        registry.observeSurface(windowID: 99, pid: 10, isOnCurrentSpace: false, isFullscreen: true)

        #expect(registry.allWindows.map(\.id) == [1])
        #expect(registry.state.windows.first?.isOnCurrentSpace == false)
        #expect(registry.state.windows.first?.isFullscreen == true)
    }

    @Test func positiveOnScreenEvidenceRepairsStaleVisibilityFlags() {
        var registry = registry(windows: [
            w(1, pid: 10, minimized: true, hidden: true, onCurrentSpace: false)
        ])

        registry.observeSurface(windowID: 1, pid: 10, isOnCurrentSpace: true)

        let target = registry.state.windows.first
        #expect(target?.isOnCurrentSpace == true)
        #expect(target?.isMinimized == false)
        #expect(target?.isHiddenApp == false)
    }

    @Test func reusedWindowIDFromAnotherProcessDoesNotRescueAStaleTarget() {
        var registry = registry(windows: [w(1, pid: 10)], mru: [1])

        registry.applySemanticAudit(pid: 10, windows: [], isComplete: true, existingWindows: [1: 99])

        #expect(registry.isQuarantined(1))
    }

    @Test func weakExistenceForSameIdentityPreservesCrossSpaceTarget() {
        var registry = registry(windows: [w(1, pid: 10)], mru: [1])

        registry.applySemanticAudit(pid: 10, windows: [], isComplete: true, existingWindows: [1: 10])

        #expect(registry.state.windows.map(\.id) == [1])
        #expect(registry.state.windows.first?.isOnCurrentSpace == false)
        #expect(!registry.isQuarantined(1))
    }

    @Test func registeringBackgroundWindowDoesNotPromoteItUntilFocus() {
        var registry = registry(windows: [w(1), w(2)], mru: [2, 1])

        registry.observeSemanticWindow(w(3))
        #expect(registry.state.mru.order == [2, 1, 3])

        registry.recordFocus(3)
        #expect(registry.state.mru.order == [3, 2, 1])
        #expect(registry.state.windows.first { $0.id == 3 }?.isOnCurrentSpace == true)
    }

    @Test func alternatingExactFocusKeepsThePreviousAppSecond() {
        var registry = registry(windows: [w(1, pid: 10), w(2, pid: 20)], mru: [1, 2])

        registry.recordFocus(2)
        #expect(registry.state.mru.order == [2, 1])

        registry.recordFocus(1)
        #expect(registry.state.mru.order == [1, 2])
    }

    @Test func incrementalEventsUpdateOnlyKnownCanonicalTargets() {
        var registry = registry(windows: [w(1, pid: 10), w(2, pid: 20)], mru: [2, 1])

        registry.updateMinimized(1, isMinimized: true)
        registry.updateTitle(1, title: "Renamed", pinyin: "renamed")
        registry.updateAppHidden(pid: 10, isHidden: true)
        registry.observeSurface(windowID: 1, pid: 10, isOnCurrentSpace: false)
        registry.observeSurface(windowID: 2, pid: 20, isOnCurrentSpace: true)

        let first = registry.allWindows.first { $0.id == 1 }
        #expect(first?.isMinimized == true)
        #expect(first?.title == "Renamed")
        #expect(first?.pinyinTitle == "renamed")
        #expect(first?.isHiddenApp == true)
        #expect(first?.isOnCurrentSpace == false)
        #expect(registry.allWindows.first { $0.id == 2 }?.isOnCurrentSpace == true)
        #expect(registry.state.mru.order == [2, 1])
    }

    @Test func explicitDestroyAndAppTerminationRemoveImmediately() {
        var registry = registry(
            windows: [w(1, pid: 10), w(2, pid: 10), w(3, pid: 20)],
            mru: [2, 1, 3]
        )

        registry.remove(1)
        registry.terminateApp(pid: 10)

        #expect(registry.allWindows.map(\.id) == [3])
        #expect(registry.state.mru.order == [3])
    }

    private func registry(windows: [WindowInfo], mru: [WindowID] = []) -> CanonicalWindowRegistry {
        CanonicalWindowRegistry(initialState: WindowState(windows: windows, mru: MRUTracker(order: mru)))
    }
}
