import CoreGraphics
import Foundation
import Testing
@testable import Napoleon

@Suite struct WindowLayerFilterTests {
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
}
