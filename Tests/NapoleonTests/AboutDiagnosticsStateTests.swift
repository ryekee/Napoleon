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

    @Test func disclosuresStateThatRawTextAndCachedImagesMayExposePaths() {
        let english = Locale(identifier: "en")

        #expect(
            AboutDiagnosticsPresentation.privacyDisclosure(for: .search, locale: english)
                == "Adds raw search text and matching window titles. Napoleon does not separately read file paths or images, but the text itself may contain file names or paths."
        )
        #expect(
            AboutDiagnosticsPresentation.privacyDisclosure(for: .thumbnail, locale: english)
                == "Adds cached window images. Napoleon does not separately add search text, window titles, or file paths, but they may appear in the images. No new screenshots are taken."
        )
    }

    @Test func diagnosticMessagesHaveCompleteFourLanguageTranslations() throws {
        let messages: [(key: String, translations: [String: String])] = [
            (
                "Adds raw search text and matching window titles. Napoleon does not separately read file paths or images, but the text itself may contain file names or paths.",
                [
                    "en": "Adds raw search text and matching window titles. Napoleon does not separately read file paths or images, but the text itself may contain file names or paths.",
                    "zh-Hans": "添加原始搜索文本和匹配的窗口标题。Napoleon 不会单独读取文件路径或图像，但文本本身可能包含文件名或路径。",
                    "zh-Hant": "加入原始搜尋文字與相符的視窗標題。Napoleon 不會另外讀取檔案路徑或影像，但文字本身可能包含檔案名稱或路徑。",
                    "ja": "検索テキストの原文と一致したウインドウタイトルを追加します。Napoleon がファイルパスや画像を個別に読み取ることはありませんが、テキスト自体にファイル名やパスが含まれる場合があります。"
                ]
            ),
            (
                "Adds cached window images. Napoleon does not separately add search text, window titles, or file paths, but they may appear in the images. No new screenshots are taken.",
                [
                    "en": "Adds cached window images. Napoleon does not separately add search text, window titles, or file paths, but they may appear in the images. No new screenshots are taken.",
                    "zh-Hans": "添加缓存的窗口图像。Napoleon 不会单独添加搜索文本、窗口标题或文件路径，但这些内容可能显示在图像中。不会新截取屏幕截图。",
                    "zh-Hant": "加入快取的視窗影像。Napoleon 不會另外加入搜尋文字、視窗標題或檔案路徑，但這些內容可能顯示在影像中。不會擷取新的螢幕截圖。",
                    "ja": "キャッシュ済みのウインドウ画像を追加します。Napoleon が検索テキスト、ウインドウタイトル、ファイルパスを個別に追加することはありませんが、それらが画像内に表示されている場合があります。新しいスクリーンショットは撮影しません。"
                ]
            ),
            (
                "Recording search details",
                [
                    "en": "Recording search details",
                    "zh-Hans": "正在记录搜索详情",
                    "zh-Hant": "正在記錄搜尋詳細資料",
                    "ja": "検索の詳細を記録中"
                ]
            ),
            (
                "Email draft cancelled; the ZIP will remain on this Mac for up to two hours.",
                [
                    "en": "Email draft cancelled; the ZIP will remain on this Mac for up to two hours.",
                    "zh-Hans": "邮件草稿已取消；ZIP 最多在本机保留两小时。",
                    "zh-Hant": "郵件草稿已取消；ZIP 最多會在此 Mac 保留兩小時。",
                    "ja": "メールの下書きをキャンセルしました。ZIP はこの Mac に最長2時間保持されます。"
                ]
            ),
            (
                "A diagnostic report is already being prepared.",
                [
                    "en": "A diagnostic report is already being prepared.",
                    "zh-Hans": "正在生成另一份诊断报告。",
                    "zh-Hant": "正在準備另一份診斷報告。",
                    "ja": "別の診断レポートを作成中です。"
                ]
            ),
            (
                "Creating the diagnostic ZIP timed out. Try again; the uncompressed report is still available.",
                [
                    "en": "Creating the diagnostic ZIP timed out. Try again; the uncompressed report is still available.",
                    "zh-Hans": "创建诊断 ZIP 超时。请重试；未压缩的报告仍保留在本机。",
                    "zh-Hant": "建立診斷 ZIP 逾時。請再試一次；未壓縮的報告仍保留在此 Mac。",
                    "ja": "診断 ZIP の作成がタイムアウトしました。もう一度お試しください。圧縮前のレポートはこの Mac に残っています。"
                ]
            ),
            (
                "Could not create the diagnostic ZIP. Try again; the uncompressed report is still available.",
                [
                    "en": "Could not create the diagnostic ZIP. Try again; the uncompressed report is still available.",
                    "zh-Hans": "无法创建诊断 ZIP。请重试；未压缩的报告仍保留在本机。",
                    "zh-Hant": "無法建立診斷 ZIP。請再試一次；未壓縮的報告仍保留在此 Mac。",
                    "ja": "診断 ZIP を作成できませんでした。もう一度お試しください。圧縮前のレポートはこの Mac に残っています。"
                ]
            )
        ]

        for message in messages {
            for (localeIdentifier, expected) in message.translations {
                let appBundle = Bundle(for: EmailDraftComposer.self)
                let localizationURL = try #require(
                    appBundle.url(forResource: localeIdentifier, withExtension: "lproj")
                )
                let localizedBundle = try #require(Bundle(url: localizationURL))
                let localized = localizedBundle.localizedString(
                    forKey: message.key,
                    value: nil,
                    table: "Localizable"
                )
                #expect(localized == expected, "Missing or incorrect \(localeIdentifier) translation")
            }
        }
    }

    @Test func searchRecordingStateSurvivesViewRebuildAndFollowsIssueLifecycle() {
        let presentation = AboutDiagnosticsPresentation()
        let diagnostics = makeDiagnostics()

        #expect(presentation.isRecordingSearchDetails == false)
        #expect(presentation.selectIssue(.search))
        #expect(presentation.isRecordingSearchDetails)

        let rebuiltView = AboutView(
            updateChecker: UpdateChecker(),
            diagnostics: diagnostics,
            presentation: presentation
        )
        #expect(rebuiltView.presentation.isRecordingSearchDetails)

        #expect(presentation.selectIssue(.thumbnail))
        #expect(presentation.isRecordingSearchDetails == false)

        #expect(presentation.selectIssue(.search))
        #expect(presentation.beginPreparation())
        presentation.finishPreparation(.handedOff(requiresManualAttachment: false))
        #expect(presentation.isRecordingSearchDetails == false)

        #expect(presentation.selectIssue(.search))
        #expect(presentation.beginPreparation())
        presentation.finishPreparation(.cancelled)
        #expect(presentation.isRecordingSearchDetails)
        #expect(presentation.emailDraftWasCancelled)
    }

    @Test func unavailableServiceChecksActualAttachmentThenFallsBackWithoutPerforming() async {
        let service = NSSharingService(
            title: "Unavailable Email",
            image: NSImage(size: .init(width: 1, height: 1)),
            alternateImage: nil,
            handler: {}
        )
        let attachment = URL(fileURLWithPath: "/tmp/napoleon-unavailable.zip")
        var checkedAttachment: URL?
        var performCount = 0
        let composer = EmailDraftComposer(
            serviceProvider: { service },
            canPerform: { _, items in
                checkedAttachment = items.first as? URL
                return false
            },
            perform: { _, _ in performCount += 1 }
        )
        let presentation = AboutDiagnosticsPresentation(emailComposer: composer)
        var fallbackAttachments: [URL] = []
        var handoffCount = 0

        #expect(presentation.beginPreparation())
        await presentation.handOffPreparedReport(
            attachment,
            openFallback: { fallbackAttachments.append($0) },
            markHandedOff: { handoffCount += 1 }
        )

        #expect(checkedAttachment == attachment)
        #expect(performCount == 0)
        #expect(fallbackAttachments == [attachment])
        #expect(handoffCount == 1)
        #expect(presentation.requiresManualAttachment)
        #expect(presentation.isPreparing == false)
    }

    @Test func cancelledEmailDraftHasNoFallbackOrHandoffAndKeepsSearchRecording() async {
        let service = NSSharingService(
            title: "Cancelled Email",
            image: NSImage(size: .init(width: 1, height: 1)),
            alternateImage: nil,
            handler: {}
        )
        let composer = EmailDraftComposer(
            serviceProvider: { service },
            canPerform: { _, _ in true },
            perform: { _, _ in }
        )
        let presentation = AboutDiagnosticsPresentation(emailComposer: composer)
        let attachment = URL(fileURLWithPath: "/tmp/napoleon-cancelled.zip")
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

        composer.sharingService(
            service,
            didFailToShareItems: [attachment],
            error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        )
        await task.value

        #expect(fallbackCount == 0)
        #expect(handoffCount == 0)
        #expect(presentation.selectedIssue == .search)
        #expect(presentation.isRecordingSearchDetails)
        #expect(presentation.emailDraftWasCancelled)
        #expect(presentation.isPreparing == false)
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
            canPerform: { _, _ in true },
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
            canPerform: { _, _ in true },
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
