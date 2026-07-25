import Testing
import CoreGraphics
import NapoleonCore
@testable import Napoleon

// Only `bestMatch` (pure scoring) is unit tested here — the private-API probe
// path in `windowID(for:)` needs a real AXUIElement/window server and is
// verified at runtime, not in this suite.
@Suite struct WindowIDResolverTests {
    @Test func singleSamePidCandidateWithExactFrameReturnsItsID() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let candidate = WindowCandidate(id: 42, pid: 100, frame: frame, title: "Notes")

        let result = WindowIDResolver.bestMatch(pid: 100, frame: frame, title: "Notes", among: [candidate])

        #expect(result == 42)
    }

    @Test func higherIoUCandidateWinsOverLowerIoUCandidate() {
        let targetFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Near-identical frame -> IoU ~0.997.
        let highIoU = WindowCandidate(id: 1, pid: 200, frame: CGRect(x: 1, y: 1, width: 799, height: 599), title: nil)
        // Mostly non-overlapping frame -> IoU ~0.03.
        let lowIoU = WindowCandidate(id: 2, pid: 200, frame: CGRect(x: 500, y: 500, width: 800, height: 600), title: nil)

        let result = WindowIDResolver.bestMatch(pid: 200, frame: targetFrame, title: nil, among: [highIoU, lowIoU])

        #expect(result == 1)
    }

    @Test func noSamePidCandidatesReturnsNil() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let candidate = WindowCandidate(id: 5, pid: 999, frame: frame, title: nil)

        let result = WindowIDResolver.bestMatch(pid: 100, frame: frame, title: nil, among: [candidate])

        #expect(result == nil)
    }

    @Test func samePidButFarApartFrameAndMismatchedTitleReturnsNil() {
        let targetFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let candidate = WindowCandidate(id: 7, pid: 100, frame: CGRect(x: 5000, y: 5000, width: 200, height: 200), title: "Other")

        let result = WindowIDResolver.bestMatch(pid: 100, frame: targetFrame, title: "Target", among: [candidate])

        #expect(result == nil)
    }

    @Test func smallFrameOffsetWithMatchingTitleStillMatches() {
        let targetFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        // 8pt offset on an 800x600 frame -> IoU ~0.95 (within tolerance).
        let offsetFrame = CGRect(x: 8, y: 8, width: 800, height: 600)
        let candidate = WindowCandidate(id: 9, pid: 100, frame: offsetFrame, title: "Notes")

        let result = WindowIDResolver.bestMatch(pid: 100, frame: targetFrame, title: "Notes", among: [candidate])

        #expect(result == 9)
    }

    @Test func lowIoUWithExactNonEmptyTitleMatches() {
        let targetFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Barely overlapping -> IoU ~0.2 (well below 0.9 threshold).
        let lowIoUFrame = CGRect(x: 600, y: 400, width: 800, height: 600)
        let candidate = WindowCandidate(id: 11, pid: 100, frame: lowIoUFrame, title: "MyWindow")

        let result = WindowIDResolver.bestMatch(pid: 100, frame: targetFrame, title: "MyWindow", among: [candidate])

        #expect(result == 11)
    }

    @Test func emptyTitleCollisionBothLowIoUReturnsNil() {
        let targetFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Two candidates with empty titles and very different frames, both with low IoU.
        let candidate1 = WindowCandidate(id: 21, pid: 100, frame: CGRect(x: 5000, y: 5000, width: 200, height: 200), title: "")
        let candidate2 = WindowCandidate(id: 22, pid: 100, frame: CGRect(x: 6000, y: 6000, width: 200, height: 200), title: "")

        let result = WindowIDResolver.bestMatch(pid: 100, frame: targetFrame, title: "", among: [candidate1, candidate2])

        #expect(result == nil)
    }

    @Test func zeroAreaFrameDoesNotCrashAndReturnsNil() {
        let targetFrame = CGRect(x: 0, y: 0, width: 0, height: 0)
        let candidate = WindowCandidate(id: 31, pid: 100, frame: CGRect(x: 0, y: 0, width: 100, height: 100), title: "Other")

        let result = WindowIDResolver.bestMatch(pid: 100, frame: targetFrame, title: nil, among: [candidate])

        #expect(result == nil)
    }
}
