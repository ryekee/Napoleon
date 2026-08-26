# Napoleon — Evidence-backed Window Registry 架构设计

> 日期：2026-08-27
>
> 状态：待用户审阅
>
> 目标版本：0.3.2
>
> 原则：身份唯一、证据分级、批次原子提交、负向结论 fail-safe、展示投影 fail-open

## 1. 背景与问题

Napoleon 同时依赖多种 macOS 窗口来源：

- Accessibility（AX）提供用户可操作的窗口语义和聚焦句柄；
- Window Server 提供 WindowID、PID、layer 和 on-screen 状态；
- ScreenCaptureKit 提供 surface、跨 Space 列表和缩略图关联；
- CGS 提供 Space 与全屏分类；
- NSWorkspace 和 AX notifications 提供 App、窗口及焦点事件。

这些来源描述的对象层级不同，且都可能瞬时缺失。现有 `CanonicalWindowRegistry` 正确地阻止了 Window Server 和 ScreenCaptureKit 直接创建 switcher target，但仍把以下概念压缩在同一个可变状态中：

- target 身份；
- 本轮来源是否可靠；
- target 是否仍存活；
- 当前 Space、隐藏、最小化及全屏等展示状态。

当前删除规则是：一次完整审计确认缺失后 quarantine，第二次确认缺失后删除。问题在于 `isComplete == true` 只表达 AX 调用成功，不足以证明本轮结果具备产生负向结论的资格。锁屏、睡眠/唤醒、登录会话切换、Space 过渡或 AX 返回结构异常时，“没有观察到”不能等价于“窗口不存在”。一旦这类结果连续落地，registry 会丢失长期有效的 target；之后焦点事件只能逐个补回当前激活的窗口。

## 2. 设计结论

保留唯一 canonical registry，但把它升级为 evidence-backed registry：

1. 数据源先产生带来源、代次和可信度的 evidence batch；
2. registry 只接受完整批次的原子提交；
3. 每个 AX element 必须被分类，任何 unresolved element 都会取消本 PID 的负向 authority；
4. target lifecycle 只接受 AX semantic/handle 证据，Window Server 与 SCK 不能证明存活；
5. 只有 authoritative batch 才能基于缺失产生 suspect 和删除；精确 destroy 与进程终止仍可立即删除；
6. Space 与筛选状态通过带 per-target Space membership 的无状态 projection 计算，不参与 target 身份生命周期。

这不是完整 event sourcing：不保存无限事件日志，也不引入持久化数据库。只在内存中保存做出当前判断所需的最后有效证据和计数。

## 3. 目标

1. 锁屏、睡眠、唤醒和长时间运行不能因不可信负向结果丢失 canonical targets。
2. 真正关闭窗口和终止 App 仍能及时收敛，不重新引入 ghost window。
3. AX 仍是创建可精确切换 target 的语义来源；弱来源不能独立创建 target。
4. MRU 不因暂时不确定而丢失或重排。
5. 过期或部分审计不能产生任何负向副作用。
6. Switcher 呼出仍为纯内存读取，不增加 AX、SCK、Window Server 或 CGS 查询。
7. Space 证据失败时宁可暂时显示更多窗口，不得把列表收窄成一扇。
8. 第一次强缺失只能标记 suspect，不能让窗口从 switcher 消失；第二次独立强缺失才删除。

## 4. 非目标

- 不把 Window Server 或 ScreenCaptureKit 提升为独立 target creation authority。
- 不在 switcher 呼出时重新枚举系统窗口。
- 不以窗口数量阈值、自动重启或定时清空 registry 作为恢复机制。
- 不保存跨进程启动的 registry；Napoleon 重启后仍从空状态建立新基线。
- 不修改窗口聚焦后端、缩略图采集、搜索或 Switcher UI。
- 不增加 App-specific 规则。

## 5. 核心不变量

### 5.1 身份不变量

- Canonical identity 使用 `(ProcessInstanceID, WindowID)`；`ProcessInstanceID` 由 PID 与进程启动时间组成，避免长运行期 PID/WindowID 同时复用后继承旧状态。
- 只有有效的 AX semantic observation，或由 surface recovery 触发后进一步取得的精确 AX semantic/handle 证据，才能创建 target；surface 本身没有创建权限。
- Window Server、SCK 和 CGS 只能补充已知 target 的 evidence。
- 无法取得进程实例 token 时，不构造或提交 batch；现有 target 原样保留，并由合并后的延迟 audit 重试。这样不会为非可选 identity 发明 provisional 值。

