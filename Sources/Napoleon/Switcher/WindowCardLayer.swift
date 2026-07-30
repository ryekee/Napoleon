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
    /// 按 App 聚合时，正面缩略图后最多露出两层窗口预览，形成参考图中的卡片堆叠。
    private let stackedThumbnailLayers = [CALayer(), CALayer()]
    /// 与 App 图标 badge 相同的分层方式：外层只负责缩略图投影，内层负责圆角裁切与细描边。
    private let thumbnailShadowLayer = CALayer()
    private let thumbnailContainer = CALayer()
    private let iconLayer = CALayer()
    private let thumbnailLayer = CALayer()
    /// 普通模式显示一个 App 图标；聚合模式按窗口数横向堆叠同一个 App 图标。每枚图标仍使用
    /// 「外层投影 + 内层裁切」两层结构，避免 `masksToBounds` 把投影一起裁掉。
    private var badgeShadowLayers: [CALayer] = []
    private var badgeLayers: [CALayer] = []
    /// Primary label line — the owning app's name (larger, brighter than `titleLayer`).
    private let appNameLayer = CATextLayer()
    /// Secondary label line — the window's own title (smaller, dimmer; blank when the window has
    /// no title, no placeholder shown).
    private let titleLayer = CATextLayer()
    /// Tracks whether a real thumbnail has ever been shown on this card. `applyThumbnail` only
    /// plays the crossfade the first time a non-nil image arrives (icon → thumbnail); a later
    /// update to a fresher capture of the same window swaps in instantly, no repeated fade.
    private var currentThumbnail: CGImage?
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
        backgroundColor = nil
        borderWidth = 0
        shadowColor = NSColor.controlAccentColor.cgColor
        shadowOffset = .zero
        shadowRadius = 8
        shadowOpacity = 0

        for (index, stackedLayer) in stackedThumbnailLayers.enumerated() {
            // 先加远层再加近层，最后由正面 thumbnailContainer 覆盖；右上方露出少量边缘。
            let offset = CGFloat(stackedThumbnailLayers.count - index) * 3
            stackedLayer.frame = CGRect(
                x: SwitcherMetrics.cardPadding + offset,
                y: SwitcherMetrics.cardPadding + offset * 0.7,
                width: cardStyle.thumbnailSize.width,
                height: cardStyle.thumbnailSize.height
            )
            stackedLayer.cornerRadius = SwitcherMetrics.thumbnailCornerRadius
            stackedLayer.masksToBounds = true
            stackedLayer.contentsGravity = .resizeAspectFill
            stackedLayer.backgroundColor = nil
            stackedLayer.borderWidth = 0.5
            stackedLayer.borderColor = cardStyle.badgeBorderColor
            stackedLayer.isHidden = true
            addSublayer(stackedLayer)
        }

        thumbnailShadowLayer.frame = CGRect(
            x: SwitcherMetrics.cardPadding,
            y: SwitcherMetrics.cardPadding,
            width: cardStyle.thumbnailSize.width,
            height: cardStyle.thumbnailSize.height
        )
        thumbnailShadowLayer.shadowColor = NSColor.black.cgColor
        thumbnailShadowLayer.shadowOpacity = cardStyle.thumbnailShadowOpacity
        thumbnailShadowLayer.shadowRadius = 4
        thumbnailShadowLayer.shadowOffset = CGSize(width: 0, height: 1)
        thumbnailShadowLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: cardStyle.thumbnailSize),
            cornerWidth: SwitcherMetrics.thumbnailCornerRadius,
            cornerHeight: SwitcherMetrics.thumbnailCornerRadius,
            transform: nil
        )
        addSublayer(thumbnailShadowLayer)

        thumbnailContainer.frame = thumbnailShadowLayer.bounds
        thumbnailContainer.masksToBounds = true
        thumbnailContainer.cornerRadius = SwitcherMetrics.thumbnailCornerRadius
        thumbnailContainer.backgroundColor = nil
        thumbnailContainer.borderWidth = 0.75
        thumbnailContainer.borderColor = cardStyle.thumbnailBorderColor
        thumbnailShadowLayer.addSublayer(thumbnailContainer)

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

        updateBadgeStack(count: 1, icon: nil, contentsScale: 1)

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
    func update(
        appName: String,
        title: String,
        icon: NSImage?,
        thumbnail: CGImage?,
        stackedThumbnails: [CGImage?],
        groupCount: Int,
        contentsScale: CGFloat
    ) {
        let fixedLayers: [CALayer] = [
            self, thumbnailShadowLayer, thumbnailContainer, iconLayer, thumbnailLayer, appNameLayer, titleLayer
        ]
        for sublayer in fixedLayers + stackedThumbnailLayers {
            sublayer.contentsScale = contentsScale
        }

        appNameLayer.string = appName
        // 关掉标题行时 `titleLayer` 根本没有被加进图层树（见 `setUp`），这里也就不必写它。
        if cardStyle.showsWindowTitle {
            titleLayer.string = title
        }
        iconLayer.contents = icon

        for (index, stackedLayer) in stackedThumbnailLayers.enumerated() {
            guard index < stackedThumbnails.count, let stackedThumbnail = stackedThumbnails[index] else {
                stackedLayer.isHidden = true
                stackedLayer.contents = nil
                continue
            }
            let offset = CGFloat(stackedThumbnailLayers.count - index) * 3
            stackedLayer.frame = fittedThumbnailFrame(for: stackedThumbnail).offsetBy(
                dx: offset,
                dy: offset * 0.7
            )
            stackedLayer.isHidden = false
            stackedLayer.contents = stackedThumbnail
        }

        if let thumbnail {
            applyThumbnail(thumbnail)
        }
        updateBadgeStack(count: groupCount, icon: icon, contentsScale: contentsScale)
    }

    private func makeBadgeLayers() {
        let badgeSize = SwitcherMetrics.badgeSize
        let badgeCorner = SwitcherMetrics.badgeCornerRadius
        let badgeBounds = CGRect(origin: .zero, size: CGSize(width: badgeSize, height: badgeSize))

        let shadowLayer = CALayer()
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.5
        shadowLayer.shadowRadius = 3
        shadowLayer.shadowOffset = CGSize(width: 0, height: 1)
        shadowLayer.shadowPath = CGPath(
            roundedRect: badgeBounds,
            cornerWidth: badgeCorner,
            cornerHeight: badgeCorner,
            transform: nil
        )
        addSublayer(shadowLayer)

        let badgeLayer = CALayer()
        badgeLayer.frame = badgeBounds
        badgeLayer.cornerRadius = badgeCorner
        badgeLayer.masksToBounds = true
        badgeLayer.backgroundColor = cardStyle.badgeBackground
        badgeLayer.borderWidth = 1
        badgeLayer.borderColor = cardStyle.badgeBorderColor
        badgeLayer.contentsGravity = .resizeAspect
        shadowLayer.addSublayer(badgeLayer)

        badgeShadowLayers.append(shadowLayer)
        badgeLayers.append(badgeLayer)
    }

    /// 图标堆叠始终整体水平居中；数量较多时自动增加重叠量，保证每扇聚合窗口仍对应一枚图标，
    /// 且不会撑出缩略图区。
    private func updateBadgeStack(count: Int, icon: NSImage?, contentsScale: CGFloat) {
        let badgeCount = max(1, count)
        while badgeShadowLayers.count < badgeCount {
            makeBadgeLayers()
        }
        while badgeShadowLayers.count > badgeCount {
            badgeShadowLayers.removeLast().removeFromSuperlayer()
            badgeLayers.removeLast()
        }

        let badgeSize = SwitcherMetrics.badgeSize
        let maxStackWidth = max(badgeSize, cardStyle.thumbnailSize.width - 16)
        let step = badgeCount > 1
            ? min(badgeSize * 0.58, (maxStackWidth - badgeSize) / CGFloat(badgeCount - 1))
            : 0
        let stackWidth = badgeSize + step * CGFloat(badgeCount - 1)
        let startX = SwitcherMetrics.cardPadding + (cardStyle.thumbnailSize.width - stackWidth) / 2
        let y = SwitcherMetrics.cardPadding - badgeSize * 0.25

        for index in badgeShadowLayers.indices {
            let shadowLayer = badgeShadowLayers[index]
            let badgeLayer = badgeLayers[index]
            shadowLayer.frame = CGRect(
                x: startX + CGFloat(index) * step,
                y: y,
                width: badgeSize,
                height: badgeSize
            )
            shadowLayer.contentsScale = contentsScale
            badgeLayer.contentsScale = contentsScale
            badgeLayer.contents = icon
        }
    }

    /// `thumbnailSize` 是每张卡片可使用的最大区域，不等于截图本身的显示边界。窄窗口会在
    /// 该区域内等比居中；描边和投影必须跟随这个实际 frame，不能继续包住整个最大区域。
    private func fittedThumbnailFrame(for image: CGImage) -> CGRect {
        let availableSize = cardStyle.thumbnailSize
        guard image.width > 0, image.height > 0 else {
            return CGRect(origin: CGPoint(x: SwitcherMetrics.cardPadding, y: SwitcherMetrics.cardPadding), size: availableSize)
        }

        let imageSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let scale = min(availableSize.width / imageSize.width, availableSize.height / imageSize.height)
        let fittedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: SwitcherMetrics.cardPadding + (availableSize.width - fittedSize.width) / 2,
            y: SwitcherMetrics.cardPadding + (availableSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func updateThumbnailGeometry(for image: CGImage) {
        let fittedFrame = fittedThumbnailFrame(for: image)
        let fittedBounds = CGRect(origin: .zero, size: fittedFrame.size)
        let iconSize = max(24, min(48, min(fittedFrame.width, fittedFrame.height) * 0.48))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbnailShadowLayer.frame = fittedFrame
        thumbnailShadowLayer.shadowPath = CGPath(
            roundedRect: fittedBounds,
            cornerWidth: SwitcherMetrics.thumbnailCornerRadius,
            cornerHeight: SwitcherMetrics.thumbnailCornerRadius,
            transform: nil
        )
        thumbnailContainer.frame = fittedBounds
        thumbnailLayer.frame = fittedBounds
        iconLayer.frame = CGRect(
            x: (fittedFrame.width - iconSize) / 2,
            y: (fittedFrame.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        CATransaction.commit()
    }

    private func applyThumbnail(_ image: CGImage) {
        guard currentThumbnail !== image else { return }
        let isFirstAppearance = currentThumbnail == nil
        currentThumbnail = image
        updateThumbnailGeometry(for: image)

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

}
