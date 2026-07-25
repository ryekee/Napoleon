import AppKit
import SwiftUI

/// 设置窗口的「关于」页：应用名 / 图标 / 版本 + 检查更新。
///
/// 更新只做「检查」——发现新版打开 GitHub Release 页面让用户自行下载，不自动下载安装
/// （见 `UpdateChecker` 的类型注释）。
struct AboutView: View {
    @ObservedObject var updateChecker: UpdateChecker

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
}
