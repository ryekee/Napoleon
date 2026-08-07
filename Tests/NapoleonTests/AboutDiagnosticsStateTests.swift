import Foundation
import Testing
@testable import Napoleon

@MainActor
@Suite struct AboutDiagnosticsStateTests {
    @Test func sharedPresentationRejectsASecondPreparationUntilTheFirstFinishes() {
        let sharedPresentation = AboutDiagnosticsPresentation()
        let diagnostics = makeDiagnostics()
        let firstView = AboutView(
            updateChecker: UpdateChecker(),
            diagnostics: diagnostics,
            presentation: sharedPresentation
        )
        let rebuiltView = AboutView(
            updateChecker: UpdateChecker(),
            diagnostics: diagnostics,
            presentation: sharedPresentation
        )

        #expect(firstView.presentation === rebuiltView.presentation)

        #expect(firstView.presentation.beginPreparation())
        #expect(rebuiltView.presentation.isPreparing)
        #expect(rebuiltView.presentation.beginPreparation() == false)

        firstView.presentation.finishPreparation(.failed("failed"))
        #expect(rebuiltView.presentation.isPreparing == false)
        #expect(rebuiltView.presentation.error == "failed")
        #expect(rebuiltView.presentation.beginPreparation())
    }

    private func makeDiagnostics() -> DiagnosticsService {
        DiagnosticsService(
            directory: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory),
            snapshot: {
                DiagnosticSnapshot(
                    appVersion: "test",
                    appBuild: "test",
                    macOSVersion: "test",
                    architecture: "test",
                    interfaceLanguage: "en",
                    accessibilityTrusted: false,
                    screenRecordingGranted: false,
                    allWindowsHotkey: "test",
                    currentAppHotkey: "test",
                    includeOtherSpaces: false,
                    includeMinimized: false,
                    includeHiddenApps: false,
                    pinyinSearchEnabled: false,
                    groupWindowsByApplication: false,
                    showDelayMs: 0,
                    apps: []
                )
            },
            cachedThumbnail: { _ in nil }
        )
    }
}
