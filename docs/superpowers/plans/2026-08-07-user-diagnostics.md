# 用户诊断日志 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 About 页提供用户主动触发、按问题类型最小披露的两小时诊断包，并通过 macOS 邮件服务把 ZIP 附件交给 `hi@ryek.ee`。

**Architecture:** 复用现有 Apple Unified Logging，仅在生成报告时导出最近两小时；搜索敏感内容使用显式启用的本地 JSONL，缩略图只读现有缓存。一个 `DiagnosticsService` 负责会话、报告与系统命令边界，About 页只负责选择、隐私说明及邮件分享。

**Tech Stack:** Swift 6、SwiftUI、AppKit、OSLog、Foundation `Process`、ImageIO、UniformTypeIdentifiers、Swift Testing、XcodeGen。

## Global Constraints

- 最低系统版本保持 macOS 14.0。
- 默认模式不新增 timer、轮询、数据库、网络请求或后台上传。
- 不新增 AX、Window Server、ScreenCaptureKit 查询；缩略图导出不得调用任何 capture API。
- General issue 不含窗口标题、搜索内容、文件路径和图片。
- Search issue 只增加搜索内容与匹配窗口标题，不读取文件路径。
- Thumbnail issue 只增加当前缓存命中的 PNG，不增加搜索内容或窗口标题。
- 所有内容只保存在本机；只有用户点击后才交给邮件客户端。
- 三种模式在相同负载下的额外 CPU time 均低于 1%。
- 不增加第三方依赖或自建日志框架。
- 完成后 kill 旧 Napoleon、替换 `/Applications/Napoleon.app`、启动新 build 并做真实 UI/runtime 验收。

---

## File Map

- Create: `Sources/Napoleon/Diagnostics/DiagnosticsService.swift` — 问题类型、搜索敏感日志、本地报告、缓存 PNG、系统日志与 ZIP。
- Create: `Tests/NapoleonTests/DiagnosticsServiceTests.swift` — 隐私边界、两小时保留、缓存命中和部分失败回归测试。
- Modify: `Sources/Napoleon/App/AppServices.swift` — 创建并注入进程唯一的诊断服务。
- Modify: `Sources/Napoleon/Windows/WindowStore.swift` — 提供不查询系统的只读热态给诊断报告。
- Modify: `Sources/Napoleon/Switcher/SwitcherController.swift` — 复用现有搜索结果记录临时诊断，并补充触发准备耗时。
- Modify: `Sources/Napoleon/Settings/SettingsView.swift` — 把诊断服务传给 About 页。
- Modify: `Sources/Napoleon/Settings/AboutView.swift` — Diagnostics UI、隐私声明、邮件分享与 fallback。
- Modify: `Resources/Localizable.xcstrings` — 英文、简中、繁中、日文文案。
- Regenerate, do not commit: `Napoleon.xcodeproj` — XcodeGen 生成物，仓库已忽略。

---

### Task 1: 隐私模型与两小时搜索日志

**Files:**
- Create: `Sources/Napoleon/Diagnostics/DiagnosticsService.swift`
- Create: `Tests/NapoleonTests/DiagnosticsServiceTests.swift`

**Interfaces:**
- Produces: `DiagnosticIssue`, `DiagnosticSearchEvent`, `SearchDiagnosticStore.begin()`, `append(_:)`, `events(since:) async throws`, `discard()`。
- Consumes: `WindowInfo` / `WindowID` from `NapoleonCore`。

- [ ] **Step 1: 记录改动前性能基线**

确认当前进程是功能改动前的 Napoleon；连续采样 30 秒，保存平均 `%CPU` 与 RSS：

```bash
pid=$(pgrep -x Napoleon | head -n 1)
test -n "$pid"
ps -p "$pid" -o command=
for _ in {1..30}; do ps -p "$pid" -o %cpu= -o rss=; sleep 1; done | tee /private/tmp/napoleon-diagnostics-baseline.txt
```

Expected: 30 行有效数据；记录采样 build 与 PID，供 Task 5 同负载比较。

- [ ] **Step 2: 写隐私与保留策略的失败测试**

在 `DiagnosticsServiceTests.swift` 使用临时目录，覆盖以下行为：

