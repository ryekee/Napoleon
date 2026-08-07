import AppKit
import ApplicationServices
import CoreGraphics
import NapoleonCore
import ScreenCaptureKit
import os

/// 把 Task 11 `WindowEnumerator`（全量枚举）、Task 12a `AXObserverController`（增量 AX
/// 通知）、Task 5b `WindowStoreReducer`（纯状态机）整合成常驻「热态」：`Controller` 触发
/// 选择器时读 `snapshot()`（O(1)，值拷贝），不再临时枚举。
///
/// **状态机边界**：本类型自己**不**决定窗口列表怎么变——所有状态变化都翻译成
/// `WindowEvent` 交给 `WindowStoreReducer.reduce` 处理（reducer 已在 NapoleonCore 单测覆盖），
/// `WindowStore` 只负责「AX/NSWorkspace 事件 → WindowEvent 翻译」+「维护句柄映射」两件事。
///
/// **句柄正反映射**：`handles: [WindowID: AXUIElement]`（正向，供未来 WindowFocuser 聚焦用）+
/// `reverse: [AXElementKey: WindowID]`（反向，把 AX 通知回调带回来的 element 映射回枚举时
/// 记下的 WindowID——`.windowDestroyed`/`.minimizedChanged`/`.titleChanged`/
/// `.focusedWindowChanged` 全靠它反查，因为这些通知本身不带 CGWindowID）。
///
/// **全量刷新的时机与合并**：`onAppAppeared`（新 App 出现，需要给它补一次枚举）和
/// `NSWorkspace.activeSpaceDidChangeNotification`（切 Space，AX 只能看见当前 Space 的窗口，
/// 集合可能整体变了）都会触发一次全量刷新；这两类事件在短时间内可能连续多次触发（比如一次
/// 切 Space 伴随系统发出的多个通知），所以用一个可取消的 `DispatchWorkItem` 做 debounce，
/// 合并成一次 `enumerateAll()`。
///
/// **跨 Space 保留：本任务暂缓**——`WindowEnumerator` 枚举到的窗口全部标记
/// `isOnCurrentSpace = true`（AX 本就只能看见当前 Space），全量刷新时旧 Space 的窗口不会被
/// 保留，reducer 的 `.fullRefresh` 直接把窗口集合替换成新枚举结果。跨 Space 保留留给之后接
/// 「其它 Space」开关时再做（那时会用到 `.spaceChanged` 事件，本类型目前不发它）。
///
/// **线程**：整个类型 `@MainActor`。`AXObserverController` 的回调本就保证落在主线程
/// （Task 12a 的设计），`enumerateAll()` 是唯一跨到后台的调用——`await` 之后自动跳回主 actor
/// 再走 `reduce` + 重建句柄映射，中间没有任何跨线程共享可变状态的窗口。
@MainActor
final class WindowStore {
    // `nonisolated`——`Logger` 是 `Sendable`，这个 `static let` 本身没有任何跨 actor 可变状态，
    // 显式放开隔离让 `Self.fetchShareableContent()`（R1，`nonisolated`，见该方法注释）也能用它
    // 记日志，不需要为了这一条 log 调用把整个抓取函数拉回主 actor。
    private nonisolated static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "WindowStore")

    /// `onAppAppeared` / Space 切换触发的全量刷新 debounce 延迟——落在任务书要求的
    /// ~150–250ms 区间，足够合并一次 Space 切换/App 启动过程中的多次事件，又不会让热态
    /// 明显滞后于真实变化。
    private static let fullRefreshDebounceInterval: TimeInterval = 0.2

    private(set) var state: WindowState

    /// 全屏逃生：最近一次全量刷新时，用户所在 Space 本身是不是全屏（由 `spaceClassifier`
    /// 从 CGS 读出）。`snapshot()` 一并带给 `SwitcherController`，让 `WindowFilter.apply` 在
    /// 用户被困在全屏 Space 时放开跨 Space 过滤（见 `WindowFilter`）。切进/切出全屏都会经
    /// `activeSpaceDidChangeNotification → scheduleFullRefresh()` 在 ~200ms 内刷新这个值，
    /// 所以触发切换器时读缓存值足够新鲜，不必在热路径上再同步查一次 CGS（保持激活低延迟）。
    private(set) var currentSpaceIsFullscreen = false

    /// 全屏逃生锚点：最近一次**在普通桌面**（`currentSpaceIsFullscreen == false`）刷新时记下的
    /// 各 display 当前桌面 Space id 集合（`spaceClassifier.currentSpaceIDs`）。进入全屏后 AX 只
    /// 看得见那扇全屏窗口，`SCShareableContent` 又会把所有其它 Space 的窗口一股脑带回来（观感
    /// 很吵）——`escapeAwareAdditions` 因此在全屏时用它 + `spaceClassifier.isOnAnySpace` 把逃生
    /// 列表收窄到「用户逃生要回到的那些桌面」的窗口。
    ///
    /// **为什么记 Space id 而不是窗口快照**：记 id 是让每次全屏刷新都用**本次新鲜**的
    /// `screenWindows` 去按 Space 过滤——关掉的窗口不在新鲜枚举里（无幽灵），桌面上新开的窗口
    /// 天然在新鲜枚举里（不漏窗）；换成记窗口快照则会因为「快照只在全量刷新更新、增量
    /// create/destroy 不维护它」而同时产生幽灵窗口 + 漏窗（fable 审查 #1）。
    ///
    /// **为什么是集合**：双显示器副屏进全屏时，用户刚离开的桌面不是「首个 display」的当前
    /// Space——记单个 id 会漏掉副屏桌面的窗口（fable 审查第 2 轮 #1）。记全所有 display 的当前
    /// 桌面 Space，任一命中即保留。
    ///
    /// 只在桌面刷新**且**这次 CGS 读取成功（`currentSpaceIDs` 非空）时更新——一次瞬态 CGS 失败
    /// 不会把好锚点冲成空集（fable 审查第 2 轮 #4）；全屏刷新保持不变（见 `refreshNow`）。空集
    /// （本次会话从未在桌面成功读到过，例如直接在全屏里启动）时 `escapeAwareAdditions` 退回显示
    /// 全部桌面窗口（脏一点但不被困，fable 审查 #2 的 fallback）。
    private var lastDesktopSpaceIDs: Set<Int> = []

    /// Task 21：读「用户是否打开了『包含其他桌面的窗口』」。全屏逃生的收窄（`escapeAwareAdditions`）
    /// 只在这个开关**关着**时才做——开关打开意味着用户明确要看到所有 Space 的窗口，这时还在 store
    /// 层把非逃生桌面的窗口裁掉，`WindowFilter` 再想放行也没得放（窗口压根不在输入里），等于设置项
    /// 在全屏状态下静默失效（fable 首轮审查 #4，当时无设置 UI 不可达，Phase 6 起可达，故在此收口）。
    ///
    /// 做成闭包而不是缓存的布尔值：每次刷新现读，天然与设置同步，不需要观察/失效通知。默认
    /// `{ false }` 保持既有行为（`WindowStore` 的单测与非 App 构造路径不必关心设置）。
    private let includesOtherSpaces: @MainActor () -> Bool

    /// 对账用的地面真相来源（见 `reconcileWithWindowServer`）。做成闭包只为了可测——生产环境
    /// 永远是默认值 `WindowServerReconciler.onScreenWindows`；测试注入一份固定的窗口列表，就能
    /// 确定性地造出「窗口服务器看得见、热态里没有」的漂移，验证自愈真的会发生。
    private let onScreenWindows: @MainActor () -> [OnScreenWindow]

    private let enumerator: WindowEnumerator
    private let observer: AXObserverController
    /// Task X2：全量刷新时额外并入的跨 Space/全屏窗口来源（公开 SCShareableContent，
    /// Task X1）。AX 依旧是当前 Space 的权威（有句柄），这一路只贡献 AX 看不到的
    /// `isOnCurrentSpace = false` 窗口，见 `CrossSpaceMerge`。R1：`refreshNow()` 现在自己
    /// `await Self.fetchShareableContent()` 抓一次 `SCShareableContent`（同一份内容也喂给
    /// `thumbnails?.setShareableContent(_:)`），再同步调用 `screenLister.windows(from:)`
    /// 做纯过滤——不再由 `screenLister` 自己发起第二次独立的 XPC（旧 `screenLister.list()`
    /// 内部会自己抓一次，跟 `ThumbnailService.refreshShareableContent()` 各抓各的，一次全量
    /// 刷新有两次 `SCShareableContent.current`，见任务书 R1）。
    private let screenLister: ScreenWindowLister
    /// Task X4：全量刷新时对跨 Space 窗口打「是否在全屏 Space」标——`refreshNow()` 每次刷新
    /// 都先 `refresh()` 重建这次的 Space→type 映射，再把 `isOnFullscreenSpace` 作为闭包注入
    /// `CrossSpaceMerge.crossSpaceAdditions`（见 `crossSpaceAdditions(axWindows:screenWindows:)`）。
    /// 私有 CGS API 全在这个类型内部 dlsym 探测/降级，`WindowStore` 不关心细节。
    private let spaceClassifier: SpaceClassifier
    /// 跨 Space MRU 修复：`handleAppActivated` 用它把「刚激活的 App 的焦点窗口」直接解析成
    /// `WindowID`，不再只依赖 `reverse` 句柄映射——见该方法头注释。无实例状态（内部只有一个
    /// `static let` 缓存的 dlsym 探测结果），跟 `WindowEnumerator` 各自持有一份互不冲突。
    private let resolver: WindowIDResolver
    /// Task 16：机会性缩略图预热的目标——注入 `nil`（默认）时下面的 `reduceFocusChange(to:)`
    /// 完全不触发预热，行为退化回 Phase 3（本类型不依赖它做任何状态判断，只是顺手调用）。
    private let thumbnails: ThumbnailService?

    /// 正向：WindowID → AXUIElement，供聚焦使用。
    private var handles: [WindowID: AXUIElement] = [:]
    /// 反向：AXUIElement → WindowID，供把 AX 通知的 element 映回 WindowID。
    private var reverse: [AXElementKey: WindowID] = [:]

    /// Task 16：上一次被 `reduceFocusChange(to:)` reduce 为聚焦窗口的 id——用来判断「这次
    /// 焦点变化是不是真的换了一扇窗口」，以及要预热哪一扇（刚失焦的那扇，也就是这个旧值）。
    /// `nil` 表示「还没见过任何一次真实的聚焦变化」（比如刚 `start()`，或者上一次聚焦的窗口
    /// 已经被判定为 `nil`——目前没有任何调用路径会把它设回 `nil`，保留这个可选类型只是为了
    /// 表达「初始状态下没有『上一个焦点』」，不是一个会在运行期被重置的字段）。
    private var lastFocusedID: WindowID?

    private var pendingFullRefresh: DispatchWorkItem?
    private var isStarted = false
    /// `stop()` 之后置 `true`，`start()` 重新拉起时复位——防止 `stop()` 调用时仍在飞行中的
    /// `refreshNow()`（`await enumerator.enumerateAll()` 还没返回）在 `await` 结束后又把
    /// `state`/`handles`/`reverse` 重新填回去（见 `refreshNow()`）。
    private var isStopped = false

    /// 每次「窗口集合可能已经变化」的时刻自增一——R3 之后**只**覆盖会改变窗口集合本身的来源：
    /// ① `handleWindowCreated`/`handleWindowDestroyed`/`handleAppTerminated` 里真正调用了
    /// `WindowStoreReducer.reduce` 的分支（一次窗口创建/销毁/App 退出生效）；② `scheduleFullRefresh()`
    /// 每次被调用（一次全量刷新被触发，不管最终是不是真的会跑）；③ `stop()`。**不**包括
    /// `.titleChanged`/`.focusedWindowChanged`/`.minimizedChanged`（含 R1 的 `handleAppActivated`）——
    /// 这些是对已存在窗口的原地字段/MRU 更新，不改变「有哪些窗口」这件事本身，一份新鲜的
    /// `.fullRefresh` 天然已经正确反映它们，让它们 bump 只会制造 livelock（见 `refreshNow()`
    /// 详细说明）。也**不**在 `refreshNow()` 成功应用 `.fullRefresh`/merge 结果之后自增——
    /// 应用本身不代表「状态又变了」，这里如果也自增会导致 `refreshNow()` 拿着应用前捕获的
    /// `gen` 去跟应用后的 `stateGeneration` 比对时错误地判定为「过期」。
    ///
    /// `refreshNow()` 用它判断是否需要 merge：`await enumerator.enumerateAll()` 期间主 actor
    /// 上可能跑了别的会改变窗口集合的事件——直接套用这份「相对当前 state 已经过期」的快照会
    /// 撤销期间发生的变化（比如让一个已经 `.windowDestroyed` 的窗口复活），所以 mismatch 时走
    /// merge（借助 `journaledRemovedIDs`），而不是简单套用或整体丢弃。
    private var stateGeneration = 0

    /// R3：`refreshNow()` 的 `await enumerator.enumerateAll()` 期间为 `true`；`handleWindowDestroyed`/
    /// `handleAppTerminated` 用它判断「这次摘除是否发生在一次全量枚举的飞行途中」，只有这种情况才需要
    /// 记进 `journaledRemovedIDs`（见下）——不在飞行中的普通摘除不需要记账，`refreshNow()` 压根不会去读它。
    private var refreshInFlight = false

    /// R3：`refreshInFlight` 为 `true` 期间，被 `handleWindowDestroyed`/`handleAppTerminated`
    /// 真实摘除（真正调用过 `reduce(.destroyed)`/`reduce(.appTerminated)`）的 `WindowID` 集合。
    /// `refreshNow()` 每次开始飞行前清空；`await` 结束后如果 generation 不一致，用它从这次
    /// `enumerateAll()` 带回来的（相对当前 `state` 略旧的）快照里剔除这些 id——保证一个在飞行
    /// 期间被真实摘除的窗口，不会被这份「摘除前拍的」快照复活。见 `refreshNow()` 详细说明。
    private var journaledRemovedIDs: Set<WindowID> = []

    /// R4（Critical）：`refreshNow()` 是唯一有挂起点（`await enumerator.enumerateAll()`）的
    /// 方法——挂起期间主 actor 被让出，如果另一路调用（`start()` 的首刷 Task /
    /// `scheduleFullRefresh()` 的 debounce Task）恰好在这段挂起期间也调用了 `refreshNow()`，
    /// 会有第二次 `enumerateAll()` 并发跑起来。`refreshInFlight`/`journaledRemovedIDs` 是
    /// single-flight 假设下的实例状态（`refreshNow()` 一开始清空 `journaledRemovedIDs`、结束时
    /// 把 `refreshInFlight` 复位）——一旦两次调用交叠，后来者的清空/复位会踩到前一次仍在飞行中的
    /// 记账：例如后来者 `journaledRemovedIDs.removeAll()` 抹掉前一次已经记下的摘除 id，前一次
    /// `await` 结束后做 merge 时少剔除了本该剔除的 id，复活一个真实已被销毁的窗口；或者前一次
    /// 先把 `refreshInFlight` 置回 `false`，此时后一次仍在 `await` 中，这段期间发生的销毁事件
    /// 会因为 `refreshInFlight == false` 而不被记账，同样导致复活。
    ///
    /// 这里不改 merge 逻辑本身（单飞行前提下已验证正确），只在入口处把并发请求「串行化」成
    /// 「最多一个在飞、之后最多再补跑一次」：`refreshNow()` 开头如果发现 `refreshInFlight`
    /// 已经是 `true`，只置位这个标记、不真的再发起一次 `enumerateAll()`；当前那次飞行结束
    /// （应用完 `.fullRefresh`/merge 结果之后，不管走的是哪条分支）如果看到这个标记被置位，
    /// 就清掉它、再补跑恰好一次 `refreshNow()`，从而收敛到一份反映最新触发原因的快照——不需要
    /// 无限重试，因为每次触发之间最多只会累积成一次「排队」，`refreshQueued` 是一个 `Bool`
    /// 不是计数器，短时间内再多次触发也只会合并成这一次补跑。
    private var refreshQueued = false

    /// R2（Critical）：`AXUIElementSetMessagingTimeout` 是 per-element 设置——`WindowEnumerator`/
    /// `AXObserverController` 目前只在各自新建的 App 级 `AXUIElement`（`AXUIElementCreateApplication`）
    /// 上显式设过 0.5s，窗口级 `AXUIElement`（`kAXWindowsAttribute` 返回的那些、AX 通知回调直接带回来
    /// 的 element）从未单独设置过，默认走系统 ~6s 超时。一个卡死/beachball 的 App，其窗口元素上任何
    /// AX 读取（`handleWindowCreated`/`handleTitleChanged`/`WindowFocuser.focus` 等）都可能因此卡住
    /// 主线程 6-24s——期间 CGEventTap 会被系统判定为无响应而自动禁用，热键彻底失灵。
    ///
    /// Apple 文档记录了一个例外：对**系统级元素**（`AXUIElementCreateSystemWide()`）调用
    /// `AXUIElementSetMessagingTimeout` 会把这个超时设成**整个进程的默认值**——之后任何新创建的
    /// `AXUIElement`（不管有没有显式调用过这个函数）都会继承它。这里借用 `static let` 本身是
    /// lazy + 线程安全 exactly-once 初始化的特性，在 `start()` 里、任何 AX 调用真正发生之前触发一次，
    /// 天然满足「进程级只需设一次」的语义，不需要额外的 dispatch_once/锁。各处已有的 per-app-element
    /// 显式调用（`WindowEnumerator`/`AXObserverController`）继续保留——现在是无害的冗余（设置同一个值
    /// 两次），保留是为了不引入不必要的 diff，也是给「万一某个系统版本上这条系统级默认值文档行为失效」
    /// 的双保险。
    private static let configureSystemWideMessagingTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }()

    /// `observer` 的默认值不能写成参数列表里的 `= .init()`——`AXObserverController` 是
    /// `@MainActor`，而 Swift 里默认参数表达式的求值发生在一个非隔离上下文，即使它所属的
    /// 初始化器本身（因为 `WindowStore` 是 `@MainActor`）是隔离的，也会报「main
    /// actor-isolated initializer in a synchronous nonisolated context」——跟
    /// `AppDelegate` 当年不能把 `AXObserverController()` 直接写成属性默认值、要挪进
    /// `applicationDidFinishLaunching` 里构造是同一个限制。这里改用 `nil` 哨兵 + 在
    /// init **函数体**内（本就是 MainActor-isolated 上下文）构造真正的默认值。
    init(
        initialState: WindowState = .init(),
        enumerator: WindowEnumerator = .init(),
        observer: AXObserverController? = nil,
        screenLister: ScreenWindowLister = .init(),
        resolver: WindowIDResolver = .init(),
        thumbnails: ThumbnailService? = nil,
        spaceClassifier: SpaceClassifier = .init(),
        includesOtherSpaces: @escaping @MainActor () -> Bool = { false },
        onScreenWindows: @escaping @MainActor () -> [OnScreenWindow] = { WindowServerReconciler.onScreenWindows() }
    ) {
        self.state = initialState
        self.onScreenWindows = onScreenWindows
        self.enumerator = enumerator
        self.observer = observer ?? AXObserverController()
        self.screenLister = screenLister
        self.resolver = resolver
        self.thumbnails = thumbnails
        self.spaceClassifier = spaceClassifier
        self.includesOtherSpaces = includesOtherSpaces
    }

    /// 先接线 AX 通知回调 + 订阅 `NSWorkspace`（Space 切换 + App 激活）+ 启动 `observer`，
    /// 最后才做首次全量枚举建立热态基线。重复调用是 no-op。
    ///
    /// O1（Important）：顺序刻意是「先开事件源，再补基线」而不是反过来——旧版本先
    /// `await refreshNow()` 建基线、最后才 `observer.start()`，这段 `await` 期间（可能几十到
    /// 几百毫秒，取决于有多少个 App/是否有卡死的 App）系统发生的窗口创建/销毁/App 启动全部
    /// 是事件真空：`observer` 还没开始送通知，这些变化永久错过，直到下一次全量刷新（如果还有
    /// 触发的话）才可能被捞回来，新启动 App 的初始窗口甚至完全没有补救路径（`onAppAppeared`
    /// 本身就没接线）。现在反过来：先把 `observer.onNotification`/`onAppAppeared`/
    /// `onAppTerminated` 接好、`NSWorkspace` 的 Space 切换 + App 激活订阅装好、`observer.start()`
    /// 跑起来，事件流开始产生之后，才 `await` 首次 `refreshNow()`。这是安全的：reducer 的
    /// `.created` 对已存在 id 是替换语义、句柄映射写入是幂等的，所以首次枚举返回时如果某个
    /// 窗口已经因为一条 AX 通知被 `handle(_:)` 提前加过一次，不会造成重复；R3 的
    /// generation/journal 机制也已经能正确处理「首次枚举飞行期间发生了真实的窗口集合变化」
    /// 这种情况（见 `refreshNow()`）。
    func start() {
        guard !isStarted else { return }
        isStarted = true
        isStopped = false

        // R2：触发一次进程级 AX messaging timeout 设置（exactly-once，见该属性的文档注释），
        // 必须在任何 AX 调用之前——下面 `observer.start()`/`refreshNow()` 都会发起 AX 调用。
        _ = Self.configureSystemWideMessagingTimeout

        observer.onNotification = { [weak self] notification in
            self?.handle(notification)
        }
        observer.onAppAppeared = { [weak self] _ in
            // 具体是哪个 pid 出现不重要——全量刷新本身就会把新 App 的窗口一起捞回来。
            self?.scheduleFullRefresh()
        }
        observer.onAppTerminated = { [weak self] pid in
            self?.handleAppTerminated(pid)
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        // R1：MRU 只靠 App 内部的 `kAXFocusedWindowChanged` 更新的话，切到另一个 App（Dock/
        // 点击）或者聚焦一个只有单窗口的 App（这类 App 内部焦点窗口没变，不会发这个通知）都不会
        // 更新 MRU——`MRU[1]`（“上一个窗口”）因此可能长期停留在错误的位置，导致两个单窗口 App
        // 之间来回切换卡死在其中一个上。`didActivateApplicationNotification` 是系统级「哪个 App
        // 变成前台」的事件源，覆盖上述两种 `kAXFocusedWindowChanged` 覆盖不到的路径。
        center.addObserver(
            self,
            selector: #selector(handleAppActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // ⌘H 隐藏/取消隐藏 App。`isHiddenApp` 此前只在枚举那一刻写入，而隐藏**不触发任何刷新**，
        // 标记会一直停在旧值——用户关掉「包含已隐藏应用的窗口」后，隐藏 App 的窗口依然出现在
        // 浮层里（真机实测的 bug）。订阅这两个通知后，标记随隐藏状态实时更新。
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

        // 见上方方法头注释：observer 必须先启动，才去补首次全量枚举，避免事件真空。
        observer.start()

        Task { [weak self] in
            await self?.refreshNow()
        }
    }

    /// 停止 observer、取消未执行的 debounce 刷新、退订 `NSWorkspace`（Space 切换订阅 +
    /// R1 新增的 App 激活订阅，同一个 `removeObserver(self)` 一并覆盖）、清空句柄映射。
    /// `state` 本身保留（调用方仍可读到「最后一次已知」的热态），重复调用/从未 `start()`
    /// 过时都是安全的 no-op。
    ///
    /// 先置 `isStopped = true` 再自增 `stateGeneration`——这样任何此刻正在
    /// `await enumerator.enumerateAll()` 里飞行中的 `refreshNow()`，`await` 返回后第一件事
    /// 就是 `guard !isStopped else { return }`，直接整体丢弃这次结果，不会在 `stop()` 之后
    /// 又把 `state`/`handles`/`reverse` 重新填回去（也不会走 R3 的 generation-mismatch
    /// merge 分支——那个分支只处理「还在跑」但状态已经变化的情况，`stop()` 之后要的是
    /// 彻底不再碰状态，两者不是一回事）。`stateGeneration += 1` 仍然保留：即使
    /// `isStopped` 已经短路了 `refreshNow()` 的应用逻辑，让 generation 也前进一格是保持
    /// 「任何一次可能改变状态的时刻都推进 generation」这条总原则的一致性，不依赖调用顺序。
    func stop() {
        guard isStarted else { return }
        isStarted = false
        isStopped = true
        stateGeneration += 1

        pendingFullRefresh?.cancel()
        pendingFullRefresh = nil

        observer.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        handles.removeAll()
        reverse.removeAll()
    }

    /// 仅主线程调用，O(1) 读当前热态 + 句柄映射（Controller 触发选择器时用）。`WindowState`
    /// 和字典都是值类型（COW），这里是一次廉价的引用计数拷贝，不是深拷贝。
    func snapshot() -> (state: WindowState, handles: [WindowID: AXUIElement], currentSpaceIsFullscreen: Bool) {
        pruneTerminatedApps()
        reconcileWithWindowServer()
        return (state, handles, currentSpaceIsFullscreen)
    }

    /// 诊断报告只读当前内存热态；`WindowState` 是值类型（COW），不会触发窗口枚举或 AX 查询。
    func diagnosticState() -> WindowState { state }

    /// 自愈：把「窗口服务器说在屏幕上、而热态里没有」的窗口补回来。
    ///
    /// **为什么必须有这一步**：热态的窗口集合是单向衰减的——增量 AX 通知负责加减窗口，而全量刷新
    /// 只由「App 启动 / 切 Space / 开关设置窗口」触发，三者都跟「热态是否还正确」毫无关系。任何一次
    /// 丢失的通知、任何一次结果偏少的枚举，都会永久留在热态里。真机实测过最坏的样子：一个连续跑了
    /// 22.5 小时的进程，列表掉到只剩 2 扇窗口，连用户当时正在用的前台 App 的窗口都不在里面，而同一
    /// 时刻独立探针能正常枚举到 18 扇；启动任意一个 App 触发一次全量刷新，列表立刻全部恢复。
    /// 缺的不是枚举能力，是对账。
    ///
    /// 放在 `snapshot()` 里跟 `pruneTerminatedApps()` 并列，理由也一样：切换器每次呼出都会经过这里，
    /// 是唯一必须保证正确的时刻，且空闲时零开销（不呼出就不查）。成本是一次
    /// `CGWindowListCopyWindowInfo`（实测中位数 0.86ms、最坏 6.7ms，纯进程内查询、无 AX IPC、
    /// 不需要任何权限），相对一次浮层渲染可以忽略。
    ///
    /// 读不到窗口服务器（返回空数组）时**整个跳过**——那说明这次查询失败了，不代表「一扇窗口都没有」，
    /// 拿它当真会得出「热态里所有窗口都是多余的」这种灾难性结论。这里本来也只补不删，但显式短路能让
    /// 这个前提写在代码里，而不是依赖读者去推。
    private func reconcileWithWindowServer() {
        let onScreen = onScreenWindows()
        guard !onScreen.isEmpty else { return }

        let reconciliation = WindowServerReconciler.reconcile(
            knownWindows: state.windows,
            onScreen: onScreen,
            appInfo: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), app.isRegularOrSelf else {
                    return nil
                }
                return .init(name: app.localizedName ?? "", bundleID: app.bundleIdentifier, isHidden: app.isHidden)
            },
            pinyin: { [enumerator] title in enumerator.pinyinEnabled ? PinyinTransformer.pinyin(for: title) : nil }
        )
        guard reconciliation.changed else { return }

        // notice 级：记录“完全丢失”和“已知但错误分类”两类漂移；标题不入日志，避免泄露用户内容。
        Self.logger.notice("""
        window list drifted — recovering \(reconciliation.recoveredIDs.count, privacy: .public) missing window(s), \
        correcting \(reconciliation.correctedIDs.count, privacy: .public) visible window(s) \
        (had \(self.state.windows.count, privacy: .public), window server sees \(onScreen.count, privacy: .public) on screen)
        """)

        state = WindowStoreReducer.reduce(state, .reconciled(reconciliation.observedWindows))

        // 只有本轮新补入的窗口，或本轮首次纠正且缺少 AX 句柄的窗口，才需要让 AX 尝试补齐。
        // 下一次呼出时状态已经正确，`reconciliation.changed == false`，不会形成刷新风暴。
        let needsHandleRefresh = !reconciliation.recoveredIDs.isEmpty
            || reconciliation.correctedIDs.contains { handles[$0] == nil }
        if needsHandleRefresh {
            scheduleFullRefresh()
        }
    }

    /// 请求一次全量刷新（debounce 合并，见 `scheduleFullRefresh`）。
    ///
    /// 给「窗口集合可能已经变了、但系统不会为此发任何通知」的场景用——目前唯一的调用方是
    /// Napoleon 自己切换 `NSApplication.activationPolicy`（设置窗口开/关时在 `.regular` 与
    /// `.accessory` 之间切换，见 `SettingsWindowController`）：枚举只收 `.regular` 的 App，
    /// 所以这一下切换会让 Napoleon 自己的窗口进入或离开列表，而 `didLaunch`/`didTerminate`
    /// 都不会因为策略变化而触发。
    func requestRefresh() {
        scheduleFullRefresh()
    }

    /// **同步**摘掉一扇已知消失的窗口，不等 `requestRefresh()` 那 200ms 的 debounce。
    ///
    /// 给「调用方比系统更早知道窗口没了」的场景用——目前唯一的调用方是 Napoleon 自己的设置窗口
    /// 关闭（`SettingsWindowController.windowWillClose`）。只发 `requestRefresh()` 是不够的：那是
    /// 一个 200ms 的 debounce，这期间窗口仍留在 `state` 里、`handles` 里也仍有它的 AX 句柄，而
    /// 自身进程的窗口销毁通知走不到这里（`AXObserver` 注册的是别的 App）。用户在这 200ms 内按
    /// Cmd+Tab 就会看到一张已经关掉的设置窗口卡片，选中它更糟：`isReleasedWhenClosed = false`
    /// 让 NSWindow 对象还活着，AX 句柄多半没失效，于是 AXRaise 静默成功、Napoleon 被提到前台，
    /// 而屏幕上什么都没有——用户原来的 App 平白丢了焦点。
    ///
    /// 复用 `.destroyed` 那条正常路径：摘窗口 + 清句柄正反映射 + generation/journal 记账，与
    /// `handleWindowDestroyed` 完全一致。调用方仍应照旧再排一次全量刷新兜底。
    func forget(windowID id: WindowID) {
        guard handles[id] != nil || state.windows.contains(where: { $0.id == id }) else { return }

        stateGeneration += 1
        state = WindowStoreReducer.reduce(state, .destroyed(id))
        if let element = handles.removeValue(forKey: id) {
            reverse.removeValue(forKey: AXElementKey(element: element))
        }
        if refreshInFlight {
            journaledRemovedIDs.insert(id)
        }
    }

    /// 自愈：丢掉「所属进程已经不在了」的窗口。
    ///
    /// **为什么不能只靠 `didTerminateApplicationNotification`**：真机实测发现有的 App 退出时这个
    /// 通知**根本不送达**（复现：Setapp 装的 MoneyWiz——启动通知正常收到、进程也确实结束了，却
    /// 收不到终止通知；同一次会话里 Calculator/TextEdit 完全正常）。一旦漏掉，那个 App 的窗口会
    /// **永远**留在列表里：窗口级的销毁通知同样随进程一起消失，而全量刷新只在「新 App 出现」和
    /// 「切 Space」时触发，用户不做这两件事就永远看不到它消失。这正是用户报的 ghost。
    ///
    /// 放在 `snapshot()` 里——切换器每次呼出都会经过这里，是唯一必须保证正确的时刻，且空闲时
    /// 零开销（不呼出就不查）。成本是每个**去重后的 pid** 一次 `NSRunningApplication`
    /// 进程内查表，窗口数是个位到低两位数、App 数更少，相对一次浮层渲染可以忽略。
    private func pruneTerminatedApps() {
        var deadPIDs: Set<ProcessID> = []
        var checked: Set<ProcessID> = []
        for window in state.windows where !checked.contains(window.pid) {
            checked.insert(window.pid)
            if NSRunningApplication(processIdentifier: window.pid) == nil {
                deadPIDs.insert(window.pid)
            }
        }
        guard !deadPIDs.isEmpty else { return }

        Self.logger.notice("pruning windows of \(deadPIDs.count, privacy: .public) terminated app(s) that never sent a termination notification")
        for pid in deadPIDs {
            // 复用正常的终止路径：摘窗口 + 清句柄正反映射 + generation/journal 记账，一致处理。
            observer.forgetTerminatedApp(pid)
            handleAppTerminated(pid)
        }
    }

    /// 安全网：拥有方忘记调用 `stop()` 就释放本实例时兜底清理。注意 `NSWorkspace` 的
    /// notification center **不会**强持有 `self`——`addObserver(_:selector:name:object:)`
    /// 这个 target-action 形式自 macOS 10.11 起就是非持有（non-owning）的，跟 block-based
    /// 的 `addObserver(forName:object:queue:using:)` 不是一回事，后者才会强持有闭包/被闭包
    /// 捕获的对象。所以就算漏调 `stop()`，`self` 也能正常 dealloc，`isolated deinit` 会
    /// 自然触发（本类型是 `@MainActor`，deinit 体真正执行前 Swift 保证已经跳回主 actor，
    /// 可以直接同步调用 `stop()`）。`stop()` 里的 `removeObserver(self)` 仍然是好习惯
    /// （尽早退订，避免 dealloc 前那段时间还收到通知），但不是让 dealloc 得以发生的必要条件。
    /// 与 12a `AXObserverController` 的 deinit 安全网是同一套模式。
    isolated deinit {
        stop()
    }

    // MARK: - Full refresh (initial + debounced)

    /// 重新 `enumerateAll()` → `reduce(.fullRefresh(windows))` → 用枚举返回的句柄整体重建
    /// `handles`/`reverse`。初始首刷与 debounce 后的全量刷新共用这同一条路径。
    ///
    /// **句柄映射与 reducer 结果的一致性**：`WindowStoreReducer` 的 `.fullRefresh` 分支直接
    /// 把 `state.windows` 替换成传入的 `newWindows`（不做任何过滤/合并——存活的窗口集合
    /// 就是 `newWindows` 本身，MRU 顺序才是唯一需要按存活集合过滤的部分）。而 `newHandles`
    /// 正是 `enumerator.enumerateAll()` 对同一批 `newWindows` 构造出的句柄，键集合与
    /// `newWindows` 的 id 集合完全一致，所以 reduce 之后直接用 `newHandles` 整体替换
    /// `handles`/`reverse` 天然就是对齐的，不需要再额外做一次差集/交集计算——**除非**走的是
    /// 下面的 generation-mismatch merge 分支，那种情况下 `newHandles` 会先被过滤/补充一遍才
    /// 使用，见下。
    ///
    /// **R3：过期结果保护改成 merge，不再整体 discard**。`await enumerator.enumerateAll()` 是
    /// 本类型唯一的挂起点，期间主 actor 可能跑别的事情——现在只有真正改变「窗口集合」的事件
    /// 才会让 `stateGeneration` 前进（`.windowCreated`/`.windowDestroyed`/`.appTerminated`，
    /// 以及 `scheduleFullRefresh()` 自己/`stop()`；`.titleChanged`/`.focusedWindowChanged`/
    /// `.minimizedChanged`——包括 R1 新增的 `handleAppActivated`——都是纯字段/MRU 原地更新，
    /// 不再 bump，因为一份新鲜的 `.fullRefresh` 天然就已经正确反映它们，没有理由让它们使一次
    /// 全量枚举失效）。旧版本一旦 mismatch 就整体丢弃并重新排一次 `scheduleFullRefresh()`——
    /// 如果 window-set 变化事件持续到来（旧版本连标题变化都算），这个 discard 分支永远赢，
    /// 全量刷新永远排不上号（livelock：切 Space 后窗口列表卡在旧 Space，新启动 App 的初始
    /// 窗口永远补不回来）。
    ///
    /// 现在的做法：`await` 之前记下 `gen = stateGeneration` 并清空 `journaledRemovedIDs`、置
    /// `refreshInFlight = true`；这段飞行期间如果 `handleWindowDestroyed`/`handleAppTerminated`
    /// 真的摘除了某些窗口，会把它们的 id 记进 `journaledRemovedIDs`（见那两个方法）。`await`
    /// 结束后：
    /// - `isStopped` 优先于一切——`stop()` 之后绝不再碰 `state`/`handles`/`reverse`（`stop()`
    ///   本身会同步清空它们，这里再套用一份旧快照等于撤销那次清空）。
    /// - generation 一致：这段 await 期间什么都没发生，直接套用 `windows`/`newHandles`。
    /// - generation 不一致：**merge**而不是 discard——
    ///   1. 从 `windows` 里剔除 `journaledRemovedIDs`：这些窗口在飞行期间被真实摘除过，这份
    ///      「摘除前拍的」快照如果原样套用会把它们复活。
    ///   2. 把当前 `state.windows` 里「`windows` 没有、也没被 `journaledRemovedIDs` 标记摘除」
    ///      的窗口原样带过去：这些是飞行期间被 `handleWindowCreated` 直接加进 `state` 的新
    ///      窗口——`enumerateAll()` 内部并发枚举多个 App，某个 App 的
    ///      `AXUIElementCopyAttributeValue(kAXWindowsAttribute)` 读取完全可能发生在它自己那个
    ///      新窗口创建之前，而由于是并发 `withTaskGroup`，只要另一个 App 还没返回，整个
    ///      `enumerateAll()` 就还没结束——这就会让这一个 App 的枚举结果对这次飞行而言是「偏旧」
    ///      的，即使窗口本身已经通过 AX 通知被 `handleWindowCreated` 正确加进了 `state`。不带
    ///      过去就会被 `.fullRefresh` 的整体替换语义（`state.windows = newWindows`）无声吞掉——
    ///      这是本次修复没有采用「无脑套用 fresh 快照」的原因：那样虽然解决了 livelock，却会
    ///      引入一种新的「丢窗口」回归。
    /// - 收敛保证：上面两种情况都会**在这一次 `await` 完成后就直接落地**一份 `.fullRefresh`，
    ///   不再需要 discard-and-retry，因此不存在「连续多次都 mismatch」的问题——不需要额外的
    ///   重试计数器。如果这次 mismatch 是因为期间又发生了一次独立的 `scheduleFullRefresh()`
    ///   触发（比如 Space 又切了一次），那次调用本身已经排好了自己的 debounced 刷新，会在之后
    ///   独立地用一份更新鲜的快照再收敛一轮——不需要这里重复补排。
    /// - 绝不复活：`journaledRemovedIDs` 只记录「这一次飞行期间」发生的真实摘除，`refreshNow()`
    ///   一开始就清空，语义上是「这次快照相对哪些 id 已知过期」，剔除它们保证一份旧快照永远不能
    ///   让一个已经被用户关掉的窗口重新出现在 `state.windows` 里。
    ///
    /// **R4：串行化，防止并发飞行**——见 `refreshQueued` 的属性注释。函数体开头先看
    /// `isStopped`（`stop()` 之后彻底不再做任何事，包括排队），再看 `refreshInFlight`：如果
    /// 已经有一次飞行在跑，只置位 `refreshQueued` 并立即返回，绝不重入
    /// `await enumerator.enumerateAll()`。真正进入飞行的这条路径上，`refreshInFlight = true`
    /// 之后立刻挂一个 `defer { refreshInFlight = false }`——这样不管后面走哪条分支（`await`
    /// 之后新增的 `isStopped` 二次检查、generation 一致/不一致两条 apply 分支），这个飞行标记
    /// 都保证会被清掉，不会因为提前 return 被永久卡在 `true`（哪怕以后这个函数变成 `throws`，
    /// `defer` 也照样覆盖异常路径）。
    ///
    /// 飞行的收尾（apply 完 `.fullRefresh`/merge 结果之后，不管走的是哪条分支，也不管
    /// `await` 之后是否发现已经 `isStopped`）统一检查一次 `refreshQueued`：如果被置位过，
    /// 说明飞行期间至少有一次新的刷新请求被合并跳过了，需要补跑一轮才能收敛到反映那次请求的
    /// 最新状态。这里**不**直接 `await refreshNow()` 递归自调——那样会在 `defer` 真正执行、
    /// `refreshInFlight` 变回 `false` 之前就重入这个函数，命中「已经在飞」的守卫，白白把
    /// `refreshQueued` 又置一次位、什么都不做，永远收敛不了。改成起一个新的 `Task` 异步再调
    /// 一次：当前这次调用先正常走到函数末尾、触发 `defer`、把 `refreshInFlight` 落地为
    /// `false`，新 `Task` 排进主 actor 队列，等主 actor 空出来才真正执行——这时候
    /// `refreshInFlight` 已经是 `false`，补跑的这次能正常进入飞行。`isStopped` 在起这个新
    /// `Task` 之前也再检查一遍：`stop()` 之后不再补跑任何排队的刷新（即使补跑了，新调用自己
    /// 开头的 `isStopped` 守卫也会立刻短路，这里提前判断只是省一次无意义的 `Task` 创建）。
    private func refreshNow() async {
        guard !isStopped else { return }

        guard !refreshInFlight else {
            refreshQueued = true
            return
        }

        let gen = stateGeneration
        journaledRemovedIDs.removeAll()
        refreshInFlight = true
        defer { refreshInFlight = false }

        // O5：`enumerator.enumerateAll()`（AX，当前 Space）和 `Self.fetchShareableContent()`
        // （SC，R1 之后是 `screenLister`/`thumbnails` 共用的唯一一次 `SCShareableContent`
        // 抓取，见下）互相之间没有数据依赖——串行 await 会白白多等一轮 XPC/AX 往返（spike
        // 实测约 +60ms）。用 `async let` 把两者并发发起，用一次 `await` 元组同时收齐结果。
        // 两个子任务仍然完整落在 `refreshInFlight = true` ~ `defer { refreshInFlight = false }`
        // 之间——不管哪个先返回，只要还没到这行下面的 `await`，`refreshInFlight` 都还是
        // `true`，所以跟原来串行版本一样受 R3/R4 的 generation/single-flight 保护：期间发生的
        // AX 创建/销毁一样会被记进 `journaledRemovedIDs`/影响 `stateGeneration`，merge/discard
        // 逻辑本身不变。
        async let axTask = enumerator.enumerateAll()
        async let contentTask = Self.fetchShareableContent()
        let (axResult, content) = await (axTask, contentTask)
        let windows = axResult.windows
        let newHandles = axResult.handles
        // R1：`screenLister.windows(from:)` 是纯同步过滤，不再自己发起 XPC——`content` 就是
        // 上面 `contentTask` 刚抓到的那一份（抓取失败/未授权时是 `nil`，过滤结果自然是 `[]`，
        // 跟旧 `screenLister.list()` 失败时返回 `[]` 的降级语义一致）。
        let screenWindows = content.map { screenLister.windows(from: $0) } ?? []

        if !isStopped {
            if let content {
                // R1：把这次刷新统一抓到的同一份 `content` 喂给 `ThumbnailService`，让它的
                // id→SCWindow 映射跟主窗口列表同步刷新——不再是永远停留在 `warmUp()` 那一刻
                // 的启动快照（旧版本只有 `warmUp()` 调用过 `ThumbnailService.
                // refreshShareableContent()`，启动后新建的窗口永远进不了这个映射，只能落到
                // 更贵的私有全分辨率兜底路径）。抓取失败（`content == nil`）时不调用，
                // `ThumbnailService` 内部保留上一次成功的映射，跟它自己
                // `refreshShareableContent()` 失败时的降级语义一致。
                thumbnails?.setShareableContent(content)
            }

            // Task X4：在计算跨 Space 追加项之前重建这次刷新的 Space→type 映射——
            // `crossSpaceAdditions(axWindows:screenWindows:)` 下面两条分支都要用到
            // `spaceClassifier.isOnFullscreenSpace`，这里只刷新一次，两条分支共用同一份
            // 拓扑快照（跟本次 `screenWindows` 同属一次全量刷新，语义上是同一时刻的状态）。
            spaceClassifier.refresh()
            // 全屏逃生：把这次刷新读到的「当前 Space 是否全屏」缓存下来，供 `snapshot()` 带给
            // `SwitcherController` → `WindowFilter.apply`（见该属性文档）。跟 `state` 落在同一段
            // 无挂起点的同步尾巴里更新，两者对同一次刷新一致。
            currentSpaceIsFullscreen = spaceClassifier.currentSpaceIsFullscreen
            // 全屏逃生锚点：只在「不在全屏」时把各 display 当前桌面 Space id 记下来（在全屏里当前
            // Space 是全屏 Space，不能拿它当逃生目标，否则会把锚点冲成全屏那一格）。显式放在这里、
            // 而不是藏进 `escapeAwareAdditions` 里当副作用——去掉那个函数名与副作用的隐性时序依赖
            // （fable 审查 #6b）。再要求 `currentSpaceIDs` 非空才更新：一次瞬态 CGS 失败（读到空集）
            // 不该把上一份好锚点冲掉（fable 审查第 2 轮 #4）。
            if !currentSpaceIsFullscreen && !spaceClassifier.currentSpaceIDs.isEmpty {
                lastDesktopSpaceIDs = spaceClassifier.currentSpaceIDs
            }

            if gen == stateGeneration {
                // 飞行期间窗口集合没变化：`windows` 本身就是当前 Space 的权威 AX 快照，直接
                // 拿它的 id 集合去重跨 Space 追加项即可。
                let additions = escapeAwareAdditions(axCurrentWindows: windows, screenWindows: screenWindows)
                applyFullRefresh(
                    windows: windows + additions,
                    handles: newHandles,
                    windowLayerSnapshot: axResult.windowLayerSnapshot
                )
            } else {
                let freshIDs = Set(windows.map(\.id))
                // 只把「飞行期间新创建、这份偏旧的 AX 快照还没来得及看到」的**当前 Space**窗口
                // 带过去——跨 Space 窗口（`isOnCurrentSpace == false`）不需要走这条路径：它们
                // 会在下面用这次刚抓到的 `screenWindows` 重新算一遍，旧的那份不带过去，否则会
                // 跟新算出来的追加项重复（同一个 windowID 出现两次）。
                let carriedOver = state.windows.filter {
                    $0.isOnCurrentSpace && !freshIDs.contains($0.id) && !journaledRemovedIDs.contains($0.id)
                }

                var mergedWindows = windows.filter { !journaledRemovedIDs.contains($0.id) }
                mergedWindows.append(contentsOf: carriedOver)

                var mergedHandles = newHandles.filter { !journaledRemovedIDs.contains($0.key) }
                for window in carriedOver {
                    if let existingHandle = handles[window.id] {
                        mergedHandles[window.id] = existingHandle
                    }
                }

                // 跨 Space 追加项按 `mergedWindows`（这次收敛出的最终 AX 当前 Space 集合，
                // 已经把飞行期间新建的窗口也算进去）去重；再剔除 `journaledRemovedIDs`——防止
                // 这次 `content` 拍到的快照里，恰好包含一个飞行期间已经
                // `handleAppTerminated` 摘除掉的 App 的窗口（该 App 的当前 Space + 跨 Space
                // 窗口在 `handleAppTerminated` 里是一并按 pid 摘除并记账的），复活它。
                let additions = escapeAwareAdditions(axCurrentWindows: mergedWindows, screenWindows: screenWindows)
                    .filter { !journaledRemovedIDs.contains($0.id) }
                mergedWindows.append(contentsOf: additions)

                applyFullRefresh(
                    windows: mergedWindows,
                    handles: mergedHandles,
                    windowLayerSnapshot: axResult.windowLayerSnapshot
                )
            }
        }

        if refreshQueued {
            refreshQueued = false
            if !isStopped {
                // 新起一个 Task，而不是直接 `await refreshNow()` 递归——见方法头注释：
                // 必须等这次调用的 `defer` 把 `refreshInFlight` 落回 `false` 之后，补跑的
                // 这次才能正常进入飞行，而不是被「已经在飞」的守卫短路。
                Task { [weak self] in
                    await self?.refreshNow()
                }
            }
        }
    }

    /// R1：`refreshNow()` 每次全量刷新只抓一次 `SCShareableContent`，喂给下面两个消费者——
    /// 取代旧版本「`ScreenWindowLister.list()` 自己抓一次、`ThumbnailService.
    /// refreshShareableContent()` 又独立抓一次」的双重 XPC（各自 spike 实测 ~59ms）+
    /// `ThumbnailService` 的 id→SCWindow 映射永远停留在 App 启动那一刻快照（新窗口永远走不到
    /// SCK 缩略图路径，只能落到更贵的私有全分辨率兜底）两个问题（见任务书 R1）。
    ///
    /// `nonisolated`——不触碰任何 `WindowStore` 的主 actor 隔离状态，只调用一个纯 C 函数
    /// （`CGPreflightScreenCaptureAccess`）和一个 SCK 静态 async 属性，让它能像旧
    /// `screenLister.list()` 一样作为 `refreshNow()` 里 `async let` 的一个独立子任务真正并发
    /// 执行，不需要先拿到主 actor 才能开始等待 XPC。跟 `ScreenWindowLister.list()`/旧版
    /// `ThumbnailService.refreshShareableContent()` 同一套权限诊断风格：
    /// `CGPreflightScreenCaptureAccess()` 短路（未授权时这次请求注定失败，直接跳过并记
    /// warning，不产生噪音/权限提示）+ `do/catch` 替换 `try?`（授权了但仍失败时记 error，而
    /// 不是静默返回 `nil`）。失败（未授权或请求异常）返回 `nil`——两个消费者对「这次没抓到」
    /// 都有各自的降级路径（`screenLister.windows(from:)` 拿到 `nil` 时 `refreshNow()` 直接把
    /// `screenWindows` 置为 `[]`；`thumbnails?.setShareableContent(_:)` 干脆不调用，保留上一次
    /// 成功的映射），不让主窗口列表跟着失败。
    private nonisolated static func fetchShareableContent() async -> SCShareableContent? {
        guard CGPreflightScreenCaptureAccess() else {
            Self.logger.warning("screen recording not granted — SCShareableContent unavailable")
            return nil
        }

        do {
            return try await SCShareableContent.current
        } catch {
            Self.logger.error("SCShareableContent.current failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Task X2：`refreshNow()` 两条分支共用的「AX 当前 Space 窗口 + SC 跨 Space 窗口 → 待追加
    /// 的跨 Space `WindowInfo` 列表」封装——纯合并决策在 `CrossSpaceMerge`（可单测），这里只
    /// 负责把生产环境的 `keepApp`/`isHiddenApp`/`pinyin` 注入进去。
    ///
    /// O1/Y1：`keepApp` 只保留「pid 当前仍对应一个存活的 `NSRunningApplication`，且
    /// `activationPolicy == .regular`」的窗口——跟 `WindowEnumerator`/`AXObserverController`
    /// 只关心常规 App 的口径对齐。pid 查不到 `NSRunningApplication`（App 已经在这次枚举和这里
    /// 读取之间退出）时 `NSRunningApplication(processIdentifier:)` 返回 `nil`，`?.` 短路成
    /// `nil == .regular` → `false`，天然跳过，顺带修掉 Y1 的死 App 幽灵窗口。
    ///
    /// Task X4：不再是 `static`——需要读 `self.spaceClassifier`，把
    /// `spaceClassifier.isOnFullscreenSpace` 作为 `isFullscreen` 闭包注入，让每个跨 Space
    /// `WindowInfo` 带上「是否在全屏 Space」标（调用方 `refreshNow()` 已经在这之前先
    /// `spaceClassifier.refresh()` 过一次，保证映射是新鲜的）。
    private func crossSpaceAdditions(axWindows: [WindowInfo], screenWindows: [ScreenWindow]) -> [WindowInfo] {
        CrossSpaceMerge.crossSpaceAdditions(
            axWindowIDs: Set(axWindows.map(\.id)),
            screenWindows: screenWindows,
            keepApp: NSRunningApplication.isRegularOrSelf(pid:),   // 与枚举侧同口径，含 Napoleon 自己
            isHiddenApp: { NSRunningApplication(processIdentifier: $0)?.isHidden ?? false },
            pinyin: PinyinTransformer.pinyin,
            isFullscreen: spaceClassifier.isOnFullscreenSpace
        )
    }

    /// 全屏逃生的「干净列表」选择（方案 1，见 `lastDesktopSpaceIDs` 文档）。`axCurrentWindows`
    /// 是本次刷新 AX 枚举的当前 Space 窗口，`screenWindows` 是本次**新鲜**的 `SCShareableContent`
    /// 跨 Space 窗口。无副作用——逃生锚点 `lastDesktopSpaceIDs` 的记录在 `refreshNow` 里显式做
    /// （fable 审查 #6b）。
    ///
    /// - **普通桌面**（`currentSpaceIsFullscreen == false`）：追加项照常是 `crossSpaceAdditions`
    ///   的全部跨 Space 窗口——是否显示交给 `WindowFilter`（桌面态下非全屏的跨 Space 会被滤掉，
    ///   列表干净）。
    /// - **全屏 Space**（`currentSpaceIsFullscreen == true`）：`SCShareableContent` 会把所有其它
    ///   Space 的窗口都带进 `allAdditions`，全放行会涌进大量别的 Space 的窗口（用户实测「很多
    ///   未激活窗口，像出了问题」）。这里保留其中**全屏**的那些（其它全屏 App，方便在全屏之间
    ///   切换），桌面窗口则用**本次新鲜**的 `allAdditions` 按 `lastDesktopSpaceIDs` 收窄到「逃生
    ///   要回到的那些桌面」：因为用的是本次新鲜枚举，关掉的窗口不在里面（无幽灵）、桌面上新开
    ///   的窗口天然在里面（不漏窗）（fable 审查 #1——记 Space id 而非窗口快照的关键收益）。
    ///
    /// **两处 fail-open 兜底**（宁可脏一点，也绝不把用户困在只剩全屏 App 的列表里）：
    ///   ① 锚点为空集（本次会话从未在桌面成功读到过，例如直接在全屏里启动）——退回全部桌面
    ///      窗口（fable 审查 #2）。
    ///   ② 锚点有值但收窄结果为空而桌面窗口非空——**区分因由**（fable 审查第 3 轮 Minor #1）：
    ///      只有「收窄机制坏了」（逐窗口 CGS 查询符号缺失，或锚点指向的桌面 Space 已被删、跟当前
    ///      拓扑不相交）才退回全部桌面窗口；若机制正常、纯粹是出发桌面**真的空了**，就只显全屏
    ///      App（不泛洪别的桌面窗口——那正是本 feature 要消除的噪声，那块空桌面本来也无处可回）。
    private func escapeAwareAdditions(axCurrentWindows: [WindowInfo], screenWindows: [ScreenWindow]) -> [WindowInfo] {
        let allAdditions = crossSpaceAdditions(axWindows: axCurrentWindows, screenWindows: screenWindows)
        guard currentSpaceIsFullscreen else { return allAdditions }
        // Task 21：用户已经明确要「包含其他桌面的窗口」时不做任何收窄——收窄的目的是替用户滤掉
        // 他没要的噪声，而不是覆盖他的选择（见 `includesOtherSpaces` 文档）。
        guard !includesOtherSpaces() else { return allAdditions }

        let fullscreenAdditions = allAdditions.filter { $0.isFullscreen }
        let desktopAdditions = allAdditions.filter { !$0.isFullscreen }

        // 兜底①：锚点未知。
        guard !lastDesktopSpaceIDs.isEmpty else { return fullscreenAdditions + desktopAdditions }

        let escapeDesktop = desktopAdditions.filter { spaceClassifier.isOnAnySpace($0.id, of: lastDesktopSpaceIDs) }
        // 兜底②：收窄结果为空但确实有桌面窗口在——只在收窄机制真的坏了时才泛洪，桌面真空则只显
        // 全屏 App（见方法头注释因由区分）。
        if escapeDesktop.isEmpty && !desktopAdditions.isEmpty {
            let mechanismBroken = !spaceClassifier.canQueryWindowSpaces
                || lastDesktopSpaceIDs.isDisjoint(with: spaceClassifier.allSpaceIDs)
            return mechanismBroken ? fullscreenAdditions + desktopAdditions : fullscreenAdditions
        }
        return fullscreenAdditions + escapeDesktop
    }

    /// `refreshNow()` 两条分支（generation 一致 / merge 后）共用的「真正套用一份全量快照」步骤，
    /// 提出来避免重复。
    ///
    /// R3e：`.fullRefresh` 是整体替换语义（见 `WindowStoreReducer` 的 `.fullRefresh` 分支），
    /// 传入的 `windows` 里每个窗口的 `title`/`isMinimized` 字段都是这次 `enumerateAll()` 读到的
    /// 快照值——这里隐含一个「新鲜枚举的字段比 `state` 里现有的更新」的假设，对绝大多数情况成立，
    /// 但不是严格保证：如果 `enumerateAll()` 内部对某个 App 的 AX 读取，恰好发生在一次
    /// `.titleChanged`/`.minimizedChanged` 增量更新（`handleTitleChanged`/`handle(.minimizedChanged)`）
    /// 落到 `state` 之前，这次全量刷新落地后会用略旧的快照值把那次增量更新的字段盖回去。这是
    /// 可接受的：`.titleChanged`/`.minimizedChanged` 不 bump `stateGeneration`（见 `handle(_:)`
    /// 头注释），所以这种情况不会被当成 mismatch 走 merge 分支——影响范围只是一次性丢掉那一个
    /// 字段更新，窗口本身（存在与否）不受影响，下一次同一个字段再变化（或下一次全量刷新）会
    /// 自然纠正，不需要额外处理。
    private func applyFullRefresh(
        windows: [WindowInfo],
        handles newHandles: [WindowID: AXUIElement],
        windowLayerSnapshot: WindowLayerSnapshot?
    ) {
        let reconciledWindows: [WindowInfo]
        var validHandles = newHandles
        if let windowLayerSnapshot {
            let appliedVisibility = WindowServerReconciler.applyingPositiveVisibility(
                to: windows,
                onScreen: windowLayerSnapshot.onScreenWindows,
                appInfo: { pid in
                    guard let app = NSRunningApplication(processIdentifier: pid), app.isRegularOrSelf else {
                        return nil
                    }
                    return .init(
                        name: app.localizedName ?? "",
                        bundleID: app.bundleIdentifier,
                        isHidden: app.isHidden
                    )
                },
                pinyin: { [enumerator] title in
                    enumerator.pinyinEnabled ? PinyinTransformer.pinyin(for: title) : nil
                }
            )
            reconciledWindows = appliedVisibility.windows
            for id in appliedVisibility.invalidHandleIDs {
                validHandles.removeValue(forKey: id)
            }
        } else {
            reconciledWindows = windows
        }

        state = WindowStoreReducer.reduce(
            state,
            .fullRefresh(Self.withFreshHiddenFlags(reconciledWindows))
        )
        handles = validHandles
        reverse = Dictionary(
            uniqueKeysWithValues: validHandles.map { id, element in (AXElementKey(element: element), id) }
        )
    }

    /// 套用全量快照前，按 pid **现读**一次「App 是否隐藏」，覆盖快照里那份可能过期的值。
    ///
    /// 快照里的 `isHiddenApp` 是 `enumerateAll()` 读 `NSRunningApplication.isHidden` 那一刻的值，
    /// 而一次全量枚举要几十到几百毫秒——期间用户完全可能 ⌘H。由于 `didHideApplication` 是一次性
    /// 通知（隐藏期间不会重发）、全量刷新又只由切 Space 触发（没有定时刷新），一旦被旧快照覆盖回
    /// `false`，隐藏窗口会一直显示到用户下次切 Space。这里现读一次就把整类时序问题消掉：不管 ⌘H
    /// 落在枚举前、枚举中还是枚举后，落地的都是当下的真实状态。
    ///
    /// 按 pid 去重后查询（窗口数是个位到低两位数、App 数更少），`NSRunningApplication(processIdentifier:)`
    /// 是廉价的进程内查表，这点开销相对一次 AX 全量枚举可以忽略。
    private nonisolated static func withFreshHiddenFlags(_ windows: [WindowInfo]) -> [WindowInfo] {
        var hiddenByPID: [ProcessID: Bool] = [:]
        return windows.map { window in
            var window = window
            let isHidden: Bool
            if let cached = hiddenByPID[window.pid] {
                isHidden = cached
            } else {
                isHidden = NSRunningApplication(processIdentifier: window.pid)?.isHidden ?? false
                hiddenByPID[window.pid] = isHidden
            }
            window.isHiddenApp = isHidden
            return window
        }
    }

    /// `onAppAppeared` / Space 切换的 debounce 入口：取消上一个尚未执行的刷新任务，重新排一个
    /// ~200ms 后触发的 `DispatchWorkItem`，从而把短时间内的连续事件合并成一次
    /// `enumerateAll()`。`DispatchWorkItem` 本身在 `.main` 队列上延迟触发，闭包内部用
    /// `Task { @MainActor in ... }` 跳进主 actor 去 `await` 异步的 `refreshNow()`——
    /// `DispatchWorkItem` 的闭包类型本身不携带 actor 隔离信息，不能直接在其中调用
    /// `@MainActor` 的 async 方法。
    ///
    /// 每次被调用都自增 `stateGeneration`——一次「全量刷新被触发」，是 generation 仍然会
    /// bump 的几类来源之一（另几类见 `handle(_:)` 头注释）：不管这次触发最终是被真正执行、
    /// 还是被下一次触发取消，都算数（`refreshNow()` 现在不再因为过期而重新调用这个方法——
    /// R3 之后过期结果走 merge，不走 discard-and-reschedule，见 `refreshNow()`）。**不**在
    /// `refreshNow()` 成功应用完 `.fullRefresh` 之后自增——那不是「触发」，是「应用」，两者
    /// 语义不同（见 `refreshNow()` 头注释）。
    private func scheduleFullRefresh() {
        stateGeneration += 1
        pendingFullRefresh?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.refreshNow()
            }
        }
        pendingFullRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fullRefreshDebounceInterval, execute: workItem)
    }

    /// O2（Important）：`registerExistingWindows`（`AXObserverController`）只在每个 App **首次**
    /// 出现时跑一次，而 `kAXWindowsAttribute` 只能看到当前 Space 的窗口——如果一个 App 在别的
    /// Space 上还有窗口，它们在这个 App 启动那一刻根本不在 `kAXWindowsAttribute` 结果里，永远
    /// 不会被注册窗口级通知（尤其是 `kAXUIElementDestroyedNotification`）。等用户切到那个
    /// Space、再关掉这些窗口，`WindowStore` 收不到 destroy 通知，会永久留着这些窗口的状态
    /// （ghost）+ 泄漏它们的句柄。每次切 Space 时，除了照常触发全量刷新（`scheduleFullRefresh()`
    /// 更新 `state`），也让 `AXObserverController` 对所有已知 App 重新跑一遍
    /// `registerExistingWindows`——它的 `registeredWindows` 去重让这是幂等/低成本操作，只有
    /// 这次刚刚进入当前 Space、之前从未被注册过的窗口才会真正补上通知注册。
    @objc private func handleActiveSpaceChanged(_ notification: Notification) {
        observer.reRegisterExistingWindows()
        scheduleFullRefresh()
    }

    // MARK: - AX notification → WindowEvent translation

    /// **R3：`stateGeneration` 只在「窗口集合」真的可能变化的分支自增**——`.windowCreated`/
    /// `.windowDestroyed`（经 `handleWindowCreated`/`handleWindowDestroyed`）/`appTerminated`
    /// （经 `handleAppTerminated`，独立回调，不在这个 switch 里）。`.titleChanged`/
    /// `.focusedWindowChanged`/`.minimizedChanged`（以及 R1 新增的 `handleAppActivated`）都是
    /// 对已存在窗口的原地字段/MRU 更新，**不**自增——一份新鲜的 `.fullRefresh` 天然已经正确
    /// 反映这些字段，让它们使一次正在飞行的全量枚举失效没有意义，反而是 livelock 的根源（一个
    /// 标题持续动画变化的 Chrome 标签页大约每 200ms 触发一次 `.titleChanged`，旧版本每次都
    /// bump，几乎总能抢在 `enumerateAll()` 完成前再次让它过期，全量刷新因此永远落不了地：切
    /// Space 后窗口列表卡在旧 Space、新启动 App 的初始窗口永远补不回来）。
    ///
    /// 自增的目的：告诉任何正在 `refreshNow()` 里 `await enumerator.enumerateAll()` 的调用，
    /// 「窗口集合在你等待期间已经变了，你手上那份结果需要 merge 而不能直接套用」——只在真正
    /// `reduce` 的分支自增（guard 提前 return 的分支不算，因为那些根本没碰 `state`）。
    private func handle(_ notification: AXWindowNotification) {
        switch notification {
        case .windowCreated(let pid, let element):
            handleWindowCreated(pid: pid, element: element)

        case .windowDestroyed(_, let element):
            handleWindowDestroyed(element: element)

        case .minimizedChanged(_, let element, let isMinimized):
            // 原地字段更新，不改变窗口集合——不 bump `stateGeneration`（见上方方法头注释）。
            guard let id = windowID(for: element) else { return }
            state = WindowStoreReducer.reduce(state, .minimizedChanged(id, isMinimized))

        case .titleChanged(_, let element):
            handleTitleChanged(element: element)

        case .focusedWindowChanged(_, let element):
            // AX 保证 element 是新聚焦的窗口本身（不是 app 元素）；element 为 nil（该 App
            // 当前没有可聚焦窗口）或反查不到 id（比如通知抢在句柄映射建好之前到达）都跳过——
            // 不驱动 MRU，等下一次真正带得到 id 的事件到来即可，不需要特殊补偿。
            // 纯 MRU 原地更新，不改变窗口集合——不 bump `stateGeneration`（见上方方法头注释）。
            guard let element, let id = windowID(for: element) else { return }
            reduceFocusChange(to: id)
        }
    }

    /// Task 16：`.focused(id)` 被 reduce 的**唯一**入口——`handle(_:)` 的
    /// `.focusedWindowChanged` 分支、`handleAppActivated` 解析成功/兜底两条路径全部改走这里，
    /// 保证「刚失焦窗口的机会性预热」不会因为某条焦点变化路径漏接而失效。
    ///
    /// **只在真正的焦点切换时预热**：`lastFocusedID` 非空且不等于这次的新 `id`（同一扇窗口
    /// 反复上报聚焦——比如同一个通知源短时间内重复触达——不算切换，不重复预热）。预热目标
    /// 是**旧**的 `lastFocusedID`（刚失焦、还在渲染，是抓图的好时机），不是新聚焦的 `id`
    /// （它正显示在屏幕上，不需要抢救缩略图）；必须在 `lastFocusedID` 被新值覆盖**之前**
    /// 调度，顺序反了就再也拿不到刚失焦的那个 id 了。
    ///
    /// Y1：额外 guard `previous` 仍然在 `state.windows` 里才调度预热——旧版本没有这一层
    /// 检查，一扇窗口被关闭时也会走这条路径（关闭本身触发一次焦点变化，`lastFocusedID` 正是
    /// 那扇刚关闭的窗口），对着一个已经不存在的 `WindowID` 发起 `schedulePrewarm`：SCK 映射
    /// 里没有它（`captureViaSCK` 直接 miss）、私有兜底 `MinimizedCapture.capture` 对一个已经
    /// 消失的 CGWindowID 发起 IPC 也注定拿不到东西——每次关窗口都白白发起一次注定失败的私有
    /// IPC + 记一条 warning 日志，没有任何收益。
    ///
    /// `thumbnails?.schedulePrewarm(...)` 是同步的 fire-and-forget 调用（`ThumbnailService`
    /// 内部自己起 `Task`），这里不 `await` 也不需要——不改变本方法、也不改变
    /// `WindowStoreReducer.reduce` 调用的同步语义，`state` 的更新时机跟接入预热之前完全一样。
    private func reduceFocusChange(to id: WindowID) {
        if let previous = lastFocusedID, previous != id, state.windows.contains(where: { $0.id == previous }) {
            thumbnails?.schedulePrewarm(previous)
        }
        lastFocusedID = id
        state = WindowStoreReducer.reduce(state, .focused(id))
    }

    /// 用 `enumerator.windowInfo(for:...)` 构造新窗口的 `WindowInfo`（与 `enumerateAll`
    /// 内部走同一份 AX 读取/过滤逻辑），失败（元素这一瞬间已经不是标准窗口/拿不到
    /// CGWindowID 等）就直接忽略这次通知。
    private func handleWindowCreated(pid: ProcessID, element: AXUIElement) {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else { return }

        guard let result = enumerator.windowInfo(
            for: element,
            pid: pid,
            appName: runningApp.localizedName ?? "",
            appBundleID: runningApp.bundleIdentifier,
            isHiddenApp: runningApp.isHidden
        ) else { return }

        handles[result.id] = result.element
        reverse[AXElementKey(element: result.element)] = result.id
        stateGeneration += 1
        state = WindowStoreReducer.reduce(state, .created(result.info))
    }

    private func handleWindowDestroyed(element: AXUIElement) {
        let key = AXElementKey(element: element)
        guard let id = reverse[key] else { return }

        stateGeneration += 1
        state = WindowStoreReducer.reduce(state, .destroyed(id))
        handles.removeValue(forKey: id)
        reverse.removeValue(forKey: key)

        // R3：这次摘除如果发生在 `refreshNow()` 的 `enumerateAll()` 飞行途中，记进
        // `journaledRemovedIDs`——那次飞行拍下的快照早于这次摘除，`await` 结束后 merge 时要
        // 靠这份记账把这个 id 从快照里剔除，否则会把刚被用户关掉的窗口复活。见 `refreshNow()`。
        if refreshInFlight {
            journaledRemovedIDs.insert(id)
        }
    }

    private func handleTitleChanged(element: AXUIElement) {
        // 原地字段更新，不改变窗口集合——不 bump `stateGeneration`（见 `handle(_:)` 头注释）。
        guard let id = windowID(for: element) else { return }
        let title = Self.readTitle(element)
        // 跟 `enumerator.windowInfo(for:...)`/`enumerateAll` 用同一个 `pinyinEnabled` 开关
        // 判断要不要算拼音——否则关掉 DI flag 之后，全量刷新不带拼音，但标题变化增量更新
        // 又会重新把拼音写回去，行为不一致。
        let pinyin = enumerator.pinyinEnabled ? PinyinTransformer.pinyin(for: title) : nil
        state = WindowStoreReducer.reduce(state, .titleChanged(id, title, pinyin: pinyin))
    }

    /// 走的是 `observer.onAppTerminated` 这条独立回调（不经过上面的 `handle(_:)`），但同样是
    /// 一次会改变窗口集合的状态变化，所以一样要计入 generation——一个 App 恰好在
    /// `refreshNow()` 的 `await` 期间整体退出，如果不算进 generation，merge 检查会漏掉这
    /// 种情况，导致该 App 已终止后的窗口被过期的快照复活。
    private func handleAppTerminated(_ pid: ProcessID) {
        // 先在 reduce 之前从当前（尚未剔除该 pid 之前的）state 里读出它名下所有窗口的 id——
        // reduce 之后 state.windows 里就没有这些条目了，没法再反查。
        let terminatedIDs = state.windows.filter { $0.pid == pid }.map(\.id)
        stateGeneration += 1
        state = WindowStoreReducer.reduce(state, .appTerminated(pid))

        for id in terminatedIDs {
            if let element = handles.removeValue(forKey: id) {
                reverse.removeValue(forKey: AXElementKey(element: element))
            }
        }

        // R3：同 `handleWindowDestroyed`——整个 App 退出期间摘掉的这批窗口，如果发生在一次
        // `refreshNow()` 飞行途中，全部记进 `journaledRemovedIDs`，防止被那次飞行拍到的旧
        // 快照复活。
        if refreshInFlight {
            journaledRemovedIDs.formUnion(terminatedIDs)
        }
    }

    /// R1（Critical）：MRU 的另一个更新来源——App 激活（跟 `.focusedWindowChanged` 是 App
    /// **内部**焦点变化互补的关系，覆盖两类它覆盖不到的路径：切到另一个 App（Dock/点击，跨
    /// App 切换整个不经过任何单个 App 内部的 `kAXFocusedWindowChanged`）、聚焦一个只有单个
    /// 窗口的 App（内部焦点窗口本来就没变过，永远不会发这个通知）。这两类路径不修的话，
    /// `MRU[1]`（“上一个窗口”）会一直停留在很久以前的值，典型症状是两个单窗口 App 之间来回
    /// 切换会卡死在其中一个上。
    ///
    /// 只处理 `isRegularOrSelf` 的 App（跟 `WindowEnumerator`/`AXObserverController` 同一条判据，
    /// 见 `NSRunningApplication.isRegularOrSelf`）。读 `kAXFocusedWindowAttribute` 用的是临时构造的
    /// `AXUIElementCreateApplication(pid)`——这次 AX 读取因为 R2 已经把系统级 messaging
    /// timeout 设成进程默认值 0.5s，不会因为目标 App 卡死而长时间挂起主线程。这是纯 MRU
    /// 原地更新，不改变窗口集合，不 bump `stateGeneration`（跟 `.focusedWindowChanged` 同样的
    /// 道理，见 `handle(_:)` 头注释）。
    ///
    /// **不再排除 Napoleon 自己的 pid**。原先排除是出于「切换器自身的操作会让 Napoleon 短暂
    /// 成为前台、污染 MRU」的顾虑，但当时 Napoleon 根本没有任何标准窗口，那纯属防御性代码；
    /// 而且浮层是 `.nonactivatingPanel` + `canBecomeKey == false`（见 `OverlayPanel`），
    /// Napoleon 成为前台**当且仅当**用户主动选择了设置窗口——菜单栏打开，或者从切换器里切回它
    /// （`WindowFocuser` 的自我分支）。那正是应该记进 MRU 的一次真实激活：设置窗口现在是切换器
    /// 里可选的普通窗口，切走再 Cmd+Tab 时它理应排在「上一个窗口」的位置。
    ///
    /// **守卫必须用 `isRegularOrSelf` 而不是 `activationPolicy == .regular`**。这里曾经写成后者，
    /// 以为「平时是 `.accessory` 的 Napoleon 自然会被挡掉，不需要额外判断」——逻辑正好反了：被挡掉
    /// 的恰恰是该记 MRU 的那一次。从切换器切回设置窗口时，进程仍然是 `.accessory`（上一次切走时
    /// 被 `WindowFocuser` 降级了），要等 `windowDidBecomeKey` 才升回 `.regular`；而这条通知与
    /// `windowDidBecomeKey` 谁先到达没有保证，读到 `.accessory` 就直接 return，MRU 不更新，
    /// 下一次 Cmd+Tab 的默认选中项因此指错。
    ///
    /// **跨 Space MRU 修复：解析优先于反查（不再只用 `reverse`）**。旧版本读到 `focusedRef`
    /// 之后走 `windowID(for:)`（即 `reverse[AXElementKey(element)]`），这对当前 Space 的窗口
    /// 有效——它们是被 `WindowEnumerator.enumerateAll()`/`handleWindowCreated` 枚举/注册过的，
    /// 有真实的 AXUIElement 句柄，`reverse` 里查得到。但跨 Space/全屏窗口（`ScreenWindowLister`
    /// 经 `SCShareableContent` 枚举出来、`isOnCurrentSpace == false` 的那些）从来没有对应的
    /// AXUIElement 句柄——它们不是通过 AX 枚举/通知产生的，`handles`/`reverse` 里压根没有它们
    /// 的条目。于是当一个全屏 App（比如全屏 Safari）被激活时，`reverse` 反查必然 miss，
    /// `.focused(id)` 从未被 reduce，这个窗口永远进不了 MRU——`WindowFocuser` 的「聚焦
    /// MRU[1]」自然也永远够不到它，这正是本次要修的 bug。
    ///
    /// 修复：拿到 `focusedRef` 之后改用 `resolver.windowID(for:)`（`_AXUIElementGetWindow`）
    /// 直接把这个 AXUIElement 解析成 `CGWindowID`——App 刚变成前台的这一刻，它的焦点窗口一定
    /// 在当前 Space 上、AX 可访问，所以 `_AXUIElementGetWindow` 能拿到它的 `CGWindowID`；这个
    /// id 跟 `SCShareableContent` 枚举同一扇窗口时报告的 id 是同一个数值空间（都是系统级
    /// `CGWindowID`），所以不管这扇窗口在 `state.windows` 里是作为「当前 Space」条目
    /// （`handleWindowCreated` 加的）还是「跨 Space」条目（`CrossSpaceMerge` 加的）存在，都能
    /// 命中。解析成功且该 id 确实在 `state.windows` 里（`WindowStoreReducer` 的 `.focused`
    /// 分支本身也会做这个存在性检查，这里提前 guard 只是为了在缺失时能继续走到下面的兜底，而
    /// 不是直接吞掉）才 reduce；否则落到下面的 pid 兜底。
    ///
    /// **兜底**：没有 `focusedRef`（该 App 当前没有可聚焦窗口）、AX 读取失败，或者
    /// `resolver.windowID(for:)` 解析不出来（比如 `_AXUIElementGetWindow` 私有符号在某个系统
    /// 版本上探测不到），改成按 pid 在 `state.windows` 里找这个 App 名下的窗口——优先选
    /// `isOnCurrentSpace == false` 的那个（正是本次要补的跨 Space/全屏条目：当前 Space 的窗口
    /// 已经能被上面的解析路径或 `focusedWindowChanged`/`reverse` 覆盖，不需要这条兜底再管），
    /// 找不到跨 Space 条目就退而求其次用该 pid 的任意一个匹配窗口——对只有一扇全屏窗口的单窗口
    /// App，这一步就已经能正确把它记进 MRU。一个匹配窗口都没有（比如这个 App 的窗口还没被任何
    /// 途径枚举过）就什么都不做，不崩溃，等下一次全量刷新/事件自然补上。
    @objc private func handleAppActivated(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.isRegularOrSelf
        else { return }

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)

        if
            error == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        {
            let element = focusedRef as! AXUIElement // swiftlint:disable:this force_cast -- CFGetTypeID 已确认类型
            if let id = resolver.windowID(for: element), state.windows.contains(where: { $0.id == id }) {
                reduceFocusChange(to: id)
                return
            }
        }

        if let fallbackID = fallbackFocusedWindowID(forPid: pid) {
            reduceFocusChange(to: fallbackID)
        }
    }

    /// ⌘H 隐藏 / 取消隐藏一个 App——把该 pid 名下所有窗口的 `isHiddenApp` 更新掉，
    /// 「包含已隐藏应用的窗口」这个设置项才能真正生效（见 `start()` 里订阅处的说明）。
    ///
    /// 纯字段原地更新，不改变窗口集合，因此不 bump `stateGeneration`（同
    /// `.titleChanged`/`.minimizedChanged`，见 `handle(_:)` 头注释）。
    ///
    /// **与那两者不同的是，这个事件是一次性的**——App 保持隐藏期间 `didHideApplication` 不会再发，
    /// 所以「被一次飞行中的旧快照覆盖回 false」不会像标题变化那样被后续事件自动纠正。解决办法
    /// 不在这里，而在 `applyFullRefresh`：套用任何全量快照时都按 pid **现读**隐藏状态，快照里那份
    /// 可能过期的值根本不会被采信。这样无论 ⌘H 落在枚举前、枚举中还是枚举后，结果都正确。
    @objc private func handleAppHidden(_ notification: Notification) {
        reduceHiddenChange(notification, isHidden: true)
    }

    @objc private func handleAppUnhidden(_ notification: Notification) {
        reduceHiddenChange(notification, isHidden: false)
    }

    private func reduceHiddenChange(_ notification: Notification, isHidden: Bool) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        state = WindowStoreReducer.reduce(state, .appHiddenChanged(app.processIdentifier, isHidden))
    }

    /// `handleAppActivated` 的兜底：按 pid 在 `state.windows` 里找这个刚激活的 App 名下的
    /// 窗口，优先选跨 Space 的那个（见调用方注释）。纯查询，不碰状态。
    private func fallbackFocusedWindowID(forPid pid: ProcessID) -> WindowID? {
        let candidates = state.windows.filter { $0.pid == pid }
        return candidates.first(where: { !$0.isOnCurrentSpace })?.id ?? candidates.first?.id
    }

    // MARK: - Handle map lookup

    private func windowID(for element: AXUIElement) -> WindowID? {
        reverse[AXElementKey(element: element)]
    }

    // MARK: - AX attribute read (single-attribute, for already-known windows)

    /// 只读 `kAXTitleAttribute` 这一个属性——跟 `WindowEnumerator.windowInfo(for:...)` 那种
    /// 「从零构造整份 WindowInfo」不是一回事（那边还要读 subrole/size/CGWindowID 等一整套），
    /// 犯不上为这一个属性读取去扩大 `WindowEnumerator` 的公开面，所以在这里单独写一个最小
    /// helper。
    private static func readTitle(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard error == .success else { return "" }
        return (value as? String) ?? ""
    }
}

// MARK: - AXUIElement Hashable wrapper

/// `AXUIElement`（`AXUIElementRef` = `CFTypeRef`）本身不是 `Hashable`——是 Core Foundation
/// 对象，相等性/哈希要用 `CFEqual`/`CFHash`，不能用默认的对象身份比较。用作 `reverse` 句柄
/// 映射的 key，把 AX 通知回调带回来的 element 映射回 `WindowID`。与
/// `AXObserverController.swift` 里同样手法的 `AXUIElementKey` 是同一套包装思路，各自私有
/// 定义（那边是 `private`，跨文件不可复用，因此这里按任务书要求另起一个同构类型）。
private struct AXElementKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
