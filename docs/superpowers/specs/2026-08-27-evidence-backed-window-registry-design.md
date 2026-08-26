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
3. 正向证据始终可以创建或更新 target；
4. 只有 authoritative batch 才能产生缺失、quarantine 和删除；
5. Space 与筛选状态通过无状态 projection 计算，不参与 target 身份生命周期。

这不是完整 event sourcing：不保存无限事件日志，也不引入持久化数据库。只在内存中保存做出当前判断所需的最后有效证据和计数。

## 3. 目标

1. 锁屏、睡眠、唤醒和长时间运行不能因不可信负向结果丢失 canonical targets。
2. 真正关闭窗口和终止 App 仍能及时收敛，不重新引入 ghost window。
3. AX 仍是创建可精确切换 target 的语义来源；弱来源不能独立创建 target。
4. MRU 不因暂时不确定而丢失或重排。
5. 过期或部分审计不能产生任何负向副作用。
6. Switcher 呼出仍为纯内存读取，不增加 AX、SCK、Window Server 或 CGS 查询。
7. Space 证据失败时宁可暂时显示更多窗口，不得把列表收窄成一扇。

## 4. 非目标

- 不把 Window Server 或 ScreenCaptureKit 提升为独立 target creation authority。
- 不在 switcher 呼出时重新枚举系统窗口。
- 不以窗口数量阈值、自动重启或定时清空 registry 作为恢复机制。
- 不保存跨进程启动的 registry；Napoleon 重启后仍从空状态建立新基线。
- 不修改窗口聚焦后端、缩略图采集、搜索或 Switcher UI。
- 不增加 App-specific 规则。

## 5. 核心不变量

### 5.1 身份不变量

- Canonical identity 使用 `(PID, WindowID)`；WindowID 被其他 PID 复用时视为新身份。
- 只有有效的 AX semantic observation，或现有的强 surface recovery 路径取得精确 AX handle 后，才能创建 target。
- Window Server、SCK 和 CGS 只能补充已知 target 的 evidence。

### 5.2 负向证据不变量

- 查询失败、结构异常、会话不活跃、代次过期和部分结果都属于 `positiveOnly`。
- `positiveOnly` batch 可以新增、恢复和更新 target，但不能 quarantine、删除、降级当前 Space 或清除 MRU。
- 只有同一 PID 的 authoritative semantic audit 才能确认“本轮未观察到”。
- App 明确终止和精确 AX destroyed notification 是强负向事件，可立即删除对应 target。

### 5.3 投影不变量

- Registry 保存 target 和证据，不保存“本次 switcher 最终应显示什么”的结论。
- 当前 Space、全屏逃生、隐藏/最小化设置和用户 scope 在 projection 阶段组合。
- Projection context 不可靠时 fail-open；不使用陈旧的收窄集合继续过滤。
- Projection 是纯函数，不修改 registry、MRU 或 evidence。

### 5.4 批次不变量

- 每轮 audit 使用单调递增的 `generation`，并捕获 `sessionEpoch`、`environmentEpoch` 和 per-PID `membershipEpoch`。
- session/environment epoch 不匹配时，semantic positives 可降级落地，但 presentation evidence 和 negatives 必须丢弃。
- membership epoch 不匹配表示窗口集合已发生创建/销毁变化；对应 PID 的整份 batch 必须拒绝并重排 audit，不能接受过期 positives。
- 同一 generation 对同一 PID 最多产生一次 authoritative absence。

## 6. 数据模型

### 6.1 Audit context

```swift
struct WindowAuditContext: Equatable, Sendable {
    let generation: UInt64
    let sessionEpoch: UInt64
    let environmentEpoch: UInt64
    let membershipEpoch: UInt64
}
```

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
    case weakSnapshotUnavailable
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
    let semanticWindows: [SemanticWindowObservation]
    let existingSurfaces: [WindowID: ProcessID]?
    let presentationEvidence: [WindowID: PresentationEvidence]
}
```

一份 batch 只描述一个 PID。跨 App 全量审计在 `WindowStore` 中拆成 per-PID batches，避免一个异常 App 否决其他 App 的正向结果。

### 6.4 Target state

```swift
struct CanonicalTarget: Equatable, Sendable {
    let identity: WindowIdentity
    var semantic: SemanticWindowState
    var presentation: PresentationEvidenceState
    var lifecycle: TargetLifecycle
    var lastPositiveGeneration: UInt64
    var consecutiveAuthoritativeAbsences: Int
}

