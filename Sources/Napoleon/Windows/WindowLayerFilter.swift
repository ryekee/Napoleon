import CoreGraphics
import Foundation
import NapoleonCore

enum WindowHandleLiveness: Equatable, Sendable {
    case alive
    case dead
    case unknown
}

struct WindowLayerSnapshot: Equatable, Sendable {
    let switchableWindows: [WindowID: ProcessID]
    let nonSwitchableWindows: [WindowID: ProcessID]
    let onScreenWindowIDs: Set<WindowID>

    init(
        switchableWindows: [WindowID: ProcessID],
        nonSwitchableWindows: [WindowID: ProcessID] = [:],
        onScreenWindowIDs: Set<WindowID>
    ) {
        self.switchableWindows = switchableWindows
        self.nonSwitchableWindows = nonSwitchableWindows
        self.onScreenWindowIDs = onScreenWindowIDs
    }

    /// AX 是语义来源；只有同一身份被 Window Server 明确标成非标准 layer 时才排除。
    func permitsSemanticWindow(id: WindowID, pid: ProcessID) -> Bool {
        if switchableWindows[id] == pid { return true }
        return nonSwitchableWindows[id] != pid
    }

    /// Window Server 的 layer-0 列表会保留已关闭窗口的 backing surface，不能单独证明窗口存活。
    /// 已缓存 AX 窗口句柄的存活探测优先；失败保持未知，避免误删隐藏、最小化或跨 Space 窗口。
    static func existingWindows(
        layerSnapshot: WindowLayerSnapshot?,
        knownWindows: [WindowID: ProcessID],
        liveness: [WindowID: WindowHandleLiveness]
    ) -> [WindowID: ProcessID]? {
        let hasConclusiveLiveness = liveness.values.contains { $0 != .unknown }
        guard layerSnapshot != nil || hasConclusiveLiveness else { return nil }

        var result = layerSnapshot?.switchableWindows ?? [:]
        for (id, pid) in knownWindows {
            let observedPID = layerSnapshot?.switchableWindows[id] ?? layerSnapshot?.nonSwitchableWindows[id]
            if let observedPID, observedPID != pid { continue }
            if layerSnapshot?.nonSwitchableWindows[id] == pid {
                if result[id] == pid { result.removeValue(forKey: id) }
                continue
            }
            switch liveness[id] ?? .unknown {
            case .alive:
                result[id] = pid
            case .unknown:
                if result[id] == nil || result[id] == pid {
                    result[id] = pid
                }
            case .dead:
                if result[id] == pid {
                    result.removeValue(forKey: id)
                }
            }
        }
        return result
    }
}

/// 用窗口服务器的 layer 排除浮动工具窗、HUD、Pet 等辅助窗口。
///
/// AX 的 `AXSubrole` 并不可靠：Electron/Chromium 的无边框浮动窗可能仍报告
/// `AXStandardWindow`，仅靠 subrole 会把它当作普通文档窗口。窗口服务器的 layer 更接近
/// 用户看到的语义：可切换的标准窗口位于 layer 0；`NSFloatingWindowLevel` 对应 layer 3。
enum WindowLayerFilter {
    /// 一次读取同时产出 layer 过滤集合和 on-screen 正向证据。调用方不得为两种用途各查一次。
    static func currentSnapshot() -> WindowLayerSnapshot? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return snapshot(from: raw)
    }

    /// 纯解析入口：`kCGWindowIsOnscreen == true` 才算正向证据；缺键和 false 都不做反向推断。
    static func snapshot(from raw: [[String: Any]]) -> WindowLayerSnapshot? {
        let windows = switchableWindows(from: raw)
        // 空快照更可能是窗口服务器处于切换/锁屏等短暂状态；fail-open 比把整个 switcher 清空安全。
        guard !windows.isEmpty else { return nil }

        let onScreenIDs = Set(raw.compactMap { entry -> WindowID? in
            guard (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true else { return nil }
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  windows[id] == pid else { return nil }
            return id
        })
        return WindowLayerSnapshot(
            switchableWindows: windows,
            nonSwitchableWindows: windowOwners(from: raw, whereLayerIsZero: false),
            onScreenWindowIDs: onScreenIDs
        )
    }

    static func switchableWindows(from raw: [[String: Any]]) -> [WindowID: ProcessID] {
        windowOwners(from: raw, whereLayerIsZero: true)
    }

    private static func windowOwners(
        from raw: [[String: Any]],
        whereLayerIsZero: Bool
    ) -> [WindowID: ProcessID] {
        Dictionary(
            raw.compactMap { entry -> (WindowID, ProcessID)? in
                guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                      (layer == 0) == whereLayerIsZero,
                      let id = entry[kCGWindowNumber as String] as? NSNumber,
                      let pid = entry[kCGWindowOwnerPID as String] as? NSNumber
                else { return nil }
                return (id.uint32Value, pid.int32Value)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
