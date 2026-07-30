import AppKit
import NapoleonCore
import QuartzCore

/// Shared visual constants for the switcher grid — kept in one place so `SwitcherView`'s
/// column-count/content-size math and `WindowCardLayer`'s internal sublayer geometry can never
/// drift apart from each other.
enum SwitcherMetrics {
    /// Inset between the card's own edge and the thumbnail box on every side.
    static let cardPadding: CGFloat = 8
    /// Gap between the thumbnail box and the label strip.
    ///
    /// The name says "top" because the arithmetic below reads top-down, but on screen the label
    /// strip sits **above** the thumbnail — see the coordinate-system note in `WindowCardLayer`'s
    /// header doc. Every constant in this enum is a distance, not a direction, so the layout math
    /// is unaffected; only the prose would mislead you.
    static let titleTopGap: CGFloat = 6
    /// Height of the primary (app name) label line — task UI-Tweak: two-line card labels, app
    /// name is now the primary/larger line.
    static let appNameHeight: CGFloat = 16
    /// Vertical gap between the app-name line and the window-title line (which renders *above* it
    /// on screen — same flipped-geometry caveat as `titleTopGap`).
    static let labelLineGap: CGFloat = 2
    /// Height of the secondary (window title) label line — smaller/dimmer than `appNameHeight`,
    /// what distinguishes windows of the same multi-window app from each other.
    static let titleHeight: CGFloat = 14
    /// Gap between adjacent cards, both axes.
    static let cardSpacing: CGFloat = 16
    /// Inset between the `NSVisualEffectView` container edge and the card grid.
    static let containerPadding: CGFloat = 20
    static let containerCornerRadius: CGFloat = 36
    static let cardCornerRadius: CGFloat = 18
    static let selectionExpansion: CGFloat = 4
    static let selectionCornerRadius: CGFloat = cardCornerRadius + selectionExpansion
    static let thumbnailCornerRadius: CGFloat = 10
    static let badgeSize: CGFloat = 24
    static let badgeCornerRadius: CGFloat = 6
    static let fadeInDuration: CFTimeInterval = 0.15

    /// Height of the display-only search bar at the top of the overlay (task UI-Tweak §2) —
    /// shows the controller's current query string; renders text only, never becomes first
    /// responder (keyboard input still arrives via the `CGEventTap`, not this bar).
    static let searchBarHeight: CGFloat = 28
    /// Clear air between the header controls and the card grid. The selected card expands 4pt
    /// beyond its normal bounds, so 12pt leaves an actual 8pt visual gap below the header.
    static let headerGridSpacing: CGFloat = 12
    static let searchTextHeight: CGFloat = 18
    /// Horizontal inset between the search bar's own edges and its text.
    static let searchBarHorizontalInset: CGFloat = 14
    static let searchBarFontSize: CGFloat = 13
    static let groupingButtonSize: CGFloat = 28
    static let groupingButtonTrailingInset: CGFloat = 12
    /// Minimum readable width for the panel content area (search bar + empty grid) — ensures
    /// typed queries remain visible even when zero windows match. Approximately two card widths.
    static let minPanelContentWidth: CGFloat = 320

}

/// Switcher 的展示单位：逐窗口模式下每项只有一扇窗口；按 App 聚合时同一 App 的窗口按原 MRU
/// 顺序放在同一项，第一扇是聚焦目标和正面缩略图，其余窗口用于堆叠预览。
struct SwitcherItem: Equatable {
    let windows: [WindowInfo]
    let primaryIndex: Int

    var primary: WindowInfo { windows[primaryIndex] }
    /// 卡片身份始终取组内 MRU 第一扇窗口，组内切换正面截图时仍能复用同一张 CALayer 卡片。
    var id: WindowID { windows[0].id }
    var secondaryWindows: [WindowInfo] {
        windows.enumerated().compactMap { index, window in
            index == primaryIndex ? nil : window
        }
    }

    init(_ windows: [WindowInfo], primaryIndex: Int = 0) {
        precondition(!windows.isEmpty)
        self.windows = windows
        self.primaryIndex = min(max(primaryIndex, 0), windows.count - 1)
    }

