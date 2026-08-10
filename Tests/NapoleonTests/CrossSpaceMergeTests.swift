import Testing
import CoreGraphics
import NapoleonCore
@testable import Napoleon

// Pure merge logic — no AX/SCShareableContent involved, so no runtime permission needed.
@Suite struct CrossSpaceMergeTests {
    private static let frame = CGRect(x: 0, y: 0, width: 800, height: 600)

    private static func screenWindow(id: WindowID, pid: ProcessID = 100, title: String = "Title") -> ScreenWindow {
        ScreenWindow(
            windowID: id,
            pid: pid,
            appName: "App\(pid)",
            appBundleID: "com.example.app\(pid)",
            title: title,
            frame: frame,
            isOnScreen: false
        )
    }

    @Test func skipsWindowsAlreadyInAXSetAndAddsTheRest() {
        let axIDs: Set<WindowID> = [1, 2]
        let screenWindows = [
            Self.screenWindow(id: 1), // in AX — skip
            Self.screenWindow(id: 3), // cross-space — add
            Self.screenWindow(id: 4)  // cross-space — add
        ]

        var hiddenCalls: [ProcessID] = []
        var pinyinCalls: [String] = []

        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: axIDs,
            screenWindows: screenWindows,
            keepApp: { _ in true },
            isHiddenApp: { pid in
                hiddenCalls.append(pid)
                return false
            },
            pinyin: { title in
                pinyinCalls.append(title)
                return nil
            },
            isFullscreen: { _ in false }
        )

        #expect(additions.map(\.id) == [3, 4])
        #expect(additions.allSatisfy { $0.isOnCurrentSpace == false })
        #expect(additions.allSatisfy { $0.isMinimized == false })
        #expect(hiddenCalls == [100, 100])
        #expect(pinyinCalls == ["App100", "Title", "App100", "Title"])
    }

    @Test func invokesInjectedClosuresWithTheirResults() {
        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: [],
            screenWindows: [Self.screenWindow(id: 9, pid: 200, title: "购物清单")],
            keepApp: { _ in true },
            isHiddenApp: { _ in true },
            pinyin: { _ in "gou wu qing dan" },
            isFullscreen: { _ in false }
        )

        #expect(additions.count == 1)
        #expect(additions[0].isHiddenApp == true)
        #expect(additions[0].pinyinAppName == "gou wu qing dan")
        #expect(additions[0].pinyinTitle == "gou wu qing dan")
        #expect(additions[0].pid == 200)
        #expect(additions[0].isOnCurrentSpace == false)
    }

    @Test func dedupesDuplicateWindowIDsWithinScreenWindows() {
        let screenWindows = [
            Self.screenWindow(id: 5, title: "First"),
            Self.screenWindow(id: 5, title: "Second") // duplicate id — should be dropped
        ]

        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: [],
            screenWindows: screenWindows,
            keepApp: { _ in true },
            isHiddenApp: { _ in false },
            pinyin: { _ in nil },
            isFullscreen: { _ in false }
        )

        #expect(additions.count == 1)
        #expect(additions[0].id == 5)
        #expect(additions[0].title == "First")
    }

    @Test func emptyScreenWindowsProducesEmptyAdditions() {
        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: [1, 2, 3],
            screenWindows: [],
            keepApp: { _ in true },
            isHiddenApp: { _ in false },
            pinyin: { _ in nil },
            isFullscreen: { _ in false }
        )

        #expect(additions.isEmpty)
    }

    @Test func attachedSheetWindowIDIsNotReaddedFromScreenCapture() {
        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: [1],
            suppressedWindowIDs: [9],
            screenWindows: [Self.screenWindow(id: 9), Self.screenWindow(id: 10)],
            keepApp: { _ in true },
            isHiddenApp: { _ in false },
            pinyin: { _ in nil },
            isFullscreen: { _ in false }
        )

        #expect(additions.map(\.id) == [10])
    }

    // MARK: - O1/Y1: keepApp filter (accessory/non-regular/dead-app pids are skipped)

    @Test func skipsWindowsWhoseOwningAppIsNotKeptByKeepApp() {
        let screenWindows = [
            Self.screenWindow(id: 10, pid: 300), // accessory/dead app — keepApp false
            Self.screenWindow(id: 11, pid: 400)  // regular app — keepApp true
        ]

        var keepAppCalls: [ProcessID] = []

        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: [],
            screenWindows: screenWindows,
            keepApp: { pid in
                keepAppCalls.append(pid)
                return pid == 400
            },
            isHiddenApp: { _ in false },
            pinyin: { _ in nil },
            isFullscreen: { _ in false }
        )

        #expect(additions.map(\.id) == [11])
        #expect(additions.map(\.pid) == [400])
        #expect(keepAppCalls == [300, 400])
    }

    @Test func keepsWindowWhoseOwningAppIsRegular() {
        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: [],
            screenWindows: [Self.screenWindow(id: 20, pid: 500)],
            keepApp: { pid in pid == 500 },
            isHiddenApp: { _ in false },
            pinyin: { _ in nil },
            isFullscreen: { _ in false }
        )

        #expect(additions.count == 1)
        #expect(additions[0].id == 20)
        #expect(additions[0].pid == 500)
    }

    @Test func keepAppFalseSkipsRegardlessOfAXDedupeOrder() {
        // A pid whose app has since terminated (or never existed) — keepApp returns
        // false for every pid, mirroring `NSRunningApplication(processIdentifier:)` == nil.
        let screenWindows = [
            Self.screenWindow(id: 30, pid: 600),
            Self.screenWindow(id: 31, pid: 600)
        ]

        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: [],
            screenWindows: screenWindows,
            keepApp: { _ in false },
            isHiddenApp: { _ in false },
            pinyin: { _ in nil },
            isFullscreen: { _ in false }
        )

        #expect(additions.isEmpty)
    }

    // MARK: - Task X4: isFullscreen tagging

    @Test func tagsEachAdditionWithInjectedIsFullscreenResult() {
        let screenWindows = [
            Self.screenWindow(id: 40), // fullscreen
            Self.screenWindow(id: 41)  // not fullscreen
        ]

        var isFullscreenCalls: [WindowID] = []

        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: [],
            screenWindows: screenWindows,
            keepApp: { _ in true },
            isHiddenApp: { _ in false },
            pinyin: { _ in nil },
            isFullscreen: { id in
                isFullscreenCalls.append(id)
                return id == 40
            }
        )

        #expect(additions.map(\.id) == [40, 41])
        #expect(additions.first(where: { $0.id == 40 })?.isFullscreen == true)
        #expect(additions.first(where: { $0.id == 41 })?.isFullscreen == false)
        #expect(isFullscreenCalls == [40, 41])
    }

    @Test func skippedWindowsDoNotInvokeIsFullscreen() {
        let axIDs: Set<WindowID> = [50]
        var isFullscreenCalls: [WindowID] = []

        let additions = CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: axIDs,
            screenWindows: [Self.screenWindow(id: 50)], // already in AX set — skipped entirely
            keepApp: { _ in true },
            isHiddenApp: { _ in false },
            pinyin: { _ in nil },
            isFullscreen: { id in
                isFullscreenCalls.append(id)
                return true
            }
        )

        #expect(additions.isEmpty)
        #expect(isFullscreenCalls.isEmpty)
    }
}
