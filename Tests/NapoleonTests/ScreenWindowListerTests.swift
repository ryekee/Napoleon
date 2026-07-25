import Testing
import CoreGraphics
@testable import Napoleon

// Only `isRealAppWindow` (pure filter predicate) is unit tested here — the
// `SCShareableContent.current` fetch in `list()` needs Screen Recording
// permission + a live window server and is verified at runtime, not here.
@Suite struct ScreenWindowListerTests {
    private static let normalFrame = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func realAppWindowPassesAllRules() {
        let result = ScreenWindowLister.isRealAppWindow(
            windowLayer: 0,
            bundleID: "com.apple.Safari",
            appName: "Safari",
            title: "Napoleon – GitHub",
            frame: Self.normalFrame
        )

        #expect(result == true)
    }

    @Test func nonZeroWindowLayerIsRejected() {
        let result = ScreenWindowLister.isRealAppWindow(
            windowLayer: 25,
            bundleID: "com.apple.Safari",
            appName: "Safari",
            title: "Napoleon – GitHub",
            frame: Self.normalFrame
        )

        #expect(result == false)
    }

    @Test func controlCenterBundleIDIsRejected() {
        let result = ScreenWindowLister.isRealAppWindow(
            windowLayer: 0,
            bundleID: "com.apple.controlcenter",
            appName: "Control Center",
            title: "Control Center",
            frame: Self.normalFrame
        )

        #expect(result == false)
    }

    @Test func emptyTitleIsRejected() {
        let result = ScreenWindowLister.isRealAppWindow(
            windowLayer: 0,
            bundleID: "com.apple.Safari",
            appName: "Safari",
            title: "",
            frame: Self.normalFrame
        )

        #expect(result == false)
    }

    @Test func emptyAppNameIsRejected() {
        let result = ScreenWindowLister.isRealAppWindow(
            windowLayer: 0,
            bundleID: "com.apple.Safari",
            appName: "",
            title: "Napoleon – GitHub",
            frame: Self.normalFrame
        )

        #expect(result == false)
    }

    @Test func tinyFrameIsRejected() {
        let result = ScreenWindowLister.isRealAppWindow(
            windowLayer: 0,
            bundleID: "com.apple.Safari",
            appName: "Safari",
            title: "Shield",
            frame: CGRect(x: 0, y: 0, width: 1, height: 1)
        )

        #expect(result == false)
    }

    @Test func nilBundleIDIsRejected() {
        let result = ScreenWindowLister.isRealAppWindow(
            windowLayer: 0,
            bundleID: nil,
            appName: "Backstop",
            title: "Backstop",
            frame: Self.normalFrame
        )

        #expect(result == false)
    }

    @Test func dockBundleIDIsRejected() {
        let result = ScreenWindowLister.isRealAppWindow(
            windowLayer: 0,
            bundleID: "com.apple.dock",
            appName: "Dock",
            title: "Wallpaper",
            frame: Self.normalFrame
        )

        #expect(result == false)
    }
}