    func selectingWindow(id: WindowID) -> SwitcherItem {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return self }
        return SwitcherItem(windows, primaryIndex: index)
    }

    func steppingPrimary(backward: Bool) -> SwitcherItem {
        guard windows.count > 1 else { return self }
        let delta = backward ? -1 : 1
        let next = (primaryIndex + delta + windows.count) % windows.count
        return SwitcherItem(windows, primaryIndex: next)
    }

    nonisolated static func make(from windows: [WindowInfo], groupByApplication: Bool) -> [SwitcherItem] {
        guard groupByApplication else { return windows.map { SwitcherItem([$0]) } }

        var groups: [[WindowInfo]] = []
        var indices: [ApplicationKey: Int] = [:]
        for window in windows {
            let key: ApplicationKey
            if let bundleID = window.appBundleID, !bundleID.isEmpty {
                key = .bundleID(bundleID)
            } else {
                key = .pid(window.pid)
            }

            if let index = indices[key] {
                groups[index].append(window)
            } else {
                indices[key] = groups.count
                groups.append([window])
            }
        }
        return groups.map { SwitcherItem($0) }
    }

    private enum ApplicationKey: Hashable {
        case bundleID(String)
        case pid(ProcessID)
    }
}

/// Task 21：`SwitcherMetrics` 里**随用户设置变化**的那部分——缩略图尺寸档位（`CardSizeOption`）、
/// 是否显示第二行窗口标题、明暗配色。固定不变的间距/圆角/字号仍留在 `SwitcherMetrics` 的
/// `static let` 里（改动面最小：绝大多数引用不用动），这里只承载会变的量以及由它们派生的卡片
/// 尺寸与颜色。
///
/// 值类型、`Sendable`——`SwitcherController` 每次 `present()` 按当前设置现算一份传给
/// `SwitcherView`/`WindowCardLayer`，不做全局可变状态（设置改了下次呼出自然生效，不需要通知机制）。
struct SwitcherStyle: Equatable, Sendable {
    /// 缩略图区尺寸（档位见 `CardSizeOption.thumbnailSize`）。
    let thumbnailSize: CGSize
    /// 卡片是否渲染第二行窗口标题——`false` 时卡片**变矮**（少一行的高度），不是留空白。
    let showsWindowTitle: Bool
    /// 深色（默认，Phase 5 起真机验证过的观感）/ 浅色。由 `SettingsStore.followSystemAppearance`
    /// 决定是恒为 `true` 还是跟随系统 `effectiveAppearance`。
    let isDark: Bool

    init(cardSize: CardSizeOption = .medium, showsWindowTitle: Bool = true, isDark: Bool = true) {
        thumbnailSize = cardSize.thumbnailSize
        self.showsWindowTitle = showsWindowTitle
        self.isDark = isDark
    }

    /// 兜底默认（中等尺寸 + 显示标题 + 深色）= Phase 5 起的既有外观，用于没有注入 style 的场景
    /// （单测、预览）。
    static let `default` = SwitcherStyle()

    /// 标签条高度：显示标题时是「App 名 + 行距 + 标题」两行，否则只有 App 名一行。
    var labelStripHeight: CGFloat {
        showsWindowTitle
            ? SwitcherMetrics.appNameHeight + SwitcherMetrics.labelLineGap + SwitcherMetrics.titleHeight
            : SwitcherMetrics.appNameHeight
    }

    /// 卡片外框尺寸 = 缩略图 + 四周留白 + 标签条。
    var cardSize: CGSize {
        CGSize(
            width: thumbnailSize.width + SwitcherMetrics.cardPadding * 2,
            height: SwitcherMetrics.cardPadding + thumbnailSize.height + SwitcherMetrics.titleTopGap
                + labelStripHeight + SwitcherMetrics.cardPadding
        )
    }

    /// 网格步距：卡片尺寸 + 卡片间距——`SwitcherView.computeLayout` 用宽度除它算列数。
    var cardStride: CGSize {
        CGSize(width: cardSize.width + SwitcherMetrics.cardSpacing, height: cardSize.height + SwitcherMetrics.cardSpacing)
    }

    // MARK: - 配色

