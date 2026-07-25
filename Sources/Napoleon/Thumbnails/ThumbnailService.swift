import CoreGraphics
import NapoleonCore
import ScreenCaptureKit
import os

/// 窗口缩略图抓取 + 缓存：切换器要显示的窗口预览（相较系统级最重要的优化）。
///
/// **两个主要成本，Spike 3（真机，macOS 26）实测**：
/// - `SCShareableContent.current` ~59ms——贵，不能每次抓图都调一次，缓存成
///   `scWindows: [WindowID: SCWindow]`。R1 之后这个映射改由 `WindowStore.refreshNow()`
///   驱动：它每次全量刷新自己抓一次 `SCShareableContent`，同时喂给 `screenLister.windows(from:)`
///   （跨 Space 窗口过滤）和这里的 `setShareableContent(_:)`（重建映射）——一次 XPC，两个消费者，
///   映射跟着每次全量刷新一起变新鲜，不再是永远停留在 App 启动那一刻的快照（旧版本只有
///   `warmUp()` 调用过 `refreshShareableContent()`，启动后新建的窗口永远进不了这个映射，只能
///   落到更贵的私有全分辨率兜底路径）。`refreshShareableContent()` 仍然保留，专供 `warmUp()`
///   （启动时还没有 `WindowStore.refreshNow()` 可复用）单独抓一次用。
/// - `SCScreenshotManager.captureImage` 首次调用 163ms（SCK 冷启动），稳态 22–26ms——
///   `warmUp()` 在 App 启动时调一次，用一次无关紧要的抓图把冷启动成本移到启动阶段，
///   而不是用户第一次唤出切换器时才付。
///
/// **抓图回退链**：公开 SCK（可见窗口）→ 私有 `MinimizedCapture`（`CGSHWCaptureWindowList`，
/// Task 15，抓最小化/离屏窗口）→ nil（调用方落回 App 图标）。失焦预热调度（决定什么时候该
/// 主动刷新/预抓）是 Task 16——这里只提供 `capture`/`cached`/`setShareableContent`/
/// `refreshShareableContent`/`warmUp` 五个方法给它编排用。
///
/// **权限诊断**：跟 `ScreenWindowLister` 同一套风格——`CGPreflightScreenCaptureAccess()`
/// 短路（未授权时这次 XPC 请求注定失败，直接跳过并记 warning，不产生噪音/权限提示）+
/// `do/catch` 替换 `try?`（授权了但仍失败时记 error，而不是静默返回 nil，方便排查
/// 「为什么缩略图消失了」）。
///
/// **线程**：整个类型 `@MainActor`。`cached(_:)` 主线程/触发时用，
/// `refreshShareableContent()`/`capture(_:targetSize:)`/`warmUp()` 都是 `@MainActor` 的
/// async 方法——内部 `await` SCK 之后 Swift 保证自动跳回主 actor 才继续执行，所以
/// `scWindows` 映射和 `ByteBudgetCache`（本身不是 Sendable，也不加锁）全程只在主 actor
/// 上被读写，不需要额外的锁；SCK 请求本身在后台线程执行，`await` 期间不占用主线程。
@MainActor
final class ThumbnailService {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "ThumbnailService")

    private let cache: ByteBudgetCache<WindowID, CGImage>

    /// `setShareableContent(_:)`（R1，`WindowStore.refreshNow()` 每次全量刷新调用）/
    /// `refreshShareableContent()`（`warmUp()` 专用）重建的 id→SCWindow 映射，
    /// `capture(_:targetSize:)` 靠它定位要抓的窗口，不用每次现抓 `SCShareableContent`。
    private var scWindows: [WindowID: SCWindow] = [:]

    /// Task 16：`schedulePrewarm` 的每窗节流状态——上次为某 id 发起预热的时间，见该方法注释。
    private var lastPrewarmAt: [WindowID: Date] = [:]
    /// Task 16：`schedulePrewarm` 的全局 in-flight 计数——当前正在跑的预热 `capture` 数量。
    private var inflightPrewarms = 0

    /// Task 16：同一 id 距上次 `schedulePrewarm` 发起 < 这个间隔就跳过——防止 Mission
    /// Control/连打 Cmd+Tab 造成的焦点风暴对同一扇窗口反复发起抓图。
    private let prewarmThrottle: TimeInterval = 1.0
    /// Task 16：并发预热 `capture` 的全局上限——超过就跳过这次调度（下次焦点变化/刷新还会
    /// 再给这扇窗口机会），避免焦点风暴瞬间堆起一堆并发 SCK 请求把 CPU 拉满。
    private let maxInflightPrewarms = 2

    init(maxCacheBytes: Int = 32 * 1024 * 1024) {
        cache = ByteBudgetCache(maxBytes: maxCacheBytes) { image in
            image.bytesPerRow * image.height
        }
    }

    /// Task 21：设置界面改「缩略图缓存上限」时调用——立刻生效（调小会按 LRU 立即淘汰，见
    /// `ByteBudgetCache.setMaxBytes`），不需要重启 App。
    func setMaxCacheBytes(_ bytes: Int) {
        cache.setMaxBytes(bytes)
    }

    /// 已缓存的缩略图，fast/接近 O(1)（切换器场景下同时存在的窗口数量是个位数到低两位数
    /// 规模）——底层 `ByteBudgetCache.get` 命中时会做一次 O(n) 的 recency 触达（把 key 移到
    /// MRU 头部），不是严格 O(1)，但这个规模下可以忽略。命中会刷新该条目的 LRU recency
    /// （正在展示的缩略图应该留在缓存热区，不应该被后台窗口的抓图挤掉）。
    func cached(_ id: WindowID) -> CGImage? {
        cache.get(id)
    }

    /// 异步抓取指定窗口的缩略图，降采样到 `targetSize`，存入缓存后返回；映射里没有这个
    /// id（还没 `refreshShareableContent()` 过，或窗口已经消失）或抓取失败都返回 nil。
    func capture(_ id: WindowID, targetSize: CGSize) async -> CGImage? {
        guard let thumbnail = await captureRaw(id, targetSize: targetSize) else { return nil }
        cache.set(id, thumbnail)
        return thumbnail
    }

    /// `capture(_:targetSize:)` 的核心实现，不写缓存——`capture` 和 `warmUp` 共用这份抓图
    /// 逻辑，区别只在于要不要 `cache.set`。`warmUp` 用一次无关紧要的 1×1 抓图暖 SCK 冷
    /// 启动，那张图不能进缓存：否则 `cached(id)` 可能对一个真实窗口返回退化的 1×1 图。
    ///
    /// **回退链：SCK（可见窗口）→ 私有 `MinimizedCapture`（最小化/离屏窗口）→ nil（调用方
    /// 落回 App 图标）。** SCK 走不通有两种情况：id 不在 `scWindows` 映射里（最小化窗口
    /// 根本不出现在 `SCShareableContent` 里，见 Task 15 brief），或者映射里有但
    /// `SCScreenshotManager.captureImage` 本身 throw/返回 nil。这两种情况都尝试同一个私有
    /// 兜底——`MinimizedCapture.capture(windowID:)`（Task 15，Spike 3 验证的
    /// `CGSHWCaptureWindowList`）。私有 API 抓到的全分辨率图，走跟 SCK 结果**同一条**
    /// `downscale` 路径，调用方（`capture`/`warmUp`）也不需要区分图片来自哪条路径。
    private func captureRaw(_ id: WindowID, targetSize: CGSize) async -> CGImage? {
        if let captured = await captureViaSCK(id, targetSize: targetSize) {
            return Self.downscale(captured, to: targetSize)
        }

        guard CGPreflightScreenCaptureAccess() else {
            Self.logger.warning("screen recording not granted — skipping private fallback capture for id \(id, privacy: .public)")
            return nil
        }

        // `MinimizedCapture.capture` 是同步的窗口服务器 IPC（`CGSHWCaptureWindowList`），
        // 会阻塞调用线程直到窗口服务器响应。切换器会话期间这条路径专门用来抓最小化/离屏
        // 窗口（这个类型存在的全部意义），绝不能在 `@MainActor` 上内联跑，否则会在用户
        // 交互期间卡住主线程，违背整个 async+cache 设计。扔到 `Task.detached` 里跑。
        //
        // O1：**降采样也在同一个 `Task.detached` 里做**，不再等 `await` 跳回主 actor 之后
        // 才调用 `downscale`。私有路径抓到的是未降采样的全分辨率位图（5K 级显示器上约 56MB），
        // 旧版本只把 `MinimizedCapture.capture` 挪到后台、`await` 拿到这张全分辨率图之后紧
        // 接着在主 actor 上调用 `downscale`——`downscale` 内部的 `CGContext.draw` 是一次对
        // 56MB 位图的完整重绘，这一步本身就不便宜，留在主线程上做会造成用户可感知的卡顿，
        // 违背整个 async+cache 设计想避免的问题。`downscale` 现在是 `nonisolated`（纯函数，
        // 不碰 `scWindows`/`cache`/`lastPrewarmAt`/`inflightPrewarms` 等任何主 actor 状态），
        // 可以在这个后台 `Task.detached` 里直接调用；只把降采样后的小图带回主 actor（`.value`
        // 之后，缓存仍在主 actor 上做，不变）。该 closure 只用 dlsym 出来的 C 函数 +
        // CoreGraphics（`downscale`），没有触碰任何主 actor 状态，在后台线程跑是安全的。
        return await Task.detached(priority: .userInitiated) {
            guard let captured = MinimizedCapture.capture(windowID: id) else { return nil }
            return Self.downscale(captured, to: targetSize)
        }.value
    }

    /// 回退链里的第一环：公开 SCK 路径，只能抓可见窗口。返回全分辨率 `CGImage`（未降采样）
    /// ——降采样统一在 `captureRaw` 里做，不管最终走的是这条路径还是私有兜底。
    private func captureViaSCK(_ id: WindowID, targetSize: CGSize) async -> CGImage? {
        guard let scWindow = scWindows[id] else {
            Self.logger.warning("capture: no SCWindow cached for id \(id, privacy: .public) — minimized/off-screen window or refreshShareableContent() not called yet; trying private fallback")
            return nil
        }

        guard CGPreflightScreenCaptureAccess() else {
            Self.logger.warning("screen recording not granted — cannot capture thumbnail for id \(id, privacy: .public)")
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        // O3：`SCStreamConfiguration.width/height` 是像素尺寸，不会自动保持窗口的宽高比——
        // 旧版本直接把 `targetSize` 原样喂给它，一扇窄长的窗口（比如竖屏浏览器）会被 SCK
        // 拉伸/压扁成 `targetSize` 的比例出图。`downscale` 的 `scale >= 1` 快路径只在图片
        // 本来就没超出目标框时才原样返回，`scale < 1` 时是「按图片自身宽高比等比缩小」——
        // 一旦 SCK 已经把图拉伸了，`downscale` 拿到的「图片自身宽高比」本身就是错的，没有
        // 办法在下游把它修正回来。这里改成以 `scWindow.frame` 的宽高比为准，在 `targetSize`
        // 的框内等比适配（`fitScale <= 1`，不放大原图，跟 `downscale` 同一套 fit-within
        // 逻辑），保证 SCK 输出的图跟私有兜底路径（`MinimizedCapture` 直接抓原始分辨率，
        // 天然不拉伸）在几何上一致——两条路径的输出都是「未拉伸、等比」的。
        let frame = scWindow.frame
        let frameWidth = max(1, frame.width)
        let frameHeight = max(1, frame.height)
        let fitScale = min(targetSize.width / frameWidth, targetSize.height / frameHeight, 1)
        config.width = max(1, Int((frameWidth * fitScale).rounded()))
        config.height = max(1, Int((frameHeight * fitScale).rounded()))
        config.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Self.logger.error("SCScreenshotManager.captureImage failed for id \(id, privacy: .public): \(error.localizedDescription, privacy: .public); trying private fallback")
            return nil
        }
    }

    /// R1：用一份**已经抓到**的 `SCShareableContent` 重建 id→SCWindow 映射，本身不发起任何
    /// 请求/不检查权限（权限检查是抓这份 content 时的事）。`WindowStore.refreshNow()` 是这个
    /// 方法现在的主要调用方——它每次全量刷新自己抓一次 `SCShareableContent`（同时喂给
    /// `screenLister.windows(from:)`），把结果传进来，取代旧版本「`ThumbnailService` 自己单独
    /// 再抓一次 `refreshShareableContent()`」的双重 XPC，也让这个映射跟着每次全量刷新一起
    /// 变新鲜（不再是永久停留在 `warmUp()` 那一刻的启动快照）。
    func setShareableContent(_ content: SCShareableContent) {
        scWindows = Dictionary(
            content.windows.map { (WindowID($0.windowID), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    /// 自己抓一次 `SCShareableContent` 并重建映射——现在只留给 `warmUp()`
    /// （App 启动时还没有 `WindowStore.refreshNow()` 可复用，得自己抓一次）用。日常的映射刷新
    /// 改由 `WindowStore.refreshNow()` 抓一次内容后调用 `setShareableContent(_:)`，不再从这里
    /// 重复抓取（R1，见类型头注释）。
    ///
    /// 无权限/请求失败时**保留旧映射**并记日志，不清空——比起「这次刷新失败就让所有缩略图
    /// 都抓不到」，宁可继续用上一次成功的映射（可能有一两个窗口关闭/新开导致映射轻微过期，
    /// 好过整体失效）。
    func refreshShareableContent() async {
        guard CGPreflightScreenCaptureAccess() else {
            Self.logger.warning("screen recording not granted — thumbnail SCWindow map unavailable")
            return
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            Self.logger.error("SCShareableContent.current failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        setShareableContent(content)
    }

    /// 启动预热：`refreshShareableContent()` 一次（建映射）+ 对第一个可用窗口触发一次
    /// 无关紧要的小尺寸抓图，把 SCK 首调 163ms 的冷启动成本移到 App 启动阶段抵消掉，
    /// 而不是等用户第一次唤出切换器才付。没有可用窗口（没权限/桌面空空）时只做刷新，
    /// 反正后面也没有真的抓图，谈不上冷启动成本。
    ///
    /// 走 `captureRaw` 而不是 `capture`——这张 1×1 图纯粹是为了触发 SCK 冷启动，不代表任何
    /// 真实窗口的内容，绝不能进 `cache`：否则 `cached(id)` 可能对一个真实窗口返回这张退化的
    /// 1×1 图，直到下一次真实抓图把它覆盖掉。
    func warmUp() async {
        await refreshShareableContent()
        guard let firstID = scWindows.keys.first else { return }
        _ = await captureRaw(firstID, targetSize: CGSize(width: 1, height: 1))
    }

    /// 把抓到的图等比缩放到「不超出 targetSize」的框内（fit-within），从不拉伸/压扁；彻底
    /// 失败时返回 `nil`（O2，见下）。
    ///
    /// `SCStreamConfiguration.width/height` 只是给 SCK 的目标尺寸建议，不是保证：Spike 3
    /// 实测的是抓图延迟（见类型头注释），并没有验证 SCK 会按目标尺寸精确出图；加上 SCK
    /// 的 `preservesAspectRatio`/`scalesToFit` 默认行为本身就可能对原图做等比缩放甚至
    /// letterbox（留边）。所以这里不能假设「尺寸已经匹配就什么都不用做」，必须始终按
    /// **图片自身的宽高比**重新计算输出尺寸，不管 SCK 实际吐出来的是什么尺寸。O3 之后
    /// `captureViaSCK` 已经会按窗口宽高比配置 SCK 输出，这里的「按图片自身宽高比」逻辑仍然
    /// 保留、不依赖 O3——两者独立成立，双重保险。
    ///
    /// 计算：`scale = min(targetWidth / image.width, targetHeight / image.height)`。
    /// - `scale >= 1`（图片本来就没超出目标框）→ 原样返回，不放大一张小窗口变成模糊的大图。
    /// - `scale < 1` → 按 `scale` 等比缩小到 `(round(width*scale), round(height*scale))`，
    ///   结果可能在某一维上小于 `targetSize`——这是对的，缩略图必须保持窗口原始宽高比；
    ///   把等比缩略图摆进固定尺寸卡片（留白/居中）是 Phase 5 UI 的事，这里不做黑边填充。
    ///
    /// O1：`nonisolated`——纯函数，只读参数、只碰局部变量，不触碰 `scWindows`/`cache`/
    /// `lastPrewarmAt`/`inflightPrewarms` 等任何 `ThumbnailService` 的主 actor 状态。这允许
    /// 调用方（`captureRaw` 的私有兜底分支）把它跟 `MinimizedCapture.capture` 一起塞进同一个
    /// `Task.detached`，在后台线程把「抓全分辨率图 + 降采样」一次做完，只把降采样后的小图
    /// 带回主 actor——避免在主 actor 上对一张 5K 级（约 56MB）位图做一次昂贵的 `CGContext`
    /// 重绘造成可感知的卡顿。SCK 路径（`captureViaSCK`）因为 SCK 本身已经按（O3 之后是等比
    /// 适配过的）`targetSize` 出图，这里的降采样多数情况下只是 `scale >= 1` 分支的原样返回，
    /// 成本可忽略，继续留在主 actor 上调用即可，不必也挪进 detached task。
    ///
    /// O2：`CGContext`/`makeImage` 失败时**不再退回原图**——旧版本 `?? image` 会让一张全
    /// 分辨率原图（典型触发场景：HDR/10-bit 窗口的非典型色彩空间/位深，配上这里硬编码的
    /// `bitsPerComponent: 8` 导致 context 创建失败）被当成「缩略图」存进 `cache`：私有兜底
    /// 路径下单个条目就可能是 ~56MB，直接吃光 `ByteBudgetCache` 32MB 的预算并把其它所有窗口
    /// 的缩略图挤出去。现在改成：第一次用「源图自己的 colorSpace/bitmapInfo」建 context 失败
    /// 后，**重试一次**——这次用标准化 context（sRGB、8-bit、`premultipliedFirst` +
    /// `byteOrder32Little`，不再依赖源图的色彩空间/位深），多数「源图色彩空间不常见」导致的
    /// 失败都能被这次重试绕过。重试也失败才真正返回 `nil`，调用方（`captureRaw`）落回「这次
    /// 没有缩略图」，不缓存任何东西，UI 落回 App 图标。
    private nonisolated static func downscale(_ image: CGImage, to targetSize: CGSize) -> CGImage? {
        let targetWidth = max(1, targetSize.width)
        let targetHeight = max(1, targetSize.height)

        let scale = min(targetWidth / CGFloat(image.width), targetHeight / CGFloat(image.height))
        guard scale < 1 else {
            return image
        }

        let dw = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let dh = max(1, Int((CGFloat(image.height) * scale).rounded()))

        if let downscaled = drawDownscaled(
            image,
            width: dw,
            height: dh,
            colorSpace: image.colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        ) {
            return downscaled
        }

        // O2 重试：标准化 context，不再依赖源图的色彩空间/位深。
        let standardizedBitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return drawDownscaled(
            image,
            width: dw,
            height: dh,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
            bitmapInfo: standardizedBitmapInfo
        )
    }

    /// `downscale` 的 context 创建 + 绘制这一小步，抽出来供「源图 colorSpace/bitmapInfo」和
    /// O2 的「标准化 colorSpace/bitmapInfo」两次尝试共用。`nonisolated`，理由同 `downscale`。
    private nonisolated static func drawDownscaled(
        _ image: CGImage,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace?,
        bitmapInfo: UInt32
    ) -> CGImage? {
        guard let colorSpace,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo
              )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Task 16: opportunistic prewarm on focus-loss

extension ThumbnailService {
    /// 机会性预热某窗口缩略图（fire-and-forget，调用方——`WindowStore`——不 `await` 这个
    /// 方法，也不关心它有没有真的抓成）：窗口刚失去焦点时（还在渲染、是抓图的好时机）顺手
    /// 触发一次抓图，让切换器唤出时热门目标大概率已经有较新的缩略图，不用现抓现等。
    ///
    /// **三重防护**（都是为了扛住 Mission Control/连打 Cmd+Tab 造成的焦点事件风暴，
    /// 这是项目「空闲不能有 CPU 尖峰」性能红线的直接体现）：
    /// ① **每窗节流**：同一 `id` 距上次调度 < `prewarmThrottle`（默认 1.0s）直接跳过——
    ///   焦点风暴期间同一扇窗口可能在几十毫秒内反复失焦/复焦（比如 Cmd+Tab 连续按住循环
    ///   预览），没必要每次都重新抓一遍。
    /// ② **全局 in-flight 上限**：当前正在跑的预热 `capture` 数量 ≥ `maxInflightPrewarms`
    ///   （默认 2）就跳过——防止风暴瞬间把一堆并发 SCK/私有兜底抓图请求堆起来；跳过的这次
    ///   不会永久丢失机会，下一次这扇窗口再失焦、或者切换器打开时的按需抓图，还会再给它
    ///   一次机会。
    /// ③ **已有较新缓存**：`capture` 内部已经会覆盖写 `cache`，这里不用额外查
    ///   `cached(id)` 再判断一遍是否「新鲜」——①的节流窗口本身就保证了同一个 id 不会被
    ///   短时间内重复抓取，效果等价于「跳过已经足够新鲜的缓存」，不需要重复实现一遍新鲜度
    ///   判断。
    ///
    /// **状态更新的顺序**：`lastPrewarmAt[id]`/`inflightPrewarms += 1` 在发起 `Task` **之前**
    /// 同步完成——整个方法体是 `@MainActor` 隔离的普通同步代码，不存在挂起点，因此不会有
    /// 两次并发调用交错读到同一份「跳过前」状态的竞态；`Task` 内部的 `await capture(...)`
    /// 才是唯一的挂起点，此时节流/计数已经落地，后续调用天然能看到正确的 in-flight 数。
    ///
    /// **`inflightPrewarms` 递减**：不管 `capture` 最终抓成还是返回 `nil`（比如窗口这一瞬间
    /// 已经关闭/权限缺失），`Task` 结束时都无条件递减——用 `[weak self]` 避免这个后台任务
    /// 意外延长 `ThumbnailService` 的生命周期；`self` 提前释放（比如 App 层拿着的引用没了）
    /// 时 `self?.inflightPrewarms -= 1` 整体短路成 no-op，不会崩溃，也不需要额外处理——反正
    /// 计数器本身也跟着 `self` 一起没了。
    func schedulePrewarm(_ id: WindowID, targetSize: CGSize = CGSize(width: 400, height: 250)) {
        guard inflightPrewarms < maxInflightPrewarms else {
            return
        }
        if let last = lastPrewarmAt[id], Date().timeIntervalSince(last) < prewarmThrottle {
            return
        }

        lastPrewarmAt[id] = Date()
        inflightPrewarms += 1
        Task { [weak self] in
            _ = await self?.capture(id, targetSize: targetSize)
            self?.inflightPrewarms -= 1
        }
    }
}
