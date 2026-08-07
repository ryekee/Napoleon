import NapoleonCore
import SwiftUI

/// 设置页里的文字操作按钮统一为同一外框尺寸；图标按钮、快捷键录制器等专用控件不在此范围。
struct SettingsActionButton<Label: View>: View {
    private let action: () -> Void
    private let label: Label

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity)
        }
        .frame(width: 140)
        .controlSize(.regular)
    }
}

/// 菜单栏 App 的设置界面。
///
/// 直接读写 `AppServices.shared` 的几个 `ObservableObject`（设置/权限/登录项/更新检查）——它们
/// 是进程级单例，界面只是它们的一个视图，不持有额外状态。改动即时持久化（`SettingsStore` 的
/// `didSet` 写 `UserDefaults`），需要立刻推给运行中子系统的（快捷键绑定、缩略图缓存上限）在下面
/// 各自的 `onChange` 里显式调用 `AppServices` 的接线方法；只影响下次呼出的（卡片尺寸/标题/明暗/
/// 显示延迟/搜索范围）不需要任何推送——`SwitcherController` 每次触发都现读设置。
///
/// **分页由窗口的 `NSToolbar` 驱动**（`navigation.tab`），本视图只负责渲染当前那一页——原因见
/// `SettingsTab` 的类型注释：SwiftUI `TabView` 的大图标标签栏是 `Settings` 场景专属外观，我们
/// 自己托管的窗口里得用 `NSToolbar` 才有一样的观感。
struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var diagnostics: DiagnosticsService
    @ObservedObject var aboutDiagnosticsPresentation: AboutDiagnosticsPresentation

    /// 「立即重启」失败时的原因（`nil` = 没失败过）。见 `relaunch()`。
    @State private var relaunchError: String?

    /// 缩略图缓存上限的可选档位（字节）。做成固定档位而不是自由输入——这是个性能旋钮，
    /// 精确到字节没有意义，档位能防止用户填出 0 或者 4GB 这种极端值。
    private static let cacheOptions: [(label: String, bytes: Int)] = [
        ("16 MB", 16 * 1024 * 1024),
        ("32 MB", 32 * 1024 * 1024),
        ("64 MB", 64 * 1024 * 1024),
        ("128 MB", 128 * 1024 * 1024)
    ]

    var body: some View {
        ScrollView {
            Group {
                switch navigation.tab {
                case .general: generalTab
                case .appearance: appearanceTab
                case .permissions: permissionsTab
                case .about:
                    AboutView(
                        updateChecker: updateChecker,
                        diagnostics: diagnostics,
                        presentation: aboutDiagnosticsPresentation
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollBounceBehavior(.basedOnSize)
        // 同 `AboutView`：只横向撑满，纵向报自然高度，让窗口按内容自适应。
        .frame(maxWidth: .infinity)
        .onAppear { refreshLiveState() }
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section("Hotkeys") {
                LabeledContent("Switch all windows") {
                    HotkeyRecorderView(
                        chord: $settings.allWindowsChord,
                        conflictingChord: settings.currentAppChord
                    ) { recording in
                        AppServices.shared.setHotkeyRecording(recording)
                    }
                    .frame(width: 140, height: 24)
                }
                LabeledContent("Switch windows of current app") {
                    HotkeyRecorderView(
                        chord: $settings.currentAppChord,
                        conflictingChord: settings.allWindowsChord
                    ) { recording in
                        AppServices.shared.setHotkeyRecording(recording)
                    }
                    .frame(width: 140, height: 24)
                }
                Text("Click, then press a new combination. It must include ⌘/⌃/⌥. Press Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    SettingsActionButton {
                        settings.resetHotkeysToDefaults()
                    } label: {
                        Text("Restore Defaults")
                    }
                    .disabled(settings.hotkeysAreDefault)
                }
            }
            // 绑定改变后立刻推给运行中的事件 tap（持久化由 SettingsStore 自己完成）。
            .onChange(of: settings.allWindowsChord) { AppServices.shared.applyChords() }
            .onChange(of: settings.currentAppChord) { AppServices.shared.applyChords() }

            Section("Scope") {
                Toggle("Include windows from other desktops", isOn: Binding(
                    get: { settings.scope.includeOtherSpaces },
                    set: { settings.scope.includeOtherSpaces = $0 }
                ))
                Text("When off, only windows on the current desktop and full-screen apps are listed. Desktop windows always appear while you are in a full-screen space, so you can switch back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Include minimized windows", isOn: Binding(
                    get: { settings.scope.includeMinimized },
                    set: { settings.scope.includeMinimized = $0 }
                ))
                Toggle("Include windows of hidden apps", isOn: Binding(
                    get: { settings.scope.includeHiddenApps },
                    set: { settings.scope.includeHiddenApps = $0 }
                ))
            }

            Section("Search") {
                Toggle("Match Chinese names by Pinyin", isOn: $settings.pinyinSearchEnabled)
                Text("Find localized app and window names by typing Pinyin — “f” matches “访达”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Interface language", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                // 语言在进程启动时就已协商完毕（`AppleLanguages` 是 Foundation 启动读的键），
                // 已加载的字符串目录不会重新协商，所以必须重启——如实告诉用户，并给一键重启。
                if languageNeedsRestart {
                    HStack {
                        Text("Restart Napoleon to apply the new language.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        SettingsActionButton(action: relaunch) {
                            Text("Relaunch Now")
                        }
                    }
                }
                if let relaunchError {
                    Text("Could not relaunch: \(relaunchError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.requiresApproval {
                    Text("Approve Napoleon in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = loginItem.lastError {
                    Text("Could not change this setting: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 外观

    private var appearanceTab: some View {
        Form {
            Section("Overlay") {
                Toggle("Group windows by application", isOn: $settings.groupWindowsByApplication)
                Text("Applies to the all-windows switcher. The current-app shortcut always lists individual windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Card size", selection: $settings.cardSize) {
                    ForEach(CardSizeOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show window titles", isOn: $settings.showWindowTitle)
                Text("When off, cards show only the app name and become more compact.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Match system appearance", isOn: $settings.followSystemAppearance)
                Text("When off, the overlay is always dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display delay") {
                Slider(
                    value: Binding(
                        get: { Double(settings.showDelayMs) },
                        set: { settings.showDelayMs = Int($0.rounded()) }
                    ),
                    in: 0...500,
                    step: 25
                ) {
                    Text("Delay")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("500")
                }
                LabeledContent("Current", value: "\(settings.showDelayMs) ms")
                Text("How long to hold the hotkey before the overlay appears. Release sooner and Napoleon switches straight to the previous window, with no overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Thumbnails") {
                Picker("Cache limit", selection: Binding(
                    get: { settings.thumbnailMaxCacheBytes },
                    set: { settings.thumbnailMaxCacheBytes = $0 }
                )) {
                    ForEach(Self.cacheOptions, id: \.bytes) { option in
                        Text(option.label).tag(option.bytes)
                    }
                }
                .onChange(of: settings.thumbnailMaxCacheBytes) {
                    AppServices.shared.thumbnails.setMaxCacheBytes(settings.thumbnailMaxCacheBytes)
                }
                Text("A larger cache keeps more thumbnails ready when you switch back and forth, at the cost of memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 权限

    private var permissionsTab: some View {
        Form {
            Section("Accessibility (required)") {
                permissionRow(
                    granted: permissions.accessibilityTrusted,
                    grantedText: "Granted",
                    missingText: "Not granted — Napoleon cannot work",
                    action: { permissions.openAccessibilitySettings() }
                )
                Text("Used to intercept hotkeys and to enumerate and focus windows. Restart Napoleon after granting it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Screen Recording (optional)") {
                permissionRow(
                    granted: permissions.screenRecordingGranted,
                    grantedText: "Granted",
                    missingText: "Not granted — cards show app icons only",
                    action: { permissions.openScreenRecordingSettings() }
                )
                Text("Used to capture window thumbnails and to enumerate windows on other desktops. The switcher still works without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !permissions.screenRecordingGranted {
                    SettingsActionButton {
                        permissions.requestScreenRecordingAccess()
                    } label: {
                        Text("Request Access")
                    }
                }
            }

            Section {
                Text("macOS 15 and later re-asks for Screen Recording access periodically. If thumbnails disappear one day, check here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(
        granted: Bool,
        grantedText: String,
        missingText: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(granted ? grantedText : missingText)
            Spacer()
            SettingsActionButton(action: action) {
                Text("Open System Settings")
            }
        }
    }

    /// 界面出现时刷新那些「系统才是事实来源」的状态——权限可能在设置窗口关着的时候被改过，
    /// 登录项也可能被用户直接在系统设置里关掉。
    private func refreshLiveState() {
        permissions.refresh()
        loginItem.refresh()
    }

    // MARK: - 语言切换需要重启

    /// 所选语言是否与**本进程启动时**的选择不同——不同就说明改过但还没重启，要提示。
    ///
    /// 曾经试图比较「本进程协商出的语言」与「系统首选语言」，那是错的：前者只可能是我们支持的
    /// 四种语言之一，后者是任意系统语言标签，在法语/韩语等系统上两者恒不相等，用户一打开设置就
    /// 看到一条永远消不掉、点了也没用的「需要重启」横幅。跟启动值比语义明确（「你改过吗」），
    /// 重启后天然相等，提示自动消失。
    private var languageNeedsRestart: Bool {
        settings.appLanguage != settings.launchLanguage
    }

    /// 重启 App：先请系统开一个新实例，**确认起来了**再终止当前实例——顺序反了或者不看错误，
    /// 都会留下「旧实例已死、新实例没起来」的空窗。Napoleon 是没有 Dock 图标的 agent，真出现
    /// 空窗用户完全看不出发生了什么（菜单栏图标也一起消失），只能自己回 Finder 重新打开。
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                guard error == nil, app != nil else {
                    // 起不来（App 被改名/移动、被系统策略拒绝、translocation 等）——保持运行并
                    // 把原因显示出来，绝不在这种情况下自杀。
                    relaunchError = error?.localizedDescription ?? String(localized: "Could not start a new instance")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
