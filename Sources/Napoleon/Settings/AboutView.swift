import AppKit
import SwiftUI

/// 把 `NSSharingServiceDelegate` 回调桥接成可等待的邮件草稿交接结果。
///
/// `NSSharingService.delegate` 是 weak，而 `perform(withItems:)` 的成功/失败又在之后异步回调；
/// 因此本对象在回调前强持有 service，自身则由稳定的 presentation 持有。
@MainActor
final class EmailDraftComposer: NSObject, NSSharingServiceDelegate {
    enum Result: Equatable {
        case shared
        case unavailableOrFailed
        case cancelled
        case unconfirmed
    }

    typealias ServiceProvider = @MainActor () -> NSSharingService?
    typealias CanPerform = @MainActor (NSSharingService, [Any]) -> Bool
    typealias Perform = @MainActor (NSSharingService, [Any]) -> Void

    private let serviceProvider: ServiceProvider
    private let canPerform: CanPerform
    private let perform: Perform
    private let confirmationTimeout: Duration
    private var retainedService: NSSharingService?
    private var continuation: CheckedContinuation<Result, Never>?
    private var confirmationTask: Task<Void, Never>?

    init(
        serviceProvider: @escaping ServiceProvider = {
            NSSharingService(named: .composeEmail)
        },
        canPerform: @escaping CanPerform = { service, items in
            service.canPerform(withItems: items)
        },
        perform: @escaping Perform = { service, items in
            service.perform(withItems: items)
        },
        confirmationTimeout: Duration = .seconds(2)
    ) {
        self.serviceProvider = serviceProvider
        self.canPerform = canPerform
        self.perform = perform
        self.confirmationTimeout = confirmationTimeout
    }

    func compose(attachment: URL) async -> Result {
        // 上层 presentation 已保证单飞；这里再拒绝意外的并发调用，
        // 避免新 continuation 覆盖仍在等回调的旧 continuation。
        guard continuation == nil else { return .unavailableOrFailed }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            guard let service = serviceProvider() else {
                resolve(.unavailableOrFailed)
                return
            }

            let items: [Any] = [attachment]
            guard canPerform(service, items) else {
                resolve(.unavailableOrFailed)
                return
            }

            retainedService = service
            service.delegate = self
            service.recipients = ["hi@ryek.ee"]
            service.subject = "Napoleon diagnostics"

            // 第三方邮件客户端可能已经打开带附件草稿，却始终不触发 delegate 回调。
            // 超时只停止等待并保留 ZIP，不把未确认状态误报为交接成功。
            confirmationTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: confirmationTimeout)
                guard !Task.isCancelled else { return }
                resolve(.unconfirmed)
            }
            perform(service, items)
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard sharingService === retainedService else { return }
        resolve(.shared)
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        guard sharingService === retainedService else { return }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            resolve(.cancelled)
        } else {
            resolve(.unavailableOrFailed)
        }
    }

    private func resolve(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        confirmationTask?.cancel()
        confirmationTask = nil
        retainedService?.delegate = nil
        retainedService = nil
        continuation.resume(returning: result)
    }
}

/// About 页诊断入口的持久展示状态。
///
/// 本对象由 `AppServices` 持有，不随 `SettingsView` 切页销毁：这样生成期间即使
/// AboutView 被重建，新视图仍会看到同一把单飞锁，不能启动第二份报告。
@MainActor
final class AboutDiagnosticsPresentation: ObservableObject {
    enum Completion {
        case handedOff(requiresManualAttachment: Bool)
        case cancelled
        case unconfirmed(URL)
        case failed(String)
    }

    @Published private(set) var selectedIssue: DiagnosticIssue = .default
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?
    @Published private(set) var requiresManualAttachment = false
    @Published private(set) var emailDraftWasCancelled = false
    @Published private(set) var unconfirmedAttachmentURL: URL?

    var isRecordingSearchDetails: Bool {
        selectedIssue == .search
    }

    private let emailComposer: EmailDraftComposer

    init(emailComposer: EmailDraftComposer? = nil) {
        self.emailComposer = emailComposer ?? EmailDraftComposer()
    }

    @discardableResult
    func selectIssue(_ issue: DiagnosticIssue) -> Bool {
        guard !isPreparing else { return false }
        selectedIssue = issue
        error = nil
        requiresManualAttachment = false
        emailDraftWasCancelled = false
        unconfirmedAttachmentURL = nil
        return true
    }

