import AppKit
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

    @Test func delayedShareFailureFallsBackBeforeExactlyOneHandoffAndRetainsService() async throws {
        weak var retainedService: NSSharingService?
        var performCount = 0
        let composer = EmailDraftComposer(
            serviceProvider: {
                let service = NSSharingService(
                    title: "Test Email",
                    image: NSImage(size: .init(width: 1, height: 1)),
                    alternateImage: nil,
                    handler: {}
                )
                retainedService = service
                return service
            },
            perform: { _, _ in performCount += 1 }
        )
        let presentation = AboutDiagnosticsPresentation(emailComposer: composer)
        let attachment = URL(fileURLWithPath: "/tmp/napoleon-test.zip")
        var fallbackAttachments: [URL] = []
        var handoffCount = 0
        var completionEvents: [String] = []

        #expect(presentation.beginPreparation())
        let task = Task { @MainActor in
            await presentation.handOffPreparedReport(
                attachment,
                openFallback: {
                    fallbackAttachments.append($0)
                    completionEvents.append("fallback")
                },
                markHandedOff: {
                    handoffCount += 1
                    completionEvents.append("handoff")
                }
            )
        }
        await Task.yield()

        #expect(performCount == 1)
        #expect(retainedService != nil)
        #expect(retainedService?.delegate != nil)
        #expect(presentation.isPreparing)
        #expect(presentation.beginPreparation() == false)
        #expect(fallbackAttachments.isEmpty)
        #expect(handoffCount == 0)

        let service = try #require(retainedService)
        composer.sharingService(
            service,
            didFailToShareItems: [attachment],
            error: NSError(domain: "test", code: 1)
        )
        await task.value

        #expect(fallbackAttachments == [attachment])
        #expect(handoffCount == 1)
        #expect(completionEvents == ["fallback", "handoff"])
        #expect(service.delegate == nil)
        #expect(presentation.requiresManualAttachment)
        #expect(presentation.isPreparing == false)
    }

    @Test func didShareCompletesExactlyOneHandoffWithoutFallback() async {
        let service = NSSharingService(
            title: "Test Email",
            image: NSImage(size: .init(width: 1, height: 1)),
            alternateImage: nil,
            handler: {}
        )
        let composer = EmailDraftComposer(
            serviceProvider: { service },
            perform: { _, _ in }
        )
        let presentation = AboutDiagnosticsPresentation(emailComposer: composer)
        let attachment = URL(fileURLWithPath: "/tmp/napoleon-test.zip")
        var fallbackCount = 0
        var handoffCount = 0

        #expect(presentation.selectIssue(.search))
        #expect(presentation.beginPreparation())
        let task = Task { @MainActor in
            await presentation.handOffPreparedReport(
                attachment,
                openFallback: { _ in fallbackCount += 1 },
                markHandedOff: { handoffCount += 1 }
            )
        }
        await Task.yield()

        #expect(handoffCount == 0)
        composer.sharingService(service, didShareItems: [attachment])
        composer.sharingService(service, didShareItems: [attachment])
        await task.value

        #expect(fallbackCount == 0)
        #expect(handoffCount == 1)
        #expect(presentation.selectedIssue == .general)
        #expect(presentation.requiresManualAttachment == false)
        #expect(presentation.isPreparing == false)
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
