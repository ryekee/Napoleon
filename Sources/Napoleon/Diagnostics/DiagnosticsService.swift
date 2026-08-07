import Combine
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import ImageIO
import NapoleonCore
import UniformTypeIdentifiers

enum DiagnosticIssue: String, CaseIterable, Identifiable, Codable, Sendable {
    case general
    case search
    case thumbnail

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

    struct App: Codable, Equatable, Sendable {
        let name: String
        let bundleID: String?
        let pid: ProcessID
        let windowCount: Int
        let windowIDs: [WindowID]
    }

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
}

struct DiagnosticManifest: Codable, Equatable, Sendable {
    let issue: DiagnosticIssue
    let generatedAt: Date
    let included: [String]
    let excluded: [String]
    let missingThumbnailWindowIDs: [WindowID]
    let failedThumbnailWindowIDs: [WindowID]
    let errors: [String]

    private struct Contents {
        let included: [String]
        let excluded: [String]
    }

    fileprivate static func contents(for issue: DiagnosticIssue) -> (included: [String], excluded: [String]) {
        let contents: Contents
        switch issue {
        case .general:
            contents = .init(
                included: ["unified.log", "state.json", "manifest.json"],
                excluded: ["search.jsonl", "thumbnails"]
            )
        case .search:
            contents = .init(
                included: ["unified.log", "state.json", "search.jsonl", "manifest.json"],
                excluded: ["thumbnails"]
            )
        case .thumbnail:
            contents = .init(
                included: ["unified.log", "state.json", "thumbnails", "manifest.json"],
                excluded: ["search.jsonl"]
            )
        }
        return (contents.included, contents.excluded)
    }
}

struct DiagnosticCommands: Sendable {
    let exportUnifiedLog: @Sendable (URL) async throws -> Void
    let encodePNG: @Sendable (CGImage, URL) throws -> Void
    let zip: @Sendable (URL, URL) async throws -> Void

    static let unifiedLogArguments = [
        "show", "--last", "2h", "--style", "compact", "--info", "--debug",
        "--predicate", "subsystem == \"com.napoleon.Napoleon\""
    ]

    static let live = Self(
        exportUnifiedLog: { url in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = unifiedLogArguments
            process.standardError = FileHandle.nullDevice
            do {
                try Data().write(to: url, options: .atomic)
                let output = try FileHandle(forWritingTo: url)
                defer { try? output.close() }
                process.standardOutput = output
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw DiagnosticCommandError.processFailed(
                        executable: "/usr/bin/log",
                        status: process.terminationStatus
                    )
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        },
        encodePNG: { image, url in
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw DiagnosticCommandError.couldNotCreatePNGDestination
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw DiagnosticCommandError.couldNotEncodePNG
            }
        },
        zip: { directory, zipURL in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                directory.path, zipURL.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DiagnosticCommandError.processFailed(
                    executable: "/usr/bin/ditto",
                    status: process.terminationStatus
                )
            }
        }
    )
}

private enum DiagnosticCommandError: Error {
    case processFailed(executable: String, status: Int32)
    case couldNotCreatePNGDestination
    case couldNotEncodePNG
}

final class SearchDiagnosticStore: @unchecked Sendable {
    let fileURL: URL

    private let directory: URL
    private let now: @Sendable () -> Date
    private let closeAppendFile: @Sendable (FileHandle) throws -> Void
    private let queue = DispatchQueue(label: "com.ryekee.napoleon.search-diagnostics", qos: .utility)
    private var isActive = false
    private var storedEvents: [DiagnosticSearchEvent] = []
    private var earliestTimestamp: Date?
    private var latestTimestamp: Date?
    private var expiryTimer: DispatchSourceTimer?
    private var scheduledExpiryTimestamp: Date?
    private var pendingFileError: Error?
    private var fileIdentity: FileIdentity?
    private var fileNeedsRewrite = false

