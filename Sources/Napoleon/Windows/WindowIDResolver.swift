import ApplicationServices
import CoreGraphics
import NapoleonCore

/// 枚举侧（如 `CGWindowListCopyWindowInfo`）报告的窗口，作为私有 API 探测不到时
/// 的打分匹配候选。
struct WindowCandidate: Equatable {
    let id: WindowID
    let pid: ProcessID
    let frame: CGRect
    let title: String?
}

/// 把 `AXUIElement`（用于聚焦）解析成窗口列表里的 `CGWindowID`（用于匹配缩略图）。
///
/// 首选私有符号 `_AXUIElementGetWindow`（AltTab/yabai 多年同款）；该符号运行时探测
/// 不到，或调用没拿到可用 id 时，调用方降级到 `bestMatch`——对一份已枚举好的候选
/// 列表做纯打分匹配。
///
/// 显式 `Sendable`：没有任何实例存储属性（只有一个 `static let` 缓存的 dlsym 探测
/// 结果），满足编译器对 `final class` 显式（非 unchecked）`Sendable` conformance 的
/// 验证条件——Task 11 的 `WindowEnumerator` 需要把同一个实例捕获进多个并发子任务。
final class WindowIDResolver: Sendable {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// 只探测一次并缓存（`nil` 表示没找到该符号）——dlsym 不便宜，不能每次调用都做。
    private static let getWindowFn: GetWindowFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") /* RTLD_DEFAULT */ else {
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()

    /// 首选路径：私有 `_AXUIElementGetWindow`。符号不存在、调用未报 `.success`，
    /// 或 id 为 0 时均返回 nil。
    func windowID(for element: AXUIElement) -> WindowID? {
        guard let getWindow = Self.getWindowFn else { return nil }

        var cgWindowID: CGWindowID = 0
        let error = getWindow(element, &cgWindowID)
        guard error == .success, cgWindowID != 0 else { return nil }
        return WindowID(cgWindowID)
    }

    /// WindowServer/SCK 能看到、`kAXWindowsAttribute` 却漏掉的当前屏窗口，可从它仍然露出的
    /// 屏幕区域反向命中 AX 子元素，再沿 `AXWindow` 找回可聚焦的真实窗口句柄。只有 PID 与
    /// WindowID 双重精确一致才接受；采样点全被遮挡或命中其它窗口时保持 nil。
    func recoverWindowElement(windowID: WindowID, pid: ProcessID, frame: CGRect) -> AXUIElement? {
        // ponytail: 只恢复至少一个采样点可命中的窗口；若要覆盖完全遮挡窗口，再接入经实机验证的
        // WindowID 聚焦后端，不能退回无句柄的 App 级激活。
        let systemWide = AXUIElementCreateSystemWide()
        for point in Self.recoverySamplePoints(in: frame) {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                systemWide,
                Float(point.x),
                Float(point.y),
                &hit
            ) == .success, let hit else { continue }

            for element in Self.windowCandidates(containing: hit) {
                var actualPID: pid_t = 0
                guard Self.isWindowElement(element),
                      AXUIElementGetPid(element, &actualPID) == .success,
                      let actualWindowID = self.windowID(for: element),
                      Self.matchesRecoveredIdentity(
                          expectedWindowID: windowID,
                          expectedPID: pid,
                          actualWindowID: actualWindowID,
                          actualPID: ProcessID(actualPID)
                      ) else { continue }
                return element
            }
        }
        return nil
    }

    static func recoverySamplePoints(in frame: CGRect) -> [CGPoint] {
        guard frame.width > 0, frame.height > 0 else { return [] }
        let ratios: [CGFloat] = [0.1, 0.5, 0.9]
        return ratios.flatMap { y in
            ratios.map { x in
                CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
            }
        }
    }

    static func matchesRecoveredIdentity(
        expectedWindowID: WindowID,
        expectedPID: ProcessID,
        actualWindowID: WindowID,
        actualPID: ProcessID
    ) -> Bool {
        expectedWindowID == actualWindowID && expectedPID == actualPID
    }

    private static func windowCandidates(containing hit: AXUIElement) -> [AXUIElement] {
        var candidates: [AXUIElement] = []
        for attribute in [kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(hit, attribute as CFString, &value) == .success,
                  let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let element = value as! AXUIElement // swiftlint:disable:this force_cast -- CF type checked above
            if !candidates.contains(where: { CFEqual($0, element) }) {
                candidates.append(element)
            }
        }
        if CFGetTypeID(hit) == AXUIElementGetTypeID(),
           !candidates.contains(where: { CFEqual($0, hit) }) {
            candidates.append(hit)
        }
        return candidates
    }

    private static func isWindowElement(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success else { return false }
        return value as? String == kAXWindowRole
    }

    /// 降级路径：为目标 (pid, frame, title) 从候选列表里挑最佳匹配。纯函数——pid
    /// 必须相等；同 pid 候选里 IoU 最高者胜出（title 完全相等加权）。低置信度一律
    /// 返回 nil——宁可掉 App 图标，也不要认错窗口。
    ///
    /// O4：**尚未接入生产代码**——目前只有测试（`WindowIDResolverTests`）在调用它。生产侧
    /// （`WindowEnumerator.windowInfo(for:...)`）在 `windowID(for:)` 返回 nil 时直接跳过该
    /// 窗口（并 log 一条诊断信息），不会走到这里，因为把这个降级路径接上去需要调用方先构建一份
    /// `[WindowCandidate]`（来自 `CGWindowListCopyWindowInfo` 之类的独立枚举源）传进来，这部分
    /// 接线本身有意延后（out of scope，未来再做）——v1 依赖私有符号 `_AXUIElementGetWindow`，
    /// 它已经能覆盖几乎所有窗口，`bestMatch` 只是给极少数探测失败的边缘情况准备的、已实现且已测
    /// 试、但暂时「死代码」的兜底，不是遗漏或 bug。
    static func bestMatch(pid: ProcessID, frame: CGRect, title: String?, among candidates: [WindowCandidate]) -> WindowID? {
        let samePid = candidates.filter { $0.pid == pid }
        guard !samePid.isEmpty else { return nil }

        // title 完全相等是足够强的信号，可以压过 IoU 略高的候选（下面 accept 判断
        // 里甚至能让低 IoU 候选也过关）——所以权重设在 IoU 值域之上。
        let titleMatchBonus = 2.0

        var bestID: WindowID?
        var bestScore = -Double.infinity
        var bestIoU = 0.0
        var bestTitleMatch = false

        for candidate in samePid {
            let candidateIoU = iou(frame, candidate.frame)
            let candidateTitleMatch: Bool = {
                guard let title, !title.isEmpty else { return false }
                return candidate.title == title
            }()
            let score = candidateIoU + (candidateTitleMatch ? titleMatchBonus : 0)

            if score > bestScore {
                bestScore = score
                bestID = candidate.id
                bestIoU = candidateIoU
                bestTitleMatch = candidateTitleMatch
            }
        }

        guard let id = bestID, bestIoU >= 0.9 || bestTitleMatch else { return nil }
        return id
    }

    /// 两个矩形的交并比：完全重合为 1.0，不相交（或退化为零面积）为 0.0。
    private static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        let intersectionArea = intersection.isNull ? 0 : Double(intersection.width * intersection.height)
        let unionArea = Double(a.width * a.height) + Double(b.width * b.height) - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}
