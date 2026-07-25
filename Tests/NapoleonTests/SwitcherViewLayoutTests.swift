import Testing
import CoreGraphics
@testable import Napoleon

// Only `SwitcherView.computeLayout` (pure column/row/contentSize math) is unit tested here — the
// rest of `SwitcherView`/`WindowCardLayer` is `CALayer`/`NSView` rendering, verified at runtime
// per the Task 18 brief.
@Suite struct SwitcherViewLayoutTests {
    @Test func fewWindowsFitOnOneRow() {
        // 3 windows, plenty of width for far more than 3 columns → single row of exactly 3,
        // not padded out to `maxCols`.
        let result = SwitcherView.computeLayout(count: 3, maxOverlayWidth: 2000)
        #expect(result.columns == 3)
        #expect(result.rows == 1)

        let expectedWidth = 3 * SwitcherStyle.default.cardStride.width - SwitcherMetrics.cardSpacing + SwitcherMetrics.containerPadding * 2
        let expectedHeight = SwitcherStyle.default.cardStride.height - SwitcherMetrics.cardSpacing + SwitcherMetrics.containerPadding * 2 + SwitcherMetrics.searchBarHeight
        #expect(result.contentSize.width == expectedWidth)
        #expect(result.contentSize.height == expectedHeight)
    }

    @Test func moreWindowsThanFitWrapIntoAGrid() {
        // Width sized for exactly 3 columns; 7 windows → 3 columns × ceil(7/3) = 3 rows, with the
        // last row left with only 1 card (left-aligned in `render(...)`, not centered — that part
        // isn't covered by this pure function, just documented here).
        let threeColumnsWidth = 3 * SwitcherStyle.default.cardStride.width
        let result = SwitcherView.computeLayout(count: 7, maxOverlayWidth: threeColumnsWidth)
        #expect(result.columns == 3)
        #expect(result.rows == 3)
    }

    @Test func maxColsNeverDropsBelowOneEvenWhenOverlayIsNarrowerThanOneCard() {
        let result = SwitcherView.computeLayout(count: 5, maxOverlayWidth: 10)
        #expect(result.columns == 1)
        #expect(result.rows == 5)
    }

    @Test func zeroWindowsReturnsEmptyLayoutWithNoDivideByZero() {
        // Even the empty case reserves the search bar band — it's fixed overlay chrome, not part
        // of the (empty) grid (task UI-Tweak §2). The width respects `minPanelContentWidth` so
        // the search bar text remains visible when the user types with no results.
        let result = SwitcherView.computeLayout(count: 0, maxOverlayWidth: 2000)
        #expect(result.columns == 0)
        #expect(result.rows == 0)
        #expect(result.contentSize == CGSize(
            width: SwitcherMetrics.minPanelContentWidth,
            height: SwitcherMetrics.containerPadding * 2 + SwitcherMetrics.searchBarHeight
        ))
    }

    @Test func exactMultipleOfCardStrideRoundsToThatManyColumns() {
        // maxOverlayWidth exactly equal to N cards' worth of stride must not round up to N+1
        // (off-by-one in the floor/`.rounded(.down)` boundary).
        let fourColumnsWidth = 4 * SwitcherStyle.default.cardStride.width
        let result = SwitcherView.computeLayout(count: 10, maxOverlayWidth: fourColumnsWidth)
        #expect(result.columns == 4)
        #expect(result.rows == 3) // ceil(10/4)
    }

    // MARK: - Task 21: style-driven card geometry

    @Test func defaultStyleMatchesPhase5Geometry() {
        // 默认档（中等 + 显示标题 + 深色）必须逐字等于 Phase 5 起真机验证过的既有尺寸——
        // 这是「默认不改变任何现有观感」的回归闸。
        let style = SwitcherStyle.default
        #expect(style.thumbnailSize == CGSize(width: 160, height: 100))
        #expect(style.cardSize == CGSize(width: 176, height: 154))
        #expect(style.isDark)
    }

    @Test func hidingWindowTitleShrinksCardByExactlyThatLine() {
        let withTitle = SwitcherStyle(showsWindowTitle: true)
        let without = SwitcherStyle(showsWindowTitle: false)
        // 关掉标题行的卡片矮了「行距 + 标题行高」，宽度不变——是真的少一行，不是留白。
        #expect(withTitle.cardSize.width == without.cardSize.width)
        #expect(withTitle.cardSize.height - without.cardSize.height
            == SwitcherMetrics.labelLineGap + SwitcherMetrics.titleHeight)
    }

    @Test func cardSizeOptionScalesThumbnailAndCard() {
        let small = SwitcherStyle(cardSize: .small)
        let medium = SwitcherStyle(cardSize: .medium)
        let large = SwitcherStyle(cardSize: .large)
        #expect(small.thumbnailSize.width < medium.thumbnailSize.width)
        #expect(medium.thumbnailSize.width < large.thumbnailSize.width)
        // 卡片宽度 = 缩略图宽 + 两侧留白，档位之间的差完全来自缩略图。
        #expect(large.cardSize.width - medium.cardSize.width
            == large.thumbnailSize.width - medium.thumbnailSize.width)
    }

    @Test func biggerCardsYieldFewerColumnsForTheSameWidth() {
        let width: CGFloat = 1200
        let smallCols = SwitcherView.computeLayout(count: 20, maxOverlayWidth: width, style: .init(cardSize: .small)).columns
        let largeCols = SwitcherView.computeLayout(count: 20, maxOverlayWidth: width, style: .init(cardSize: .large)).columns
        #expect(smallCols > largeCols)
    }

    @Test func lightStyleDiffersFromDarkInColorsOnly() {
        let dark = SwitcherStyle(isDark: true)
        let light = SwitcherStyle(isDark: false)
        // 明暗只影响配色，不影响任何几何量——否则切换外观会让浮层尺寸跳变。
        #expect(dark.cardSize == light.cardSize)
        #expect(dark.cardStride == light.cardStride)
        #expect(dark.appNameColor != light.appNameColor)
    }
}