    init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        closeAppendFile: @escaping @Sendable (FileHandle) throws -> Void = { try $0.close() }
    ) {
        self.directory = directory
        self.now = now
        self.closeAppendFile = closeAppendFile
        fileURL = directory.appending(path: "search-diagnostics.jsonl", directoryHint: .notDirectory)
    }

    func begin() {
        queue.async {
            self.isActive = true
            self.storedEvents.removeAll()
            self.earliestTimestamp = nil
            self.latestTimestamp = nil
            self.cancelExpiryTimer()
            self.pendingFileError = nil
            self.fileIdentity = nil
            self.fileNeedsRewrite = !self.removeFile()
            self.createDirectory()
            self.fileNeedsRewrite = self.fileNeedsRewrite || self.pendingFileError != nil
        }
    }

    func append(_ event: DiagnosticSearchEvent) {
        queue.async {
            guard self.isActive else { return }

            self.storedEvents.append(event)
            self.updateTimestampBounds(adding: event.timestamp)

            let retentionCutoff = self.latestTimestamp?.addingTimeInterval(-Self.retentionInterval)
            if let retentionCutoff,
               self.earliestTimestamp.map({ $0 < retentionCutoff }) == true {
                self.removeEvents(olderThan: retentionCutoff)
                self.recomputeTimestampBounds()
                self.writeEventsAtomically()
            } else if self.fileNeedsRewrite {
                self.writeEventsAtomically()
            } else {
                self.appendEventLine(event)
            }
            self.scheduleNextExpiry()
        }
    }

    func events(since cutoff: Date) async throws -> [DiagnosticSearchEvent] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }

                guard self.isActive else {
                    if let error = self.consumePendingFileError() {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: [])
                    }
                    return
                }

                let previousCount = self.storedEvents.count
                self.removeEvents(olderThan: cutoff)
                if self.storedEvents.count != previousCount {
                    self.recomputeTimestampBounds()
                    self.writeEventsAtomically()
                } else if self.fileNeedsRewrite {
                    self.writeEventsAtomically()
                } else if !self.currentFileStateIsValid() {
                    self.writeEventsAtomically()
                }
                self.scheduleNextExpiry()

                if let error = self.consumePendingFileError() {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: self.storedEvents)
                }
            }
        }
    }

    func discard() {
        queue.async {
            self.isActive = false
            self.storedEvents.removeAll()
            self.earliestTimestamp = nil
            self.latestTimestamp = nil
            self.cancelExpiryTimer()
            self.fileIdentity = nil
            self.fileNeedsRewrite = !self.removeFile()
        }
    }

    private static let retentionInterval: TimeInterval = 7_200

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let length: Int64
    }

    private enum FileError: Error {
        case unexpectedFile
    }

    private func createDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            recordFileError(error)
        }
    }

    @discardableResult
    private func removeFile() -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return true
        } catch {
            recordFileError(error)
            return false
        }
    }

    // ponytail: 搜索诊断由用户临时启用，事件量按低千级上限处理；只有现场数据证明更大时才改分段文件。
    private func writeEventsAtomically() {
        guard !storedEvents.isEmpty else {
            fileIdentity = nil
            fileNeedsRewrite = !removeFile()
            return
        }

        createDirectory()

        do {
            let encoder = JSONEncoder()
            var data = Data()
            for event in storedEvents {
                data.append(try encoder.encode(event))
                data.append(0x0A)
            }
            fileIdentity = try replaceFileAtomically(with: data)
            fileNeedsRewrite = false
        } catch {
            fileIdentity = nil
            fileNeedsRewrite = true
            recordFileError(error)
        }
    }

    private func appendEventLine(_ event: DiagnosticSearchEvent) {
        do {
            var data = try JSONEncoder().encode(event)
            data.append(0x0A)
            fileIdentity = try append(data)
            fileNeedsRewrite = false
        } catch {
            recordFileError(error)
            fileIdentity = nil
            fileNeedsRewrite = true
            writeEventsAtomically()
        }
    }

    private func append(_ data: Data) throws -> FileIdentity {
        let flags = O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        let descriptor: Int32
        if fileIdentity == nil {
            descriptor = Darwin.open(fileURL.path, flags | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        } else {
            descriptor = Darwin.open(fileURL.path, flags)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var closed = false
        defer {
            if !closed {
                try? handle.close()
            }
        }

        let before = try identity(for: descriptor)
        if let fileIdentity {
            guard before == fileIdentity else { throw FileError.unexpectedFile }
        } else {
            guard before.length == 0 else { throw FileError.unexpectedFile }
        }

        try handle.write(contentsOf: data)
        let after = try identity(for: descriptor)
        guard after.device == before.device,
              after.inode == before.inode,
              after.length == before.length + Int64(data.count) else {
            throw FileError.unexpectedFile
        }

        try closeAppendFile(handle)
        closed = true
        try validateCurrentFile(matching: after)
        return after
    }

    private func replaceFileAtomically(with data: Data) throws -> FileIdentity {
        let temporaryURL = directory.appending(
            path: ".search-diagnostics-\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        var renamed = false
        defer {
            if !renamed {
                _ = Darwin.unlink(temporaryURL.path)
            }
        }

        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var closed = false
        defer {
            if !closed {
                try? handle.close()
            }
        }

        try handle.write(contentsOf: data)
        try handle.synchronize()
        let identity = try identity(for: descriptor)
        guard identity.length == Int64(data.count) else { throw FileError.unexpectedFile }
        try handle.close()
        closed = true

        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw currentPOSIXError()
        }
        renamed = true
        return identity
    }

    private func identity(for descriptor: Int32) throws -> FileIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw currentPOSIXError() }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw FileError.unexpectedFile }
        return FileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            length: metadata.st_size
        )
    }

    private func validateCurrentFile(matching expectedIdentity: FileIdentity) throws {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw currentPOSIXError() }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var closed = false
        defer {
            if !closed {
                try? handle.close()
            }
        }

        let currentIdentity = try identity(for: descriptor)
        guard currentIdentity == expectedIdentity else { throw FileError.unexpectedFile }
        try handle.close()
        closed = true
    }

    private func currentFileStateIsValid() -> Bool {
        guard let fileIdentity else { return storedEvents.isEmpty }
        do {
            try validateCurrentFile(matching: fileIdentity)
            return true
        } catch {
            recordFileError(error)
            self.fileIdentity = nil
            fileNeedsRewrite = true
            return false
        }
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func recordFileError(_ error: Error) {
        pendingFileError = error
    }

    private func consumePendingFileError() -> Error? {
        defer { pendingFileError = nil }
        return pendingFileError
    }

    private func removeEvents(olderThan cutoff: Date) {
        storedEvents.removeAll { $0.timestamp < cutoff }
    }

    private func removeEvents(atOrBefore cutoff: Date) {
        storedEvents.removeAll { $0.timestamp <= cutoff }
    }

    private func updateTimestampBounds(adding timestamp: Date) {
        earliestTimestamp = min(earliestTimestamp ?? timestamp, timestamp)
        latestTimestamp = max(latestTimestamp ?? timestamp, timestamp)
    }

    private func recomputeTimestampBounds() {
        earliestTimestamp = nil
        latestTimestamp = nil
        for event in storedEvents {
            updateTimestampBounds(adding: event.timestamp)
        }
    }

    private func scheduleNextExpiry() {
        guard let earliestTimestamp else {
            cancelExpiryTimer()
            return
        }

        let expiryTimestamp = earliestTimestamp.addingTimeInterval(Self.retentionInterval)
        if expiryTimer != nil, scheduledExpiryTimestamp == expiryTimestamp {
            return
        }

        cancelExpiryTimer()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let delay = max(0, expiryTimestamp.timeIntervalSince(now()))
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelExpiryTimer()
            self.removeEvents(atOrBefore: self.now().addingTimeInterval(-Self.retentionInterval))
            self.recomputeTimestampBounds()
            self.writeEventsAtomically()
            self.scheduleNextExpiry()
        }
        expiryTimer = timer
        scheduledExpiryTimestamp = expiryTimestamp
        timer.resume()
    }

    private func cancelExpiryTimer() {
        expiryTimer?.setEventHandler {}
        expiryTimer?.cancel()
        expiryTimer = nil
        scheduledExpiryTimestamp = nil
    }
}

