import AppKit
import Foundation
import SwiftUI
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

    @Test func settingsActionButtonsUseTheSameSizeAcrossLabels() {
        let updateButton = NSHostingView(rootView: SettingsActionButton(action: {}) {
            Text("Check for Updates")
        })
        let diagnosticsButton = NSHostingView(rootView: SettingsActionButton(action: {}) {
            Text("Share data...")
        })

        #expect(abs(updateButton.fittingSize.width - diagnosticsButton.fittingSize.width) < 0.5)
        #expect(abs(updateButton.fittingSize.height - diagnosticsButton.fittingSize.height) < 0.5)
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
                "Could not open your default email app. The ZIP is selected in Finder; attach it manually to an email to hi@ryek.ee.",
                [
                    "en": "Could not open your default email app. The ZIP is selected in Finder; attach it manually to an email to hi@ryek.ee.",
                    "zh-Hans": "无法打开默认邮件应用。ZIP 已在访达中选中；请手动将其添加到发送至 hi@ryek.ee 的邮件中。",
                    "zh-Hant": "無法開啟預設郵件 App。ZIP 已在 Finder 中選取；請手動將它加入寄給 hi@ryek.ee 的郵件。",
                    "ja": "デフォルトのメールアプリを開けませんでした。ZIP は Finder で選択されています。hi@ryek.ee 宛てのメールに手動で添付してください。"
                ]
            ),
            (
                "System model: %@\nmacOS version: %@\nNapoleon version: %@ (build %@)\n\nPlease attach the diagnostic ZIP opened in Finder. Napoleon does not upload it automatically.",
                [
                    "en": "System model: %@\nmacOS version: %@\nNapoleon version: %@ (build %@)\n\nPlease attach the diagnostic ZIP opened in Finder. Napoleon does not upload it automatically.",
                    "zh-Hans": "系统型号：%@\nmacOS 版本：%@\nNapoleon 版本：%@（build %@）\n\n请将访达中打开的诊断 ZIP 手动添加为附件。Napoleon 不会自动上传该文件。",
                    "zh-Hant": "系統型號：%@\nmacOS 版本：%@\nNapoleon 版本：%@（build %@）\n\n請將 Finder 中開啟的診斷 ZIP 手動加入為附件。Napoleon 不會自動上傳此檔案。",
                    "ja": "システムモデル：%@\nmacOS バージョン：%@\nNapoleon バージョン：%@（build %@）\n\nFinder で開いた診断 ZIP を手動で添付してください。Napoleon がこのファイルを自動でアップロードすることはありません。"
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
                let appBundle = Bundle(for: AboutDiagnosticsPresentation.self)
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
        presentation.finishPreparation(.handedOff)
        #expect(presentation.isRecordingSearchDetails == false)
    }

    @Test func mailtoContainsRecipientSystemModelVersionAndManualAttachmentInstruction() throws {
        let draft = DiagnosticEmailDraft(
            systemModel: "Mac14,6",
            macOSVersion: "26.0.1",
            appVersion: "0.2.0",
            appBuild: "39"
        )
        let url = try #require(draft.url(locale: Locale(identifier: "en")))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(components.scheme == "mailto")
        #expect(components.path == "hi@ryek.ee")
        #expect(query["subject"] == "Napoleon diagnostics")
        #expect(
            query["body"]
                == "System model: Mac14,6\nmacOS version: 26.0.1\nNapoleon version: 0.2.0 (build 39)\n\nPlease attach the diagnostic ZIP opened in Finder. Napoleon does not upload it automatically."
        )
    }

    @Test func preparedReportRevealsZipThenOpensDefaultEmailAndCompletesHandoff() throws {
        let presentation = AboutDiagnosticsPresentation()
        let attachment = URL(fileURLWithPath: "/tmp/napoleon-test.zip")
        let mailto = try #require(URL(string: "mailto:hi@ryek.ee"))
        var events: [String] = []
        var handoffCount = 0

        #expect(presentation.selectIssue(.search))
        #expect(presentation.beginPreparation())
        presentation.handOffPreparedReport(
            attachment,
            mailtoURL: mailto,
            revealInFinder: {
                #expect($0 == attachment)
                events.append("finder")
            },
            openEmail: {
                #expect($0 == mailto)
                events.append("email")
                return true
            },
            markHandedOff: {
                events.append("handoff")
                handoffCount += 1
            }
        )

        #expect(events == ["finder", "email", "handoff"])
        #expect(handoffCount == 1)
        #expect(presentation.selectedIssue == .general)
        #expect(presentation.error == nil)
        #expect(presentation.isPreparing == false)
    }

    @Test func failedDefaultEmailStillRevealsZipWithoutDiscardingReportState() throws {
        let presentation = AboutDiagnosticsPresentation()
        let attachment = URL(fileURLWithPath: "/tmp/napoleon-email-failed.zip")
        let mailto = try #require(URL(string: "mailto:hi@ryek.ee"))
        var revealedAttachments: [URL] = []
        var openedURLs: [URL] = []
        var handoffCount = 0

        #expect(presentation.selectIssue(.search))
        #expect(presentation.beginPreparation())
        presentation.handOffPreparedReport(
            attachment,
            mailtoURL: mailto,
            revealInFinder: { revealedAttachments.append($0) },
            openEmail: {
                openedURLs.append($0)
                return false
            },
            markHandedOff: { handoffCount += 1 }
        )

        #expect(revealedAttachments == [attachment])
        #expect(openedURLs == [mailto])
        #expect(presentation.isPreparing == false)
        #expect(handoffCount == 0)
        #expect(presentation.selectedIssue == .search)
        #expect(presentation.isRecordingSearchDetails)
        #expect(
            presentation.error
                == String(localized: "Could not open your default email app. The ZIP is selected in Finder; attach it manually to an email to hi@ryek.ee.")
        )
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