enum TargetLifecycle: Equatable, Sendable {
    case active
    case uncertain
}
```

`WindowIdentity` 只包含 PID 与 WindowID；`SemanticWindowState` 保存 App 名、bundle ID、标题和搜索别名；`PresentationEvidenceState` 保存最小化、App hidden、当前 Space、全屏及其来源 generation/session epoch。AX handle 继续由 `WindowStore` 的 handle map 持有，不进入 `NapoleonCore` 值类型。

现有 `WindowInfo` 调整为 registry/projection 的输出 DTO，不再充当 identity、lifecycle 和 presentation evidence 的混合存储。

`uncertain` 对应现有 quarantine：不参与 switcher projection，但 target、handle 映射和 MRU 排名继续保留。第二次独立 authoritative absence 才最终删除。任意新的 semantic positive evidence 都立即恢复为 `active` 并清零 absence。

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
- 必须读取的窗口身份字段因系统过渡态整体不可用。

合法的空 AX windows 数组仍可 authoritative：没有窗口的 App 是正常情况。判据是“结构是否为合法窗口列表”，不是“结果是否为空”。

### 7.3 弱来源完整性

Authoritative absence 还要求 Window Server/liveness 组合结果可用。弱来源失败时，semantic positives 仍可落地，但缺失 target 不能进入 absence 流程。

## 8. Registry reducer

`CanonicalWindowRegistry` 提供单一批次入口：

```swift
mutating func apply(_ batch: WindowEvidenceBatch)
```

处理顺序：

1. 拒绝同一 PID 的重复或倒退 generation；
2. membership epoch 不匹配时拒绝本 PID 整份 batch 并请求新 audit；
3. 应用全部 semantic positive observations；
4. 仅在 session/environment epoch 仍匹配时应用 presentation evidence；
5. 若 authority 为 `positiveOnly`，立即结束；
6. 对本 PID 未被 semantic observation 命中的 targets：
   - 弱来源确认同一 `(PID, WindowID)` 仍存在：保留 active，标记为非当前 Space，不增加 absence；
   - 弱来源同 PID 明确不存在：增加一次 authoritative absence；
   - 第一次 absence：进入 `uncertain`，保留 MRU 和 handle；
   - 第二次不同 generation 的 absence：删除 target、handle 和 MRU 项。

显式 destroy 和 process termination 不通过 batch absence 计数，继续使用立即删除入口。

## 9. WindowStore orchestration

`WindowStore` 继续拥有实时观察者和系统查询，但不再直接拼装 lifecycle 判断：

1. audit 开始时生成 context；
2. AX、SCK、Window Server、liveness 并行采集；
3. 对每个 PID 计算 authority 和 evidence batch；
4. 回到 `MainActor` 后按 PID 原子提交；membership epoch 已变化的 batch 整份拒绝，session/environment 已变化的 batch 只保留 semantic positives；
5. 同步 registry 返回的 target removals 到 handle/suppression maps；
6. 基于最新可靠环境事实创建 projection context；
7. 修复前台精确焦点并更新 MRU。

当 audit 飞行期间发生 session/environment 变化，结果中的 semantic positives 仍可按精确 identity 接受，但 presentation evidence 与 negatives 必须降级。membership 变化意味着同一 PID 的窗口集合已改变，对应 batch 必须整份拒绝并重排 audit，避免过期 positive 复活已经销毁或被复用的 WindowID。

## 10. Projection

新增纯值 `WindowProjection`：

```swift
struct WindowProjectionContext: Equatable, Sendable {
    let scope: ScopeOptions
    let mode: SwitchMode
    let spaceEvidence: SpaceEvidence
}