```swift
import Foundation
import NapoleonCore
import Testing
@testable import Napoleon

@Suite struct DiagnosticsServiceTests {
    @Test func generalIsTheDefaultAndIssueDataIsNotCumulative() {
        #expect(DiagnosticIssue.default == .general)
        #expect(DiagnosticIssue.general.includesSearch == false)
        #expect(DiagnosticIssue.general.includesThumbnails == false)
        #expect(DiagnosticIssue.search.includesSearch == true)
        #expect(DiagnosticIssue.search.includesThumbnails == false)
        #expect(DiagnosticIssue.thumbnail.includesSearch == false)
        #expect(DiagnosticIssue.thumbnail.includesThumbnails == true)
    }

    @Test func searchStoreKeepsOnlyTheLastTwoHours() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SearchDiagnosticStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 7_201) }
        )
        store.begin()
        store.append(.fixture(timestamp: Date(timeIntervalSince1970: 0), query: "old"))
        store.append(.fixture(timestamp: Date(timeIntervalSince1970: 7_201), query: "new"))

        let events = try await store.events(since: Date(timeIntervalSince1970: 1))
        #expect(events.map(\.query) == ["new"])
    }

    @Test func discardRemovesSensitiveSearchFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SearchDiagnosticStore(directory: directory, now: Date.init)
        store.begin()
        store.append(.fixture(timestamp: .now, query: "private"))
        store.discard()
        _ = try await store.events(since: .distantPast)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path) == false)
    }
}

private extension DiagnosticSearchEvent {
    static func fixture(timestamp: Date, query: String) -> Self {
        .init(
            timestamp: timestamp,
            query: query,
            results: [
                .init(
                    windowID: 42,
                    appName: "Finder",
                    bundleID: "com.apple.finder",
                    windowTitle: "Secret"
                )
            ]
        )
    }
}
```

测试不得使用真实桌面数据。

- [ ] **Step 3: 运行测试，确认因类型缺失而失败**

先生成工程，再运行唯一的新 suite：

```bash
xcodegen generate
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon \
  -destination 'platform=macOS' \
  -only-testing:NapoleonTests/DiagnosticsServiceTests test
```

Expected: FAIL，错误包含 `cannot find 'DiagnosticIssue' in scope` 或 `cannot find 'SearchDiagnosticStore' in scope`。

- [ ] **Step 4: 实现最小模型与串行文件存储**

在新文件定义：

```swift
enum DiagnosticIssue: String, CaseIterable, Identifiable, Codable {
    case general, search, thumbnail

    static let `default`: Self = .general
    var id: String { rawValue }
    var includesSearch: Bool { self == .search }
    var includesThumbnails: Bool { self == .thumbnail }
}

struct DiagnosticSearchEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let query: String
    let results: [Result]

    struct Result: Codable, Equatable, Sendable {
        let windowID: WindowID
        let appName: String
        let bundleID: String?
        let windowTitle: String
    }
}
```

`SearchDiagnosticStore.init(directory:now:)` 的 `now` 默认 `Date.init`，测试注入固定时间。store 使用一个 utility QoS 串行 `DispatchQueue` 隔离 `events`、文件和一个 `DispatchSourceTimer`。`begin()`、`append(_:)`、`discard()` 都同步把工作按调用顺序 enqueue 后立即返回；`events(since:) async throws` 是队列 barrier，返回前保证之前的工作已完成，并抛出队列中最近一次文件错误。这样 SwiftUI 的同步 Picker setter 不需要等待，也不会出现 begin/append/discard 乱序。

`begin()` 设置 `isActive = true`、创建目录并清空旧文件；`append(_:)` 在 inactive 时直接返回，在 active 时以当前最新事件时间减 7,200 秒为 cutoff，先移除旧事件，再原子重写 JSONL；随后只为“最早事件到期时间”安排一次 one-shot timer。timer 触发时按 `now()` 清理到期事件、重写文件，并为下一条最早事件重新安排；默认模式或空事件时没有 timer。`events(since:)` 在返回前再次按传入 cutoff 清理；inactive 时只返回空数组、不重新创建文件。`discard()` 设置 inactive、取消 timer、删除文件并清空内存。

文件中保留这一条明确的上限说明：

```swift
// ponytail: 搜索诊断由用户临时启用，事件量按低千级上限处理；只有现场数据证明更大时才改分段文件。
```

`events(since:)` 使用 checked continuation 等待串行队列；其余方法只 enqueue，不阻塞主线程。

- [ ] **Step 5: 运行定向测试并提交**

```bash
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon \
  -destination 'platform=macOS' \
  -only-testing:NapoleonTests/DiagnosticsServiceTests test
git add Sources/Napoleon/Diagnostics/DiagnosticsService.swift Tests/NapoleonTests/DiagnosticsServiceTests.swift
git commit -m "实现两小时搜索诊断存储" \
  -m "「问题或需求描述」搜索问题需要用户明确开启后保存敏感诊断，且只保留最近两小时。" \
  -m "「修复或实现思路」使用本地 JSONL 和串行队列，退出模式时删除，不影响默认热路径。"
```

Expected: 新 suite PASS；提交仅包含两个文件。

---

### Task 2: 生成隐私受控的诊断 ZIP

