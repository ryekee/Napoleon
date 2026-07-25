import CoreGraphics
import NapoleonCore

/// Task X4：私有 CGS API 封装——判定一个跨 Space windowID 是否位于全屏 Space（type==4）。
/// Spike（`spikes/window-space-class/main.swift`，macOS 26 已实测）验证过这套 dlsym 绑定/
/// 参数：`CGSCopySpacesForWindows(cid, 0x7, [windowID]) -> [Int]`（该窗口所在的 space id 列表）
/// + `CGSCopyManagedDisplaySpaces(cid)`（各 display 的 Space 列表，`type==4` 即全屏）。这里
/// 原样复用同一套签名/dlsym 探测方式，不做改动。
///
/// 私有 API 一律 dlsym 探测、缓存进 `static let`（探测只做一次，dlsym 不便宜）；任一符号缺失
/// （系统版本变化导致私有符号消失）时 `isOnFullscreenSpace` 恒返回 `false`——优雅降级：全屏
/// 窗口这时会被 `WindowFilter` 当成普通跨 Space 窗口处理（默认隐藏，`includeOtherSpaces`
/// 开关可兜底显示），不会崩溃、也不会误判成「全屏」。
///
/// 不是 `Sendable`——只作为 `WindowStore`（`@MainActor`）的私有存储属性使用，跟同类型的
/// `ScreenWindowLister`/`WindowEnumerator` 一样不需要跨 actor 传递。
final class SpaceClassifier {
    private typealias CGSConnectionID = Int32
    private typealias MainConnFn = @convention(c) () -> CGSConnectionID
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    // CGSCopySpacesForWindows(cid, mask, windowIDsArray) -> spaceIDs；mask 0x7 = current|other|all
    // （与 spike 一致，查一个 windowID 所在的所有 space，不限于当前可见的那个）。
    private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, UInt32, CFArray) -> Unmanaged<CFArray>?

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) /* RTLD_DEFAULT */ else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let mainConnectionFn: MainConnFn? = sym("CGSMainConnectionID", MainConnFn.self)
    private static let copyManagedDisplaySpacesFn: CopyManagedDisplaySpacesFn? =
        sym("CGSCopyManagedDisplaySpaces", CopyManagedDisplaySpacesFn.self)
            ?? sym("SLSCopyManagedDisplaySpaces", CopyManagedDisplaySpacesFn.self)
    private static let copySpacesForWindowsFn: CopySpacesForWindowsFn? =
        sym("CGSCopySpacesForWindows", CopySpacesForWindowsFn.self)
            ?? sym("SLSCopySpacesForWindows", CopySpacesForWindowsFn.self)

    private static let spacesForWindowsMask: UInt32 = 0x7

    /// `refresh()` 建好的「全屏 Space id」集合（`id64`/`ManagedSpaceID`）。`refresh()` 从未
    /// 成功调用过，或私有符号缺失时保持为空集合——`isOnFullscreenSpace` 因此自然全部返回
    /// `false`，不需要额外的可用性标志位。
    private var fullscreenSpaceIDs: Set<Int> = []

    /// `refresh()` 时全部 display 上**所有** Space 的 id 集合（桌面 + 全屏都算）。供
    /// `escapeAwareAdditions` 的精确兜底判「逃生锚点 `lastDesktopSpaceIDs` 是否还存在于当前拓扑
    /// 里」——锚点与它不相交 = 锚点指向的桌面已被删（fable 审查第 3 轮 Minor #1）。私有符号
    /// 缺失/查询失败时为空集。
    private(set) var allSpaceIDs: Set<Int> = []

    /// 逐窗口 Space 查询（`CGSCopySpacesForWindows`）的私有符号是否可用。`escapeAwareAdditions`
    /// 用它区分「收窄机制坏了（符号缺失，`isOnAnySpace` 恒 false）」与「机制正常但出发桌面真的
    /// 空了」——前者才 fail-open 泛洪，后者只显全屏 App（fable 审查第 3 轮 Minor #1）。
    var canQueryWindowSpaces: Bool { Self.copySpacesForWindowsFn != nil }

    /// 全屏逃生：用户此刻所在的 Space（任一 display 的 `Current Space`）是不是全屏（`type==4`）。
    /// `refresh()` 每次全量刷新时重算；私有符号缺失/CGS 查询失败时保持 `false`（降级：等同
    /// 普通桌面，不会误开逃生放行）。多 display 时只要有一个 display 的当前 Space 是全屏就为
    /// `true`——单 display（最常见）下即精确等于「当前 Space 是否全屏」；多 display 下偏保守地
    /// 多显示窗口（只会让列表更全、绝不漏显该显的窗口），是可接受的 v1 取舍。
    private(set) var currentSpaceIsFullscreen: Bool = false

    /// 全屏逃生：`refresh()` 时**每个 display** 各自当前 Space 的 id 集合（`id64`/`ManagedSpaceID`）。
    /// `WindowStore` 在「不在全屏」（`currentSpaceIsFullscreen == false`，即没有任何 display 在
    /// 全屏、每个 display 的当前 Space 都是桌面）时把它整份记成 `lastDesktopSpaceIDs`，之后进
    /// 全屏用它 + `isOnAnySpace(_:of:)` 把逃生列表收窄到「刚离开的那些桌面」的窗口。
    ///
    /// **为什么是集合而不是单个 id**：双显示器下用户可能在**副屏**进全屏，此时「首个 display」
    /// 的当前 Space 并不是用户刚离开的那个桌面——记单个 id 会把副屏桌面的窗口整片漏掉（fable
    /// 审查第 2 轮 #1）。记下所有 display 的当前桌面 Space，逃生时任一命中即保留，副屏/主屏
    /// 都能回。私有符号缺失/查询失败时为空集。
    private(set) var currentSpaceIDs: Set<Int> = []

    init() {}

    /// 重新扫一遍当前 Space 拓扑，重建 `fullscreenSpaceIDs`。每次全量刷新
    /// （`WindowStore.refreshNow`，CrossSpaceMerge 之前）调一次，保证跟本次要分类的窗口快照
    /// 处在同一个 Space 拓扑状态下——CGS 调用是本地 IPC（同机 Window Server 往返，无网络），
    /// 可以放心按每次全量刷新的节奏调用，不需要额外节流/缓存有效期。
    func refresh() {
        guard
            let mainConnectionFn = Self.mainConnectionFn,
            let copyManagedDisplaySpacesFn = Self.copyManagedDisplaySpacesFn
        else {
            fullscreenSpaceIDs = []
            allSpaceIDs = []
            currentSpaceIsFullscreen = false
            currentSpaceIDs = []   // fable 审查第 2 轮 #5：与下方 guard 一致地一并重置（当前不可达，纯一致性）。
            return
        }

        let cid = mainConnectionFn()
        guard let displays = copyManagedDisplaySpacesFn(cid)?.takeRetainedValue() as? [[String: Any]] else {
            fullscreenSpaceIDs = []
            allSpaceIDs = []
            currentSpaceIsFullscreen = false
            currentSpaceIDs = []
            return
        }

        var fullscreenIDs = Set<Int>()
        var allIDs = Set<Int>()
        var currentFullscreen = false
        var currentDesktopIDs = Set<Int>()
        for display in displays {
            let spaces = (display["Spaces"] as? [[String: Any]]) ?? []
            for space in spaces {
                let sid = (space["id64"] as? Int) ?? (space["ManagedSpaceID"] as? Int)
                if let sid { allIDs.insert(sid) }
                if (space["type"] as? Int) == 4, let sid { fullscreenIDs.insert(sid) }
            }
            // 全屏逃生：这个 display 当前正显示的 Space。跟 spike 一致读 `Current Space` 的
            // `type`（0=桌面 / 4=全屏）：type==4 → 置 `currentFullscreen`；type==0 → 收进逃生锚点
            // 候选 `currentDesktopIDs`（供 `WindowStore` 记锚点——双显示器副屏进全屏必须记全每个
            // display 的桌面，否则漏掉副屏桌面窗口）。其它过渡态 type 两者都不做（fable 审查第 3
            // 轮 Minor #2：避免过渡态 id 混进锚点集合）。
            let current = display["Current Space"] as? [String: Any]
            let currentType = current?["type"] as? Int
            if currentType == 4 {
                currentFullscreen = true
            } else if currentType == 0,
                      let sid = (current?["id64"] as? Int) ?? (current?["ManagedSpaceID"] as? Int) {
                currentDesktopIDs.insert(sid)
            }
        }
        fullscreenSpaceIDs = fullscreenIDs
        allSpaceIDs = allIDs
        currentSpaceIsFullscreen = currentFullscreen
        currentSpaceIDs = currentDesktopIDs
    }

    /// 查 `windowID` 所在的全部 Space id（`CGSCopySpacesForWindows`）。私有符号缺失/查询失败
    /// 返回 `nil`——两个调用方（`isOnFullscreenSpace`/`isOnSpace`）都把 `nil` 当「查不到 →
    /// `false`」处理，降级语义见类型文档注释。
    private func spaceIDs(for windowID: WindowID) -> [Int]? {
        guard
            let mainConnectionFn = Self.mainConnectionFn,
            let copySpacesForWindowsFn = Self.copySpacesForWindowsFn
        else {
            return nil
        }
        let cid = mainConnectionFn()
        let windowIDs = [CGWindowID(windowID)] as CFArray
        return copySpacesForWindowsFn(cid, Self.spacesForWindowsMask, windowIDs)?.takeRetainedValue() as? [Int]
    }

    /// `windowID` 是否位于一个全屏 Space（`refresh()` 建的 `fullscreenSpaceIDs` 里任一）。
    /// 私有符号缺失、这次 CGS 查询失败，或 `fullscreenSpaceIDs` 为空（`refresh()` 从未成功
    /// 建过映射/当前压根没有全屏 Space），都返回 `false`——降级语义见类型文档注释。
    func isOnFullscreenSpace(_ windowID: WindowID) -> Bool {
        guard !fullscreenSpaceIDs.isEmpty else { return false }
        guard let spaces = spaceIDs(for: windowID) else { return false }
        return spaces.contains { fullscreenSpaceIDs.contains($0) }
    }

    /// 全屏逃生：`windowID` 是否位于给定集合里的**任一** Space（把全屏浮层里的桌面窗口收窄到
    /// 用户逃生要回去的那些桌面 `lastDesktopSpaceIDs`）。私有符号缺失/查询失败一律 `false`——
    /// 宁可少显一扇也不误显别的桌面的窗口；调用方 `escapeAwareAdditions` 对「整片查询失效导致
    /// 逃生列表为空」另有兜底（见那里的 fallback），所以这里的保守失败不会把用户困住。
    func isOnAnySpace(_ windowID: WindowID, of anchors: Set<Int>) -> Bool {
        guard let windowSpaces = spaceIDs(for: windowID) else { return false }
        return windowSpaces.contains { anchors.contains($0) }
    }
}