@MainActor
final class DiagnosticsService: ObservableObject {
    nonisolated static let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first!
        .appending(path: "Napoleon/Diagnostics", directoryHint: .isDirectory)

    private static let retentionInterval: TimeInterval = 7_200

    private let directory: URL
    private let snapshot: @MainActor () -> DiagnosticSnapshot
    private let cachedThumbnail: @MainActor (WindowID) -> CGImage?
    private let commands: DiagnosticCommands
    private let searchStore: SearchDiagnosticStore
    private let now: @Sendable () -> Date
    private let startupCleanup: Task<Void, Never>
    private var selectedIssue: DiagnosticIssue = .default
    private var lastWorkingDirectory: URL?

    init(
        directory: URL = DiagnosticsService.defaultDirectory,
        snapshot: @escaping @MainActor () -> DiagnosticSnapshot,
        cachedThumbnail: @escaping @MainActor (WindowID) -> CGImage?,
        commands: DiagnosticCommands = .live,
        searchStore: SearchDiagnosticStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.snapshot = snapshot
        self.cachedThumbnail = cachedThumbnail
        self.commands = commands
        self.searchStore = searchStore ?? SearchDiagnosticStore(directory: directory, now: now)
        self.now = now

        self.searchStore.discard()
        let cutoff = now().addingTimeInterval(-Self.retentionInterval)
        startupCleanup = Task.detached(priority: .utility) {
            try? Self.removeExpiredReports(in: directory, olderThan: cutoff)
        }
    }

    func selectIssue(_ issue: DiagnosticIssue) {
        guard issue != selectedIssue else { return }

        if issue == .search {
            searchStore.begin()
        } else if selectedIssue == .search {
            searchStore.discard()
        }
        selectedIssue = issue
    }

    func recordSearch(query: String, results: [WindowInfo]) {
        guard selectedIssue.includesSearch else { return }

        let event = DiagnosticSearchEvent(
            timestamp: now(),
            query: query,
            results: results.map { window in
                .init(
                    windowID: window.id,
                    appName: window.appName,
                    bundleID: window.appBundleID,
                    windowTitle: window.title
                )
            }
        )
        searchStore.append(event)
    }