enum SpaceEvidence: Equatable, Sendable {
    case reliable(currentSpaceIDs: Set<Int>, fullscreenSpaceIDs: Set<Int>)
    case unavailable
}
```

规则：

- `reliable`：按当前 Space、全屏逃生和用户 scope 精确过滤；
- `unavailable`：不执行基于 Space 的排除，仍应用隐藏和最小化设置；
- 不持久化 `fullscreenEscapeWindowIDs` 作为下一轮的权威过滤条件；
- 若需要保留上一个桌面作为全屏逃生锚点，该锚点必须带 `sessionEpoch` 和 topology generation，二者不匹配即失效并 fail-open。

Switcher trigger 只读取 registry snapshot、MRU 和 projection context，不发起系统调用。

## 11. MRU 与 tombstone

- `active` 和 `uncertain` targets 都保留在 MRUTracker 中；projection 只显示 active。
- positive observation 恢复 uncertain target 时沿用原 MRU 位置。
- target 最终删除或进程终止时才移除 MRU 项。
- WindowID 被另一 PID 复用时，旧 identity 立即终止，新 identity 作为未聚焦窗口追加到 MRU 尾部。

本版本不增加 target tombstone TTL。现有两次 authoritative absence 已提供确定性回收，TTL 会引入无法证明正确的时间启发式。

## 12. 可观测性

每轮 audit 只记录一条聚合日志，不记录窗口标题：

- generation、sessionEpoch、environmentEpoch；
- authoritative/positiveOnly 及 reason；
- observed、active、uncertain、removed 数量；
- 被 epoch 降级的 PID 数量；
- projection 的 Space evidence 是否可靠。

Diagnostics `state.json` 增加上述聚合状态和每个 App 的 active/uncertain 计数，避免下次只能从 switcher 最终数量反推 registry 内部状态。

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
2. 非法 AX role 数组生成 `structurallyInvalidAXResult`。
3. 两个不同 generation 的 authoritative absence 依次 uncertain、removed。
4. 同一 generation 重复提交不能累计两次 absence。
5. uncertain target 被 positive observation 恢复，MRU 排名保持。
6. 进程终止和精确 destroy 立即删除。
7. WindowID 被另一 PID 复用时不错误复活旧 target。
8. 单个 PID 的无效结果不影响其他 PID 的 authoritative batch。

### 14.2 Audit orchestration

1. audit 飞行期间 sessionEpoch 改变：semantic positives 落地，presentation 与 negatives 丢弃。
2. membershipEpoch 改变：对应 PID 整份 batch 拒绝，其他 PID 正常提交。
3. 锁屏和 session unknown 时不能产生 absence。
4. 解锁/唤醒触发一次立即 audit，不重复启动并发 audit。
5. 弱快照失败时 positives 仍落地，已知 targets 保持。
6. 合法空窗口 App 可以 authoritative；非空伪 `AXApplication` 数组不可以。

### 14.3 Projection

1. reliable Space evidence 精确过滤当前 Space。
2. unavailable Space evidence fail-open，不能把多窗口压成一扇。
3. 上一 session/topology 的全屏逃生锚点失效。
4. projection 重复调用是纯读且幂等。
5. projection 不改变 registry、MRU、handle 或 evidence。

### 14.4 回归

- attached sheet owner canonicalization；
- native tab suppression；
- non-standard layer filtering；
- strong surface recovery；
- current Space、隐藏、最小化和全屏 escape；
- exact focus 与 MRU；
- ghost-window 两次 authoritative absence 清理。

## 15. 真实运行验收

自动化验证后必须使用项目既有 `./script/build_and_run.sh --verify` 替换旧实例，再完成：

1. 普通桌面同时打开至少 5 个 App，验证 Cmd+Tab 与 Cmd+`；
2. 锁屏至少 30 秒后解锁，列表和 MRU 不丢失；
3. 睡眠/唤醒至少 3 个循环；
4. 普通 Space 与全屏 Space 往返，失败时只能多显示、不能只剩全屏 App；
5. 在过渡过程中真正关闭窗口和退出 App，确认 ghost target 最终清理；
6. 保持新进程运行至少 24 小时并经历一次自然锁屏/唤醒，再复核列表；
7. 检查 diagnostics aggregate，确认没有无效 batch 产生 authoritative absence。

自动化测试、build 成功或一次短时 runtime 验证都不能替代第 6 项长期 gate。

## 16. 迁移与改动边界

Registry 是进程内状态，不需要持久化数据迁移。实施按以下边界进行：

- `NapoleonCore`：evidence batch、authority、registry reducer、projection 纯逻辑；
- `Napoleon`：session validity、系统结果到 evidence 的适配、observer 生命周期和 diagnostics；
- Tests：纯 reducer、orchestration、projection 和既有回归测试。

不修改 Switcher UI、ThumbnailService、WindowFocuser、设置模型或发布脚本。若实现过程中必须改变这些边界，应停止并重新审阅设计。

## 17. 验收标准

- 任意数量的非 authoritative 审计都不能隐藏或删除 canonical target。
- 真正关闭窗口仍可通过显式事件或两次独立 authoritative absence 清理。
- 锁屏、睡眠、唤醒和 Space 查询失败不破坏 MRU。
- 未知 Space 状态下 projection fail-open。
- switcher 呼出热路径不增加系统查询。
- 现有 sheet、native tab、auxiliary surface 和 ghost-window 回归测试继续通过。
- 完整测试、构建替换、短时 runtime 与 24 小时 dogfood gate 分开留证。
