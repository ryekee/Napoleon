import AppKit
import QuartzCore

/// Visual card for a single window in the switcher grid — a hand-built `CALayer` composition
/// (thumbnail + icon placeholder + app-icon badge + two-line truncated label + selection chrome),
/// not an `NSView`. This is the hot path the whole project exists to make fast (spec: thumbnail
/// preview is the headline optimization over the system Cmd+Tab), so it's plain `CALayer`s driven
/// by `SwitcherView.render(...)` — no Auto Layout, no SwiftUI diffing, deterministic first-frame.
///
/// **Two-line label** (task UI-Tweak): `appNameLayer` (primary, larger, ~90% white) shows the
/// owning app's name; `titleLayer` (secondary, smaller, ~55% white) shows the window's own title.
/// The app name is primary because a single multi-window app (e.g. several Chrome tabs) otherwise
/// renders as indistinguishable cards when only the window title was shown. On screen the title
/// line sits *above* the app-name line, and the whole label strip sits *above* the thumbnail —
/// see the geometry note below; it is not what the frame arithmetic reads like.
///
/// **Reuse, not rebuild**: `SwitcherView` keeps one `WindowCardLayer` alive per `WindowID` across
/// `render(...)` calls within a switcher session (a small pool keyed by id) instead of destroying
/// and recreating cards on every forward/backward step. That reuse is what makes the async
/// thumbnail fade-in (`applyThumbnail`) possible at all — the crossfade has something to animate
/// *from* only because the same layer instance survives from the "icon-only" render to the
/// "thumbnail arrived" render.
///
/// **Geometry — read this before moving anything**: the host views (`SwitcherView` and its
/// `cardHostView`) are `isFlipped = true`, and this layer additionally sets
/// `isGeometryFlipped = true`. The two flips cancel out, so for the card's own sublayers
/// **`y` is measured upward from the card's bottom edge: a larger `y` renders higher on
/// screen.**
///
/// This was verified empirically, not inferred: replicating the exact nesting (an `isFlipped`
/// host view whose layer holds a sublayer with `isGeometryFlipped = true`) and both rendering it
/// and running `CALayer.convert` shows a sublayer at `y == 0` landing at the card's **bottom**.
/// The historical record agrees — before the badge moved, its `y` was `cardPadding +
/// thumbnailHeight - badgeSize * 0.75` (a large `y`) and it appeared in the thumbnail's *top*
/// left corner.
///
/// The consequence is that the card renders **upside down relative to how the frames below
/// read**: window title on top, then app name, then the thumbnail at the bottom. That is the
/// opposite of the conventional switcher card and the opposite of what every name in this file
/// suggests. It is nonetheless the arrangement in use — reviewed and deliberately kept — so the
/// flip stays. Any change to these frames has to be reasoned about bottom-up and verified
/// visually; do not "fix" the arithmetic to match the prose.
final class WindowCardLayer: CALayer {
    private let thumbnailContainer = CALayer()
    private let iconLayer = CALayer()
    private let thumbnailLayer = CALayer()
    /// Badge 的投影层。必须与 `badgeLayer` 分开：一个 layer 的 `masksToBounds`（badge 要靠它
    /// 把图标裁成圆角）会把**它自己**的投影一起裁掉，两个属性放同一层上互斥。所以外层只管投影
    /// 不裁剪，内层只管裁剪不投影。
    private let badgeShadowLayer = CALayer()
    private let badgeLayer = CALayer()
    /// Primary label line — the owning app's name (larger, brighter than `titleLayer`).
    private let appNameLayer = CATextLayer()
    /// Secondary label line — the window's own title (smaller, dimmer; blank when the window has
    /// no title, no placeholder shown).
    private let titleLayer = CATextLayer()

    /// Tracks whether a real thumbnail has ever been shown on this card. `applyThumbnail` only
    /// plays the crossfade the first time a non-nil image arrives (icon → thumbnail); a later
    /// update to a fresher capture of the same window swaps in instantly, no repeated fade.
    private var currentThumbnail: CGImage?
    private var isCardSelected = false