    private func ink(_ alpha: CGFloat) -> CGColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(alpha).cgColor
    }

    var containerBorderColor: CGColor { ink(isDark ? 0.10 : 0.07) }
    var fallbackSelectionBackground: CGColor { ink(isDark ? 0.14 : 0.08) }
    var thumbnailBorderColor: CGColor { ink(isDark ? 0.22 : 0.16) }
    var thumbnailShadowOpacity: Float { isDark ? 0.30 : 0.20 }
    /// Primary card label color — the app name.
    var appNameColor: CGColor { ink(isDark ? 0.9 : 0.85) }
    /// Secondary card label color — the window title, dimmer than `appNameColor` so the app name
    /// reads as primary.
    var titleColor: CGColor { ink(isDark ? 0.55 : 0.5) }
    var searchPlaceholderColor: CGColor { ink(isDark ? 0.35 : 0.4) }
    var searchQueryColor: CGColor { ink(isDark ? 0.9 : 0.85) }

    var glassTintColor: NSColor {
        isDark
            ? NSColor.black.withAlphaComponent(0.06)
            : NSColor.white.withAlphaComponent(0.14)
    }

    var selectionGlassTintColor: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.08)
    }

    /// Stable selected-card fill drawn above the glass. Glass tint alone gets visually absorbed
    /// by the panel material, so this adaptive translucent gray provides the intended contrast.
    var selectionOverlayColor: CGColor { ink(isDark ? 0.14 : 0.12) }

    /// 角标底色/描边——深色下是半透明黑底 + 浅描边，浅色下反过来，保证 App 图标在两种模式下
    /// 都有足够对比的托底。
    var badgeBackground: CGColor {
        (isDark ? NSColor.black.withAlphaComponent(0.4) : NSColor.white.withAlphaComponent(0.7)).cgColor
    }
    var badgeBorderColor: CGColor {
        (isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).cgColor
    }

    /// 毛玻璃材质：深色沿用 Phase 5 验证过的 `.hudWindow`（系统「始终深色 HUD」材质）；浅色用
    /// `.menu`——同样是半透明取景材质，但在浅色外观下呈现为亮底。
    var effectMaterial: NSVisualEffectView.Material { isDark ? .hudWindow : .menu }
    /// 施加给毛玻璃视图的外观。
    ///
    /// 深色档返回 `nil`——**刻意与 Phase 5 逐字一致**：那版从未设置过 `appearance`（继承系统），
    /// 而 `.hudWindow` 本身就是「始终深色」材质，强行设 `vibrantDark` 属于行为变更，没有必要
    /// 冒这个险（默认配置必须与用户已经验证过的观感完全相同）。浅色档才需要显式指定，让
    /// `.menu` 材质在深色系统下也呈现为亮底。
    var effectAppearance: NSAppearance? {
        isDark ? nil : NSAppearance(named: .vibrantLight)
    }
}

/// Transparent, layer-backed host for the card `CALayer`s — a dedicated subview added **after**
/// `effectView` so its layer stacks above the glass (see the note in `SwitcherView.setUp()` for
/// why this can't just be `SwitcherView`'s own layer). Mirrors `SwitcherView`'s flipped coordinate
/// space so card frame math in `render(...)` and hit-testing in `cardIndex(at:)` need no
/// per-view conversion — both views share the same origin, size, and flippedness.
private final class SwitcherCardHostView: NSView {
    override var isFlipped: Bool { true }
}

/// `NSGlassEffectContainerView.contentView` 默认使用左下角原点；Switcher 其余布局使用左上角
/// 原点。两者不一致会让选中玻璃上下镜像、按钮玻璃底跑到右下角。
private final class SwitcherGlassHostView: NSView {
    override var isFlipped: Bool { true }
}

/// 玻璃层只负责视觉，不参与命中测试；否则 `NSGlassEffectContainerView` 会把内部 glass surface
/// 提到更高的渲染层级，并可能挡住上方真正负责交互的 grouping button。
private final class SwitcherPassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(macOS 26.0, *)
private final class SwitcherPassthroughGlassContainerView: NSGlassEffectContainerView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 真正的 NSButton（而不是只画一层图标），保留 tooltip / 可访问性；允许非激活 panel 的第一次
/// 点击直接触发，行为与卡片的 `acceptsFirstMouse` 一致。
private final class SwitcherGroupingButton: NSButton {
    enum InteractionState {
        case idle
        case hovered
        case pressed
    }

    var onPress: (() -> Void)?
    var onInteractionStateChange: ((InteractionState) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onInteractionStateChange?(.hovered)
    }

    override func mouseExited(with event: NSEvent) {
        onInteractionStateChange?(.idle)
    }

    override func mouseDown(with event: NSEvent) {
        onInteractionStateChange?(.pressed)
        super.mouseDown(with: event)
        let location = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        onInteractionStateChange?(bounds.contains(location) ? .hovered : .idle)
    }

    func resetInteractionState() {
        onInteractionStateChange?(.idle)
    }

    @objc private func pressed() {
        onPress?()
    }
}

/// The switcher's content view: an adaptive row/grid of `WindowCardLayer` thumbnail cards over a
/// dark translucent (`NSVisualEffectView`) rounded container. Pure `AppKit` + hand-built
/// `CALayer`s — this is the latency hot path (spec: thumbnail preview is the project's headline
/// optimization over the system Cmd+Tab), so it deliberately avoids SwiftUI's diffing/first-frame
/// cost, matching the same reasoning documented on `OverlayPanel`.
///
/// TEMP-wired directly from `NapoleonApp.swift` for this task (Task 18); Task 19's
/// `SwitcherController` becomes the real caller and adds the keyboard-driven `SelectionModel`
/// that `onHover`/`onClick`/the returned `columns` feed into.
@MainActor
final class SwitcherView: NSView {
    /// Fires on tracking-area hover (mouse move/enter) with the hit card's index into the
    /// `items` array passed to the most recent `render(...)` call. Task 19 wires this to live
    /// selection changes.
    var onHover: ((Int) -> Void)?
    /// Fires on `mouseUp` inside a card, same index convention as `onHover`. Task 19 wires this
    /// to commit (focus that window).
    var onClick: ((Int) -> Void)?
    /// Fires when the top-right quick toggle is clicked.
    var onToggleGrouping: (() -> Void)?

