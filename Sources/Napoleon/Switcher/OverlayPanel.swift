import AppKit

/// 切换器浮层的窗口容器（spec §7.1，R5/R6）。**只负责「一个不抢焦点、全屏/多屏都能显示的
/// 容器」**——内容视图由调用方（TEMP：`NapoleonApp.swift`；正式：Task 19 `SwitcherController`）
/// 通过 `setContentView(_:)` 注入，键盘输入完全由 Task 19 的 CGEventTap 喂入，本类型不参与。
///
/// **不抢焦点（核心约束）**：`.nonactivatingPanel` styleMask + 覆写 `canBecomeKey`/
/// `canBecomeMain` 恒为 `false`——两者缺一不可：前者只是「允许」面板在不激活 App 的前提下显示，
/// 真正杜绝它被系统提升为 key/main window（进而在用户松开 Cmd 时把焦点错误地交给浮层而不是
/// 目标窗口）靠的是这两个覆写。这是 Spotlight/Alfred 同款模式——key window 状态与 App 激活
/// 是两件独立的事，这里两者都不要。显示时也必须用 `orderFrontRegardless()`，**不能**用
/// `makeKeyAndOrderFront`（后者会尝试激活/成为 key window）。
///
/// **全屏 App 的 Space 上可见**：默认 window 在全屏 App 独占的 Space 上不显示；
/// `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` +
/// `level = .popUpMenu` 让浮层能跟着当前 Space 走并浮在全屏内容之上。`.stationary` 防止浮层
/// 被 Mission Control/Space 切换动画一起搬走。
///
/// **多显示器**：显示前按 `NSEvent.mouseLocation` 落在哪个 `NSScreen.frame` 内定位到「鼠标所在
/// 屏」（找不到则退回 `.main`），在该屏 `visibleFrame` 内居中；并把 `contentView.layer.contentsScale`
/// 设成该屏的 `backingScaleFactor`，避免两块 scale 不同的屏之间缩略图/文字发糊。
///
/// **预创建复用**：调用方应只持有一个实例，反复 `present`/`dismiss`，不要每次触发都新建
/// `NSPanel`——新建/销毁 `NSWindow` 有不必要的开销，且会打断复用同一 CALayer 带来的
/// 视觉连续性（Task 18 的内容视图淡入/高亮态过渡）。
@MainActor
final class OverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        worksWhenModal = true
    }

    /// 松开 Cmd 时的焦点终点必须是目标窗口，不能是这个浮层——所以浮层永远不能成为
    /// key/main window。键盘输入全部由 Task 19 的 CGEventTap 直接喂给 Controller。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 把浮层内容视图设为 `view`（Task 19 传入真正的 `SwitcherView`；本任务 TEMP 传占位视图）。
    func setContentView(_ view: NSView) {
        contentView = view
    }

    /// 在鼠标所在屏居中显示浮层：定位鼠标屏 → 设 frame → 按该屏 backing scale 设
    /// `contentView.layer.contentsScale` → `orderFrontRegardless()` 显示但不激活 App。
    func present(contentSize: CGSize) {
        let screen = Self.screenUnderMouse()

        setContentSize(contentSize)
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - contentSize.width / 2,
            y: visible.midY - contentSize.height / 2
        )
        setFrameOrigin(origin)

        contentView?.wantsLayer = true
        contentView?.layer?.contentsScale = screen.backingScaleFactor

        orderFrontRegardless()
    }

    /// 隐藏浮层。面板本身不销毁，供下次 `present` 复用。
    func dismiss() {
        orderOut(nil)
    }

    /// 鼠标当前所在的 `NSScreen`——遍历 `NSScreen.screens` 找 `frame` 包含
    /// `NSEvent.mouseLocation` 的那一块；理论上鼠标必落在某块屏内，找不到（如显示器配置
    /// 刚变化的过渡瞬间）时退回 `.main`，再退回第一块屏兜底，保证永远有一个非 nil 结果。
    private static func screenUnderMouse() -> NSScreen {
        let location = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}