**Files:**
- Modify: `Sources/Napoleon/Diagnostics/DiagnosticsService.swift`
- Modify: `Tests/NapoleonTests/DiagnosticsServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `DiagnosticIssue`, `SearchDiagnosticStore`。
- Produces: `DiagnosticSnapshot`, `DiagnosticManifest`, `DiagnosticCommands.live`, `DiagnosticsService.selectIssue(_:)`, `recordSearch(query:results:)`, `prepareReportDirectory() async throws -> URL`, `prepareReport() async throws -> URL`, `reportWasHandedOff()`。

- [ ] **Step 1: 写报告隐私边界的失败测试**

增加确定性 snapshot：两扇同 App 窗口，标题分别为 `Secret A` / `Secret B`。注入 commands：日志导出写入固定文本，ZIP 测试替身只记录源目录而不调用系统工具。

测试文件定义以下 helper，不读取当前机器状态：

```swift
private func onePixelImage() -> CGImage {
    let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

private func snapshot() -> DiagnosticSnapshot {
    .init(
        appVersion: "0.2.0",
        appBuild: "1",
        macOSVersion: "26.0",
        architecture: "arm64",
        interfaceLanguage: "en",
        accessibilityTrusted: true,
        screenRecordingGranted: true,
        allWindowsHotkey: "⌘Tab",
        currentAppHotkey: "⌘`",
        includeOtherSpaces: false,
        includeMinimized: false,
        includeHiddenApps: false,
        pinyinSearchEnabled: true,
        groupWindowsByApplication: false,
        showDelayMs: 100,
        apps: [
            .init(
                name: "Finder",
                bundleID: "com.apple.finder",
                pid: 10,
                windowCount: 2,
                windowIDs: [42, 43]
            )
        ]
    )
}

private func manifest(at directory: URL) throws -> DiagnosticManifest {
    let data = try Data(contentsOf: directory.appending(path: "manifest.json"))
    return try JSONDecoder().decode(DiagnosticManifest.self, from: data)
}

private func makeService(
    issue: DiagnosticIssue,
    query: String? = nil,
    cachedIDs: Set<WindowID> = [],
    commands override: DiagnosticCommands? = nil
) async throws -> DiagnosticsService {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let commands = override ?? DiagnosticCommands(
        exportUnifiedLog: { url in try Data("fixed log".utf8).write(to: url) },
        encodePNG: DiagnosticCommands.live.encodePNG,
        zip: { _, zipURL in try Data("zip".utf8).write(to: zipURL) }
    )
    let service = DiagnosticsService(
        directory: directory,
        snapshot: snapshot,
        cachedThumbnail: { cachedIDs.contains($0) ? onePixelImage() : nil },
        commands: commands,
        now: { Date(timeIntervalSince1970: 10_000) }
    )
    service.selectIssue(issue)
    if let query {
        service.recordSearch(
            query: query,
            results: [
                WindowInfo(
                    id: 42,
                    pid: 10,
                    appName: "Finder",
                    appBundleID: "com.apple.finder",
                    title: "Secret A"
                )
            ]
        )
    }
    return service
}
```

测试必须断言：

```swift
@Test func generalReportExcludesSensitiveFilesAndTitles() async throws {
    let report = try await makeService(issue: .general).prepareReportDirectory()
    let state = try String(contentsOf: report.appending(path: "state.json"), encoding: .utf8)
    #expect(state.contains("Secret A") == false)
    #expect(FileManager.default.fileExists(atPath: report.appending(path: "search.jsonl").path) == false)
    #expect(FileManager.default.fileExists(atPath: report.appending(path: "thumbnails").path) == false)
}

@Test func searchReportAddsTitlesButNotThumbnails() async throws {
    let report = try await makeService(issue: .search, query: "f").prepareReportDirectory()
    #expect(try String(contentsOf: report.appending(path: "search.jsonl")).contains("Secret A"))
    #expect(FileManager.default.fileExists(atPath: report.appending(path: "thumbnails").path) == false)
}

@Test func thumbnailReportUsesOnlyCacheHits() async throws {
    let service = try await makeService(issue: .thumbnail, cachedIDs: [42])
    let report = try await service.prepareReportDirectory()
    #expect(FileManager.default.fileExists(atPath: report.appending(path: "thumbnails/42.png").path))
    #expect(try manifest(at: report).missingThumbnailWindowIDs == [43])
}

@Test func generalModeDoesNotCreateSensitiveSearchStorage() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let searchStore = SearchDiagnosticStore(directory: directory)
    let service = DiagnosticsService(
        directory: directory,
        snapshot: snapshot,
        cachedThumbnail: { _ in nil },
        commands: DiagnosticCommands(
            exportUnifiedLog: { url in try Data("fixed log".utf8).write(to: url) },
            encodePNG: DiagnosticCommands.live.encodePNG,
            zip: { _, zipURL in try Data("zip".utf8).write(to: zipURL) }
        ),
        searchStore: searchStore,
        now: Date.init
    )
    let privateWindow = WindowInfo(
        id: 42,
        pid: 10,
        appName: "Finder",
        appBundleID: "com.apple.finder",
        title: "Private"
    )
    for _ in 0..<1_000 {
        service.recordSearch(query: "secret", results: [privateWindow])
    }
    let events = try await searchStore.events(since: .distantPast)
    #expect(events.isEmpty)
    #expect(FileManager.default.fileExists(atPath: searchStore.fileURL.path) == false)

    service.selectIssue(.search)
    service.recordSearch(query: "f", results: [privateWindow])
    let searchEvents = try await searchStore.events(since: .distantPast)
    #expect(searchEvents.map(\.query) == ["f"])
    service.selectIssue(.general)
    _ = try await searchStore.events(since: .distantPast)
    #expect(FileManager.default.fileExists(atPath: searchStore.fileURL.path) == false)
}
```

测试 seam 只允许注入 `cachedThumbnail: (WindowID) -> CGImage?`；生产 service 的初始化接口中不得出现 capture closure 或 capture 方法。这个编译期边界保证报告生成器没有发起新截图的能力，不新增协议。

- [ ] **Step 2: 写部分失败与两小时导出的失败测试**

增加：

- `exportUnifiedLog` 抛错时仍有 `state.json`，manifest 的 `errors` 包含 `unified_log_export_failed`；
- PNG 编码单项失败时其它图片仍存在，失败 ID 进入 `failedThumbnailWindowIDs`；
- `DiagnosticCommands.unifiedLogArguments` 精确为 `show --last 2h --style compact --info --debug --predicate subsystem == "com.napoleon.Napoleon"`，且不含 `--privacy`；
- ZIP 命令失败时 `prepareReport()` 抛错并保留未压缩工作目录。

使用以下形式锁定失败行为：

```swift
private enum StubError: Error { case failed }

