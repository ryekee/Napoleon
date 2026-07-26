import AppKit
import Combine
import SwiftUI

/// 设置窗口：一个自己托管的 `NSWindow`，顶部用 `NSToolbar`（`.preference` 样式）做分页标签栏，
/// 内容区托管 SwiftUI 的 `SettingsView`。
///
/// **为什么自己建窗口**：菜单栏改成 `NSStatusItem` 之后（见 `MenuBarController`，为了做出图标的
/// 点击态），App 里已经没有 SwiftUI `Scene`，`SettingsLink` / `@Environment(\.openSettings)` 都
/// 无从谈起，剩下的路子是调私有选择器 `showSettingsWindow:`。自己托管更确定，也彻底避开
/// 「agent App 打开设置窗口不置前」这个老问题（`show()` 里显式激活）。
///
/// **为什么标签栏是 NSToolbar 而不是 SwiftUI TabView**：见 `SettingsTab` 的类型注释——
/// `TabView` 的大图标标签栏外观是 `Settings` 场景专属的，普通窗口里会退化成没有图标的分段控件。
@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    /// 所有分页共用的窗口宽度；高度按当前页内容自适应（见 `resizeWindow`）。
    private static let contentWidth: CGFloat = 520
    /// 内容高度下限——短页面（关于）也不要缩成一条缝。
    private static let minContentHeight: CGFloat = 320
    /// 与屏幕可用高度之间保留的余量：窗口不该顶满整个屏幕。
    private static let screenMargin: CGFloat = 120

    private let navigation = SettingsNavigation()
    private let makeContent: (SettingsNavigation) -> AnyView

    /// 设置窗口显示/关闭时回调（`true` = 已显示）。调用方据此请求一次窗口列表刷新——
    /// 见 `applyActivationPolicy` 说明：策略变化不产生任何系统通知。
    var onVisibilityChanged: ((Bool) -> Void)?

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private var cancellables: Set<AnyCancellable> = []

    init(makeContent: @escaping (SettingsNavigation) -> AnyView) {
        self.makeContent = makeContent
        super.init()

        // 分页切换时同步工具栏选中态与窗口高度。
        navigation.$tab
            .receive(on: RunLoop.main)
            .sink { [weak self] tab in
                self?.window?.toolbar?.selectedItemIdentifier = tab.toolbarItemIdentifier
                self?.resizeWindow(for: tab, animated: true)
            }
            .store(in: &cancellables)
    }

    /// 显示设置窗口：首次调用建窗，之后复用同一个（不会开出第二个）。
    ///
    /// `NSApp.activate` 必须有——Napoleon 平时是 `.accessory`，进程不参与前台切换，
    /// 只 `makeKeyAndOrderFront` 的话窗口会垫在当前 App 后面，用户以为「点了没反应」。
    func show() {
        if window == nil {
            buildWindow()
        }
        // 先切策略再激活：`.regular` 之后这个进程才算「有前台身份」的普通 App，激活与置前才
        // 按常规窗口的方式生效。
        applyActivationPolicy(settingsVisible: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChanged?(true)
    }

    /// 按「设置窗口是否可见」切换进程的 activation policy。
    ///
    /// 平时 Napoleon 是 `.accessory`（对应 Info.plist 的 `LSUIElement`）：没有 Dock 图标、
    /// 不参与前台切换——这正是一个菜单栏工具该有的样子。但设置窗口打开时它就是一扇**普通窗口**，
    /// 用户理应能像对待任何 App 一样对待它：Dock 里有图标、能用切换器切回来、菜单栏显示菜单。
    /// `.accessory` 下这些全都不成立，而且 Napoleon 自己的窗口枚举只收 `activationPolicy ==
    /// .regular` 的 App（见 `WindowEnumerator`），所以它自己的设置窗口连自己的切换器都进不去。
    ///
    /// 因此窗口显示期间临时切成 `.regular`，关闭后切回 `.accessory`——这是菜单栏 App 需要展示
    /// 真实窗口时的标准做法。**策略变化不会产生任何系统通知**（既不是 launch 也不是 terminate），
    /// 所以两个方向都要显式请求一次窗口列表刷新，否则设置窗口要么进不了列表，要么关掉之后还
    /// 赖在列表里。
    private func applyActivationPolicy(settingsVisible: Bool) {
        NSApp.setActivationPolicy(settingsVisible ? .regular : .accessory)
        guard settingsVisible else { return }

        // Dock tile 的图标要**显式喂**给 AppKit。运行时才从 `.accessory` 提升上来的进程，
        // LaunchServices 当初是按「无图标的 agent」注册的，Dock 这时新建的 tile 不会回头去
        // bundle 里取 `CFBundleIconName`——结果就是一个空白图标。（同一个原因也让
        // `NSApp.applicationIconImage` 在本 App 里取不到图，见 `AboutView.appIcon`。）
        // 资产目录里的 `AppIcon` 是可靠来源，这里直接赋给它；重复赋值无害。
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        applyActivationPolicy(settingsVisible: false)
        onVisibilityChanged?(false)
    }

    private func buildWindow() {
        let hosting = NSHostingView(rootView: makeContent(navigation))
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.contentWidth,
                height: Self.minContentHeight   // 占位，建窗后立刻按内容自适应（见下面的 resizeWindow）
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false // 关窗后保留实例，下次直接复用
        // 记住窗口位置：`setFrameAutosaveName` 只负责**保存**，恢复必须显式 `setFrameUsingName`；
        // 没有存档（首次运行）时才居中。之前写了 autosave 却从不恢复、后面还紧跟一个 `center()`，
        // 等于每次切页往 defaults 写一条永远用不上的记录。
        window.setFrameAutosaveName("NapoleonSettingsWindow")
        if !window.setFrameUsingName("NapoleonSettingsWindow") {
            window.center()
        }

        let toolbar = NSToolbar(identifier: "NapoleonSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = navigation.tab.toolbarItemIdentifier
        window.toolbar = toolbar
        // `.preference` 就是系统设置那种「工具栏即标签栏」的样式：图标在上、标签在下、居中。
        window.toolbarStyle = .preference

        self.hostingView = hosting
        self.window = window
        // 建窗时用的是占位高度，这里按首页内容立刻定尺寸（不动画——窗口还没显示出来）。
        // 注意不要在这之后再 `center()`：那会抹掉上面刚恢复的用户窗口位置。
        resizeWindow(for: navigation.tab, animated: false)
    }

    /// 窗口标题跟随当前页（系统设置也是这个行为）。
    private func updateTitle(for tab: SettingsTab) {
        window?.title = tab.title
    }

    /// 按当前页**内容的实际高度**调整窗口，保持标题栏位置不动（AppKit 的 y 原点在下，改高度要
    /// 同时挪 origin，否则窗口会「从底部长出来」，视觉上顶栏在跳）。
    ///
    /// 高度取自 `NSHostingView.fittingSize`（SwiftUI 算出的理想高度）而不是每页写死的常量：
    /// 写死的数字一定会过期——加一个设置项就得记得同步改，改漏了要么页面被截断（内容够不着）
    /// 要么底部留一大片空白。上下用 `minHeight`/屏幕可用高度夹一下，防止极端值。
    private func resizeWindow(for tab: SettingsTab, animated: Bool) {
        guard let window, let hostingView else { return }
        updateTitle(for: tab)

        // 先让 SwiftUI 按新页面重新布局，再问它高度，否则拿到的是上一页的尺寸。
        hostingView.layoutSubtreeIfNeeded()

        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let maxContentHeight = max(Self.minContentHeight, available - Self.screenMargin)
        // 读 `fittingSize`（`NSHostingView` 没有 UIKit 那种 `sizeThatFits(_:)`）。它是缓存值，
        // 「是否已随挂起的 SwiftUI 更新失效」不在文档保证之内，所以上面先 `layoutSubtreeIfNeeded()`
        // 强制冲刷一次。真出现没冲刷到的情况，最坏后果只是这一次按上一页的高度定尺寸（页面偏高或
        // 偏矮），下次切页即恢复——不会出错，也不会卡住。
        let fitted = hostingView.fittingSize.height
        let height = min(max(fitted, Self.minContentHeight), maxContentHeight)

        let contentSize = NSSize(width: Self.contentWidth, height: height)
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.setFrame(frame, display: true, animate: animated)
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    /// 可选中的项——正是这个方法让工具栏项获得「当前页」的高亮态，标签栏才成立。
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab.tab(for: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectTab(_:))
        return item
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab.tab(for: sender.itemIdentifier) else { return }
        navigation.tab = tab
    }
}
