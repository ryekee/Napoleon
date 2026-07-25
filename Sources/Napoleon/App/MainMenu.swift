import AppKit

/// 进程的主菜单栏。
///
/// **为什么 agent App 也需要它**：`LSUIElement` App 不显示菜单栏，但 `NSApplication.sendEvent`
/// 的快捷键派发走的正是 `NSApp.mainMenu.performKeyEquivalent(_:)`——没有主菜单，标准编辑快捷键
/// 就**全部失效**。改成手写 `main()`（原来是 SwiftUI 的 `@main struct ... : App`，SwiftUI 会自动
/// 装一套标准主菜单）之后这套没了，症状是：设置窗口里 ⌘W 关不掉窗口、⌘Q 退不出 App、「关于」页
/// 那行专门做成可选中的版本号 ⌘C 复制不了。
///
/// 这里只装真正用得上的三组：App（设置/退出）、编辑（撤销/剪切/复制/粘贴/全选）、窗口（关闭/
/// 最小化）。不做「显示菜单栏」这类无意义的项——反正不显示，只为快捷键派发而存在。
///
/// 所有 action 都不设 target（`nil`），交给响应者链派发：编辑类落到当前 first responder（文本
/// 控件自带这些方法），窗口类落到 key window，`openSettings` 落到 `AppDelegate`。
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Napoleon")

        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(AppDelegate.openSettingsFromMenu),
            keyEquivalent: ","
        )
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(localized: "Quit Napoleon"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Edit"))

        // 用字符串构造的选择器是 AppKit 编辑动作的标准写法（`NSText`/`NSResponder` 上有这些方法，
        // 但没有一个统一的协议可以 `#selector` 到，所以只能按名字）。
        menu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(
            withTitle: String(localized: "Close"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(
            withTitle: String(localized: "Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        item.submenu = menu
        return item
    }
}