### 5.2 负向证据不变量

- 查询失败、结构异常、会话不活跃、代次过期和部分结果都属于 `positiveOnly`。
- `positiveOnly` batch 可以接受 semantic/AX 正向证据并更新 target，但不能标记 suspect、删除、降级当前 Space 或清除 MRU。
- 只有同一 process instance 的 authoritative semantic audit 才能确认“本轮未观察到”。
- App 明确终止和精确 AX destroyed notification 是强负向事件，可立即删除对应 target。
- Window Server/SCK surface 只能证明 presentation，不得把 suspect target 恢复为 active，也不得清零 absence。

### 5.3 投影不变量

- Registry 保存 target 和证据，不保存“本次 switcher 最终应显示什么”的结论。
- 当前 Space、全屏逃生、隐藏/最小化设置和用户 scope 在 projection 阶段组合。
- Projection context 不可靠时 fail-open；不使用陈旧的收窄集合继续过滤。
- Projection 是纯函数，不修改 registry、MRU 或 evidence。

### 5.4 批次不变量

- 每轮 audit 使用单调递增的 `generation`，并捕获 `sessionEpoch`、`environmentEpoch`、`topologyEpoch` 和 per-process-instance `membershipEpoch`。
- session/environment epoch 不匹配时，semantic positives 可降级落地，但 presentation evidence 和 negatives 必须丢弃。
- membership epoch 不匹配表示窗口集合已发生创建/销毁变化；对应 PID 的整份 batch 必须拒绝并重排 audit，不能接受过期 positives。
- 每个 target 维护 `mutationRevision`，App hidden 另维护 per-process-instance revision。revision 不匹配只保护对应 target/字段，不把整个 App 的 audit 降级；create/destroy 仍由 membership epoch 否决整批。
- 同一 generation 对同一 process instance 最多产生一次 authoritative absence。

## 6. 数据模型

### 6.1 Audit context

```swift
struct WindowAuditContext: Equatable, Sendable {
    let generation: UInt64
    let processInstance: ProcessInstanceID
    let sessionEpoch: UInt64
    let environmentEpoch: UInt64
    let topologyEpoch: UInt64
    let membershipEpoch: UInt64
    let targetMutationRevisions: [WindowID: UInt64]
    let appPresentationRevision: UInt64
}
```

`ProcessInstanceID` 使用 `proc_pidinfo(PROC_PIDTBSDINFO)` 返回的进程启动秒/微秒与 PID 组合。读取失败时本轮不构造 batch，也不改变 registry；重试通过单一 audit scheduler debounce/coalesce，不能递归立即启动。

### 6.2 Authority

```swift
enum AuditAuthority: Equatable, Sendable {
    case authoritative
    case positiveOnly(PositiveOnlyReason)
}

enum PositiveOnlyReason: Equatable, Sendable {
    case sessionInactive
    case sessionStateUnavailable
    case axFailure(Int32)
    case structurallyInvalidAXResult
    case unresolvedAXElement
    case staleGeneration
}
```

`PositiveOnlyReason` 用于测试和聚合日志，不进入用户可见 UI。

### 6.3 Evidence batch

```swift
struct WindowEvidenceBatch: Sendable {
    let pid: ProcessID
    let context: WindowAuditContext
    let authority: AuditAuthority
    let elementDispositions: [AXElementDisposition]
    let livenessEvidence: [WindowID: TargetLivenessEvidence]
    let presentationEvidence: [WindowID: PresentationEvidence]
}
```

一份 batch 只描述一个 process instance。跨 App 全量审计在 `WindowStore` 中拆成 per-process-instance batches，避免一个异常 App 否决其他 App 的正向结果。`elementDispositions` 是 semantic observations 的唯一事实源；reducer 只从其中的 `.observed` 派生 observed identity 集合，不另存一份可能失配的数组。Batch 使用校验构造器，并禁止公开 memberwise initializer。

每个 `kAXWindowsAttribute` 元素必须得到且只得到一种 disposition：

```swift
enum AXElementDisposition: Sendable {
    case observed(SemanticWindowObservation)
    case deliberatelySuppressed(SuppressedWindowObservation)
    case definitivelyNonSwitchable(NonSwitchableReason)
    case unresolved(UnresolvedAXReason)
}

enum TargetLivenessEvidence: Equatable, Sendable {
    case aliveByAXHandle
    case deadByAXHandle
    case unknown
}
```

