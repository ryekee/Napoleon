import CoreGraphics
import Foundation
import NapoleonCore

/// 用窗口服务器的 layer 排除浮动工具窗、HUD、Pet 等辅助窗口。
///
/// AX 的 `AXSubrole` 并不可靠：Electron/Chromium 的无边框浮动窗可能仍报告
/// `AXStandardWindow`，仅靠 subrole 会把它当作普通文档窗口。窗口服务器的 layer 更接近
/// 用户看到的语义：可切换的标准窗口位于 layer 0；`NSFloatingWindowLevel` 对应 layer 3。
enum WindowLayerFilter {
    /// 获取当前全部 layer 0 窗口 ID。读取失败时返回 nil，调用方应 fail-open，避免窗口服务器
    /// 短暂异常导致整个切换器变空。
    static func currentSwitchableWindowIDs() -> Set<WindowID>? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let ids = switchableWindowIDs(from: raw)
        // 空快照更可能是窗口服务器处于切换/锁屏等短暂状态；fail-open 比把整个 switcher 清空安全。
        return ids.isEmpty ? nil : ids
    }

    /// 纯逻辑入口，供单测覆盖。只认 layer 0；缺少 layer 或 window id 的条目不是可切换窗口。
    static func switchableWindowIDs(from raw: [[String: Any]]) -> Set<WindowID> {
        Set(raw.compactMap { entry -> WindowID? in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = entry[kCGWindowNumber as String] as? NSNumber
            else {
                return nil
            }
            return id.uint32Value
        })
    }
}