    /// MainActor 上同步完成 check-and-set，因此重建后的视图也无法穿透生成锁。
    func beginPreparation() -> Bool {
        guard !isPreparing else { return false }
        isPreparing = true
        error = nil
        requiresManualAttachment = false
        emailDraftWasCancelled = false
        unconfirmedAttachmentURL = nil
        return true
    }

    func finishPreparation(_ completion: Completion) {
        guard isPreparing else { return }
        defer { isPreparing = false }

        switch completion {
        case .handedOff(let requiresManualAttachment):
            selectedIssue = .general
            error = nil
            self.requiresManualAttachment = requiresManualAttachment
            emailDraftWasCancelled = false
            unconfirmedAttachmentURL = nil
        case .cancelled:
            error = nil
            requiresManualAttachment = false
            emailDraftWasCancelled = true
            unconfirmedAttachmentURL = nil
        case .unconfirmed(let attachment):
            error = nil
            requiresManualAttachment = false
            emailDraftWasCancelled = false
            unconfirmedAttachmentURL = attachment
        case .failed(let message):
            error = message
            requiresManualAttachment = false
            emailDraftWasCancelled = false
            unconfirmedAttachmentURL = nil
        }
    }

    static func privacyDisclosure(for issue: DiagnosticIssue, locale: Locale = .current) -> String {
        switch issue {
        case .general:
            String(
                localized: "Includes app names, Bundle IDs, window counts and IDs, permission states, hotkey events, durations, and error codes. Excludes window titles, searches, file paths, and images.",
                locale: locale
            )
        case .search:
            String(
                localized: "Adds raw search text and matching window titles. Napoleon does not separately read file paths or images, but the text itself may contain file names or paths.",
                locale: locale
            )
        case .thumbnail:
            String(
                localized: "Adds cached window images. Napoleon does not separately add search text, window titles, or file paths, but they may appear in the images. No new screenshots are taken.",
                locale: locale
            )
        }
    }

    /// 只有 sharing service 回调 `didShareItems` 才视为系统邮件交接成功。
    /// 非取消的 `didFailToShareItems` 或系统没有可用 Email service 时先进入手动附件 fallback，
    /// 然后才统一清理原始报告状态；用户取消只结束进度并保留当前 issue。
    /// 所有路径都不代表用户最终点击了 Send。
    func handOffPreparedReport(
        _ attachment: URL,
        openFallback: @MainActor (URL) -> Void,
        markHandedOff: @MainActor () -> Void
    ) async {
        guard isPreparing else { return }

        switch await emailComposer.compose(attachment: attachment) {
        case .shared:
            markHandedOff()
            finishPreparation(.handedOff(requiresManualAttachment: false))
        case .unavailableOrFailed:
            openFallback(attachment)
            markHandedOff()
            finishPreparation(.handedOff(requiresManualAttachment: true))
        case .cancelled:
            finishPreparation(.cancelled)
        case .unconfirmed:
            finishPreparation(.unconfirmed(attachment))
        }
    }
}

/// 设置窗口的「关于」页：应用名 / 图标 / 版本 + 检查更新。
///
/// 更新只做「检查」——发现新版打开 GitHub Release 页面让用户自行下载，不自动下载安装
/// （见 `UpdateChecker` 的类型注释）。
struct AboutView: View {
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var diagnostics: DiagnosticsService
    @ObservedObject var presentation: AboutDiagnosticsPresentation

    /// App 图标。
    ///
    /// **不用 `NSApp.applicationIconImage`**：Napoleon 是 `.accessory`（`LSUIElement`）App，没有
    /// Dock 图标，这个属性对 agent App 不保证返回 bundle 图标（实测拿不到，「关于」页因此一片空白）。
    /// 改为直接按名字取资产目录里的 `AppIcon`，取不到再退回 `NSWorkspace` 按 bundle 路径要图标——
    /// 后者只要 App 装在磁盘上就一定有结果。
    private static var appIcon: NSImage? {
        NSImage(named: "AppIcon")
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            identity
            Divider()
            updateSection
            Divider()
            diagnosticsSection
        }
        // 只横向撑满：纵向要报自己的自然高度，窗口才能按内容收到刚好的尺寸
        // （见 `SettingsWindowController.resizeWindow`）。写 `maxHeight: .infinity` 会让
        // `fittingSize` 报出一个被撑大的值，「关于」页底部就会留一大片空白。
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - 应用身份

