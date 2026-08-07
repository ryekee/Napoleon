# Napoleon — 用户诊断日志设计

> 日期：2026-08-07
> 状态：待用户审阅
> 原则：用户主动、默认最小披露、本地保存、稳态性能开销低于 1%

## 1. 目标

在「设置 › About」增加诊断入口。用户选择问题类型、主动生成诊断包后，Napoleon 调用 macOS 邮件分享服务，将单个 ZIP 作为附件交给邮件客户端，收件人为 `hi@ryek.ee`。

Napoleon 不建设服务端、不接入第三方遥测 SDK、不自动上传，也不在后台持续采样。

## 2. 问题类型与披露边界

三个选项不是逐级累加，而是“隐私友好的基础信息 + 当前问题所必需的附加信息”：

| 设置项 | 包含 | 明确不包含 |
|---|---|---|
| General issue（默认） | 最近 2 小时 Napoleon Unified Logging、当前 App/窗口清单、权限、版本和相关设置 | 搜索内容、窗口标题、文件路径、缩略图 |
| Search issue | General issue + 用户启用后产生的搜索内容、匹配窗口标题 | 文件路径、缩略图 |
| Thumbnail issue | General issue + 当前缓存中已有的窗口缩略图 | 搜索内容、窗口标题、文件路径、新截图 |

Napoleon 当前不读取真实文件路径。本功能不新增 AX 文档路径查询，避免扩大隐私面和窗口枚举成本。窗口标题本身若包含文件名，只会在 Search issue 中出现。

## 3. 设置页交互

About 页在更新区域下方新增「Diagnostics」区域：

1. 问题类型 Picker，默认 `General issue`。
2. 随选择实时变化的隐私说明，清楚列出“会包含 / 不会包含”。
3. `Prepare Email…` 按钮；生成期间显示进度并禁止重复点击。
4. 成功后打开邮件撰写窗口，由用户最终确认发送。macOS 不提供“给任意第三方默认邮件客户端添加附件”的统一 API，因此首选系统 Email 分享服务；不能用时走下一条降级路径。
5. 失败时在原位置显示可操作错误；若系统没有可用的邮件分享服务，则在 Finder 中显示 ZIP，并打开写给 `hi@ryek.ee` 的 `mailto:` 草稿，提示用户手动添加附件。

选择 `Search issue` 即开始本次进程内的临时诊断会话，界面显示正在记录。诊断包成功交给邮件分享服务、切回其他问题类型或重新启动 Napoleon 后停止记录并回到默认模式，避免用户忘记关闭敏感采集。邮件客户端是否最终发出邮件不在 Napoleon 的可观测范围内。

## 4. 基础诊断内容

### 4.1 Apple Unified Logging

复用项目现有 `Logger(subsystem: "com.napoleon.Napoleon", category: ...)`：

- 权限和 event tap 状态变化；
- Switcher 触发、窗口数量、模式和聚焦结果；
- AX / Window Server / ScreenCaptureKit 失败及错误码；
- 窗口漂移修正、进程退出清理；
- 更新检查、登录项等错误。

只在用户生成诊断包时，按 subsystem 导出最近 2 小时的 compact 文本；不启用 private-data 展开，因此现有 `.private` 窗口标题保持 `<private>`。使用 compact 格式，避免系统 NDJSON 自带的二进制路径字段进入基础日志。

Apple Unified Logging 由 macOS 管理，Napoleon 能保证诊断包只导出最近 2 小时，不能保证 macOS 底层日志库恰好在 2 小时时物理删除原记录。

### 4.2 当前状态快照

生成诊断包时才读取当前内存状态，写入结构化 JSON：

- Napoleon 版本、build、macOS 版本、CPU 架构、界面语言；
- Accessibility / Screen Recording 权限；
- 快捷键绑定和 Switcher 相关设置；
- 每个 App 的名称、Bundle ID、PID、窗口数量、窗口 ID；
- 不含窗口标题、搜索内容和文件路径。

仅在现有 Switcher 触发日志上补充已经计算出的准备耗时，不增加查询、轮询或高频逐窗日志。

## 5. Search issue

Unified Logging 的 private 字段无法可靠导出原文，因此搜索诊断使用独立的本地 JSONL：