@Test func unifiedLogFailureStillProducesStateAndManifestError() async throws {
    let commands = DiagnosticCommands(
        exportUnifiedLog: { _ in throw StubError.failed },
        encodePNG: DiagnosticCommands.live.encodePNG,
        zip: { _, zipURL in try Data("zip".utf8).write(to: zipURL) }
    )
    let service = try await makeService(issue: .general, commands: commands)
    let report = try await service.prepareReportDirectory()
    #expect(FileManager.default.fileExists(atPath: report.appending(path: "state.json").path))
    #expect(try manifest(at: report).errors.contains("unified_log_export_failed"))
}

@Test func onePNGFailureDoesNotDiscardOtherCacheHits() async throws {
    let commands = DiagnosticCommands(
        exportUnifiedLog: { url in try Data("log".utf8).write(to: url) },
        encodePNG: { image, url in
            if url.lastPathComponent == "42.png" { throw StubError.failed }
            try DiagnosticCommands.live.encodePNG(image, url)
        },
        zip: { _, zipURL in try Data("zip".utf8).write(to: zipURL) }
    )
    let service = try await makeService(issue: .thumbnail, cachedIDs: [42, 43], commands: commands)
    let report = try await service.prepareReportDirectory()
    #expect(FileManager.default.fileExists(atPath: report.appending(path: "thumbnails/43.png").path))
    #expect(try manifest(at: report).failedThumbnailWindowIDs == [42])
}

@Test func liveLogExportNeverRequestsPrivateExpansion() {
    #expect(DiagnosticCommands.unifiedLogArguments == [
        "show", "--last", "2h", "--style", "compact", "--info", "--debug",
        "--predicate", "subsystem == \"com.napoleon.Napoleon\""
    ])
    #expect(DiagnosticCommands.unifiedLogArguments.contains("--privacy") == false)
}

@Test func zipFailureKeepsUncompressedDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let service = DiagnosticsService(
        directory: directory,
        snapshot: snapshot,
        cachedThumbnail: { _ in nil },
        commands: .init(
            exportUnifiedLog: { url in try Data("log".utf8).write(to: url) },
            encodePNG: DiagnosticCommands.live.encodePNG,
            zip: { _, _ in throw StubError.failed }
        ),
        now: { Date(timeIntervalSince1970: 10_000) }
    )
    await #expect(throws: StubError.self) { try await service.prepareReport() }
    let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(children.contains { $0.hasDirectoryPath })
}
```

- [ ] **Step 3: 运行测试，确认报告功能尚未实现**

```bash
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon \
  -destination 'platform=macOS' \
  -only-testing:NapoleonTests/DiagnosticsServiceTests test
