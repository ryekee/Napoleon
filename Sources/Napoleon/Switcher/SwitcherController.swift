import AppKit
import ApplicationServices
import Foundation
import NapoleonCore
import os

/// Task 19：把前面全部组件（`HotkeyManager` / `WindowStore` / `ThumbnailService` /
/// `WindowFocuser` / `OverlayPanel` / `SwitcherView` / `SelectionModel` / `WindowFilter` /
/// `SettingsStore`）编排成真正的切换器——本类型是唯一的 `HotkeyManagerDelegate`，取代
/// `NapoleonApp.swift` 里全部 TEMP 接线。
///
/// **修的三个真机 bug**：
/// 1. `commitFocus()` 聚焦 `items[selection.index].primary`——真实选中项，不再是固定的 `MRU[1]`。
/// 2. 有 AX 句柄（当前 Space）走 `WindowFocuser.focus`；没有句柄（跨 Space/全屏）走
///    `WindowFocuser.focusApp(pid:)`。
/// 3. 显示范围默认「当前 Space + 全屏」（`SettingsStore.includeOtherSpaces` 默认 `false`，桌面
///    列表保持干净）；当用户被困在全屏 Space 时，`handleTrigger` 把 `snapshot()` 带回的
///    `currentSpaceIsFullscreen` 传给 `WindowFilter.apply`，临时放开跨 Space 过滤，让桌面窗口
///    重新进入列表，从而能借切换器切回桌面（focusApp 兜底完成跨 Space 聚焦）。
///
/// **会话状态**：一次 `hotkeyDidTrigger` → `hotkeyDidCommit`/`hotkeyDidCancel` 之间有效，
/// commit/cancel 都会清空（`resetSessionState()`），下次 trigger 重新建立——不跨会话残留。
///
/// **线程**：`HotkeyManagerDelegate` 协议本身不是 `@MainActor`（`HotkeyManager` 的线程模型
/// 文档保证所有 delegate 回调都经 `DispatchQueue.main.async` 派发），本类型标 `@MainActor`
/// 图内部状态/其它方法方便，但满足协议要求的那几个方法本身声明成 `nonisolated`，函数体内用
/// `MainActor.assumeIsolated { ... }` 把「已知处在主线程」这个事实告诉类型系统——跟旧
/// `AppDelegate` TEMP 接线用的是同一套手法。
@MainActor
final class SwitcherController: HotkeyManagerDelegate {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "SwitcherController")

    /// 缩略图抓取尺寸相对卡片缩略图区的倍率。2.5× 是 Phase 5 的既有关系（160×100 → 400×250）：
    /// 覆盖 2× Retina 还留一点余量，不追求恰好命中。
    ///
    /// 做成按当前卡片档位派生（而不是固定 400×250）——「大」档缩略图区 220×138pt，在 2× 屏上需要
    /// 440×276px，固定 400×250 会让图被 `.resizeAspect` 放大约 10%，大档位反而更糊。
    private static let thumbnailCaptureScale: CGFloat = 2.5

    private func thumbnailCaptureSize(for style: SwitcherStyle) -> CGSize {
        CGSize(
            width: style.thumbnailSize.width * Self.thumbnailCaptureScale,
            height: style.thumbnailSize.height * Self.thumbnailCaptureScale
        )
    }

    private let windowStore: WindowStore
    private let thumbnails: ThumbnailService
    private let settings: SettingsStore
    private let overlay: OverlayPanel
    private let cancelHotkeySession: () -> Void
    private let recordSearch: (String, [WindowInfo]) -> Void

    // MARK: - Session state（一次 trigger→commit/cancel 有效，见类型头注释）

    private var mode: SwitchMode = .allWindows
    /// trigger 时刻的过滤结果，**不随搜索变化**——`WindowFilter.search` 每次都对这份不变的
    /// 基线重新过滤，而不是对上一次搜索的结果再过滤（否则退格键删不回之前被滤掉的窗口）。
    private var baseFiltered: [WindowInfo] = []
    /// 当前实际显示/参与聚焦判定的列表——trigger 时等于 `baseFiltered`，搜索时替换成
    /// `WindowFilter.search` 的结果。逐窗口/按 App 聚合都以它为输入。
    private var ordered: [WindowInfo] = []
    /// 真正显示和参与选中索引的卡片项。它始终由 `ordered` 和当前聚合设置派生，避免搜索、
    /// 快速切换聚合方式时维护两份列表而发生漂移。
    private var items: [SwitcherItem] {
        let result = SwitcherItem.make(from: ordered, groupByApplication: isApplicationGroupingActive)
        guard isApplicationGroupingActive else { return result }
        return result.map { item in
            guard let selectedWindowID = groupPrimaryWindowIDs[item.id] else { return item }
            return item.selectingWindow(id: selectedWindowID)
        }
    }
    private var handles: [WindowID: AXUIElement] = [:]
    private var query = ""
    /// 最近一次 `render(...)` 返回的列数，`hotkeyDidMove` 的 `moveInGrid` 要用；
    /// 面板还没显示过（`shown == false`）时保持 1，让方向键在这之前退化成「单列」导航
    /// （dy 上下移动等价于 next/previous，dx 无效果），不会因为列数未知而崩或乱跳。
    private var columns = 1
    private var selection = SelectionModel(count: 0)
    /// 每个聚合卡片当前放到正面的窗口。key 是组内 MRU 第一扇窗口（稳定卡片 id），value 是
    /// 用户在该组里用 ⌘+` 选中的窗口；松开 Cmd 时 `commitFocus()` 聚焦这个 primary。
    private var groupPrimaryWindowIDs: [WindowID: WindowID] = [:]
    /// 每次会话新建一个实例（不像 `overlay` 跨会话复用）——`SwitcherView` 内部按 WindowID
    /// 复用的 `WindowCardLayer` 池只需要在同一次会话内维持缩略图淡入状态。
    private var switcherView: SwitcherView?
    /// 显示延迟到点前挂起的 `present()` 调用；下一次 trigger、字符输入触发的立即 present、
    /// 或者 commit/cancel 都会 `cancel()` 它，防止过期触发（重复 present 或在会话已经清空后
    /// 把面板重新弹出来）。
    private var pendingShow: DispatchWorkItem?
    /// 面板这次会话是否已经真正显示过——`false` 时 forward/backward/move/deleteChar 只更新
    /// 内部 `selection`，不触碰 UI（还没到显示延迟阈值）；`hotkeyDidReceiveChar` 是唯一在
    /// `false` 时会主动翻成 `true` 的入口（用户开始打字说明想要看到面板）。
    private var shown = false
    /// 每次 trigger/reset 自增——`fetchThumbnails` 里异步抓图完成后拿它跟当前值比对，
    /// 过期（跨会话）的抓图结果不会触发 `rerender()`，不会在 commit/cancel 之后把已经
    /// dismiss 的面板意外重新 present 出来。
    private var sessionToken = 0

    init(
        windowStore: WindowStore,
        thumbnails: ThumbnailService,
        settings: SettingsStore,
        overlay: OverlayPanel,
        cancelHotkeySession: @escaping () -> Void,
        recordSearch: @escaping (String, [WindowInfo]) -> Void = { _, _ in }
    ) {
        self.windowStore = windowStore
        self.thumbnails = thumbnails
        self.settings = settings
        self.overlay = overlay
        self.cancelHotkeySession = cancelHotkeySession
        self.recordSearch = recordSearch
        overlay.onClickOutside = { [weak self] in
            self?.handleOutsideClick()
        }
    }

    // MARK: - HotkeyManagerDelegate

    nonisolated func hotkeyDidTrigger(_ trigger: HotkeyTrigger) {
        MainActor.assumeIsolated { self.handleTrigger(trigger) }
    }

    nonisolated func hotkeyDidStepForward() {
        MainActor.assumeIsolated { self.handleStepForward() }
    }

    nonisolated func hotkeyDidStepBackward() {
        MainActor.assumeIsolated { self.handleStepBackward() }
    }

    nonisolated func hotkeyDidStepWithinGroup(backward: Bool) {
        MainActor.assumeIsolated { self.handleStepWithinGroup(backward: backward) }
    }

    nonisolated func hotkeyDidReceiveChar(_ s: String) {
        MainActor.assumeIsolated { self.handleReceiveChar(s) }
    }

    nonisolated func hotkeyDidDeleteChar() {
        MainActor.assumeIsolated { self.handleDeleteChar() }
    }

    nonisolated func hotkeyDidMove(dx: Int, dy: Int) {
        MainActor.assumeIsolated { self.handleMove(dx: dx, dy: dy) }
    }

    nonisolated func hotkeyDidCancel() {
        MainActor.assumeIsolated { self.handleCancel() }
    }

    nonisolated func hotkeyDidCommit() {
        MainActor.assumeIsolated { self.finishSession(focus: true) }
    }

    // MARK: - Orchestration (runs on MainActor)

    /// 每次触发（Cmd+Tab / Cmd+`）重新建立本次会话：拍一次 `WindowStore` 快照、按 mode+scope
    /// 过滤、按 MRU 排好序，默认选中「上一个窗口」（index 1，没有上一个就是 0）。**不立即
    /// present**——排一个 `showDelayMs` 之后触发的 `DispatchWorkItem`；如果 commit 在延迟窗口
    /// 内到来（经典快速切换），`finishSession` 会先 `cancel()` 掉它，面板永远不会弹出，直接
    /// 聚焦此刻的 `selection`（此时就是默认的「上一个窗口」）。
    private func handleTrigger(_ trigger: HotkeyTrigger) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        switch trigger {
        case .allWindows:
            mode = .allWindows
        case .currentApp:
            mode = .currentApp(NSWorkspace.shared.frontmostApplication?.windowOwnerPID ?? -1)
        }

        let (state, hs, currentSpaceIsFullscreen) = windowStore.snapshot()
        let mruOrdered = state.mru.ordered(state.windows)
        // 全屏逃生：人所在 Space 本身是全屏时，`WindowFilter` 会放开跨 Space 过滤，让桌面窗口
        // 重新进入列表（否则全屏 Space 只有那一扇全屏窗口，切换器无法切回桌面）——见 `WindowFilter`。
        let filtered = WindowFilter.apply(
            mruOrdered,
            mode: mode,
            scope: settings.scope,
            currentSpaceIsFullscreen: currentSpaceIsFullscreen
        )

        baseFiltered = filtered
        ordered = filtered
        handles = hs
        query = ""
        columns = 1
        shown = false
        switcherView = nil
        groupPrimaryWindowIDs = [:]
        selection = SelectionModel(count: items.count, initial: items.count > 1 ? 1 : 0)

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        Self.logger.info("trigger: \(filtered.count, privacy: .public) windows, mode=\(String(describing: trigger), privacy: .public), prepare_ms=\(elapsedMs, format: .fixed(precision: 3), privacy: .public)")

        pendingShow?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.present() }
        pendingShow = workItem
        let delay = Double(settings.showDelayMs) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// 显示延迟到点（或搜索提前触发）时真正显示面板：建 `SwitcherView`、接 hover/click、渲染、
    /// present、再对当前列表异步抓缩略图。会取消任何还没触发的 `pendingShow`——不管这次
    /// `present()` 是由那个 `DispatchWorkItem` 自己触发的（此时 cancel 自身是无害的 no-op），
    /// 还是被 `handleReceiveChar` 提前调用的（这次必须取消，否则延迟到点后那个旧
    /// `DispatchWorkItem` 会再触发一次，重复 present）。
    private func present() {
        pendingShow?.cancel()
        pendingShow = nil
        shown = true

        let style = currentStyle()
        let view = SwitcherView(frame: .zero, style: style)
        view.onHover = { [weak self] index in
            guard let self else { return }
            self.selection.select(index)
            self.rerender()
        }
        view.onClick = { [weak self] index in
            guard let self else { return }
            self.selection.select(index)
            self.finishSession(focus: true)
        }
        view.onToggleGrouping = { [weak self] in
            self?.toggleApplicationGrouping()
        }
        switcherView = view

        let (cols, size) = view.render(
            items: items,
            selected: selection.index,
            query: query,
            groupingByApplication: isApplicationGroupingActive,
            showsGroupingToggle: mode == .allWindows,
            iconProvider: Self.icon(for:),
            thumbnailProvider: { [thumbnails] id in thumbnails.cached(id) }
        )
        columns = cols

        overlay.setContentView(view)
        overlay.present(contentSize: size)

        fetchThumbnails(for: ordered, token: sessionToken, captureSize: thumbnailCaptureSize(for: style))
    }

    /// 用当前 `items`/`selection` 重新渲染并重新居中面板——内容/尺寸变了（搜索/方向键/
    /// hover/缩略图到达）都要走这条路径。面板还没显示过（`switcherView == nil`）时是 no-op，
    /// 这也是 `fetchThumbnails` 里过期抓图结果不会意外把已 dismiss 的面板重新弹出来的关键
    /// 一环（`resetSessionState()`/`handleTrigger` 都会把 `switcherView` 置 `nil`）。
    private func rerender() {
        guard let view = switcherView else { return }
        let (cols, size) = view.render(
            items: items,
            selected: selection.index,
            query: query,
            groupingByApplication: isApplicationGroupingActive,
            showsGroupingToggle: mode == .allWindows,
            iconProvider: Self.icon(for:),
            thumbnailProvider: { [thumbnails] id in thumbnails.cached(id) }
        )
        columns = cols
        overlay.present(contentSize: size)
    }

    private func handleStepForward() {
        selection.next()
        if shown { rerender() }
    }

    private func handleStepBackward() {
        selection.previous()
        if shown { rerender() }
    }

    private func handleStepWithinGroup(backward: Bool) {
        guard isApplicationGroupingActive else { return }
        let currentItems = items
        guard currentItems.indices.contains(selection.index) else { return }

        let current = currentItems[selection.index]
        let next = current.steppingPrimary(backward: backward)
        guard next.primary.id != current.primary.id else { return }

        groupPrimaryWindowIDs[current.id] = next.primary.id
        if shown { rerender() }
    }

    private func handleMove(dx: Int, dy: Int) {
        selection.moveInGrid(dx: dx, dy: dy, columns: columns)
        if shown { rerender() }
    }

    /// 搜索：字符追加进 `query`，对不变的 `baseFiltered` 重新 `WindowFilter.search`，替换
    /// `ordered`、重置选中态、重算尺寸/重定位。还没显示过面板时立即 `present()`——用户开始
    /// 打字就是想要看到面板，不用等显示延迟阈值。
    private func handleReceiveChar(_ s: String) {
        query += s
        recomputeSearch()
        if shown {
            rerender()
        } else {
            present()
        }
    }

    /// 退格：去掉 `query` 尾字符，重新搜索。跟 forward/backward 同样的「未显示则只更新内部
    /// 状态」原则——不像 `handleReceiveChar` 那样在未显示时强制 present（退格不代表用户开始
    /// 想要面板，只有真正打了字符才代表）。
    private func handleDeleteChar() {
        if !query.isEmpty {
            query.removeLast()
        }
        recomputeSearch()
        if shown { rerender() }
    }

    private func recomputeSearch() {
        // 拼音是否参与匹配现读设置——开关下一次按键即生效（见 `WindowFilter.search`）。
        let results = WindowFilter.search(baseFiltered, query: query, includePinyin: settings.pinyinSearchEnabled)
        recordSearch(query, results)
        ordered = results
        groupPrimaryWindowIDs = [:]
        selection.setCount(items.count)
        selection.resetSelection()
    }

    /// 顶部快捷按钮只服务“全部窗口”模式。切换后持久化同一设置，并尽量保留原先选中的窗口/App，
    /// 避免卡片数量改变时选中态跳到无关目标。
    private func toggleApplicationGrouping() {
        guard mode == .allWindows else { return }
        let selectedWindowID: WindowID? = items.indices.contains(selection.index)
            ? items[selection.index].primary.id
            : nil

        settings.groupWindowsByApplication.toggle()
        groupPrimaryWindowIDs = [:]
        selection.setCount(items.count)

        if let selectedWindowID,
           let newIndex = items.firstIndex(where: { item in item.windows.contains { $0.id == selectedWindowID } }) {
            selection.select(newIndex)
            if isApplicationGroupingActive {
                groupPrimaryWindowIDs[items[newIndex].id] = selectedWindowID
            }
        } else {
            selection.resetSelection()
        }
        rerender()
    }

    /// Esc：取消未到点的显示延迟、收起面板、清空会话——**不聚焦任何窗口**。
    private func handleCancel() {
        pendingShow?.cancel()
        pendingShow = nil
        overlay.dismiss()
        resetSessionState()
    }

    /// 鼠标点到浮层外：与 Esc 一样立即收起且不聚焦；另外主动结束 tap 线程 session，避免继续
    /// 吞键或在 Cmd 松开时补发一次 commit。
    private func handleOutsideClick() {
        cancelHotkeySession()
    }

    /// commit（松开触发 chord 的修饰键，或鼠标点击卡片）的共同收尾：取消未到点的显示延迟、
    /// 按需聚焦、收起面板、清空会话。`focus == false` 目前没有调用方用到（Esc 走独立的
    /// `handleCancel`），保留这个参数是让「commit 但不聚焦」这类未来场景（如果有）不需要
    /// 再拆一份重复的收尾逻辑。
    private func finishSession(focus: Bool) {
        pendingShow?.cancel()
        pendingShow = nil
        if focus {
            commitFocus()
        }
        overlay.dismiss()
        resetSessionState()
    }

    /// 问题 1/2 的核心修复：聚焦 `items[selection.index].primary`——真实选中的这一项，不再是固定的
    /// `MRU[1]`。`selection.index` 由 `SelectionModel` 自身保证落在 `[0, count-1]`
    /// （`count == items.count`，`setCount`/`select`/`moveInGrid` 全部会 clamp），这里的
    /// guard 是最后一道防线，不依赖那个不变式。
    private func commitFocus() {
        guard selection.index >= 0, selection.index < items.count else {
            Self.logger.info("commitFocus: no valid selection (count=\(self.items.count, privacy: .public))")
            return
        }
        let target = items[selection.index].primary

        if let element = handles[target.id] {
            let ok = WindowFocuser.focus(windowID: target.id, element: element, pid: target.pid)
            if ok { windowStore.recordCommittedFocus(target.id) }
            Self.logger.info("commitFocus: focus(AX) \(target.appName, privacy: .public) ok=\(ok, privacy: .public)")
        } else {
            // 跨 Space/无句柄——已知 v1 局限：多窗口 App 只能到 App 级，不保证精准聚焦那一扇窗口。
            let ok = WindowFocuser.focusApp(pid: target.pid)
            if ok { windowStore.recordCommittedActivation(pid: target.pid) }
            Self.logger.info("commitFocus: focusApp(cross-space) \(target.appName, privacy: .public) ok=\(ok, privacy: .public)")
        }
    }

    /// 会话结束（commit/cancel）后的清空——把所有 session-only 状态复位到「没有活跃会话」，
    /// 并让 `sessionToken` 前进一格，使这次会话里还在飞行的 `fetchThumbnails` 异步回调全部
    /// 过期（见该属性文档）。
    private func resetSessionState() {
        sessionToken += 1
        mode = .allWindows
        baseFiltered = []
        ordered = []
        handles = [:]
        query = ""
        columns = 1
        selection = SelectionModel(count: 0)
        groupPrimaryWindowIDs = [:]
        switcherView = nil
        shown = false
    }

    /// 对 `windows` 里每一个窗口各自独立异步抓一张缩略图——命中就立刻 `rerender()` 让它
    /// 单独淡入（不等全部抓完再一起刷新，观感上更快）。`token` 是抓图发起那一刻的
    /// `sessionToken` 快照：抓图耗时期间如果会话已经结束/换了下一次触发，`token` 就跟
    /// 那之后新的 `sessionToken` 对不上，直接跳过——不会用一次过期抓图结果触发
    /// `rerender()`（`switcherView` 那时也多半已经是 `nil`，`rerender()` 自己也会短路，
    /// 这里提前 guard 只是避免做无意义的 `render(...)` 调用）。
    private func fetchThumbnails(for windows: [WindowInfo], token: Int, captureSize: CGSize) {
        for window in windows {
            let id = window.id
            Task { [weak self] in
                guard let self else { return }
                guard await self.thumbnails.capture(id, targetSize: captureSize) != nil else { return }
                guard self.sessionToken == token, self.shown else { return }
                self.rerender()
            }
        }
    }

    private static func icon(for window: WindowInfo) -> NSImage? {
        NSRunningApplication(processIdentifier: window.pid)?.icon
    }

    /// “当前 App 窗口”快捷键必须保持逐窗口；否则同一个 App 聚合后永远只有一项。
    private var isApplicationGroupingActive: Bool {
        mode == .allWindows && settings.groupWindowsByApplication
    }

    /// Task 21：按当前设置现算这次会话的外观参数（卡片尺寸档位、是否显示窗口标题、明暗）。
    /// 每次 `present()` 调用一次——设置改了下一次呼出自然生效，不需要设置→浮层的通知通道。
    ///
    /// `followSystemAppearance == false`（默认）时恒为深色，保持 Phase 5 起真机验证过的观感；
    /// 打开后读 `NSApp.effectiveAppearance` 判断系统当前是深色还是浅色。
    private func currentStyle() -> SwitcherStyle {
        let isDark: Bool
        if settings.followSystemAppearance {
            isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        } else {
            isDark = true
        }
        return SwitcherStyle(
            cardSize: settings.cardSize,
            showsWindowTitle: settings.showWindowTitle,
            isDark: isDark
        )
    }
}