- 只在用户明确选择 `Search issue` 后记录；
- 每次搜索条件变化记录时间、搜索内容、匹配窗口 ID、App/Bundle ID 和匹配窗口标题；
- 不读取 AX 文件路径；
- 文件只保留最近 2 小时事件；诊断包交付或退出该模式时停止写入，下次启动直接删除上一进程遗留的搜索文件；
- 写入放在低优先级串行队列，不阻塞 Switcher 主线程。

搜索诊断关闭时没有文件写入、timer 或字符串构造。

## 6. Thumbnail issue

生成诊断包时，以当前 `WindowStore` 的 window ID 读取 `ThumbnailService.cached(_:)`：

- 只导出缓存命中项并编码为 PNG；
- 绝不调用 `capture`、`SCShareableContent.current` 或 `SCScreenshotManager`；
- 不申请新权限、不刷新图片；
- 缩略图是最近一次缓存状态，可能略旧；
- 缓存未命中或已淘汰的 window ID 记录进 manifest，便于区分“没有缓存”和“导出失败”。

## 7. 本地文件与邮件

诊断工作目录位于 Napoleon 自己的 Application Support 目录。每个 ZIP 包含：

- `manifest.json`：问题类型、生成时间、包含/排除项、缓存缺失项；
- `napoleon.log`：最近 2 小时 compact Unified Logging；
- `state.json`：基础状态快照；
- `search.jsonl`：仅 Search issue；
- `thumbnails/*.png`：仅 Thumbnail issue。

使用系统自带 `ditto` 在用户点击后创建单个 ZIP，不增加依赖。通过 `NSSharingService.composeEmail` 设置收件人、主题和附件；邮件客户端负责真正发送，Napoleon 不读取邮件账号。

诊断工作目录和旧 ZIP 在启动及下次导出时删除超过 2 小时的内容。邮件撰写窗口可能异步读取附件，因此新 ZIP 不在打开邮件后立即删除，而是留到上述清理时机。

## 8. 性能约束

默认模式稳态只复用已有 Unified Logging：

- 不新增 timer、轮询、数据库、ScreenCaptureKit / AX / Window Server 查询；
- 不在 event tap 回调中增加文件 I/O；
- 完整状态快照、日志导出、PNG 编码和 ZIP 压缩只在用户点击时执行；
- 搜索 JSONL 写入只在临时 Search issue 模式启用，并脱离主线程。

验收时比较改动前后空闲 CPU time 与相同次数的重复 Switcher 触发 CPU time；三种模式在相同负载下的额外 CPU time 均须低于 1%，默认模式空闲 CPU 不得出现可测增量，且触发耗时无统计显著回归。若不满足，优先撤销新增热路径日志，而不是放宽指标。

## 9. 错误处理

- Unified Logging 导出失败：仍生成其余文件，manifest 标记错误。
- 单张 PNG 编码失败：跳过该图并记录 window ID，不中止整个包。
- ZIP 失败：不打开邮件，保留工作目录并显示错误。
- 邮件分享服务不可用：保留 ZIP、Finder 定位、打开 `mailto:` 草稿。
- 任一失败都不得删除尚未成功生成的可恢复诊断内容。

## 10. 测试与真实验收

最小回归测试覆盖：

1. 三种问题类型的包含/排除清单正确，默认不泄露标题、搜索和缩略图。
2. Search issue 只在启用后记录，2 小时外事件不会进入诊断包。
3. Thumbnail issue 只导出缓存命中项，缓存缺失项进入 manifest，测试替身若收到 capture 请求则失败。
4. 日志或单张图片失败时仍能生成可解释的部分诊断包。

真实验收按项目既定流程：测试后构建，kill 当前 Napoleon，以新 build 替换 `/Applications/Napoleon.app` 并启动；分别生成三种诊断包，检查 ZIP 内容、隐私边界、邮件收件人和附件；最后确认运行的是新 build。

## 11. 不在本次范围

- 自动发送、后台上传、服务端接收和用户身份追踪；
- 全桌面、其他 Space 或新抓取的截图；
- 文件路径、键盘原始事件流和窗口正文；
- 自定义通用日志框架、数据库或第三方遥测 SDK。