```

Expected: FAIL，错误指向缺失的 `DiagnosticSnapshot`、`DiagnosticsService` 或 `prepareReport()`。

- [ ] **Step 4: 实现状态快照与 manifest**

定义 Codable 值类型；`state.json` 仅包含：

```swift
struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let architecture: String
    let interfaceLanguage: String
    let accessibilityTrusted: Bool
    let screenRecordingGranted: Bool
    let allWindowsHotkey: String
    let currentAppHotkey: String
    let includeOtherSpaces: Bool
    let includeMinimized: Bool
    let includeHiddenApps: Bool
    let pinyinSearchEnabled: Bool
    let groupWindowsByApplication: Bool
    let showDelayMs: Int
    let apps: [App]
}
```

`App` 包含 `name`, `bundleID`, `pid`, `windowCount`, `windowIDs`，不含 title。按 `(bundleID ?? "pid:<pid>")` 分组，输出按 `name`、`pid` 稳定排序。

同一步实现 live snapshot；这里只读取现有对象，不发起新权限或窗口查询：

```swift
@MainActor
static func live(
    windows: [WindowInfo],
    settings: SettingsStore,
    permissions: PermissionsManager
) -> DiagnosticSnapshot {
    let groups = Dictionary(grouping: windows) { window in
        "\(window.appBundleID ?? "pid"):\(window.pid)"
    }
    let apps = groups.values.compactMap { windows -> DiagnosticSnapshot.App? in
        guard let first = windows.first else { return nil }
        return .init(
            name: first.appName,
            bundleID: first.appBundleID,
            pid: first.pid,
            windowCount: windows.count,
            windowIDs: windows.map(\.id).sorted()
        )
    }.sorted {
        ($0.name, $0.pid) < ($1.name, $1.pid)
    }

    #if arch(arm64)
    let architecture = "arm64"
    #else
    let architecture = "x86_64"
    #endif

    return .init(
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: architecture,
        interfaceLanguage: Bundle.main.preferredLocalizations.first ?? "unknown",
        accessibilityTrusted: permissions.accessibilityTrusted,
        screenRecordingGranted: permissions.screenRecordingGranted,
        allWindowsHotkey: settings.allWindowsChord.displayString,
        currentAppHotkey: settings.currentAppChord.displayString,
        includeOtherSpaces: settings.scope.includeOtherSpaces,
        includeMinimized: settings.scope.includeMinimized,
        includeHiddenApps: settings.scope.includeHiddenApps,
        pinyinSearchEnabled: settings.pinyinSearchEnabled,
        groupWindowsByApplication: settings.groupWindowsByApplication,
        showDelayMs: settings.showDelayMs,
        apps: apps
    )
}
```

`DiagnosticManifest` 包含 issue、生成时间、`included`, `excluded`, `missingThumbnailWindowIDs`, `failedThumbnailWindowIDs`, `errors`。三个 issue 的 included/excluded 由一个纯函数生成并由 Step 1 测试锁定。

- [ ] **Step 5: 实现本地报告和系统命令边界**

`DiagnosticsService` 构造器使用最小 closure seam：

```swift
@MainActor
final class DiagnosticsService: ObservableObject {
    init(
        directory: URL = DiagnosticsService.defaultDirectory,
        snapshot: @escaping @MainActor () -> DiagnosticSnapshot,
        cachedThumbnail: @escaping @MainActor (WindowID) -> CGImage?,
        commands: DiagnosticCommands = .live,
        searchStore: SearchDiagnosticStore? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    )

    func selectIssue(_ issue: DiagnosticIssue)
    func recordSearch(query: String, results: [WindowInfo])
    func prepareReportDirectory() async throws -> URL
    func prepareReport() async throws -> URL
    func reportWasHandedOff()
}
```

`DiagnosticsService.init` 先 enqueue 一次 `discard()`，删除上一进程遗留的敏感搜索文件；`selectIssue(.search)` 调用 `SearchDiagnosticStore.begin()`，离开 search 再调用 `discard()`。`recordSearch` 在 guard 前不构造标题数组，默认模式直接返回；启用后才把已计算的 `results` 映射为 `DiagnosticSearchEvent`。测试把同一个 `SearchDiagnosticStore` 传给构造器并直接等待其 `events(since:)`，不增加 test-only API。

`prepareReport()` 顺序固定：

1. 主线程取得 snapshot；
2. Thumbnail issue 才对 snapshot 中 window ID 调 `cachedThumbnail`；
3. 后台创建 UUID 工作目录；
4. 调 `/usr/bin/log` 导出 compact 日志，失败写 manifest error 后继续；
5. 写 `state.json`，Search issue 写 `search.jsonl`；
6. Thumbnail issue 使用 `CGImageDestination` + `UTType.png` 写缓存图；
7. 最后写 manifest；
8. 调 `/usr/bin/ditto -c -k --sequesterRsrc --keepParent`，后两个 arguments 分别传实际 UUID 工作目录和 ZIP URL；
9. 返回 ZIP URL。

系统边界类型固定为：

```swift
struct DiagnosticCommands: Sendable {
    let exportUnifiedLog: @Sendable (URL) async throws -> Void
    let encodePNG: @Sendable (CGImage, URL) throws -> Void
    let zip: @Sendable (URL, URL) async throws -> Void

    static let unifiedLogArguments = [
        "show", "--last", "2h", "--style", "compact", "--info", "--debug",
        "--predicate", "subsystem == \"com.napoleon.Napoleon\""
    ]
    static let live: Self
}
```

`.live` 使用 `Process` + `Pipe` 和 ImageIO，直接传 executable URL 和 arguments，不经 shell。启动与下次导出时删除诊断根目录中修改时间早于两小时的工作目录/ZIP；新 ZIP 保留两小时供邮件客户端异步读取。

- [ ] **Step 6: 跑测试并提交**

```bash
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon \
  -destination 'platform=macOS' \
  -only-testing:NapoleonTests/DiagnosticsServiceTests test
git add Sources/Napoleon/Diagnostics/DiagnosticsService.swift Tests/NapoleonTests/DiagnosticsServiceTests.swift
git commit -m "实现本地诊断包生成" \
  -m "「问题或需求描述」用户需主动生成最近两小时日志，并按问题类型控制敏感内容。" \
  -m "「修复或实现思路」按需导出 Unified Logging，生成状态 JSON，缩略图仅读缓存并使用系统 ditto 打包。"