已知非窗口 role、明确辅助 subrole、已建立 owner relationship 的 sheet/dialog 可归入 deliberate/non-switchable。潜在 `AXStandardWindow` 读不到 role、WindowID 或关键身份属性时必须归入 unresolved，不能静默 drop。普通/模态 `AXDialog` 无 owner 或 owner 模糊时沿用现有语义作为独立 target；只有语义上必须依赖 owner 才能 canonicalize 的 sheet 在 owner 读取失败时才归入 unresolved。

### 6.4 Target state

```swift
struct CanonicalTarget: Equatable, Sendable {
    let identity: TargetIdentity
    var semantic: SemanticWindowState
    var presentation: PresentationEvidenceState
    var lifecycle: TargetLifecycle
    var lastPositiveGeneration: UInt64
    var consecutiveAuthoritativeAbsences: Int
}

enum TargetLifecycle: Equatable, Sendable {
    case active
    case suspect
}
```

`TargetIdentity` 包含 `ProcessInstanceID` 与 WindowID；`SemanticWindowState` 保存 App 名、bundle ID、标题和搜索别名；`PresentationEvidenceState` 保存最小化、App hidden、on-screen、可选的 `TargetSpaceMembership`、全屏及其来源 generation/session/topology epoch。AX handle 继续由 `WindowStore` 的 handle map 持有，不进入 `NapoleonCore` 值类型。

现有 `WindowInfo` 调整为 registry/projection 的输出 DTO，不再充当 identity、lifecycle 和 presentation evidence 的混合存储。

`suspect` 取代现有 quarantine。第一次强缺失后 target 仍参与 switcher projection，并保留 handle 与 MRU；第二次不同 generation 的强缺失才最终删除。这样一轮误判不会再次造成“只剩一个 App”。任意新的 semantic positive 或 `.aliveByAXHandle` 都立即恢复为 `active` 并清零 absence；surface-only evidence 不能恢复 lifecycle。

不增加按时间自动删除。时间经过本身不是窗口不存在的证据。

## 7. Authority 判定

### 7.1 登录会话

增加只读 `SessionValidityProvider`，基于当前 console session 信息判断：

- 登录完成；
- 当前用户位于 console；
- 屏幕未锁定。

无法取得任一必要字段时返回 unknown，整轮结果只能 `positiveOnly(.sessionStateUnavailable)`。

`WindowStore` 监听：

- `NSWorkspace.sessionDidResignActiveNotification`；
- `NSWorkspace.sessionDidBecomeActiveNotification`；
- `NSWorkspace.screensDidSleepNotification`；
- `NSWorkspace.screensDidWakeNotification`。

resign/sleep 时递增 `sessionEpoch` 并禁止负向落地；active/wake 时再次递增 epoch、清除陈旧 projection context，并立即安排一次 audit。事件只负责失效和刷新，最终 authority 仍由提交时的实时 session 状态决定。

### 7.2 AX 结构完整性

以下结果不能标为 authoritative：

- `kAXWindowsAttribute` 调用失败；
- 返回值不是 AX element 数组；
- 非空数组包含 role 为 `AXApplication` 等明显不是窗口的伪元素；
- 任一 element 的 disposition 为 unresolved；
- 任一潜在可切换窗口的 role、subrole、WindowID 或关键身份字段无法确定；以及语义上必须依赖 owner 才能 canonicalize 的 sheet 无法读取 owner。

合法的空 AX windows 数组仍可 authoritative：没有窗口的 App 是正常情况。判据是“结构是否为合法窗口列表”，不是“结果是否为空”。

`WindowEnumerator.windowInfo(...) == nil` 不再足以表达所有排除原因。枚举器必须返回有类型的 disposition，使 reducer 能区分“确认不应成为 target”和“本轮无法判断”。单个 unresolved element 只把该 PID 降为 positive-only，不影响其他 PID。

### 7.3 弱来源完整性

Window Server 与 SCK 不进入 lifecycle 判定：它们可能保留已关闭窗口的 backing surface，只能更新 on-screen、layer、Space 与缩略图等 presentation evidence。

对 semantic audit 未观察到的已知 target：

- `.aliveByAXHandle`：恢复/保持 active，清零 absence；
- `.deadByAXHandle`：本 generation 产生一次强 absence；
- `.unknown`：保持现有 lifecycle 和 absence，不恢复，也不增加 absence。