    private var identity: some View {
        VStack(spacing: 8) {
            if let icon = Self.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
            }
            Text(verbatim: "Napoleon")   // App 名不翻译，同下面的 slogan
                .font(.title2.weight(.semibold))
            Text("Version \(updateChecker.currentVersion) (build \(updateChecker.currentBuild))")
                .font(.callout)
                .foregroundStyle(.secondary)
                // 版本号常被用来报问题，做成可选中复制。
                .textSelection(.enabled)
            // `verbatim:` = 不查本地化表，四种语言下都显示这句英文原文（产品 slogan，
            // 跟 App 名一样不翻译）。
            Text(verbatim: "Every window has its Waterloo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - 更新

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                statusLabel
                Spacer()
                Button {
                    Task { await updateChecker.check() }
                } label: {
                    if case .checking = updateChecker.state {
                        Text("Checking…")
                    } else {
                        Text("Check for Updates")
                    }
                }
                .disabled(updateChecker.state == .checking)
            }

            if case .available(let version, let notes, let url) = updateChecker.state {
                releaseNotes(version: version, notes: notes, url: url)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch updateChecker.state {
        case .idle:
            Label("Not checked yet", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("You are up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available(let version, _, _):
            Label("Version \(version) available", systemImage: "sparkles")
                .foregroundStyle(.blue)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        case .notConfigured:
            Label("Update source not configured", systemImage: "wrench.and.screwdriver")
                .foregroundStyle(.secondary)
        }
    }

    private func releaseNotes(version: String, notes: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
            }
            Button("Download \(version)") {
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics")
                .font(.headline)

            Picker("Issue to diagnose", selection: Binding(
                get: { presentation.selectedIssue },
                set: { newIssue in
                    guard presentation.selectIssue(newIssue) else { return }
                    diagnostics.selectIssue(newIssue)
                }
            )) {
                ForEach(DiagnosticIssue.allCases) { issue in
                    Text(issueTitle(issue)).tag(issue)
                }
            }
            .disabled(presentation.isPreparing)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: issuePrivacyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.isRecordingSearchDetails {
                Label("Recording search details", systemImage: "record.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .top, spacing: 12) {
                Button(action: prepareDiagnosticsEmail) {
                    HStack(spacing: 6) {
                        if presentation.isPreparing {
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing…")
                        } else {
                            Text("Prepare Email…")
                        }
                    }
                    .frame(width: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(presentation.isPreparing)

                diagnosticsStatus
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private func issueTitle(_ issue: DiagnosticIssue) -> LocalizedStringKey {
        switch issue {
        case .general: "General issue"
        case .search: "Search issue"
        case .thumbnail: "Thumbnail issue"
        }
    }

    private var issuePrivacyDescription: String {
        AboutDiagnosticsPresentation.privacyDisclosure(for: presentation.selectedIssue)
    }

    @ViewBuilder
    private var diagnosticsStatus: some View {
        if let error = presentation.error {
            Text(error)
                .foregroundStyle(.red)
        } else if presentation.requiresManualAttachment {
            Text("Could not attach the ZIP automatically. Add it to the email draft from Finder.")
                .foregroundStyle(.orange)
        } else if presentation.emailDraftWasCancelled {
            Text("Email draft cancelled; the ZIP will remain on this Mac for up to two hours.")
                .foregroundStyle(.secondary)
        } else if let attachment = presentation.unconfirmedAttachmentURL {
            VStack(alignment: .leading, spacing: 4) {
                Text("The email client did not confirm the draft. The ZIP will remain on this Mac for up to two hours.")
                    .foregroundStyle(.secondary)
                Button("Show ZIP in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([attachment])
                }
                .buttonStyle(.link)
            }
        } else {
            Text("Napoleon does not upload logs directly. Your email client may sync the draft and attachment. Review the email before sending.")
                .foregroundStyle(.secondary)
        }
    }

    private func prepareDiagnosticsEmail() {
        let diagnostics = diagnostics
        let presentation = presentation
        guard presentation.beginPreparation() else { return }

        Task { @MainActor [diagnostics, presentation] in
            do {
                let attachment = try await diagnostics.prepareReport()
                await presentation.handOffPreparedReport(
                    attachment,
                    openFallback: Self.openManualAttachmentFallback,
                    markHandedOff: { diagnostics.reportWasHandedOff() }
                )
            } catch {
                presentation.finishPreparation(
                    .failed(
                        String(
                            format: String(localized: "Could not prepare diagnostics: %@"),
                            error.localizedDescription
                        )
                    )
                )
            }
        }
    }

    private static func openManualAttachmentFallback(attachment: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([attachment])
        if let draftURL = URL(string: "mailto:hi@ryek.ee?subject=Napoleon%20diagnostics") {
            NSWorkspace.shared.open(draftURL)
        }
    }
}