```

Expected: 全部 DiagnosticsServiceTests PASS；`git diff --check` 无输出。

---

### Task 3: 接入运行状态、搜索事件与耗时

**Files:**
- Modify: `Sources/Napoleon/App/AppServices.swift`
- Modify: `Sources/Napoleon/Windows/WindowStore.swift`
- Modify: `Sources/Napoleon/Switcher/SwitcherController.swift`

**Interfaces:**
- Consumes: Task 2 的 `DiagnosticsService` 和 `DiagnosticSnapshot`。
- Produces: `WindowStore.diagnosticState() -> WindowState`; `AppServices.diagnostics`; `SwitcherController` 新增 `recordSearch: (String, [WindowInfo]) -> Void` 初始化参数。

- [ ] **Step 1: 在 AppServices 创建唯一服务**

先给 `WindowStore` 增加只读热态方法；它只返回 COW 值，不调用 `snapshot()`、`reconcileWithWindowServer()` 或任何系统 API：

```swift
func diagnosticState() -> WindowState { state }
```

然后在 `windowStore` 创建后、`SwitcherController` 创建前构造：

```swift
let diagnostics = DiagnosticsService(
    snapshot: {
        DiagnosticSnapshot.live(
            windows: windowStore.diagnosticState().windows,
            settings: settings,
            permissions: permissions
        )
    },
    cachedThumbnail: { [thumbnails] id in thumbnails.cached(id) }
)
self.diagnostics = diagnostics
```

Task 2 同时实现的 `DiagnosticSnapshot.live` 从 `Bundle.main`、`ProcessInfo`、`SettingsStore`、`PermissionsManager` 读取已经存在的值。该 closure 只在用户生成报告时执行；不得在 `AppServices.start()` 预生成 snapshot。

- [ ] **Step 2: 复用搜索结果并补充触发耗时**

给 `SwitcherController.init` 增加：

```swift
recordSearch: @escaping (String, [WindowInfo]) -> Void = { _, _ in }
```

`AppServices` 传入：

```swift
recordSearch: { [diagnostics] query, results in
    diagnostics.recordSearch(query: query, results: results)
}
```

在 `recomputeSearch()` 的现有搜索之后调用 `recordSearch(query, results)`；不得重新搜索或重新枚举窗口。

在 `handleTrigger` 开头读取一次 `ProcessInfo.processInfo.systemUptime`，现有 trigger logger 增加 `prepare_ms`：

```swift
let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
Self.logger.info("trigger: \(filtered.count, privacy: .public) windows, mode=\(String(describing: trigger), privacy: .public), prepare_ms=\(elapsedMs, format: .fixed(precision: 3), privacy: .public)")
```

不得记录原始按键流；现有 trigger、tap 状态和错误日志已经覆盖快捷键诊断。

- [ ] **Step 3: 运行定向测试和编译检查并提交**

```bash
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon \
  -destination 'platform=macOS' \
  -only-testing:NapoleonTests/DiagnosticsServiceTests \
  -only-testing:NapoleonTests/SwitcherItemTests test
git add Sources/Napoleon/App/AppServices.swift Sources/Napoleon/Windows/WindowStore.swift Sources/Napoleon/Switcher/SwitcherController.swift
git commit -m "接入诊断状态与搜索事件" \
  -m "「问题或需求描述」诊断包需要关联当前窗口状态、搜索复现过程与快捷键触发耗时。" \
  -m "「修复或实现思路」复用已有 snapshot 和搜索结果，默认模式提前返回，不新增系统查询。"