    /// Task 21：尺寸/明暗参数，由 `SwitcherView.render(...)` 建卡时注入（同一会话内所有卡片共用
    /// 同一份）。决定缩略图区尺寸、是否有第二行标题、以及全部配色。
    private let cardStyle: SwitcherStyle

    init(cardStyle: SwitcherStyle) {
        self.cardStyle = cardStyle
        super.init()
        setUp()
    }

    override convenience init() {
        self.init(cardStyle: .default)
    }

    /// Required override for `CALayer` subclasses that add stored properties: Core Animation
    /// creates a presentation-layer copy via this initializer whenever an animation is running
    /// on a `WindowCardLayer` instance (the implicit backgroundColor/borderWidth/transform
    /// animation in `setSelected`, and the opacity crossfade in `applyThumbnail`). The five
    /// sublayer properties above all carry their own default-value initializers
    /// (`= CALayer()` / `= CATextLayer()`), which Swift runs before this body regardless of
    /// which designated initializer is used, so there is nothing left to copy by hand here —
    /// `super.init(layer:)` is what clones the actual visible sublayer tree at the CALayer level,
    /// and `update(...)` is never called again on a presentation-layer copy.
    ///
    /// Task 21：`cardStyle` 现在是存储属性，必须在这里显式初始化——从被复制的那个 `WindowCardLayer`
    /// 抄一份（正常路径），拿不到就退回 `.default`（不会发生：Core Animation 只会用一个同类型的
    /// 实例调这个初始化器；写成兜底而不是 `fatalError` 是因为展示层副本纯用于动画，绝不该因为
    /// 一个理论上的类型意外让 App 崩掉）。
    override init(layer: Any) {
        cardStyle = (layer as? WindowCardLayer)?.cardStyle ?? .default
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        isGeometryFlipped = true
        masksToBounds = false // selection glow (`shadowOpacity`) must be free to bleed outside bounds
        cornerRadius = SwitcherMetrics.cardCornerRadius
        backgroundColor = cardStyle.normalCardBackground
        borderWidth = 0
        shadowColor = NSColor.controlAccentColor.cgColor
        shadowOffset = .zero
        shadowRadius = 10
        shadowOpacity = 0

        thumbnailContainer.frame = CGRect(
            x: SwitcherMetrics.cardPadding,
            y: SwitcherMetrics.cardPadding,
            width: cardStyle.thumbnailSize.width,
            height: cardStyle.thumbnailSize.height
        )
        thumbnailContainer.masksToBounds = true
        thumbnailContainer.cornerRadius = SwitcherMetrics.thumbnailCornerRadius
        thumbnailContainer.backgroundColor = cardStyle.thumbnailWellBackground
        addSublayer(thumbnailContainer)

        // Icon placeholder: a centered square well inside the thumbnail box — shown until a real
        // capture arrives, and left in place underneath it afterwards (opacity 0) so the crossfade
        // in `applyThumbnail` has something to fade *from* without re-adding layers.
        // 图标占位尺寸随缩略图档位缩放（小卡片上 48pt 会顶满），但不小于 32pt 以免糊成一团。
        let iconSize = max(32, min(48, cardStyle.thumbnailSize.height * 0.48))
        iconLayer.frame = CGRect(
            x: (cardStyle.thumbnailSize.width - iconSize) / 2,
            y: (cardStyle.thumbnailSize.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        iconLayer.contentsGravity = .resizeAspect
        thumbnailContainer.addSublayer(iconLayer)

        thumbnailLayer.frame = CGRect(origin: .zero, size: cardStyle.thumbnailSize)
        // `ThumbnailService.cached`/`capture` already return a fit-within (aspect-correct, never
        // upscaled) image — `.resizeAspect` here is belt-and-suspenders against stretching, not
        // the thing doing the aspect-fit math; it also centers/letterboxes cleanly regardless of
        // exactly how large the incoming image is relative to this 160×100 box.
        thumbnailLayer.contentsGravity = .resizeAspect
        thumbnailLayer.opacity = 0 // icon shows through until a real thumbnail arrives
        thumbnailContainer.addSublayer(thumbnailLayer)

        // App-icon badge: horizontally centred, straddling the thumbnail's **visually lower**
        // edge — ~3/4 sits over the thumbnail, ~1/4 hangs below it into the card's bottom
        // padding. That overlap is what makes it read as a badge belonging to the thumbnail
        // rather than a second, disconnected icon. Added as a sibling of `thumbnailContainer`
        // (not its child) so the drop shadow and the overhang aren't clipped by
        // `thumbnailContainer.masksToBounds`.
        //
        // `y` here is measured **upward from the card's bottom** — see the note on the
        // coordinate system in the type's header doc. Hence the visual bottom of the thumbnail
        // is at `y == cardPadding`, and subtracting a quarter of the badge drops it below.
        let badgeSize = SwitcherMetrics.badgeSize
        let badgeCorner = SwitcherMetrics.badgeCornerRadius
        badgeShadowLayer.frame = CGRect(
            x: SwitcherMetrics.cardPadding + (cardStyle.thumbnailSize.width - badgeSize) / 2,
            y: SwitcherMetrics.cardPadding - badgeSize * 0.25,
            width: badgeSize,
            height: badgeSize
        )
        badgeShadowLayer.shadowColor = NSColor.black.cgColor
        badgeShadowLayer.shadowOpacity = 0.5
        badgeShadowLayer.shadowRadius = 3
        badgeShadowLayer.shadowOffset = CGSize(width: 0, height: 1)
        // 形状是已知的圆角矩形，直接给 `shadowPath`：省掉 Core Animation 每帧从 alpha 通道推
        // 投影轮廓的开销，这里是每张卡片都要走的热路径。
        badgeShadowLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: CGSize(width: badgeSize, height: badgeSize)),
            cornerWidth: badgeCorner, cornerHeight: badgeCorner, transform: nil
        )
        addSublayer(badgeShadowLayer)

        // 内层填满外层，只负责把图标裁成圆角；投影归外层管（见 `badgeShadowLayer` 的注释）。
        badgeLayer.frame = CGRect(origin: .zero, size: CGSize(width: badgeSize, height: badgeSize))
        badgeLayer.cornerRadius = badgeCorner
        badgeLayer.masksToBounds = true
        badgeLayer.backgroundColor = cardStyle.badgeBackground
        badgeLayer.borderWidth = 1
        badgeLayer.borderColor = cardStyle.badgeBorderColor
        badgeLayer.contentsGravity = .resizeAspect
        badgeShadowLayer.addSublayer(badgeLayer)

        let labelWidth = cardStyle.cardSize.width - SwitcherMetrics.cardPadding * 2

        appNameLayer.frame = CGRect(
            x: SwitcherMetrics.cardPadding,
            y: SwitcherMetrics.cardPadding + cardStyle.thumbnailSize.height + SwitcherMetrics.titleTopGap,
            width: labelWidth,
            height: SwitcherMetrics.appNameHeight
        )
        appNameLayer.fontSize = 12.5
        appNameLayer.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        appNameLayer.foregroundColor = cardStyle.appNameColor
        appNameLayer.alignmentMode = .center
        appNameLayer.truncationMode = .end
        appNameLayer.isWrapped = false
        addSublayer(appNameLayer)

        // Task 21：关掉「显示窗口标题」时第二行整个不存在——卡片高度已经在 `SwitcherStyle.cardSize`
        // 里少算了这一行，这里也就不能把 layer 加进来（加了会画到卡片外面去）。
        guard cardStyle.showsWindowTitle else { return }

        titleLayer.frame = CGRect(
            x: SwitcherMetrics.cardPadding,
            y: appNameLayer.frame.maxY + SwitcherMetrics.labelLineGap,
            width: labelWidth,
            height: SwitcherMetrics.titleHeight
        )
        titleLayer.fontSize = 10.5
        titleLayer.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        titleLayer.foregroundColor = cardStyle.titleColor
        titleLayer.alignmentMode = .center
        titleLayer.truncationMode = .end
        titleLayer.isWrapped = false
        addSublayer(titleLayer)
    }

