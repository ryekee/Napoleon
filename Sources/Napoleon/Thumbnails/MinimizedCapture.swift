import CoreGraphics
import NapoleonCore

/// 私有 SkyLight `CGSHWCaptureWindowList` 兑底：抓最小化/离屏窗口的「最后一帧」。
///
/// ScreenCaptureKit 抓不到最小化窗口（Spike 3 实测 `SCScreenshotManager.captureImage`
/// 对最小化窗口 throw -3811）。`CGSHWCaptureWindowList` 是 SkyLight 私有 API，Spike 3
/// （`spikes/capture/main.swift`，macOS 26 真机实测）验证过：`dlsym` 能拿到
/// `CGSMainConnectionID`/`CGSHWCaptureWindowList`，且对一个手动最小化的窗口成功返回图像。
///
/// 所有私有 API 相关代码隔离在本文件——`ThumbnailService` 只调 `capture(windowID:)`，
/// 不直接接触 dlsym/CGS 类型。
enum MinimizedCapture {
    private typealias CGSConnectionID = Int32
    private typealias MainConnFn = @convention(c) () -> CGSConnectionID
    private typealias HWCaptureFn = @convention(c) (
        CGSConnectionID, UnsafePointer<CGWindowID>, UInt32, UInt32
    ) -> Unmanaged<CFArray>?

    /// dlsym 探测结果缓存一次（`static let`，进程生命周期内只探测一次），避免每次抓图都
    /// 重新 `dlsym`。探测失败（比如未来系统版本改了符号名）时两者都是 nil，`capture` 直接
    /// 返回 nil 兜底，不 crash。
    private static let mainConnFn: MainConnFn? = symbol("CGSMainConnectionID")
    private static let hwCaptureFn: HWCaptureFn? = symbol("CGSHWCaptureWindowList")

    private static func symbol<T>(_ name: String) -> T? {
        // RTLD_DEFAULT：在已加载的动态库（含 SkyLight.framework）里按符号名查找。
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// 用私有 `CGSHWCaptureWindowList` 抓指定 `WindowID` 的最后一帧（可抓最小化/离屏窗口）。
    /// dlsym 探测失败或返回空 → nil（调用方回退到 App 图标）。返回全分辨率 `CGImage`，
    /// 降采样是调用方（`ThumbnailService`）的事。
    static func capture(windowID: WindowID) -> CGImage? {
        guard let mainConn = mainConnFn, let hwCapture = hwCaptureFn else { return nil }

        let connectionID = mainConn()
        var cgWindowID = CGWindowID(windowID)
        // Spike 3 实测有效的组合：ignoreGlobalClipShape (1<<11) | bestResolution (1<<9)——
        // 这两个名称是根据行为推断出来的，未经 Apple 确认（私有未文档化 bitflag，符号名
        // 也是社区反推的），别当作官方语义来读。
        let options: UInt32 = (1 << 11) | (1 << 9)

        guard let images = hwCapture(connectionID, &cgWindowID, 1, options)?
            .takeRetainedValue() as? [CGImage]
        else {
            return nil
        }

        return images.first
    }
}