```

Expected: 定向测试 PASS；默认模式 1,000 次调用不创建敏感文件。

---

### Task 4: About 页隐私选择与邮件附件

**Files:**
- Modify: `Sources/Napoleon/Settings/AboutView.swift`
- Modify: `Sources/Napoleon/Settings/SettingsView.swift`
- Modify: `Sources/Napoleon/App/AppServices.swift`
- Modify: `Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AppServices.diagnostics`, `DiagnosticsService.prepareReport()`。
- Produces: About 页 Diagnostics section；`composeEmail(attachment:) -> Bool`。

- [ ] **Step 1: 接入 About 依赖并实现 UI**

`SettingsView` 增加 `@ObservedObject var diagnostics: DiagnosticsService`，About 分支改为：

```swift
AboutView(updateChecker: updateChecker, diagnostics: diagnostics)
```

`AppServices` 构造 `SettingsView` 时传入同一实例。

`AboutView` 增加：

```swift
@ObservedObject var diagnostics: DiagnosticsService
@State private var preparingDiagnostics = false
@State private var diagnosticsError: String?
```

在更新区域后新增 Divider + Diagnostics section：问题 Picker 使用显式 Binding 调 `selectIssue(_:)`，下方显示当前 issue 的“包含 / 不包含”说明；按钮文案为 `Prepare Email…`，进行中显示 `ProgressView` + `Preparing…` 并禁止重复点击。

- [ ] **Step 2: 使用系统邮件服务并提供可靠降级**

生成成功后调用：

```swift
private func composeEmail(attachment: URL) -> Bool {
    guard let service = NSSharingService(named: .composeEmail) else { return false }
    service.recipients = ["hi@ryek.ee"]
    service.subject = "Napoleon diagnostics"
    service.perform(withItems: [attachment])
    return true
}
```

若返回 false：

```swift
NSWorkspace.shared.activateFileViewerSelecting([attachment])
NSWorkspace.shared.open(URL(string: "mailto:hi@ryek.ee?subject=Napoleon%20diagnostics")!)
```

界面明确提示“系统无法自动附加文件，请从 Finder 手动添加”。无论首选或 fallback，报告已经准备好后调用 `diagnostics.reportWasHandedOff()` 停止并删除原始 search JSONL；ZIP 本身按两小时清理规则保留。Napoleon 不尝试判断用户是否最终点击邮件客户端的 Send。

- [ ] **Step 3: 添加四语文案**

在 String Catalog 增加以下核心文案，保持含义一致：

| English key | 简体中文 | 繁體中文 | 日本語 |
|---|---|---|---|
| Diagnostics | 诊断日志 | 診斷日誌 | 診断ログ |
| Issue to diagnose | 需要诊断的问题 | 需要診斷的問題 | 診断する問題 |
| General issue | 一般问题 | 一般問題 | 一般的な問題 |
| Search issue | 搜索问题 | 搜尋問題 | 検索の問題 |
| Thumbnail issue | 缩略图问题 | 縮圖問題 | サムネイルの問題 |
| Prepare Email… | 准备邮件… | 準備郵件… | メールを準備… |
| Preparing… | 正在准备… | 正在準備… | 準備中… |
| No logs are uploaded automatically. Review the email before sending. | 日志不会自动上传，请在发送前检查邮件。 | 日誌不會自動上傳，請在傳送前檢查郵件。 | ログは自動送信されません。送信前にメールを確認してください。 |
| Uses cached thumbnails only. No new screenshot will be taken. | 仅使用缓存缩略图，不会重新截图。 | 僅使用快取縮圖，不會重新截圖。 | キャッシュ済みサムネイルのみを使用し、新しいスクリーンショットは撮りません。 |
| Includes app names, Bundle IDs, window counts and IDs, permission states, hotkey events, durations, and error codes. Excludes window titles, searches, file paths, and images. | 包含应用名称、Bundle ID、窗口数量和 ID、权限状态、快捷键事件、耗时与错误码。不包含窗口标题、搜索内容、文件路径或图片。 | 包含應用程式名稱、Bundle ID、視窗數量和 ID、權限狀態、快速鍵事件、耗時與錯誤碼。不包含視窗標題、搜尋內容、檔案路徑或圖片。 | アプリ名、Bundle ID、ウインドウ数と ID、権限状態、ホットキーイベント、所要時間、エラーコードを含みます。ウインドウタイトル、検索内容、ファイルパス、画像は含みません。 |
| Adds search text and matching window titles. Excludes file paths and images. | 增加搜索内容和匹配的窗口标题，不包含文件路径或图片。 | 增加搜尋內容和符合的視窗標題，不包含檔案路徑或圖片。 | 検索内容と一致したウインドウタイトルを追加します。ファイルパスと画像は含みません。 |
| Adds cached window thumbnails. Excludes search text, window titles, file paths, and new screenshots. | 增加缓存的窗口缩略图，不包含搜索内容、窗口标题、文件路径或新截图。 | 增加快取的視窗縮圖，不包含搜尋內容、視窗標題、檔案路徑或新截圖。 | キャッシュ済みウインドウサムネイルを追加します。検索内容、ウインドウタイトル、ファイルパス、新しいスクリーンショットは含みません。 |
| Could not attach the ZIP automatically. Add it to the email draft from Finder. | 无法自动附加 ZIP，请从 Finder 将其添加到邮件草稿。 | 無法自動附加 ZIP，請從 Finder 將其加入郵件草稿。 | ZIP を自動添付できませんでした。Finder からメール下書きに追加してください。 |
| Could not prepare diagnostics: %@ | 无法准备诊断日志：%@ | 無法準備診斷日誌：%@ | 診断ログを準備できませんでした：%@ |

表内三个 issue 的 included/excluded 文案直接用于当前选择下方的隐私说明，不再引入另一套措辞。

- [ ] **Step 4: 编译并做最小设置页验收**

```bash
xcodegen generate
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon \
  -configuration Debug -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED；About 页自然高度可完整显示 Diagnostics section，无常驻滚动条；四种语言均无缺 key。

- [ ] **Step 5: 提交 UI 与本地化**