    /// Push a window's content into this card. Called on every `render(...)` — both for a
    /// brand-new card and for a reused one whose selection/thumbnail/labels may have changed.
    ///
    /// `title` (the window's own title) may be empty — some windows genuinely have none — in
    /// which case the secondary line is simply blank, no placeholder text is shown for it.
    ///
    /// `contentsScale` is propagated to every sublayer explicitly: unlike a layer-backed
    /// `NSView`'s own root layer (which AppKit keeps in sync with the window's backing scale
    /// automatically — see `OverlayPanel.present`), a manually-built `CALayer` tree like this one
    /// does not inherit `contentsScale` down from its superlayer, so each hand-added sublayer
    /// needs it set directly to stay crisp on whichever screen the switcher is currently shown on.
    func update(appName: String, title: String, icon: NSImage?, thumbnail: CGImage?, isSelected: Bool, contentsScale: CGFloat) {
        for sublayer: CALayer in [self, thumbnailContainer, iconLayer, thumbnailLayer, badgeShadowLayer, badgeLayer, appNameLayer, titleLayer] {
            sublayer.contentsScale = contentsScale
        }

        appNameLayer.string = appName
        // 关掉标题行时 `titleLayer` 根本没有被加进图层树（见 `setUp`），这里也就不必写它。
        if cardStyle.showsWindowTitle {
            titleLayer.string = title
        }
        iconLayer.contents = icon
        badgeLayer.contents = icon

        if let thumbnail {
            applyThumbnail(thumbnail)
        }

        setSelected(isSelected)
    }

