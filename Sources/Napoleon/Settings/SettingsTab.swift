import AppKit
import SwiftUI

/// 设置窗口的分页。
///
/// 之所以不是 SwiftUI `TabView` + `.tabItem`：那套只有放在 SwiftUI 的 `Settings` 场景里才会被
/// 渲染成 macOS 系统设置那种「大图标 + 标签」的顶部标签栏；放在我们自己托管的普通窗口里，它退化
/// 成一条普通的分段控件（图标全丢），这正是改用 `NSStatusItem` 之后出现的回归。现在改由窗口的
/// `NSToolbar`（`toolbarStyle = .preference`）来做标签栏——这本来就是 AppKit 里做设置窗口的
/// 标准做法，外观与系统设置一致。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, permissions, about

    var id: String { rawValue }

    /// 工具栏项标题。用 `String(localized:)` 而不是 SwiftUI 的 `LocalizedStringKey`——这些字符串
    /// 要交给 `NSToolbarItem.label`（纯 `String`），不经过 SwiftUI 的本地化通道。
    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .appearance: return String(localized: "Appearance")
        case .permissions: return String(localized: "Permissions")
        case .about: return String(localized: "About")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    var toolbarItemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("settings.tab.\(rawValue)")
    }

    static func tab(for identifier: NSToolbarItem.Identifier) -> SettingsTab? {
        allCases.first { $0.toolbarItemIdentifier == identifier }
    }
}

/// 当前选中的分页。工具栏点击写它，SwiftUI 侧观察它决定渲染哪一页。
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}
