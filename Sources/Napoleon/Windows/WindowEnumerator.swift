import AppKit
import ApplicationServices
import CoreGraphics
import NapoleonCore
import os

/// 并发枚举当前所有「常规」App 的窗口，产出 `[WindowInfo]` + `[WindowID: AXUIElement]`
/// 句柄映射（句柄留给之后的 WindowFocuser 用来聚焦）。
///
/// **并发模型**：先在调用方线程把 `NSRunningApplication` 快照成纯值类型
/// （`AppSnapshot`：pid/appName/bundleID/isHidden，全是 Sendable 原始类型），再用
/// `withTaskGroup` 给每个 App 起一个子任务。每个子任务内部独立完成该 App 的全部
/// AX 同步调用（`AXUIElementCreateApplication` → 设 messaging timeout → 读
/// `kAXWindowsAttribute` → 逐窗口读属性），不与其它子任务共享任何可变状态，天然
/// 按 App 隔离失败——一个 App 卡死/抛错，只让它自己那个子任务返回空结果（顶多拖到
/// messaging timeout 到点），不阻塞、不影响其它 App 的子任务并发执行。
///
/// **防卡死**：AX 读取是同步 mach IPC，目标 App 卡死/无响应时默认 ~6s 超时会拖垮
/// 整个枚举。所以每个 App 的 `AXUIElement`（App 本身）在读取任何属性之前，第一步
/// 就调用 `AXUIElementSetMessagingTimeout(axApp, 0.5)`——0.5s 对正常响应的 App 完全
/// 够用，又保证单个卡死 App 最多拖 0.5s。
///
/// **Sendable 处理**：`AXUIElement`（底层是 `CFTypeRef`）本身不满足 `Sendable`。
/// 子任务的返回值内部带着 `[WindowID: AXUIElement]` 句柄映射要跨任务边界传回调用
/// 方，这里用 `AppEnumerationResult: @unchecked Sendable` 包一层——之所以标 unchecked
/// 而不是硬凑 checked conformance：这批 AX 句柄在子任务内部构造完毕后才整体返回，
/// 期间没有真正意义上的跨线程并发写入同一份可变状态（每个子任务只写自己的局部
/// 变量），而 ApplicationServices 框架本身允许在非创建线程上持有/使用 AXUIElement
/// 发起后续 AX 调用（`WindowFocuser` 后续就是从主线程用这些句柄发起 focus 调用），
/// 所以 `@unchecked` 在这里是「已核实安全」的如实标注，不是绕开检查的偷懒写法。
/// `WindowIDResolver`（Task 10）改为显式 `Sendable`——它没有任何实例存储属性
/// （只有一个 `static let` 缓存的 dlsym 探测结果），符合 `final class` 显式
/// （非 unchecked）`Sendable` conformance 的编译器验证条件，这样子任务闭包捕获它
/// 时不需要再包一层。
final class WindowEnumerator: Sendable {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "WindowEnumerator")

    private let resolver: WindowIDResolver
    /// internal（非 private）：Task 12b `WindowStore.handleTitleChanged` 需要读这个开关，
    /// 让 `.titleChanged` 事件的 pinyin 计算跟 `windowInfo(for:...)`/`enumerateAll` 用同一份
    /// 判断，行为不因走的是全量枚举还是 AX 通知增量更新而不一致。
    let pinyinEnabled: Bool

    init(resolver: WindowIDResolver = WindowIDResolver(), pinyinEnabled: Bool = true) {
        self.resolver = resolver
        self.pinyinEnabled = pinyinEnabled
    }

    /// 全量枚举。后台并发执行，返回窗口列表 + AXUIElement 句柄映射（按 WindowID）。
    func enumerateAll() async -> EnumerationResult {
        let snapshots = Self.snapshotRunningApplications()
        var appResults: [AppEnumerationResult] = []

        // 捕获 self（Sendable，无可变状态）而不是像早前版本那样把 resolver/pinyinEnabled
        // 拆成局部变量传入——这样每个子任务都走 `windowInfo(for:pid:appName:appBundleID:
        // isHiddenApp:)` 这同一条对外公开的单窗口构造路径，跟 Task 12b `WindowStore` 的
        // `.windowCreated` 事件处理共用同一份 AX 读取/过滤逻辑，不重复实现。
        await withTaskGroup(of: AppEnumerationResult.self) { group in
            for snapshot in snapshots {
                group.addTask {
                    self.enumerateWindows(of: snapshot)
                }
            }

            for await result in group {
                appResults.append(result)
            }
        }

        // AX subrole 不足以识别 Electron/Chromium 的无边框浮动窗；全部 AX 枚举完成后只读
        // 一次窗口服务器，既统一做 layer 过滤，也把同一份快照交给 Registry 审计做存在性校验。
        let result = Self.merge(
            appResults: appResults,
            windowLayerSnapshot: WindowLayerFilter.currentSnapshot()
        )
        for failure in result.failedApplications {
            Self.logger.warning(
                """
                AX window enumeration failed pid=\(failure.pid, privacy: .public) \
                app=\(failure.appName, privacy: .public) error=\(failure.axErrorRawValue, privacy: .public)
                """
            )
        }
        return result
    }

    // MARK: - Cross-task-boundary value types

    /// 单个 App 子任务的产出——该 App 的全部 AX 工作已经在子任务内部做完，这里只
    /// 是把结果值带回调用方。见类型头注释里的 Sendable 说明。
    struct ApplicationFailure: Equatable, Sendable {
        let pid: ProcessID
        let appName: String
        let axErrorRawValue: Int32
    }

    struct EnumerationResult: @unchecked Sendable {
        let appResults: [AppEnumerationResult]
        let windowLayerSnapshot: WindowLayerSnapshot?
        let failedApplications: [ApplicationFailure]
    }

    struct SuppressedWindow: @unchecked Sendable {
        let id: WindowID
        let pid: ProcessID
        let ownerID: WindowID
        let element: AXUIElement
    }

    struct AppEnumerationResult: @unchecked Sendable {
        let pid: ProcessID
        let windows: [WindowInfo]
        let handles: [WindowID: AXUIElement]
        let suppressedWindows: [SuppressedWindow]
        let suppressionIsComplete: Bool
        let failure: ApplicationFailure?

        var semanticIsComplete: Bool { failure == nil }
    }

    static func merge(
        appResults: [AppEnumerationResult],
        windowLayerSnapshot: WindowLayerSnapshot?
    ) -> EnumerationResult {
        let filteredResults = appResults.map { result in
            let windows = result.windows.filter { window in
                guard let snapshot = windowLayerSnapshot else { return true }
                return snapshot.permitsSemanticWindow(id: window.id, pid: result.pid)
            }
            let ids = Set(windows.map(\.id))
            return AppEnumerationResult(
                pid: result.pid,
                windows: windows,
                handles: result.handles.filter { ids.contains($0.key) },
                suppressedWindows: result.suppressedWindows,
                suppressionIsComplete: result.suppressionIsComplete,
                failure: result.failure
            )
        }
        return EnumerationResult(
            appResults: filteredResults,
            windowLayerSnapshot: windowLayerSnapshot,
            failedApplications: filteredResults.compactMap(\.failure)
        )
    }

    /// `NSRunningApplication` 的纯值快照——真正跨子任务边界传入的输入，全是
    /// Sendable 原始类型，不携带 AppKit 对象本身。
    private struct AppSnapshot: Sendable {
        let pid: ProcessID
        let appName: String
        let appBundleID: String?
        let isHiddenApp: Bool
    }

    private static func snapshotRunningApplications() -> [AppSnapshot] {
        // 常规 App + 可能临时拥有 Application Windows 的 accessory App。判据的完整理由见
        // `NSRunningApplication.canOwnApplicationWindows`——这条判据同时被 AX 观察者和前台 MRU 使用，
        // 三条入口必须同口径。
        return WindowApplicationIdentity.applications()
            .map {
                AppSnapshot(
                    pid: $0.pid,
                    appName: $0.app.localizedName ?? "",
                    appBundleID: $0.app.bundleIdentifier,
                    isHiddenApp: $0.app.isHidden
                )
            }
    }

    // MARK: - Per-app enumeration (runs inside one task)

    /// 单个 App 的枚举——这里发生的每一次 `AXUIElementCopyAttributeValue` 都是同步
    /// mach IPC，是唯一真正的「卡死点」，所以靠 `AXUIElementSetMessagingTimeout`
    /// 兜底；这层本身不额外套超时/重试，交给 messaging timeout 的语义处理。
    private func enumerateWindows(of app: AppSnapshot) -> AppEnumerationResult {
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var windowsRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard error == .success, let axWindows = windowsRef as? [AXUIElement] else {
            return AppEnumerationResult(
                pid: app.pid,
                windows: [],
                handles: [:],
                suppressedWindows: [],
                suppressionIsComplete: false,
                failure: ApplicationFailure(
                    pid: app.pid,
                    appName: app.appName,
                    axErrorRawValue: error.rawValue
                )
            )
        }

        var windows: [WindowInfo] = []
        var handles: [WindowID: AXUIElement] = [:]
        var suppressedWindows: [SuppressedWindow] = []
        var suppressionIsComplete = true
        let standardWindowIDs = axWindows.compactMap { element -> WindowID? in
            guard Self.stringAttribute(element, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return nil }
            return resolver.windowID(for: element)
        }

        for element in axWindows {
            if let suppressed = suppressedWindow(
                for: element,
                pid: app.pid,
                ownerCandidateIDs: standardWindowIDs
            ) {
                suppressedWindows.append(suppressed)
                continue
            }
            if let sheets = attachedSheets(of: element, pid: app.pid) {
                suppressedWindows.append(contentsOf: sheets)
            } else {
                suppressionIsComplete = false
            }
            guard let result = windowInfo(
                for: element,
                pid: app.pid,
                appName: app.appName,
                appBundleID: app.appBundleID,
                isHiddenApp: app.isHiddenApp,
                windowLayerSnapshot: nil
            ) else {
                continue
            }
            windows.append(result.info)
            handles[result.id] = result.element
        }

        return AppEnumerationResult(
            pid: app.pid,
            windows: windows,
            handles: handles,
            suppressedWindows: suppressedWindows,
            suppressionIsComplete: suppressionIsComplete,
            failure: nil
        )
    }

    /// Sheet 是父窗口的一部分，不是独立切换目标；Window Server/SCK 却会为它分配单独 ID。
    func suppressedWindow(
        for element: AXUIElement,
        pid: ProcessID,
        ownerCandidateIDs: [WindowID] = []
    ) -> SuppressedWindow? {
        if Self.stringAttribute(element, kAXRoleAttribute) == kAXSheetRole,
           let id = resolver.windowID(for: element),
           let owner = Self.elementAttribute(element, kAXWindowAttribute),
           let ownerID = resolver.windowID(for: owner) {
            return SuppressedWindow(id: id, pid: pid, ownerID: ownerID, element: element)
        }

        guard let id = resolver.windowID(for: element),
              let ownerID = Self.modalDialogOwnerID(
                  subrole: Self.stringAttribute(element, kAXSubroleAttribute),
                  isModal: Self.boolAttribute(element, kAXModalAttribute),
                  ownerCandidateIDs: ownerCandidateIDs
              )
        else { return nil }
        return SuppressedWindow(id: id, pid: pid, ownerID: ownerID, element: element)
    }

    static func modalDialogOwnerID(
        subrole: String?,
        isModal: Bool,
        ownerCandidateIDs: [WindowID]
    ) -> WindowID? {
        guard subrole == kAXDialogSubrole, isModal else { return nil }
        let candidates = Set(ownerCandidateIDs)
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    private func attachedSheets(of window: AXUIElement, pid: ProcessID) -> [SuppressedWindow]? {
        guard let children = Self.elementsAttribute(window, kAXChildrenAttribute) else { return nil }
        var sheets: [SuppressedWindow] = []
        for child in children {
            guard let role = Self.stringAttribute(child, kAXRoleAttribute) else { return nil }
            guard role == kAXSheetRole else { continue }
            guard let id = resolver.windowID(for: child),
                  let ownerID = resolver.windowID(for: window)
            else { return nil }
            sheets.append(SuppressedWindow(id: id, pid: pid, ownerID: ownerID, element: child))
        }
        return sheets
    }

    /// 单个窗口 AXUIElement → `WindowInfo` + 句柄。任一必要条件不满足（subrole 不对、
    /// 判定为垃圾窗口、拿不到 WindowID）都返回 nil，调用方直接跳过该窗口。
    ///
    /// 公开给 Task 12b `WindowStore` 复用——收到 `kAXWindowCreatedNotification` 时用
    /// 同一套 AX 读取/过滤逻辑为新窗口构造 `WindowInfo`，跟 `enumerateAll` 内部
    /// （`enumerateWindows(of:)`）走的是完全同一个方法，不重复实现一份。返回的
    /// `element` 就是入参本身，随手带出来方便调用方直接存句柄映射，不用另外持有。
    func windowInfo(
        for element: AXUIElement,
        pid: ProcessID,
        appName: String,
        appBundleID: String?,
        isHiddenApp: Bool,
        windowLayerSnapshot: WindowLayerSnapshot? = WindowLayerFilter.currentSnapshot()
    ) -> (info: WindowInfo, id: WindowID, element: AXUIElement)? {
        // subrole 过滤：只收标准窗口 + 对话框，其余（面板、气泡、装饰窗等）跳过。
        let subrole = Self.stringAttribute(element, kAXSubroleAttribute)
        guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else {
            return nil
        }

        let title = Self.stringAttribute(element, kAXTitleAttribute) ?? ""
        let isMinimized = Self.boolAttribute(element, kAXMinimizedAttribute)

        // 尺寸过滤：零尺寸 且 无标题 且 非最小化——大概率是不可见的辅助/装饰窗口。
        if Self.isZeroSize(element), title.isEmpty, !isMinimized {
            return nil
        }

        // 没有 CGWindowID 就没法后续做聚焦目标匹配/去重/缩略图关联，跳过该窗口。
        //
        // O4：`_AXUIElementGetWindow`（`resolver.windowID(for:)` 的唯一路径，见
        // `WindowIDResolver`）对绝大多数窗口都能成功，但少数边缘 App（老 Carbon 应用、部分
        // Java AWT 窗口）会让它返回 nil，此时窗口被静默跳过、永远不会出现在切换器里，对用户
        // 而言是无法解释的「App 明明开着但看不到」。记一条 debug/info 级 log（带 pid + subrole
        // + title）方便事后诊断，而不是让这类窗口无声无息地消失在日志里。
        //
        // 注意：`WindowIDResolver.bestMatch(...)` 这个打分降级路径目前**没有**接到这里
        // ——见该方法处的注释：它已经实现且有测试覆盖，但要接上去需要调用方先构建一份
        // `[WindowCandidate]`（来自 `CGWindowListCopyWindowInfo` 之类的枚举源），这部分本次
        // 有意不做（out of scope），v1 依赖私有 `_AXUIElementGetWindow` 已能覆盖几乎所有窗口。
        guard let windowID = resolver.windowID(for: element) else {
            let subrole = Self.stringAttribute(element, kAXSubroleAttribute) ?? "<nil>"
            Self.logger.info("""
            dropping window: resolver.windowID(for:) returned nil \
            pid=\(pid, privacy: .public) subrole=\(subrole, privacy: .public) \
            title=\(title, privacy: .private)
            """)
            return nil
        }

        // fail-open：只有窗口服务器明确把同一 ID+PID 标成非标准 layer 时才排除。快照漏项或
        // 身份冲突都由更强的 AX 语义证据胜出，避免一次弱来源残缺把真实窗口误删。
        if let windowLayerSnapshot,
           !windowLayerSnapshot.permitsSemanticWindow(id: windowID, pid: pid) {
            Self.logger.info(
                "dropping non-standard-layer window id=\(windowID, privacy: .public) pid=\(pid, privacy: .public)"
            )
            return nil
        }

        let pinyinAppName: String? = pinyinEnabled ? PinyinTransformer.pinyin(for: appName) : nil
        let pinyinTitle: String? = pinyinEnabled ? PinyinTransformer.pinyin(for: title) : nil

        let info = WindowInfo(
            id: windowID,
            pid: pid,
            appName: appName,
            appBundleID: appBundleID,
            title: title,
            isMinimized: isMinimized,
            isHiddenApp: isHiddenApp,
            isOnCurrentSpace: true, // Spike 2 确认：AX 只能枚举到当前 Space 的窗口
            pinyinAppName: pinyinAppName,
            pinyinTitle: pinyinTitle
        )
        return (info, windowID, element)
    }

    // MARK: - AX attribute helpers

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func elementsAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? [AXUIElement] ?? []
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement) // swiftlint:disable:this force_cast -- CFGetTypeID 已确认类型
    }

    private static func isZeroSize(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return false // 读不到尺寸就不当零尺寸处理，避免误杀正常窗口
        }

        let axValue = value as! AXValue // swiftlint:disable:this force_cast -- CFGetTypeID 已确认类型
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return false }
        return size.width == 0 && size.height == 0
    }
}
