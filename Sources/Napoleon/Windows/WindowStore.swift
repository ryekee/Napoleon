import AppKit
import ApplicationServices
import CoreGraphics
import NapoleonCore
import ScreenCaptureKit
import os

/// 事件驱动的 Canonical Target Registry。
///
/// AX 是唯一能创建切换目标的语义来源；Window Server、ScreenCaptureKit 与 CGS 只为已知
/// 身份提供存在性和展示元数据。审计按 App 独立落地，任何审计飞行期间收到事件的 App 都丢弃
/// 自己那份过期结果并重跑，不再用全量快照覆盖热态。
@MainActor
final class WindowStore {
    private nonisolated static let logger = Logger(
        subsystem: "com.napoleon.Napoleon",
        category: "WindowStore"
    )
    private static let auditDebounceInterval: TimeInterval = 0.2
    private static let healthAuditInterval: TimeInterval = 30

    private static let configureSystemWideMessagingTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }()

    private typealias SuppressedTarget = (
        pid: ProcessID,
        ownerID: WindowID,
        element: AXUIElement
    )

    private struct HandleProbe: @unchecked Sendable {
        let id: WindowID
        let pid: ProcessID
        let element: AXUIElement
    }

    private var registry: CanonicalWindowRegistry
    private(set) var currentSpaceIsFullscreen = false

    private let enumerator: WindowEnumerator
    private let observer: AXObserverController
    private let screenLister: ScreenWindowLister
    private let resolver: WindowIDResolver
    private let thumbnails: ThumbnailService?
    private let spaceClassifier: SpaceClassifier
    private let includesOtherSpaces: @MainActor () -> Bool

    private var handles: [WindowID: AXUIElement] = [:]
    private var reverse: [AXElementKey: WindowID] = [:]
    private var suppressedWindows: [WindowID: SuppressedTarget] = [:]
    private var suppressedReverse: [AXElementKey: WindowID] = [:]
    private var lastFocusedID: WindowID?

    private var lastDesktopSpaceIDs: Set<Int> = []
    /// 非 nil 时，处于全屏 Space 的纯读快照只投影这些已知目标；Registry 本身不被裁剪。
    private var fullscreenEscapeWindowIDs: Set<WindowID>?

    private var environmentEpoch: UInt64 = 0
    private var membershipEpochs: [ProcessID: UInt64] = [:]
    private var pendingAudit: DispatchWorkItem?
    private var healthAuditTimer: Timer?
    private var auditInFlight = false
    private var auditQueued = false
    private var isStarted = false
    private var isStopped = true

    init(
        initialState: WindowState = .init(),
        enumerator: WindowEnumerator = .init(),
        observer: AXObserverController? = nil,
        screenLister: ScreenWindowLister = .init(),
        resolver: WindowIDResolver = .init(),
        thumbnails: ThumbnailService? = nil,
        spaceClassifier: SpaceClassifier = .init(),
        includesOtherSpaces: @escaping @MainActor () -> Bool = { false }
    ) {
        registry = CanonicalWindowRegistry(initialState: initialState)
        self.enumerator = enumerator
        self.observer = observer ?? AXObserverController()
        self.screenLister = screenLister
        self.resolver = resolver
        self.thumbnails = thumbnails
        self.spaceClassifier = spaceClassifier
        self.includesOtherSpaces = includesOtherSpaces
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        isStopped = false
        _ = Self.configureSystemWideMessagingTimeout

        observer.onNotification = { [weak self] in self?.handle($0) }
        observer.onAppAppeared = { [weak self] pid in
            guard let self else { return }
            self.advanceMembership(pid)
            self.scheduleAudit()
        }
        observer.onAppTerminated = { [weak self] pid in
            self?.removeTerminatedApp(pid)
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppHidden),
            name: NSWorkspace.didHideApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppUnhidden),
            name: NSWorkspace.didUnhideApplicationNotification,
            object: nil
        )

        // 先打开事件流，再补冷启动基线，避免审计飞行期间出现事件真空。
        observer.start()
        startHealthAuditTimer()
        Task { [weak self] in await self?.auditNow() }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        isStopped = true
        environmentEpoch &+= 1

        pendingAudit?.cancel()
        pendingAudit = nil
        healthAuditTimer?.invalidate()
        healthAuditTimer = nil
        auditQueued = false

        observer.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        handles.removeAll()
        reverse.removeAll()
        suppressedWindows.removeAll()
        suppressedReverse.removeAll()
    }

    /// 热键路径只读取内存快照；不枚举、不对账、不修剪，也不改变 MRU。
    func snapshot() -> (state: WindowState, handles: [WindowID: AXUIElement], currentSpaceIsFullscreen: Bool) {
        var state = registry.state
        if currentSpaceIsFullscreen,
           !includesOtherSpaces(),
           let allowed = fullscreenEscapeWindowIDs {
            state.windows.removeAll { !allowed.contains($0.id) }
        }
        return (state, handles, currentSpaceIsFullscreen)
    }

    func diagnosticState() -> WindowState { registry.state }

    func requestRefresh() {
        environmentEpoch &+= 1
        scheduleAudit()
    }

    func forget(windowID id: WindowID) {
        guard registry.window(id) != nil || handles[id] != nil else { return }
        if let pid = registry.window(id)?.pid { advanceMembership(pid) }
        registry.remove(id)
        removeHandle(id)
    }

    /// 精确窗口聚焦已经成功时立即提交 MRU，不依赖稍后是否送达 App 激活通知。
    func recordCommittedFocus(_ id: WindowID) {
        guard registry.window(id) != nil else { return }
        reduceFocusChange(to: id)
    }

    /// 没有句柄时只接受 App 激活后的精确 AX 焦点；读不到就等待通知/审计，绝不猜窗口。
    func recordCommittedActivation(pid: ProcessID) {
        _ = repairFocusedWindow(pid: pid)
        scheduleAudit()
    }

    isolated deinit {
        stop()
    }

    // MARK: - Audit

    private func startHealthAuditTimer() {
        let timer = Timer(timeInterval: Self.healthAuditInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleAudit() }
        }
        healthAuditTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleAudit() {
        guard !isStopped else { return }
        pendingAudit?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.pendingAudit = nil
                await self?.auditNow()
            }
        }
        pendingAudit = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.auditDebounceInterval,
            execute: item
        )
    }

    private func auditNow() async {
        guard !isStopped else { return }
        guard !auditInFlight else {
            auditQueued = true
            return
        }

        auditInFlight = true
        defer {
            auditInFlight = false
            if auditQueued, !isStopped {
                auditQueued = false
                Task { @MainActor [weak self] in await self?.auditNow() }
            }
        }

        let capturedEnvironmentEpoch = environmentEpoch
        let capturedMembershipEpochs = membershipEpochs
        let knownWindows = Dictionary(
            uniqueKeysWithValues: registry.allWindows.map { ($0.id, $0.pid) }
        )
        let handleProbes = handles.compactMap { id, element -> HandleProbe? in
            guard let pid = knownWindows[id] else { return nil }
            return HandleProbe(id: id, pid: pid, element: element)
        }
        async let axTask = enumerator.enumerateAll()
        async let contentTask = Self.fetchShareableContent()
        async let livenessTask = Self.probeWindowLiveness(handleProbes)
        let (axResult, content, liveness) = await (axTask, contentTask, livenessTask)

        guard !isStopped else { return }
        guard Self.auditResultIsCurrent(
            capturedEnvironment: capturedEnvironmentEpoch,
            currentEnvironment: environmentEpoch,
            capturedPID: 0,
            currentPID: 0
        ) else {
            auditQueued = true
            return
        }

        if let content {
            thumbnails?.setShareableContent(content)
        }
        let screenWindows = content.map(screenLister.windows(from:)) ?? []
        if spaceClassifier.refresh() {
            currentSpaceIsFullscreen = spaceClassifier.currentSpaceIsFullscreen
            if !currentSpaceIsFullscreen, !spaceClassifier.currentSpaceIDs.isEmpty {
                lastDesktopSpaceIDs = spaceClassifier.currentSpaceIDs
            }
        }

        let existingWindows = WindowLayerSnapshot.existingWindows(
            layerSnapshot: axResult.windowLayerSnapshot,
            knownWindows: knownWindows,
            liveness: liveness
        )
        for result in axResult.appResults.sorted(by: { $0.pid < $1.pid }) {
            guard Self.auditResultIsCurrent(
                capturedEnvironment: capturedEnvironmentEpoch,
                currentEnvironment: environmentEpoch,
                capturedPID: capturedMembershipEpochs[result.pid, default: 0],
                currentPID: membershipEpochs[result.pid, default: 0]
            ) else {
                auditQueued = true
                continue
            }
            observer.registerApp(pid: result.pid)
            apply(result, existingWindows: existingWindows)
        }

        let enumeratedPIDs = Set(axResult.appResults.map(\.pid))
        for pid in Set(knownWindows.values).subtracting(enumeratedPIDs) {
            guard capturedMembershipEpochs[pid, default: 0] == membershipEpochs[pid, default: 0] else {
                auditQueued = true
                continue
            }
            registry.applySemanticAudit(
                pid: pid,
                windows: [],
                isComplete: true,
                existingWindows: existingWindows
            )
        }

        recoverStrongSurfaceTargets(
            screenWindows: screenWindows,
            layerSnapshot: axResult.windowLayerSnapshot
        )

        applyWeakSurfaceMetadata(
            layerSnapshot: axResult.windowLayerSnapshot,
            existingWindows: existingWindows,
            screenWindows: screenWindows,
            capturedMembershipEpochs: capturedMembershipEpochs
        )
        pruneTerminatedTargets()
        trimMappingsToRegistry()
        rebuildFullscreenEscapeProjection()

        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.canOwnApplicationWindows,
           let pid = frontmost.windowOwnerPID {
            _ = repairFocusedWindow(pid: pid, app: frontmost)
        }
    }

    private func apply(
        _ result: WindowEnumerator.AppEnumerationResult,
        existingWindows: [WindowID: ProcessID]?
    ) {
        if result.suppressionIsComplete {
            removeSuppressedWindows(pid: result.pid)
        }
        for suppressed in result.suppressedWindows {
            registerSuppressed(suppressed)
        }

        let isHidden = NSRunningApplication(processIdentifier: result.pid)?.isHidden
        let windows = result.windows.map { window in
            var window = window
            if let isHidden { window.isHiddenApp = isHidden }
            window.isOnCurrentSpace = true
            return window
        }
        registry.applySemanticAudit(
            pid: result.pid,
            windows: windows,
            isComplete: result.semanticIsComplete,
            existingWindows: existingWindows
        )
        if let isHidden {
            registry.updateAppHidden(pid: result.pid, isHidden: isHidden)
        }

        for window in windows {
            guard let element = result.handles[window.id] else { continue }
            registerHandle(element, for: window.id)
        }
    }

    private func applyWeakSurfaceMetadata(
        layerSnapshot: WindowLayerSnapshot?,
        existingWindows: [WindowID: ProcessID]?,
        screenWindows: [ScreenWindow],
        capturedMembershipEpochs: [ProcessID: UInt64]
    ) {
        guard let existingWindows else { return }
        var onScreenIDs = layerSnapshot?.onScreenWindowIDs ?? []

        for window in screenWindows {
            guard existingWindows[window.windowID] == window.pid else { continue }
            if window.isOnScreen { onScreenIDs.insert(window.windowID) }
        }

        for (id, pid) in existingWindows where registry.contains(id, pid: pid) {
            guard capturedMembershipEpochs[pid, default: 0] == membershipEpochs[pid, default: 0] else { continue }
            registry.observeSurface(
                windowID: id,
                pid: pid,
                isOnCurrentSpace: onScreenIDs.contains(id) ? true : nil,
                isFullscreen: spaceClassifier.fullscreenStatus(id)
            )
        }
    }

    private func recoverStrongSurfaceTargets(
        screenWindows: [ScreenWindow],
        layerSnapshot: WindowLayerSnapshot?
    ) {
        let candidates = Self.strongSurfaceCandidates(
            screenWindows: screenWindows,
            layerSnapshot: layerSnapshot,
            knownWindowIDs: registry.allWindowIDs,
            suppressedWindowIDs: Set(suppressedWindows.keys),
            isAssignedToSpace: spaceClassifier.isAssignedToSpace
        )

        for candidate in candidates {
            guard let element = resolver.recoverWindowElement(
                windowID: candidate.windowID,
                pid: candidate.pid,
                frame: candidate.frame
            ),
            let app = NSRunningApplication(processIdentifier: candidate.pid),
            app.canOwnApplicationWindows,
            let result = enumerator.windowInfo(
                for: element,
                pid: candidate.pid,
                appName: candidate.appName,
                appBundleID: candidate.appBundleID,
                isHiddenApp: app.isHidden,
                windowLayerSnapshot: layerSnapshot
            ),
            result.id == candidate.windowID else { continue }

            registry.observeSemanticWindow(result.info)
            registerHandle(result.element, for: result.id)
            Self.logger.notice(
                "recovered omitted AX window id=\(result.id, privacy: .public) pid=\(candidate.pid, privacy: .public)"
            )
        }
    }

    nonisolated static func strongSurfaceCandidates(
        screenWindows: [ScreenWindow],
        layerSnapshot: WindowLayerSnapshot?,
        knownWindowIDs: Set<WindowID>,
        suppressedWindowIDs: Set<WindowID>,
        isAssignedToSpace: (WindowID) -> Bool?
    ) -> [ScreenWindow] {
        guard let layerSnapshot else { return [] }
        return screenWindows.filter { window in
            !knownWindowIDs.contains(window.windowID)
                && !suppressedWindowIDs.contains(window.windowID)
                && window.isOnScreen
                && layerSnapshot.onScreenWindowIDs.contains(window.windowID)
                && layerSnapshot.switchableWindows[window.windowID] == window.pid
                && isAssignedToSpace(window.windowID) == true
        }
    }

    private func pruneTerminatedTargets() {
        observer.pruneTerminatedApplications()
        let deadPIDs = Set(registry.allWindows.map(\.pid))
            .filter { WindowApplicationIdentity.isConfirmedTerminated($0) }
        for pid in deadPIDs {
            Self.logger.notice("removing targets for terminated pid=\(pid, privacy: .public)")
            observer.forgetTerminatedApp(pid)
            removeTerminatedApp(pid)
        }
    }

    private func rebuildFullscreenEscapeProjection() {
        guard currentSpaceIsFullscreen, !includesOtherSpaces() else {
            fullscreenEscapeWindowIDs = nil
            return
        }
        guard !lastDesktopSpaceIDs.isEmpty, spaceClassifier.canQueryWindowSpaces else {
            fullscreenEscapeWindowIDs = nil
            return
        }

        let windows = registry.state.windows
        var allowed = Set(windows.filter { $0.isOnCurrentSpace || $0.isFullscreen }.map(\.id))
        let desktopWindows = windows.filter { !$0.isOnCurrentSpace && !$0.isFullscreen }
        let escapeDesktopIDs = desktopWindows.compactMap { window in
            spaceClassifier.isOnAnySpace(window.id, of: lastDesktopSpaceIDs) ? window.id : nil
        }
        allowed.formUnion(escapeDesktopIDs)

        if escapeDesktopIDs.isEmpty,
           !desktopWindows.isEmpty,
           lastDesktopSpaceIDs.isDisjoint(with: spaceClassifier.allSpaceIDs) {
            fullscreenEscapeWindowIDs = nil
        } else {
            fullscreenEscapeWindowIDs = allowed
        }
    }

    private nonisolated static func fetchShareableContent() async -> SCShareableContent? {
        guard CGPreflightScreenCaptureAccess() else {
            Self.logger.warning("screen recording not granted — surface metadata unavailable")
            return nil
        }
        do {
            return try await SCShareableContent.current
        } catch {
            Self.logger.error("SCShareableContent.current failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func probeWindowLiveness(
        _ probes: [HandleProbe]
    ) async -> [WindowID: WindowHandleLiveness] {
        await withTaskGroup(of: (WindowID, WindowHandleLiveness).self) { group in
            for probe in probes {
                group.addTask {
                    guard probe.pid != NSRunningApplication.ownProcessID else {
                        return (probe.id, .unknown)
                    }
                    AXUIElementSetMessagingTimeout(probe.element, 0.5)
                    var role: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(
                        probe.element,
                        kAXRoleAttribute as CFString,
                        &role
                    )
                    switch error {
                    case .success:
                        return (probe.id, .alive)
                    case .invalidUIElement:
                        return (probe.id, .dead)
                    default:
                        return (probe.id, .unknown)
                    }
                }
            }

            var result: [WindowID: WindowHandleLiveness] = [:]
            for await (id, liveness) in group {
                result[id] = liveness
            }
            return result
        }
    }

    // MARK: - AX events

    private func handle(_ notification: AXWindowNotification) {
        switch notification {
        case .windowCreated(let pid, let element):
            advanceMembership(pid)
            handleWindowCreated(pid: pid, element: element)

        case .windowDestroyed(let pid, let element):
            advanceMembership(pid)
            handleWindowDestroyed(element: element)

        case .minimizedChanged(let pid, let element, let isMinimized):
            guard let id = canonicalWindowID(for: element, pid: pid) else { return }
            registry.updateMinimized(id, isMinimized: isMinimized)

        case .titleChanged(let pid, let element):
            guard let id = canonicalWindowID(for: element, pid: pid) else { return }
            let title = Self.readTitle(element)
            let pinyin = enumerator.pinyinEnabled ? PinyinTransformer.pinyin(for: title) : nil
            registry.updateTitle(id, title: title, pinyin: pinyin)

        case .focusedWindowChanged(let pid, let element):
            guard let element else { return }
            if canonicalWindowID(for: element, pid: pid) == nil {
                advanceMembership(pid)
            }
            _ = acceptFocusedElement(element, pid: pid)
        }
    }

    private func handleWindowCreated(pid: ProcessID, element: AXUIElement) {
        guard let app = NSRunningApplication(processIdentifier: pid), app.canOwnApplicationWindows else { return }
        if let suppressed = enumerator.suppressedWindow(
            for: element,
            pid: pid,
            ownerCandidateIDs: registry.allWindows.filter { $0.pid == pid }.map(\.id)
        ) {
            registerSuppressed(suppressed)
            return
        }
        guard let result = enumerator.windowInfo(
            for: element,
            pid: pid,
            appName: app.localizedName ?? "",
            appBundleID: app.bundleIdentifier,
            isHiddenApp: app.isHidden
        ) else { return }
        registry.observeSemanticWindow(result.info)
        registerHandle(result.element, for: result.id)
    }

    private func handleWindowDestroyed(element: AXUIElement) {
        let key = AXElementKey(element: element)
        if let id = suppressedReverse.removeValue(forKey: key) {
            suppressedWindows.removeValue(forKey: id)
            return
        }
        guard let id = reverse[key] else {
            scheduleAudit()
            return
        }
        registry.remove(id)
        removeHandle(id)
    }

    private func reduceFocusChange(to id: WindowID) {
        if let previous = lastFocusedID,
           previous != id,
           registry.window(previous) != nil {
            thumbnails?.schedulePrewarm(previous)
        }
        lastFocusedID = id
        registry.recordFocus(id)
    }

    @objc private func handleActiveSpaceChanged(_ notification: Notification) {
        environmentEpoch &+= 1
        observer.reRegisterExistingWindows()
        scheduleAudit()
    }

    @objc private func handleAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.canOwnApplicationWindows else { return }
        guard let pid = app.windowOwnerPID else { return }
        _ = repairFocusedWindow(pid: pid, app: app)
        scheduleAudit()
    }

    @objc private func handleAppHidden(_ notification: Notification) {
        updateHidden(notification, isHidden: true)
    }

    @objc private func handleAppUnhidden(_ notification: Notification) {
        updateHidden(notification, isHidden: false)
    }

    private func updateHidden(_ notification: Notification, isHidden: Bool) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        guard let pid = app.windowOwnerPID else { return }
        registry.updateAppHidden(pid: pid, isHidden: isHidden)
    }

    private func repairFocusedWindow(pid: ProcessID, app: NSRunningApplication? = nil) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef,
        CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }

        let element = focusedRef as! AXUIElement // swiftlint:disable:this force_cast -- CF type checked above
        return acceptFocusedElement(element, pid: pid, app: app)
    }

    private func acceptFocusedElement(
        _ element: AXUIElement,
        pid: ProcessID,
        app suppliedApp: NSRunningApplication? = nil
    ) -> Bool {
        if let id = canonicalWindowID(for: element, pid: pid) {
            if resolver.windowID(for: element) == id {
                registerHandle(element, for: id)
            }
            reduceFocusChange(to: id)
            return true
        }

        if let suppressed = enumerator.suppressedWindow(
            for: element,
            pid: pid,
            ownerCandidateIDs: registry.allWindows.filter { $0.pid == pid }.map(\.id)
        ) {
            registerSuppressed(suppressed)
            guard registry.contains(suppressed.ownerID, pid: pid) else { return false }
            reduceFocusChange(to: suppressed.ownerID)
            return true
        }

        guard let app = suppliedApp ?? NSRunningApplication(processIdentifier: pid), app.canOwnApplicationWindows else {
            return false
        }
        guard let result = enumerator.windowInfo(
            for: element,
            pid: pid,
            appName: app.localizedName ?? "",
            appBundleID: app.bundleIdentifier,
            isHiddenApp: app.isHidden
        ) else { return false }

        registry.observeSemanticWindow(result.info)
        registerHandle(result.element, for: result.id)
        reduceFocusChange(to: result.id)
        return true
    }

    private func removeTerminatedApp(_ pid: ProcessID) {
        advanceMembership(pid)
        registry.terminateApp(pid: pid)
        removeSuppressedWindows(pid: pid)
        trimMappingsToRegistry()
    }

    // MARK: - Identity and handle maps

    private func advanceMembership(_ pid: ProcessID) {
        membershipEpochs[pid, default: 0] &+= 1
    }

    private func registerHandle(_ element: AXUIElement, for id: WindowID) {
        removeHandle(id)
        handles[id] = element
        reverse[AXElementKey(element: element)] = id
    }

    private func removeHandle(_ id: WindowID) {
        guard let element = handles.removeValue(forKey: id) else { return }
        reverse.removeValue(forKey: AXElementKey(element: element))
    }

    private func registerSuppressed(_ window: WindowEnumerator.SuppressedWindow) {
        if let old = suppressedWindows[window.id] {
            suppressedReverse.removeValue(forKey: AXElementKey(element: old.element))
        }
        suppressedWindows[window.id] = (
            pid: window.pid,
            ownerID: window.ownerID,
            element: window.element
        )
        suppressedReverse[AXElementKey(element: window.element)] = window.id
        registry.remove(window.id)
        removeHandle(window.id)
    }

    private func removeSuppressedWindows(pid: ProcessID) {
        let ids = suppressedWindows.compactMap { $0.value.pid == pid ? $0.key : nil }
        for id in ids {
            guard let target = suppressedWindows.removeValue(forKey: id) else { continue }
            suppressedReverse.removeValue(forKey: AXElementKey(element: target.element))
        }
    }

    private func trimMappingsToRegistry() {
        let validIDs = registry.allWindowIDs
        let staleHandleIDs = handles.keys.filter { !validIDs.contains($0) }
        for id in staleHandleIDs {
            removeHandle(id)
        }
        if let lastFocusedID, !validIDs.contains(lastFocusedID) {
            self.lastFocusedID = nil
        }
    }

    private func canonicalWindowID(for element: AXUIElement, pid: ProcessID) -> WindowID? {
        let key = AXElementKey(element: element)
        if let id = reverse[key], registry.contains(id, pid: pid) { return id }
        if let sheetID = suppressedReverse[key],
           let suppressed = suppressedWindows[sheetID],
           suppressed.pid == pid,
           registry.contains(suppressed.ownerID, pid: pid) {
            return suppressed.ownerID
        }
        guard let resolvedID = resolver.windowID(for: element) else { return nil }
        if registry.contains(resolvedID, pid: pid) { return resolvedID }
        guard let suppressed = suppressedWindows[resolvedID],
              suppressed.pid == pid,
              registry.contains(suppressed.ownerID, pid: pid) else { return nil }
        return suppressed.ownerID
    }

    nonisolated static func canonicalFocusID(
        resolvedID: WindowID,
        knownWindowIDs: Set<WindowID>,
        suppressedOwnerIDs: [WindowID: WindowID]
    ) -> WindowID? {
        if knownWindowIDs.contains(resolvedID) { return resolvedID }
        guard let ownerID = suppressedOwnerIDs[resolvedID], knownWindowIDs.contains(ownerID) else { return nil }
        return ownerID
    }

    nonisolated static func auditResultIsCurrent(
        capturedEnvironment: UInt64,
        currentEnvironment: UInt64,
        capturedPID: UInt64,
        currentPID: UInt64
    ) -> Bool {
        capturedEnvironment == currentEnvironment && capturedPID == currentPID
    }

    private static func readTitle(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXTitleAttribute as CFString,
            &value
        ) == .success else { return "" }
        return value as? String ?? ""
    }
}

private struct AXElementKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
