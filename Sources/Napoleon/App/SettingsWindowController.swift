import AppKit
import Combine
import NapoleonCore
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

    /// 设置窗口显示/关闭时回调（`visible == true` = 已显示）。调用方据此请求一次窗口列表刷新——
    /// 见 `applyActivationPolicy` 说明：策略变化不产生任何系统通知。
    ///
    /// `closingWindowID` 只在关闭时非 `nil`，是这扇窗口的 `CGWindowID`。调用方要拿它**同步**把窗口
    /// 从列表里摘掉（`WindowStore.forget(windowID:)`），不能只靠刷新：刷新是 200ms 的 debounce，
    /// 这段空窗期里窗口仍在列表中且句柄仍然有效，被选中就会把 Napoleon 提到一个不存在的窗口上。
    var onVisibilityChanged: ((_ visible: Bool, _ closingWindowID: WindowID?) -> Void)?

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
        NSApp.activate(ignoringOtherApps: true)   // accessory App 自我激活是允许的
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChanged?(true, nil)
    }

    /// 切换进程的 activation policy——**只为了 Dock 图标**，条件是「设置窗口正处于前台」。
    ///
    /// 平时 Napoleon 是 `.accessory`（对应 Info.plist 的 `LSUIElement`）：没有 Dock 图标、
    /// 不参与前台切换——菜单栏工具该有的样子。设置窗口在前台时它是一扇普通窗口，Dock 里理应有
    /// 图标，所以那时提升为 `.regular`。
    ///
    /// **不能一直保持 `.regular`**（最初就是这么写的，导致了一个严重回归）：普通 App 在自己不
    /// 处于前台时无权激活别的 App（macOS 14 协作式激活的防抢焦点规则），而 Napoleon 恰恰总是在
    /// 后台完成激活——切换器会因此彻底失效，目标窗口只升到「次前台」。所以绑定的是**前台状态**
    /// 而不是「窗口是否存在」：窗口失去 key、或被 `WindowFocuser` 切去别的 App 时都会降回
    /// `.accessory`。设置窗口出现在切换器列表里则与策略无关，由 `WindowEnumerator` 无条件纳入
    /// 自身进程来保证。
    ///
    /// **策略变化不产生任何系统通知**（既不是 launch 也不是 terminate），所以窗口开/关时要显式
    /// 请求一次窗口列表刷新，否则设置窗口要么进不了列表，要么关掉之后还赖在列表里。
    private func applyActivationPolicy(settingsVisible: Bool) {
        NSApp.setActivationPolicy(settingsVisible ? .regular : .accessory)
        guard settingsVisible else { return }

        // Dock tile 的图标要**显式喂**给 AppKit。运行时才从 `.accessory` 提升上来的进程，
        // LaunchServices 当初是按「无图标的 agent」注册的，Dock 这时新建的 tile 不会回头去
        // bundle 里取 `CFBundleIconName`——结果就是一个空白图标。（同一个原因也让
        // `NSApp.applicationIconImage` 在本 App 里取不到图，见 `AboutView.appIcon`。）
        // 兜底跟 `AboutView` 用同一条：`NSImage(named:)` 不保证拿得到，而这里一旦拿不到就
        // 什么都不做的话，留下的正是这段代码要修的那个空白 Dock 图标。
        NSApp.applicationIconImage = Self.appIcon
    }

    /// App 图标的可靠来源：优先资产目录，退回 bundle 自己的图标。与 `AboutView.appIcon` 同源。
    static var appIcon: NSImage {
        NSImage(named: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        applyActivationPolicy(settingsVisible: false)
        // 把 `CGWindowID` 一起交出去，让调用方同步摘掉它——只请求刷新会留下 200ms 的幽灵窗口，
        // 见 `onVisibilityChanged` 的文档。`windowNumber` 在窗口关闭前取，关闭后就取不到了。
        let closingID = window.flatMap { WindowID(exactly: $0.windowNumber) }
        onVisibilityChanged?(false, closingID)
    }

    /// 设置窗口成为前台（菜单栏打开、Dock 点击、或从切换器切回来）——提升为 `.regular` 拿回
    /// Dock 图标。切换器把它切回来时走的是 `SelfFrontProcess` 的私有前置，激活后这个回调随之
    /// 触发，Dock 图标因此自然恢复。
    func windowDidBecomeKey(_ notification: Notification) {
        applyActivationPolicy(settingsVisible: true)
    }

    /// 设置窗口失去 key——降回 `.accessory`。
    ///
    /// 少了这一条，「用户不关设置窗口、直接用系统 Cmd+Tab 或点 Dock 切到别的 App」这条路径会让
    /// Napoleon 停在「`.regular` 且不在前台」——正是 `applyActivationPolicy` 文档里标为严重回归的
    /// 那个状态（普通 App 不在前台时无权激活别的 App，切换器失效）。`WindowFocuser` 在切走时的
    /// 那次降级只覆盖「经由 Napoleon 切换器切走」，覆盖不到系统自己的切换。
    func windowDidResignKey(_ notification: Notification) {
        applyActivationPolicy(settingsVisible: false)
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

        // 先把宽度钉成窗口的实际宽度再量高度。`fittingSize` 给的是 SwiftUI 的**理想**尺寸，
        // 而窗口宽度是固定的 520：当某段说明文字的理想宽度超过 520（换个语言就可能发生），
        // SwiftUI 报的是「一行放得下」时的高度，真正排版时会换行、变高——照理想值定尺寸就会
        // 把底部内容截掉。先给一个 520 宽的 frame，布局便是在真实宽度下算的。
        hostingView.frame.size.width = Self.contentWidth
        // 再让 SwiftUI 按新页面重新布局，然后才问它高度，否则拿到的是上一页的尺寸。
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
