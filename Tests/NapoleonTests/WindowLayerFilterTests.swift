import CoreGraphics
import Foundation
import Testing
@testable import Napoleon

@Suite struct WindowLayerFilterTests {
    private func entry(
        id: Int,
        pid: Int = 100,
        layer: Int = 0,
        onScreen: Bool? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: 1),
            kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 800, "Height": 600],
            kCGWindowName as String: "Window \(id)"
        ]
        if let onScreen {
            value[kCGWindowIsOnscreen as String] = NSNumber(value: onScreen)
        }
        return value
    }

    @Test func keepsStandardLayerAndDropsFloatingPetWindow() {
        let raw: [[String: Any]] = [
            [
                kCGWindowNumber as String: NSNumber(value: 73),
                kCGWindowLayer as String: NSNumber(value: 0)
            ],
            [
                kCGWindowNumber as String: NSNumber(value: 226),
                kCGWindowLayer as String: NSNumber(value: 3)
            ]
        ]

        #expect(WindowLayerFilter.switchableWindowIDs(from: raw) == [73])
    }

    @Test func malformedEntriesFailClosedIndividually() {
        let raw: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 1)],
            [kCGWindowLayer as String: NSNumber(value: 0)]
        ]
        #expect(WindowLayerFilter.switchableWindowIDs(from: raw).isEmpty)
    }

    @Test func oneSnapshotSeparatesSwitchableAndPositivelyOnScreenWindows() throws {
        let snapshot = try #require(WindowLayerFilter.snapshot(from: [
            entry(id: 73, onScreen: true),
            entry(id: 74, onScreen: false),
            entry(id: 226, layer: 3, onScreen: true)
        ]))

        #expect(snapshot.switchableWindowIDs == [73, 74])
        #expect(snapshot.onScreenWindows.map(\.windowID) == [73])
    }

    @Test func missingOnScreenKeyIsNotTreatedAsPositiveEvidence() throws {
        let snapshot = try #require(WindowLayerFilter.snapshot(from: [entry(id: 73)]))

        #expect(snapshot.switchableWindowIDs == [73])
        #expect(snapshot.onScreenWindows.isEmpty)
    }

    @Test func snapshotFailsOpenWhenNoSwitchableWindowsCanBeRead() {
        #expect(WindowLayerFilter.snapshot(from: [entry(id: 226, layer: 3, onScreen: true)]) == nil)
    }
}
