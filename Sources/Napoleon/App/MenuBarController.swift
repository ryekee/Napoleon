import AppKit
import Combine

/// 菜单栏图标与菜单。
///
/// **为什么用 `NSStatusItem` 而不是 SwiftUI 的 `MenuBarExtra`**：需求是图标有「点击态」
/// （菜单展开时用 `command.square.fill`）。`MenuBarExtra` 没有暴露菜单开合状态，做不到；
/// `NSStatusItem` + `NSMenuDelegate` 的 `menuWillOpen`/`menuDidClose` 正好是这个信号。
/// 顺带解决了 `SettingsLink`/`TapGesture` 在菜单跟踪循环里不保证派发的问题——现在「设置…」
/// 是普通的 `NSMenuItem` action，行为确定。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// 缺权限时的警示图标点数（SF Symbol 需要显式给尺寸；自定义模板图的尺寸已经烘进资产里）。
    private static let symbolPointSize: CGFloat = 15

    private let statusItem: NSStatusItem
    private let permissions: PermissionsManager
    private let settings: SettingsStore
    private let onOpenSettings: () -> Void

    private var cancellables: Set<AnyCancellable> = []

    init(
        permissions: PermissionsManager,
        settings: SettingsStore,
        onOpenSettings: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = String(localized: "Napoleon — window switcher")

        updateIcon()

        // 权限状态变化要立刻反映到图标上（缺辅助功能时显示警示，见 `updateIcon`）。
        // `PermissionsManager` 是 `ObservableObject`，`objectWillChange` 在属性**将要**变化时
        // 触发，所以放到下一个 runloop tick 再读，读到的才是新值。
        // 用 `DispatchQueue.main` 而不是 `RunLoop.main`：后者只在 `.default` 模式投递，菜单展开
        // 期间（`eventTracking` 模式）不会送达——权限恰好在菜单开着时恢复，菜单里那行警示会消失
        // 而图标上的警示三角要等菜单收起才换回来。`PermissionsManager` 的轮询 timer 出于同样的
        // 原因挂在 `.common` 模式，这里保持一致。
        permissions.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    // MARK: - 图标

    /// 两态：缺关键权限 → 警示三角；平时 → Napoleon 剪影（`MenuBarIcon` 资产，模板图）。
    ///
    /// **点击态由系统负责**：模板图在状态项被高亮（菜单展开）时会被 AppKit 自动反色并加上高亮
    /// 底，这本身就是清晰的按下反馈。之前用 `command.square` / `command.square.fill` 手动切两张
    /// 图，是因为 SF Symbol 的实心/空心变体天然成对；换成实心剪影后不存在「空心版」，再手动切
    /// 图既没有意义也会跟系统高亮打架，所以交回给系统。
    ///
    /// 权限警示优先——App 此时根本不能工作，这个信息比外观重要得多。
    private func updateIcon() {
        guard permissions.isFullyOperational else {
            let configuration = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .regular)
            let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            warning?.isTemplate = true
            statusItem.button?.image = warning
            return
        }

        // 资产目录里已经标了 `template-rendering-intent: template`，这里再显式置一次
        // `isTemplate`，避免将来有人改了资产属性却不知道菜单栏依赖它。
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Napoleon"
        statusItem.button?.image = icon
    }

    // MARK: - NSMenuDelegate

    /// 每次展开前重建菜单——快捷键绑定、权限状态都可能已经变了，重建比维护增量更新简单可靠
    /// （菜单只有几项，重建成本可以忽略）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !permissions.accessibilityTrusted {
            menu.addItem(actionItem(
                title: String(localized: "⚠️ Accessibility permission required…"),
                action: #selector(openAccessibilitySettings)
            ))
            menu.addItem(.separator())
        } else if !permissions.screenRecordingGranted {
            menu.addItem(actionItem(
                title: String(localized: "⚠️ Screen Recording permission required (thumbnails)…"),
                action: #selector(openScreenRecordingSettings)
            ))
            menu.addItem(.separator())
        }

        // 当前绑定一眼可见（菜单栏 App 最常被问的「我设的是什么键来着」）。信息项，不可点。
        menu.addItem(infoItem(
            String(
                format: String(localized: "All windows: %@"),
                settings.allWindowsChord.displayString
            )
        ))
        menu.addItem(infoItem(
            String(
                format: String(localized: "Current app: %@"),
                settings.currentAppChord.displayString
            )
        ))

        menu.addItem(.separator())

        let settingsItem = actionItem(
            title: String(localized: "Settings…"),
            action: #selector(openSettings)
        )
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = actionItem(
            title: String(localized: "Quit Napoleon"),
            action: #selector(quit)
        )
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    // 不再需要 `menuWillOpen`/`menuDidClose` 切图标——按下态由系统对模板图的高亮反色负责
    // （见 `updateIcon`）。

    // MARK: - 菜单项构造

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// 只读信息项：`action == nil` 会让 AppKit 自动把它画成灰色不可选。
    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func openAccessibilitySettings() {
        permissions.openAccessibilitySettings()
    }

    @objc private func openScreenRecordingSettings() {
        permissions.openScreenRecordingSettings()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