    func prepareReportDirectory() async throws -> URL {
        let issue = selectedIssue
        let generatedAt = now()
        let snapshot = snapshot()
        let thumbnails = issue.includesThumbnails ? cachedThumbnails(for: snapshot) : [:]
        let searchEvents = issue.includesSearch
            ? try await searchStore.events(since: generatedAt.addingTimeInterval(-Self.retentionInterval))
            : []

        await startupCleanup.value
        let cutoff = generatedAt.addingTimeInterval(-Self.retentionInterval)
        let rootDirectory = directory
        let commands = commands
        let report = try await Task.detached(priority: .utility) {
            try Self.removeExpiredReports(in: rootDirectory, olderThan: cutoff)
            return try await Self.writeReport(
                rootDirectory: rootDirectory,
                issue: issue,
                generatedAt: generatedAt,
                snapshot: snapshot,
                searchEvents: searchEvents,
                thumbnails: thumbnails,
                commands: commands
            )
        }.value
        lastWorkingDirectory = report
        return report
    }

    func prepareReport() async throws -> URL {
        let report = try await prepareReportDirectory()
        let zipURL = report.appendingPathExtension("zip")
        do {
            try await commands.zip(report, zipURL)
        } catch {
            try? FileManager.default.removeItem(at: zipURL)
            throw error
        }
        return zipURL
    }

    func reportWasHandedOff() {
        searchStore.discard()
        selectedIssue = .general
        guard let lastWorkingDirectory else { return }
        self.lastWorkingDirectory = nil
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: lastWorkingDirectory)
        }
    }

    private func cachedThumbnails(for snapshot: DiagnosticSnapshot) -> [WindowID: CGImage] {
        var thumbnails: [WindowID: CGImage] = [:]
        for windowID in Set(snapshot.apps.flatMap(\.windowIDs)).sorted() {
            if let image = cachedThumbnail(windowID) {
                thumbnails[windowID] = image
            }
        }
        return thumbnails
    }

    nonisolated private static func writeReport(
        rootDirectory: URL,
        issue: DiagnosticIssue,
        generatedAt: Date,
        snapshot: DiagnosticSnapshot,
        searchEvents: [DiagnosticSearchEvent],
        thumbnails: [WindowID: CGImage],
        commands: DiagnosticCommands
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let report = rootDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: report, withIntermediateDirectories: false)

        var errors: [String] = []
        do {
            try await commands.exportUnifiedLog(report.appending(path: "unified.log"))
        } catch {
            errors.append("unified_log_export_failed")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: report.appending(path: "state.json"), options: .atomic)

        if issue.includesSearch {
            let lineEncoder = JSONEncoder()
            lineEncoder.outputFormatting = [.sortedKeys]
            let lines = try searchEvents.map { event in
                String(decoding: try lineEncoder.encode(event), as: UTF8.self)
            }
            try Data(lines.joined(separator: "\n").utf8)
                .write(to: report.appending(path: "search.jsonl"), options: .atomic)
        }

        let allWindowIDs = Set(snapshot.apps.flatMap(\.windowIDs))
        let missingThumbnailWindowIDs = issue.includesThumbnails
            ? allWindowIDs.subtracting(thumbnails.keys).sorted()
            : []
        var failedThumbnailWindowIDs: [WindowID] = []
        if issue.includesThumbnails {
            let thumbnailDirectory = report.appending(path: "thumbnails", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: false)
            for windowID in thumbnails.keys.sorted() {
                guard let image = thumbnails[windowID] else { continue }
                let imageURL = thumbnailDirectory.appending(path: "\(windowID).png")
                do {
                    try commands.encodePNG(image, imageURL)
                } catch {
                    try? fileManager.removeItem(at: imageURL)
                    failedThumbnailWindowIDs.append(windowID)
                }
            }
        }

        let contents = DiagnosticManifest.contents(for: issue)
        let manifest = DiagnosticManifest(
            issue: issue,
            generatedAt: generatedAt,
            included: contents.included,
            excluded: contents.excluded,
            missingThumbnailWindowIDs: missingThumbnailWindowIDs,
            failedThumbnailWindowIDs: failedThumbnailWindowIDs,
            errors: errors
        )
        try encoder.encode(manifest).write(to: report.appending(path: "manifest.json"), options: .atomic)
        return report
    }

    nonisolated private static func removeExpiredReports(in directory: URL, olderThan cutoff: Date) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }

        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let isZIP = child.pathExtension == "zip"
            let stem = isZIP ? child.deletingPathExtension().lastPathComponent : child.lastPathComponent
            guard UUID(uuidString: stem) != nil else { continue }

            let values = try child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard isZIP || values.isDirectory == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate < cutoff else { continue }
            try fileManager.removeItem(at: child)
        }
    }
}