    private let fallbackEffectView = NSVisualEffectView()
    private var glassContainerView: NSView?
    private var selectionSurface: NSView?
    /// 选中描边独立于卡片内容，向外扩展后不会继续挤着卡片底部的 App 图标。
    private let selectionOutlineLayer = CALayer()
    private var groupingButtonSurface: NSView?
    /// Cards live in this view's layer, not `self.layer` — see `setUp()`'s comment for why.
    private let cardHostView = SwitcherCardHostView()
    /// Display-only search bar text (task UI-Tweak §2) — lives in `cardHostView.layer` (same
    /// above-the-glass host as the cards, see the note in `setUp()`) so it isn't hidden behind
    /// `effectView`. Never becomes first responder; `render(query:)` just sets its string every
    /// call, keystrokes still arrive at `SwitcherController` via the `CGEventTap`.
    private let searchTextLayer = CATextLayer()
    private let groupingButton = SwitcherGroupingButton(frame: .zero)
    /// One `WindowCardLayer` kept alive per `WindowID` across `render(...)` calls within a
    /// session (see `WindowCardLayer`'s header doc for why this reuse is what makes the async
    /// thumbnail fade-in possible), rebuilt from scratch each new switcher session (fresh
    /// `SwitcherView` instance — see the TEMP wiring in `NapoleonApp.swift`).
    private var cardLayers: [WindowID: WindowCardLayer] = [:]
    /// Index-aligned with the `items` array from the most recent `render(...)` call. Hit
    /// testing (`cardIndex(at:)`) is a linear scan over this — fine at switcher-grid scale
    /// (single-digit to low-double-digit window counts).
    private var cardFrames: [CGRect] = []
    private var trackingArea: NSTrackingArea?
    private var lastHoverIndex: Int?
    private var groupingButtonInteractionState = SwitcherGroupingButton.InteractionState.idle
    /// 「忽略静止光标」用：本会话是否已经因鼠标真实移动而 arm；以及记录首次 hover 时的全局鼠标基准位置。
    private var hoverArmed = false
    private var hoverBaseLocation: NSPoint?

    /// Task 21：本次会话的外观/尺寸参数（卡片尺寸档位、是否显示窗口标题、明暗），由
    /// `SwitcherController` 按当前设置在 `present()` 时现算并注入。会话期内不变——设置改了要等
    /// 下一次呼出才生效（切换器呼出期间用户不可能同时在改设置，不需要热更新通道）。
    private let style: SwitcherStyle