弱来源失败不阻止 semantic positives 落地，但不能独立产生或抵消 absence。若 target 没有可探测 AX handle，它不能通过 audit absence 自动删除，只能等待精确 destroy、process termination 或后续重新取得 handle；这是避免 ghost 与真实窗口误删之间的明确安全取舍。

### 7.4 进程实例

每轮枚举及 App launch 时读取并缓存 `ProcessInstanceID`；termination notification 使用对应 `NSRunningApplication` 在存活期缓存的 token，避免进程退出后无法再读取。Registry、handle map、suppression map 和 MRU 内部均以 `TargetIdentity(ProcessInstanceID, WindowID)` 关联，避免 PID/WindowID 同时复用时继承旧状态。拿不到精确 token 的 termination 事件不得按 PID 删除另一个已确认的新实例。

实时 process state 使用三态，而不是把“查不到 token”直接等同于进程结束：

```swift
enum CurrentProcessState: Equatable, Sendable {
    case running(ProcessInstanceID)
    case notRunning
    case unknown
}
```

每轮 health audit 除了枚举 running Apps，也遍历 registry 中仍有 targets 的 process instances 并查询该状态，以覆盖 termination notification 漏送。提交 batch 前，`WindowStore` 同样重新查询：

- `.running(currentToken)`：精确终止 registry 中同 PID、不同 token 的旧实例；只有 current token 与 batch token 相同才允许提交，不同则整批拒绝，绝不能让迟到的旧 batch 覆盖新实例；
- `.notRunning`：精确终止 registry 中该 PID 的现存 process instances，并拒绝任何迟到 batch；
- `.unknown`：保留全部现有状态，拒绝 batch，并安排合并后的延迟重试。

`.notRunning` 必须来自能区分“PID 不存在”和“查询失败/权限问题”的实时结果；后者只能是 `.unknown`。提交时的 state 查询与 reconciliation 在同一个 `MainActor` 临界段内完成，中间不得 `await`；任何 launch/termination handler 先更新同一 actor 上的 per-PID lifecycle revision。这样漏送 termination 最终可以收敛，查询异常或已进入 registry 的 PID 复用也不会误删 target。

提交时确认 current token 已变化后：

1. 旧实例的 targets、handles 和 suppression records 立即终止；
2. 新实例的 semantic windows 作为新 targets 注册；
3. 新 targets 追加到 MRU 尾部，不能继承旧实例排名。

### 7.5 增量事件 revision

`WindowStore` 为每个 target 保存 `mutationRevision`。title、minimize 和精确 focus 等 target 事件只递增对应 target；App hidden 使用独立的 per-process-instance `appPresentationRevision`；create/destroy 同时递增 membership epoch。Space 字段由 topology epoch 保护，不复用 mutation revision。

若 batch 返回时 revision 已变化：

- 新发现且 identity 精确匹配 current process instance 的 semantic target 仍可注册；
- 对 revision 已变化的已知 target，不覆盖其 title/minimize 等 mutable fields，也不应用该 target 的旧 `.deadByAXHandle`；
- App presentation revision 已变化时，不覆盖 hidden；
- 其他 target 的 semantic、presentation 和 liveness 结果照常提交，整批 authority 不降级。

Focus 事件只更新 MRU；它递增对应 target revision，是为了阻止同一时段采集的旧 liveness 删除刚刚成功聚焦的 target。持续活跃的窗口最多保护自身，不会让同 App 内静默 ghost 失去收敛机会。revision 冲突需要刷新时只向单一 scheduler 提交 coalesced request，不允许立即递归形成 audit storm。

## 8. Registry reducer

`CanonicalWindowRegistry` 提供单一批次入口：

```swift
mutating func apply(_ batch: WindowEvidenceBatch)
```

处理顺序：