    private func applyThumbnail(_ image: CGImage) {
        guard currentThumbnail !== image else { return }
        let isFirstAppearance = currentThumbnail == nil
        currentThumbnail = image

        CATransaction.begin()
        if isFirstAppearance {
            // Spec: card starts on the app icon; once a real thumbnail is ready it fades in over
            // the icon (~0.15s), it doesn't just pop in.
            CATransaction.setAnimationDuration(SwitcherMetrics.fadeInDuration) // 淡入时长与档位无关
            thumbnailLayer.contents = image
            thumbnailLayer.opacity = 1
            iconLayer.opacity = 0
        } else {
            // A fresher capture of a window we already showed a thumbnail for — swap instantly.
            // The fade is specifically the "icon → thumbnail" reveal moment, not every refresh.
            CATransaction.setDisableActions(true)
            thumbnailLayer.contents = image
        }
        CATransaction.commit()
    }

    private func setSelected(_ selected: Bool) {
        // Read live rather than cached, and do it on *every* call (not just on a selection-state
        // transition below): must track whatever accent color is current in System Settings, which
        // can change while this card stays selected across several `render()` calls in the same
        // session. `setDisableActions` keeps this a hard set — no implicit fade for a same-value
        // re-assignment on every unrelated render.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let accent = NSColor.controlAccentColor.cgColor
        borderColor = accent
        shadowColor = accent
        CATransaction.commit()

        guard selected != isCardSelected else { return }
        isCardSelected = selected

        CATransaction.begin()
        backgroundColor = selected ? cardStyle.selectedCardBackground : cardStyle.normalCardBackground
        borderWidth = selected ? 2 : 0
        shadowOpacity = selected ? 0.5 : 0
        transform = selected
            ? CATransform3DMakeScale(SwitcherMetrics.selectedScale, SwitcherMetrics.selectedScale, 1)
            : CATransform3DIdentity
        CATransaction.commit()
    }
}