    /// Top-left origin so row 0 of the grid reads top-to-bottom, matching the intuitive reading
    /// order used throughout `computeLayout`'s row/column math and `WindowCardLayer`'s own
    /// `isGeometryFlipped = true` sublayer geometry.
    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, style: SwitcherStyle = .default) {
        self.style = style
        super.init(frame: frameRect)
        setUp()
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, style: .default)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = SwitcherMetrics.containerCornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = style.containerBorderColor

        installGlassSurfaces()

        // AppKit always stacks a layer-backed view's SUBVIEWS above that view's own
        // manually-added sublayers, regardless of `addSubview`/`addSublayer` call order — so
        // adding card layers directly to `self.layer` (as this used to do) put them BELOW
        // `effectView`'s subview layer, hiding every card behind the glass. `cardHostView` is a
        // separate transparent subview added after `effectView`, so it's the topmost subview;
        // `render(...)` adds card layers to `cardHostView.layer` instead of `self.layer`.
        cardHostView.wantsLayer = true
        cardHostView.layer?.backgroundColor = NSColor.clear.cgColor
        cardHostView.frame = bounds
        cardHostView.autoresizingMask = [.width, .height]
        addSubview(cardHostView)

        selectionOutlineLayer.cornerRadius = SwitcherMetrics.selectionCornerRadius
        selectionOutlineLayer.borderWidth = 2
        selectionOutlineLayer.backgroundColor = style.selectionOverlayColor
        selectionOutlineLayer.shadowOffset = .zero
        selectionOutlineLayer.shadowRadius = 8
        selectionOutlineLayer.shadowOpacity = 0.24
        selectionOutlineLayer.isHidden = true
        cardHostView.layer?.addSublayer(selectionOutlineLayer)

        // Search bar layers — same host as the cards (above the glass), positioned/updated per
        // render in `updateSearchBar(query:contentWidth:contentsScale:)`.
        searchTextLayer.fontSize = SwitcherMetrics.searchBarFontSize
        searchTextLayer.font = NSFont.systemFont(ofSize: SwitcherMetrics.searchBarFontSize, weight: .regular)
        searchTextLayer.alignmentMode = .left
        searchTextLayer.truncationMode = .end
        searchTextLayer.isWrapped = false
        cardHostView.layer?.addSublayer(searchTextLayer)

        groupingButton.isBordered = false
        groupingButton.imagePosition = .imageOnly
        groupingButton.imageScaling = .scaleProportionallyDown
        groupingButton.focusRingType = .none
        groupingButton.wantsLayer = true
        groupingButton.layer?.backgroundColor = NSColor.clear.cgColor
        groupingButton.isHidden = true
        groupingButton.onPress = { [weak self] in self?.onToggleGrouping?() }
        groupingButton.onInteractionStateChange = { [weak self] state in
            self?.groupingButtonInteractionState = state
            self?.updateGroupingButtonInteraction(state)
        }
        addSubview(groupingButton)
    }

    /// macOS 26 使用原生 Liquid Glass；旧系统保留一层低对比度毛玻璃。卡片和按钮都不再
    /// 自己绘制不透明底板，避免「容器底色 → 缩略图井 → 截图」三层框叠在一起。
    private func installGlassSurfaces() {
        if #available(macOS 26.0, *) {
            let container = SwitcherPassthroughGlassContainerView(frame: bounds)
            container.autoresizingMask = [.width, .height]
            container.spacing = 10

            let host = SwitcherGlassHostView(frame: bounds)
            host.autoresizingMask = [.width, .height]
            container.contentView = host

            let background = NSGlassEffectView(frame: bounds)
            background.autoresizingMask = [.width, .height]
            background.style = .regular
            background.cornerRadius = SwitcherMetrics.containerCornerRadius
            background.tintColor = style.glassTintColor
            background.appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
            host.addSubview(background)

            let selection = NSGlassEffectView(frame: .zero)
            selection.style = .regular
            selection.cornerRadius = SwitcherMetrics.selectionCornerRadius
            selection.tintColor = style.selectionGlassTintColor
            selection.appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
            selection.isHidden = true
            host.addSubview(selection)

            let button = NSGlassEffectView(frame: .zero)
            button.style = .clear
            button.cornerRadius = SwitcherMetrics.groupingButtonSize / 2
            button.tintColor = style.glassTintColor
            button.wantsLayer = true
            button.isHidden = true
            host.addSubview(button)

            glassContainerView = container
            selectionSurface = selection
            groupingButtonSurface = button
            addSubview(container)
        } else {
            fallbackEffectView.material = style.effectMaterial
            fallbackEffectView.appearance = style.effectAppearance
            fallbackEffectView.blendingMode = .behindWindow
            fallbackEffectView.state = .active
            fallbackEffectView.frame = bounds
            fallbackEffectView.autoresizingMask = [.width, .height]
            addSubview(fallbackEffectView)

            let selection = SwitcherPassthroughVisualEffectView(frame: .zero)
            selection.material = .selection
            selection.blendingMode = .withinWindow
            selection.state = .active
            selection.appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
            selection.wantsLayer = true
            selection.layer?.cornerRadius = SwitcherMetrics.selectionCornerRadius
            selection.layer?.masksToBounds = true
            selection.layer?.backgroundColor = style.fallbackSelectionBackground
            selection.isHidden = true
            selectionSurface = selection
            addSubview(selection)

            let button = SwitcherPassthroughVisualEffectView(frame: .zero)
            button.material = .menu
            button.blendingMode = .withinWindow
            button.state = .active
            button.wantsLayer = true
            button.layer?.cornerRadius = SwitcherMetrics.groupingButtonSize / 2
            button.layer?.masksToBounds = true
            button.isHidden = true
            groupingButtonSurface = button
            addSubview(button)
        }
    }

    /// `OverlayPanel` is a `.nonactivatingPanel` that never becomes key (Task 17) — without this
    /// override, the very first click on any card would be consumed by AppKit to bring the
    /// (inert, never-key) window forward instead of reaching `mouseUp`/`onClick`.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Render

    /// Renders `windows` as an adaptive row/grid of cards, `selected` highlighted. Rebuilds/
    /// updates all card layers and repositions them every call — cheap at this scale (brief:
    /// "render 每次全量重建卡片 layer；数量通常 <50，CALayer 便宜"), while still reusing the
    /// underlying `WindowCardLayer` per `WindowID` (see `cardLayers`) so unchanged cards don't
    /// lose fade-in state.
    ///
    /// Returns `columns` (Task 19's `SelectionModel.moveInGrid` needs it for grid navigation) and
    /// `contentSize` (Task 19 passes it straight to `OverlayPanel.present`; task UI-Tweak grows
    /// its height by `SwitcherMetrics.searchBarHeight` to make room for the search bar above the
    /// grid — see `computeLayout`).
    @discardableResult
    func render(
        items: [SwitcherItem],
        selected: Int,
        query: String,
        groupingByApplication: Bool,
        showsGroupingToggle: Bool,
        iconProvider: (WindowInfo) -> NSImage?,
        thumbnailProvider: (WindowID) -> CGImage?
    ) -> (columns: Int, contentSize: CGSize) {
        let screen = Self.screenUnderMouse()
        let layout = Self.computeLayout(
            count: items.count,
            maxOverlayWidth: screen.visibleFrame.width * 0.9,
            style: style
        )

        setFrameSize(layout.contentSize)
        updateHeader(
            query: query,
            contentWidth: layout.contentSize.width,
            contentsScale: screen.backingScaleFactor,
            groupingByApplication: groupingByApplication,
            showsGroupingToggle: showsGroupingToggle
        )

        var frames: [CGRect] = []
        frames.reserveCapacity(items.count)
        var usedIDs = Set<WindowID>()
        let columns = max(layout.columns, 1) // guard divide-by-zero; unreachable when items is non-empty (see computeLayout)

        for (i, item) in items.enumerated() {
            let window = item.primary
            let row = i / columns
            let col = i % columns
            let origin = CGPoint(
                x: SwitcherMetrics.containerPadding + CGFloat(col) * style.cardStride.width,
                y: SwitcherMetrics.containerPadding + SwitcherMetrics.searchBarHeight
                    + SwitcherMetrics.headerGridSpacing + CGFloat(row) * style.cardStride.height
            )
            let cardFrame = CGRect(origin: origin, size: style.cardSize)
            frames.append(cardFrame)
            usedIDs.insert(window.id)

            let card = cardLayers[window.id] ?? {
                let created = WindowCardLayer(cardStyle: style)
                cardLayers[window.id] = created
                cardHostView.layer?.addSublayer(created)
                return created
            }()
            card.bounds = CGRect(origin: .zero, size: cardFrame.size)
            card.position = CGPoint(x: cardFrame.midX, y: cardFrame.midY)
            card.update(
                appName: window.appName,
                title: window.title,
                icon: iconProvider(window),
                thumbnail: thumbnailProvider(window.id),
                stackedThumbnails: item.secondaryWindows.prefix(2).map { thumbnailProvider($0.id) },
                groupCount: item.windows.count,
                contentsScale: screen.backingScaleFactor
            )
        }

        cardFrames = frames
        updateSelectionSurface(selected: selected, frames: frames)

        // Drop cards for windows that fell out of the list (closed, or simply not part of this
        // render) — collect ids first, since mutating `cardLayers` while iterating its own `keys`
        // view is not safe.
        let staleIDs = cardLayers.keys.filter { !usedIDs.contains($0) }
        for id in staleIDs {
            cardLayers[id]?.removeFromSuperlayer()
            cardLayers.removeValue(forKey: id)
        }

        lastHoverIndex = nil // card identities under the cursor may have shifted; re-establish on next mouse event
        return (columns: layout.columns, contentSize: layout.contentSize)
    }

    /// Positions and re-strings the display-only search bar for this render pass. `contentWidth`
    /// is the same `layout.contentSize.width` `render(...)` just resized `self` to, so the bar's
    /// width tracks the grid's width (brief: "搜索栏宽度 = 网格宽度（跟随列数）") without this
    /// method needing to recompute the column count itself. Runs on every `render(...)` call, so
    /// typing (routed through `SwitcherController.query` → this `query` param) updates the bar
    /// immediately, same as it updates card selection/content.
    private func updateHeader(
        query: String,
        contentWidth: CGFloat,
        contentsScale: CGFloat,
        groupingByApplication: Bool,
        showsGroupingToggle: Bool
    ) {
        searchTextLayer.contentsScale = contentsScale

        let barWidth = contentWidth - SwitcherMetrics.containerPadding * 2
        let buttonReservation = showsGroupingToggle
            ? SwitcherMetrics.groupingButtonSize + SwitcherMetrics.groupingButtonTrailingInset
            : 0
        searchTextLayer.frame = CGRect(
            x: SwitcherMetrics.containerPadding + SwitcherMetrics.searchBarHorizontalInset,
            y: SwitcherMetrics.containerPadding
                + (SwitcherMetrics.searchBarHeight - SwitcherMetrics.searchTextHeight) / 2,
            width: max(0, barWidth - SwitcherMetrics.searchBarHorizontalInset * 2 - buttonReservation),
            height: SwitcherMetrics.searchTextHeight
        )
        if query.isEmpty {
            searchTextLayer.string = String(localized: "Type to search…")
            searchTextLayer.foregroundColor = style.searchPlaceholderColor
        } else {
            searchTextLayer.string = query
            searchTextLayer.foregroundColor = style.searchQueryColor
        }

        groupingButton.isHidden = !showsGroupingToggle
        groupingButtonSurface?.isHidden = !showsGroupingToggle
        guard showsGroupingToggle else {
            groupingButtonInteractionState = .idle
            groupingButton.resetInteractionState()
            return
        }
        let buttonFrame = CGRect(
            x: contentWidth - SwitcherMetrics.containerPadding - SwitcherMetrics.groupingButtonSize,
            y: SwitcherMetrics.containerPadding
                + (SwitcherMetrics.searchBarHeight - SwitcherMetrics.groupingButtonSize) / 2,
            width: SwitcherMetrics.groupingButtonSize,
            height: SwitcherMetrics.groupingButtonSize
        )
        groupingButton.frame = buttonFrame
        groupingButtonSurface?.frame = buttonFrame

        let symbolName = groupingByApplication ? "macwindow.on.rectangle" : "macwindow"
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        groupingButton.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        )
        groupingButton.contentTintColor = style.isDark
            ? NSColor.white.withAlphaComponent(0.82)
            : NSColor.black.withAlphaComponent(0.76)
        groupingButton.toolTip = groupingByApplication
            ? String(localized: "Show individual windows")
            : String(localized: "Group windows by application")
        groupingButton.setAccessibilityLabel(groupingButton.toolTip)
        updateGroupingButtonInteraction(groupingButtonInteractionState, animated: false)
    }

    private func updateGroupingButtonInteraction(
        _ state: SwitcherGroupingButton.InteractionState,
        animated: Bool = true
    ) {
        let scale: CGFloat
        let surfaceAlpha: CGFloat
        let contentAlpha: CGFloat
        let tint: NSColor

        switch state {
        case .idle:
            scale = 1
            surfaceAlpha = 0.72
            contentAlpha = 0.76
            tint = style.glassTintColor
        case .hovered:
            scale = 1.06
            surfaceAlpha = 1
            contentAlpha = 0.94
            tint = style.isDark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.07)
        case .pressed:
            scale = 0.92
            surfaceAlpha = 1
            contentAlpha = 1
            tint = style.isDark
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.12)
        }

        if #available(macOS 26.0, *), let glass = groupingButtonSurface as? NSGlassEffectView {
            glass.tintColor = tint
        } else {
            groupingButtonSurface?.layer?.backgroundColor = tint.cgColor
        }
        groupingButtonSurface?.alphaValue = surfaceAlpha
        groupingButton.contentTintColor = (
            style.isDark ? NSColor.white : NSColor.black
        ).withAlphaComponent(contentAlpha)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        let transform = CATransform3DMakeScale(scale, scale, 1)
        groupingButton.layer?.transform = transform
        groupingButtonSurface?.layer?.transform = transform
        CATransaction.commit()
    }

    private func updateSelectionSurface(selected: Int, frames: [CGRect]) {
        guard frames.indices.contains(selected) else {
            selectionSurface?.isHidden = true
            selectionOutlineLayer.isHidden = true
            return
        }
        let frame = frames[selected].insetBy(
            dx: -SwitcherMetrics.selectionExpansion,
            dy: -SwitcherMetrics.selectionExpansion
        )
        selectionSurface?.frame = frame
        selectionSurface?.isHidden = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionOutlineLayer.frame = frame
        selectionOutlineLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let accent = NSColor.controlAccentColor.withAlphaComponent(0.90).cgColor
        selectionOutlineLayer.borderColor = accent
        selectionOutlineLayer.shadowColor = accent
        selectionOutlineLayer.isHidden = false
        CATransaction.commit()

        if #available(macOS 26.0, *), let glass = selectionSurface as? NSGlassEffectView {
            glass.tintColor = style.selectionGlassTintColor
        }
    }

    // MARK: - Adaptive layout math (pure, testable)

    struct LayoutResult: Equatable {
        let columns: Int
        let rows: Int
        let contentSize: CGSize
    }

    /// `maxCols = max(1, floor(maxOverlayWidth / cardStride.width))`, `columns = min(n, maxCols)`,
    /// `rows = ceil(n / columns)`.
    ///
    /// Few windows → single centered row: when `n <= maxCols`, `columns == n`, so `contentSize`
    /// already wraps exactly that one row of `n` cards — centering then falls out of
    /// `OverlayPanel.present` centering the whole panel on screen, no separate step needed here.
    /// More windows than fit on one row → wraps into a grid; `render(...)`'s row-major placement
    /// (`col = i % columns`) naturally left-aligns a short last row instead of centering it,
    /// per spec.
    ///
    /// Task UI-Tweak: non-empty layouts include `SwitcherMetrics.searchBarHeight` and
    /// `SwitcherMetrics.headerGridSpacing` above the card grid. The empty case still reserves the
    /// fixed search-bar band, but has no grid to separate from it.
    /// `nonisolated`: pure function, touches no `@MainActor` state — lets it (and its unit tests)
    /// be called from a plain synchronous, non-main-actor context without needing `await`.
    nonisolated static func computeLayout(
        count: Int,
        maxOverlayWidth: CGFloat,
        style: SwitcherStyle = .default
    ) -> LayoutResult {
        guard count > 0 else {
            let width = max(SwitcherMetrics.containerPadding * 2, SwitcherMetrics.minPanelContentWidth)
            let height = SwitcherMetrics.containerPadding * 2 + SwitcherMetrics.searchBarHeight
            return LayoutResult(columns: 0, rows: 0, contentSize: CGSize(width: width, height: height))
        }

        let maxCols = max(1, Int((maxOverlayWidth / style.cardStride.width).rounded(.down)))
        let columns = min(count, maxCols)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))

        // Exact fit around the cards actually placed: `columns` cards across / `rows` cards down,
        // minus the one trailing inter-card gap neither axis needs (nothing follows the last
        // card), plus the container's own padding on both sides, the search bar band, and the
        // deliberate breathing room between the header and the selected card's expanded bounds.
        let width = CGFloat(columns) * style.cardStride.width - SwitcherMetrics.cardSpacing + SwitcherMetrics.containerPadding * 2
        let height = CGFloat(rows) * style.cardStride.height - SwitcherMetrics.cardSpacing
            + SwitcherMetrics.containerPadding * 2 + SwitcherMetrics.searchBarHeight
            + SwitcherMetrics.headerGridSpacing
        return LayoutResult(columns: columns, rows: rows, contentSize: CGSize(width: width, height: height))
    }

    // MARK: - Mouse hit testing

    /// `.activeAlways` per the brief: the panel never becomes key, but a tracking area with this
    /// option still delivers enter/exit/moved events regardless of key/active app status.
    /// `.inVisibleRect` keeps the area's rect in sync with `bounds` automatically across the
    /// resizes `render(...)` does via `setFrameSize`, so this doesn't need to be redone per render.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { handleHover(event) }
    override func mouseMoved(with event: NSEvent) { handleHover(event) }
    override func mouseExited(with event: NSEvent) { lastHoverIndex = nil }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = cardIndex(at: point) {
            onClick?(index)
        }
    }

    private func handleHover(_ event: NSEvent) {
        // 忽略「静止光标」：浮层弹出时如果光标恰好停在某张卡上，mouseEntered 会立刻触发一次
        // hover 把那张卡高亮，盖掉键盘的默认选中（上一个窗口）。记录本会话首次收到 hover 时的
        // 全局鼠标位置为基准，在鼠标真正移动（超过阈值）之前一律不响应 hover；一旦移动过就
        // 永久 arm、正常响应。SwitcherView 每次呼出都是新实例，所以这个基准天然每会话重置。
        if !hoverArmed {
            let now = NSEvent.mouseLocation
            if let base = hoverBaseLocation {
                if abs(now.x - base.x) < 2 && abs(now.y - base.y) < 2 { return } // 还没移动，忽略
                hoverArmed = true // 移动了，从此响应
            } else {
                hoverBaseLocation = now // 记录基准，这次先不响应
                return
            }
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = cardIndex(at: point) else {
            lastHoverIndex = nil
            return
        }
        guard index != lastHoverIndex else { return } // don't spam onHover for every pixel of movement within the same card
        lastHoverIndex = index
        onHover?(index)
    }

    private func cardIndex(at point: CGPoint) -> Int? {
        cardFrames.firstIndex { $0.contains(point) }
    }

    // MARK: - Mouse-screen detection

    /// Mirrors `OverlayPanel.screenUnderMouse()` (Task 17) — same "which display is the user
    /// pointing at" question, needed independently here for the `maxOverlayWidth` layout budget.
    /// This runs on every `render(...)` call (including the very first one of a session, before
    /// `OverlayPanel.present` has positioned anything yet), so it can't just read the panel's
    /// current screen back.
    private static func screenUnderMouse() -> NSScreen {
        let location = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}