1. 拒绝同一 process instance 的重复或倒退 generation；
2. 以提交时的 `CurrentProcessState` 先做进程级 reconciliation：`.running` 清理同 PID 的旧 token 后仅接受 token 匹配的 batch，`.notRunning` 清理该 PID 的现存实例并拒绝 batch，`.unknown` 保留状态并拒绝 batch；
3. membership epoch 不匹配时拒绝本 PID 整份 batch 并请求新 audit；
4. 从 `elementDispositions.observed` 唯一派生并应用 semantic positives；
5. per-target/app revision 不匹配时，只跳过对应 target/字段的旧值及该 target 的旧 dead liveness，不改变其余 batch authority；
6. 仅在 session/environment/topology epoch 仍匹配时应用 presentation evidence；
7. Window Server/SCK evidence 只更新 presentation，不触碰 lifecycle/absence；
8. 若 authority 为 `positiveOnly`，立即结束；
9. 对本 PID 未被 semantic observation 命中的 targets：
   - `.aliveByAXHandle`：保持或恢复 active，清零 absence；
   - `.unknown`：保持当前 lifecycle 与 absence；
   - `.deadByAXHandle` 第一次出现：标记 suspect，但继续参与 projection，保留 MRU 和 handle；
   - `.deadByAXHandle` 在第二个不同 generation 再次出现：删除 target、handle 和 MRU 项。

显式 destroy 和 process termination 不通过 batch absence 计数，继续使用立即删除入口。

## 9. WindowStore orchestration

`WindowStore` 继续拥有实时观察者和系统查询，但不再直接拼装 lifecycle 判断：

1. audit 开始时对 running Apps 和 registry 中遗留 process instances 做三态 process reconciliation，再为可确认 running 的实例生成 context；
2. AX 枚举对每个 element 生成 typed disposition，不允许无原因 drop；
3. AX、SCK、Window Server、Space membership 和 AX handle liveness 并行采集；
4. 对每个 process instance 计算 authority 和 evidence batch；token 读取失败时记录 outcome，但不构造 batch；
5. 回到 `MainActor` 后在无 `await` 临界段内重新查询 `CurrentProcessState` 并按 process instance 原子提交；membership epoch 已变化的 batch 整份拒绝，session/environment 已变化的 batch 只保留 semantic positives，target/app revision 冲突只屏蔽对应旧字段和旧 liveness；
6. 同步 registry 返回的 target removals 到 handle/suppression maps；
7. 基于最新可靠 environment/topology facts 创建 projection context；
8. 修复前台精确焦点并更新 MRU。

当 audit 飞行期间发生 session/environment 变化，结果中的 semantic positives 仍可按 process instance + WindowID 接受，但 presentation evidence 与 negatives 必须降级。membership 变化意味着同一进程实例的窗口集合已改变，对应 batch 必须整份拒绝并请求 coalesced audit。target/app revision 变化只保护发生冲突的字段或 target liveness，不能饿死同 App 的其余 authoritative results。

## 10. Projection

新增纯值 `WindowProjection`：

```swift
struct WindowProjectionContext: Equatable, Sendable {
    let scope: ScopeOptions
    let mode: SwitchMode
    let spaceEvidence: SpaceEvidence
}

enum SpaceEvidence: Equatable, Sendable {
    case reliable(
        currentSpaceIDs: Set<Int>,
        fullscreenSpaceIDs: Set<Int>,
        desktopEscapeAnchor: SpaceAnchor?,
        topologyEpoch: UInt64
    )
    case unavailable
}
```

`topologyEpoch` 由规范化后的 CGS Space topology snapshot 驱动：只有 display/Space/fullscreen 关系实际变化时递增。`currentSpaceIDs`、`fullscreenSpaceIDs`、escape anchor 与所有 per-target membership 必须来自同一次 topology generation；混合 generation 的结果整体视为 `.unavailable`。

每个 `PresentationEvidenceState` 同时保存：

```swift
struct TargetSpaceMembership: Equatable, Sendable {
    let spaceIDs: Set<Int>
    let sessionEpoch: UInt64
    let topologyEpoch: UInt64
}
```

规则：

- `reliable`：只使用 session/topology epoch 同时匹配的 per-target membership，按当前 Space、全屏逃生和用户 scope 精确过滤；
- `unavailable`：不执行基于 Space 的排除，仍应用隐藏和最小化设置；
- 某一 target 的 membership 缺失或 epoch 过期时，只对该 target fail-open，不能因为其他 target 信息完整而误删它；
- 不持久化 `fullscreenEscapeWindowIDs` 作为下一轮的权威过滤条件；
- 若需要保留上一个桌面作为全屏逃生锚点，该锚点必须带 `sessionEpoch` 和 topology generation，二者不匹配即失效并 fail-open。

Switcher trigger 只读取 registry snapshot、MRU 和 projection context，不发起系统调用。

## 11. MRU 与 lifecycle

