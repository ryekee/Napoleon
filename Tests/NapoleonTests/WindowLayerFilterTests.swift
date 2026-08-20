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
            entry(id: 73),
            entry(id: 226, layer: 3)
        ]

        #expect(WindowLayerFilter.switchableWindows(from: raw) == [73: 100])
    }

    @Test func malformedEntriesFailClosedIndividually() {
        let raw: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 1)],
            [kCGWindowLayer as String: NSNumber(value: 0)]
        ]
        #expect(WindowLayerFilter.switchableWindows(from: raw).isEmpty)
    }

    @Test func oneSnapshotSeparatesSwitchableAndPositivelyOnScreenWindows() throws {
        let snapshot = try #require(WindowLayerFilter.snapshot(from: [
            entry(id: 73, onScreen: true),
            entry(id: 74, onScreen: false),
            entry(id: 226, layer: 3, onScreen: true)
        ]))

        #expect(snapshot.switchableWindows == [73: 100, 74: 100])
        #expect(snapshot.nonSwitchableWindows == [226: 100])
        #expect(snapshot.onScreenWindowIDs == [73])
        #expect(snapshot.permitsSemanticWindow(id: 73, pid: 100))
        #expect(snapshot.permitsSemanticWindow(id: 999, pid: 100))
        #expect(!snapshot.permitsSemanticWindow(id: 226, pid: 100))
        #expect(snapshot.permitsSemanticWindow(id: 226, pid: 999))
    }

    @Test func missingOnScreenKeyIsNotTreatedAsPositiveEvidence() throws {
        let snapshot = try #require(WindowLayerFilter.snapshot(from: [entry(id: 73)]))

        #expect(snapshot.switchableWindows == [73: 100])
        #expect(snapshot.onScreenWindowIDs.isEmpty)
    }

    @Test func deadHandleOverridesAStaleWindowServerSurface() throws {
        let snapshot = try #require(WindowLayerFilter.snapshot(from: [
            entry(id: 73),
            entry(id: 74),
            entry(id: 77, pid: 400, layer: 3)
        ]))

        let existingWindows = WindowLayerSnapshot.existingWindows(
            layerSnapshot: snapshot,
            knownWindows: [73: 100, 75: 200, 76: 300, 77: 300],
            liveness: [73: .dead, 75: .alive, 76: .unknown, 77: .alive]
        )

        #expect(existingWindows == [74: 100, 75: 200, 76: 300])
        #expect(WindowLayerSnapshot.existingWindows(
            layerSnapshot: nil,
            knownWindows: [73: 100],
            liveness: [73: .dead]
        ) == [:])
        #expect(WindowLayerSnapshot.existingWindows(
            layerSnapshot: nil,
            knownWindows: [73: 100],
            liveness: [73: .unknown]
        ) == nil)
    }

    @Test func snapshotFailsOpenWhenNoSwitchableWindowsCanBeRead() {
        #expect(WindowLayerFilter.snapshot(from: [entry(id: 226, layer: 3, onScreen: true)]) == nil)
    }
}
