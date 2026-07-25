import AppKit

/// 进程入口。
///
/// **为什么是 AppKit 而不是 SwiftUI `App`**：菜单栏图标需要「点击态」（菜单展开时换成
/// `command.square.fill`），SwiftUI 的 `MenuBarExtra` 没有暴露菜单开合状态，只能用
/// `NSStatusItem` + `NSMenuDelegate`（见 `MenuBarController`）。菜单栏一旦自己管，App 里就
/// 不再需要任何 SwiftUI `Scene`——设置窗口也改为自己托管同一份 `SettingsView`
/// （见 `SettingsWindowController`）。SwiftUI 仍然是设置界面的实现，只是不再负责 App 骨架。
///
/// 显式写 `main()`（而不是 `@NSApplicationMain`）是为了让启动顺序一目了然：建 App → 装
/// delegate → 定活动策略 → run。`.accessory` 与 Info.plist 的 `LSUIElement` 一致：无 Dock
/// 图标、不参与常规前台切换（设置窗口靠 `NSApp.activate` 显式置前）。
@main
struct NapoleonMain {
    static func main() {
        let app = NSApplication.shared
        // delegate 必须被强持有到进程结束——`NSApplication.delegate` 是 weak 的。
        app.delegate = Self.delegate
        // 主菜单不会显示（agent App 没有菜单栏），但**快捷键派发依赖它**——没有它设置窗口里
        // ⌘W/⌘Q/⌘C/⌘A 全部失效。见 `MainMenu`。
        app.mainMenu = MainMenu.make()
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static let delegate = AppDelegate()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fix Y4: NapoleonTests is app-hosted, so this method also runs during `xcodebuild test`.
        // Without this guard it would install a REAL global CGEventTap (swallowing Cmd+Tab system-wide
        // for the duration of the test run) and start the Accessibility observer inside the test
        // process, with behavior depending on the machine's TCC state. Bail out early so the test
        // process stays clean — none of the wiring below is needed for XCTest to run.
        let isRunningTests = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if isRunningTests {
            return
        }

        AppServices.shared.start()
    }

    /// 主菜单「设置…」（⌘,）的目标——不设 target 的菜单项经响应者链走到 App delegate。
    ///
    /// 菜单动作一定在主线程派发，但 `@objc` 方法本身不带 actor 隔离信息，用
    /// `assumeIsolated` 把这个事实告诉类型系统（与本项目其它 AppKit 回调同一套写法）。
    @objc func openSettingsFromMenu() {
        MainActor.assumeIsolated { AppServices.shared.showSettings() }
    }
}