- `active` 和 `suspect` targets 都参与 projection 并保留在 MRUTracker 中；一次强缺失不会改变用户可见列表。
- positive observation 恢复 suspect target 时沿用原 MRU 位置。
- target 最终删除或进程终止时才移除 MRU 项。
- process instance 或 WindowID 被复用时，旧 identity 立即终止，新 identity 作为未聚焦窗口追加到 MRU 尾部。

本版本不增加 target tombstone TTL。两次来自 `.deadByAXHandle` 的不同 generation 提供确定性回收，TTL 会引入无法证明正确的时间启发式。若 suspect ghost 被用户选中，当前 `WindowFocuser` 可能返回失败；它最多保留到下一次强 liveness audit，设计不把一次模糊 focus failure 当作立即删除依据。

## 12. 可观测性

每轮 audit 只记录一条聚合日志，不记录窗口标题：

- generation、sessionEpoch、environmentEpoch、topologyEpoch；
- authoritative/positiveOnly 及 reason；
- AX element disposition 的 observed/suppressed/nonSwitchable/unresolved 数量；
- liveness 的 alive/dead/unknown 数量；
- observed、active、suspect、removed 数量；
- 被 epoch 降级的 PID 数量；
- projection 的 Space evidence 是否可靠。

Diagnostics `state.json` 增加上述聚合状态和每个 App 的 active/suspect 计数，避免下次只能从 switcher 最终数量反推 registry 内部状态。

## 13. 拒绝的方案

### 13.1 窗口太少时强制刷新

无法定义可靠阈值；用户可能真的只有一扇窗口。它只能掩盖错误状态，不能阻止下一次错误删除。

### 13.2 自动重启 WindowStore 或 Napoleon

会丢 MRU、制造 TCC/observer 生命周期问题，也无法解释根因。

### 13.3 每次 switcher 呼出重新枚举

AX 是同步 IPC，目标 App 无响应时会直接污染热路径延迟。该方案也无法解决来源 authority。

### 13.4 完全事件驱动、取消审计

AX 和 NSWorkspace notifications 会漏；睡眠、Space 切换和 App 异常退出后无法保证最终收敛。

### 13.5 让 Window Server/SCK 创建所有 targets

会重新引入 native background tabs、辅助 surfaces、无法精确聚焦的 handleless cards 和 ghost windows。

## 14. 测试设计

### 14.1 Registry reducer

1. 重复 100 次 `positiveOnly` 空审计不隐藏、不删除、不改变 MRU。
2. 非法 AX role 数组生成 `structurallyInvalidAXResult`；单个潜在窗口解析失败生成 `unresolvedAXElement`。
3. 两个不同 generation 的 `.deadByAXHandle` 依次 suspect、removed；suspect 仍参与 projection。
4. 同一 generation 重复提交不能累计两次 absence。
5. suspect target 被 semantic positive 或 `.aliveByAXHandle` 恢复，MRU 排名保持。
6. 进程终止和精确 destroy 立即删除。
7. PID、process instance 或 WindowID 被复用时不错误复活旧 target 或继承旧 MRU。
8. 单个 PID 的无效结果不影响其他 PID 的 authoritative batch。
9. Window Server/SCK surface 不能恢复 suspect、不能清零 absence。
10. `.unknown` liveness 重复出现既不恢复也不累计 absence。
11. `elementDispositions` 无第二份 semantic array；校验构造器拒绝重复 identity 和无 disposition element。

### 14.2 Audit orchestration

1. audit 飞行期间 sessionEpoch 改变：semantic positives 落地，presentation 与 negatives 丢弃。
2. membershipEpoch 改变：对应 PID 整份 batch 拒绝，其他 PID 正常提交。
3. target mutation revision 改变：旧 batch 不覆盖该 target 的 title/minimize，也不应用其旧 dead liveness；其他 target 仍可 authoritative 收敛。
4. 锁屏和 session unknown 时不能产生 absence。
5. 解锁/唤醒触发一次立即 audit，不重复启动并发 audit。
6. presentation snapshot 失败时 positives 仍落地，已知 targets 保持。
7. 合法空窗口 App 可以 authoritative；非空伪 `AXApplication` 数组不可以。
8. 一个 App 返回两扇 AX 窗口，其中一扇 WindowID/role 解析失败时，本 PID 整批 positive-only，已知窗口连续两轮仍不进入 suspect。
9. audit capture 与 commit 之间发生 title/minimize/focus 事件时，增量事件值胜出。
10. 旧实例 A 的 batch 延迟返回时 PID 已由实例 B 复用：A batch 整批拒绝，B target 与 MRU 不变。
11. process token 读取失败时不创建 provisional target、不更新或删除既有 target，重试被 debounce/coalesce。
12. 活跃 App 持续产生 title/focus 事件时，只保护对应 target；同 App 内无事件的 dead ghost 仍能连续两轮收敛，且不形成 audit storm。
13. termination notification 漏送且 PID 未复用：health audit 得到 `.notRunning` 后仍清理旧 targets、handles 与 MRU；查询失败得到 `.unknown` 时不得清理。