```bash
git add Sources/Napoleon/Settings/AboutView.swift Sources/Napoleon/Settings/SettingsView.swift Sources/Napoleon/App/AppServices.swift Resources/Localizable.xcstrings
git commit -m "在 About 页添加诊断邮件入口" \
  -m "「问题或需求描述」用户需要选择问题类型并通过系统邮件客户端发送诊断附件。" \
  -m "「修复或实现思路」展示逐项隐私声明，生成 ZIP 后调用系统 Email 分享服务并提供 Finder 降级。"
```

Expected: commit 仅包含 UI、接线和本地化文件。

---

### Task 5: 完整验证、性能验收与替换运行 App

**Files:**
- Verify: files already listed in Tasks 1–4
- Verify: `/Applications/Napoleon.app`

**Interfaces:**
- Consumes: Tasks 1–4 的完整功能。
- Produces: 新签名运行 build、三种诊断包验收证据、性能结论。

- [ ] **Step 1: 运行格式检查、定向测试和完整测试**

```bash
git diff --check
xcodegen generate
xcodebuild -project Napoleon.xcodeproj -scheme NapoleonCore \
  -destination 'platform=macOS' test
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon \
  -destination 'platform=macOS' test
```

Expected: 两个 scheme 全部 PASS；不得用单独 build success 代替 tests。

- [ ] **Step 2: 运行实现后检查 skill**

按仓库要求调用 `check` skill，审查：隐私字段、默认热路径、文件生命周期、Process 参数、主线程 I/O、错误恢复。只修复与本功能直接相关的问题；修复后重复 Step 1 的相关测试。

- [ ] **Step 3: 构建、签名并启动项目本地 build**

```bash
./script/build_and_run.sh --verify
codesign --verify --deep --strict build/Build/Products/Debug/Napoleon.app
```

Expected: 脚本 kill 旧进程、BUILD SUCCEEDED、`pgrep -x Napoleon` 成功、codesign 无错误。

- [ ] **Step 4: 验收三种诊断包但不发送邮件**

在真实 About 页依次操作：

1. General：生成 ZIP，解包确认只有 manifest、compact log、state；全文搜索已知窗口标题与搜索词均无命中。
2. Search：先选择该模式，在 Switcher 输入 `f`，再生成 ZIP；确认 search JSONL 有 `f`、匹配 App/Bundle ID/窗口标题，无 thumbnails 与文件路径字段。
3. Thumbnail：先正常呼出一次 Switcher 让既有缓存处于真实状态，再生成 ZIP；确认只出现缓存命中的 PNG，manifest 列出 misses；导出期间 Unified Logging 没有新的 capture 调用。
4. 邮件撰写窗口收件人为 `hi@ryek.ee` 且带一个 ZIP；关闭草稿，不点击 Send。

Expected: 三类披露边界与设计规格一致；缓存缺失不会触发截图或权限弹窗。

- [ ] **Step 5: 比较性能**

对新进程执行与 Task 1 相同的 30 秒空闲采样：

```bash
pid=$(pgrep -x Napoleon | head -n 1)
test -n "$pid"
for _ in {1..30}; do ps -p "$pid" -o %cpu= -o rss=; sleep 1; done | tee /private/tmp/napoleon-diagnostics-after.txt
```

再连续完成 30 次 Cmd+Tab 会话，从导出的 `prepare_ms` 计算 median 与 p95。验收条件：默认空闲 CPU 无可测增量；相同负载 CPU time 相对增幅低于 1%；trigger median/p95 无统计显著回归。Search 模式输入十组短查询后也不得超过 1%；报告生成阶段是用户主动的离线工作，不计入稳态指标，但 UI 必须保持响应。

- [ ] **Step 6: 替换 `/Applications` 中的 App 并验证新进程**

先用 `mktemp -d` 建可恢复备份目录，kill 当前进程，把旧 `/Applications/Napoleon.app` 移入备份，再用 `ditto` 安装刚验证的 build：

```bash
pkill -x Napoleon || true
backup_dir=$(mktemp -d /private/tmp/napoleon-app-backup.XXXXXX)
test -d /Applications/Napoleon.app
mv /Applications/Napoleon.app "$backup_dir/Napoleon.app"
/usr/bin/ditto build/Build/Products/Debug/Napoleon.app /Applications/Napoleon.app
/usr/bin/open -n /Applications/Napoleon.app
pgrep -x Napoleon
codesign --verify --deep --strict /Applications/Napoleon.app
mdls -name kMDItemVersion -name kMDItemCFBundleIdentifier /Applications/Napoleon.app
```

Expected: 运行路径为 `/Applications/Napoleon.app`，Bundle ID 为 `com.napoleon.Napoleon`，签名有效，About 展示的新 build 号与当前 git 提交数一致。保留并报告 `backup_dir`，直到最终验收完成后再删除。

- [ ] **Step 7: 确认仓库与运行交付状态**

```bash
git status --short --branch
```

Expected: `git status --short` 只剩用户已有的 `.codex/`，不纳入任何提交；`/Applications/Napoleon.app` 的新进程保持运行；不 push，等待用户明确授权。验收若发现缺陷，回到对应 Task 的精确文件和测试步骤修复并用该 Task 的中文格式创建补充提交。