### 14.3 Projection

1. reliable Space evidence 精确过滤当前 Space。
2. unavailable Space evidence fail-open，不能把多窗口压成一扇。
3. 桌面 A、桌面 B 与全屏 F 并存时，per-target membership 只投影 F+A，排除 B。
4. 单个 target membership 缺失或 epoch 过期时，该 target 单独 fail-open。
5. 上一 session/topology 的全屏逃生锚点失效。
6. projection 重复调用是纯读且幂等。
7. projection 不改变 registry、MRU、handle 或 evidence。

### 14.4 回归

- attached sheet owner canonicalization；
- native tab suppression；
- non-standard layer filtering；
- surface-triggered、AX-validated recovery；
- current Space、隐藏、最小化和全屏 escape；
- exact focus 与 MRU；
- ghost-window 经两个不同 generation 的 `.deadByAXHandle` 清理。

## 15. 真实运行验收

自动化验证后必须使用项目既有 `./script/build_and_run.sh --verify` 替换旧实例，再完成：

1. 普通桌面同时打开至少 5 个 App，验证 Cmd+Tab 与 Cmd+`；
2. 锁屏至少 30 秒后解锁，列表和 MRU 不丢失；
3. 睡眠/唤醒至少 3 个循环；
4. 普通 Space 与全屏 Space 往返，失败时只能多显示、不能只剩全屏 App；
5. 在过渡过程中真正关闭窗口和退出 App，确认 ghost target 最终清理；
6. 保持新进程运行至少 24 小时并经历一次自然锁屏/唤醒，再复核列表；
7. 制造一次 AX 单窗口解析失败，确认该 App 的已知 targets 不进入 suspect；
8. 检查 diagnostics aggregate，确认没有 unresolved/unknown batch 产生 authoritative absence，也没有 surface-only evidence 恢复 lifecycle。

自动化测试、build 成功或一次短时 runtime 验证都不能替代第 6 项长期 gate。

## 16. 迁移与改动边界

Registry 是进程内状态，不需要持久化数据迁移。实施按以下边界进行：

- `NapoleonCore`：evidence batch、authority、registry reducer、projection 与基于 `TargetIdentity` 的 MRU 纯逻辑；
- `Napoleon`：session validity、系统结果到 evidence 的适配、observer 生命周期和 diagnostics；
- Tests：纯 reducer、orchestration、projection 和既有回归测试。

不修改 Switcher UI、ThumbnailService、WindowFocuser、设置模型或发布脚本。若实现过程中必须改变这些边界，应停止并重新审阅设计。

## 17. 验收标准

- 任意数量的非 authoritative 审计都不能隐藏或删除 canonical target。
- 第一次强 absence 只能标记 suspect 且继续展示；真正关闭窗口可通过显式事件或两次独立 `.deadByAXHandle` 清理。
- 锁屏、睡眠、唤醒和 Space 查询失败不破坏 MRU。
- 未知 Space 状态下 projection fail-open。
- 单个 AX element unresolved 会把对应 PID 降为 positive-only。
- Window Server/SCK surface 不能恢复 lifecycle。
- 增量事件不会被飞行中的旧 audit 覆盖。
- 迟到的旧 process-instance batch 不能终止或覆盖 PID 复用后的当前实例。
- process token 不可用时不创建 provisional identity，也不改变 registry。
- termination notification 漏送时，实时 `.notRunning` health reconciliation 仍能清理旧 process instance；`.unknown` 不产生删除。
- process instance 与 Space membership 均有可验证 epoch。
- switcher 呼出热路径不增加系统查询。
- 现有 sheet、native tab、auxiliary surface 和 ghost-window 回归测试继续通过。
- 完整测试、构建替换、短时 runtime 与 24 小时 dogfood gate 分开留证。
