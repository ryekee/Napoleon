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

struct DiagnosticProcessResult: Equatable, Sendable {
    let terminationStatus: Int32
    let outputTruncated: Bool
}

enum DiagnosticProcessRunnerError: Error, Equatable, Sendable {
    case timedOut
}

struct DiagnosticProcessRunner: Sendable {
    private enum WaitEvent: Sendable {
        case terminated(Int32)
        case timedOut
    }

    let timeout: TimeInterval
    let terminationGracePeriod: TimeInterval
    private let processDidStart: @Sendable () -> Void

    init(
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval = 0.25,
        processDidStart: @escaping @Sendable () -> Void = {}
    ) {
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.processDidStart = processDidStart
    }

    func run(
        executableURL: URL,
        arguments: [String],
        standardOutputURL: URL? = nil,
        maxOutputBytes: Int? = nil
    ) async throws -> DiagnosticProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice

        let outputPipe = standardOutputURL.map { _ in Pipe() }
        process.standardOutput = outputPipe?.fileHandleForWriting ?? FileHandle.nullDevice
        let controller = DiagnosticProcessController(
            process: process,
            terminationGracePeriod: terminationGracePeriod
        )
        let outputPump: DiagnosticOutputPump?
        if let outputPipe, let standardOutputURL {
            outputPump = try DiagnosticOutputPump(
                reader: outputPipe.fileHandleForReading,
                outputURL: standardOutputURL,
                maxBytes: maxOutputBytes ?? .max,
                controller: controller
            )
            outputPump?.start()
        } else {
            outputPump = nil
        }
        process.terminationHandler = { [weak controller] process in
            controller?.processDidTerminate(status: process.terminationStatus)
        }

        return try await withTaskCancellationHandler {
            defer {
                try? outputPipe?.fileHandleForWriting.close()
                outputPump?.finishImmediately()
            }
            try Task.checkCancellation()
            do {
                try controller.launch()
            } catch {
                try? outputPipe?.fileHandleForWriting.close()
                outputPump?.finishImmediately()
                throw error
            }
            try? outputPipe?.fileHandleForWriting.close()
            processDidStart()

            let waitResult: (status: Int32, timedOut: Bool)
            do {
                waitResult = try await waitForTermination(of: controller)
            } catch {
                _ = await controller.waitForTermination()
                outputPump?.finishAfterDrainPeriod(terminationGracePeriod)
                _ = try? await outputPump?.result()
                throw error
            }

            outputPump?.finishAfterDrainPeriod(terminationGracePeriod)
            if waitResult.timedOut {
                _ = try? await outputPump?.result()
                throw DiagnosticProcessRunnerError.timedOut
            }
            let outputTruncated = try await outputPump?.result() ?? false
            try Task.checkCancellation()
            return .init(
                terminationStatus: waitResult.status,
                outputTruncated: outputTruncated
            )
        } onCancel: {
            controller.requestStop()
        }
    }

    private func waitForTermination(
        of controller: DiagnosticProcessController
    ) async throws -> (status: Int32, timedOut: Bool) {
        try await withThrowingTaskGroup(of: WaitEvent.self) { group in
            group.addTask {
                .terminated(await controller.waitForTermination())
            }
            group.addTask {
                let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                return .timedOut
            }

            var didTimeOut = false
            while let event = try await group.next() {
                switch event {
                case let .terminated(status):
                    group.cancelAll()
                    return (status, didTimeOut)
                case .timedOut:
                    didTimeOut = true
                    controller.requestStop()
                }
            }
            throw CancellationError()
        }
    }
}

private final class DiagnosticOutputPump: @unchecked Sendable {
    private let reader: FileHandle
    private let output: FileHandle
    private let byteLimit: Int
    private let controller: DiagnosticProcessController
    private let queue = DispatchQueue(label: "com.ryekee.napoleon.diagnostic-output", qos: .utility)
    private var writtenByteCount = 0
    private var isTruncated = false
    private var completion: Result<Bool, Error>?
    private var continuation: CheckedContinuation<Bool, Error>?

    init(
        reader: FileHandle,
        outputURL: URL,
        maxBytes: Int,
        controller: DiagnosticProcessController
    ) throws {
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.reader = reader
        output = try FileHandle(forWritingTo: outputURL)
        byteLimit = max(0, maxBytes)
        self.controller = controller
    }

    func start() {
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                self?.consume(data)
            }
        }
    }

    func finishAfterDrainPeriod(_ drainPeriod: TimeInterval) {
        queue.asyncAfter(deadline: .now() + max(0, drainPeriod)) { [self] in
            finish(.success(isTruncated))
        }
    }

    func finishImmediately() {
        queue.async { [self] in
            finish(.success(isTruncated))
        }
    }

    func result() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let completion {
                    resume(continuation, with: completion)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    private func consume(_ data: Data) {
        guard completion == nil else { return }
        guard !data.isEmpty else {
            finish(.success(isTruncated))
            return
        }
        guard !isTruncated else { return }

        let writableByteCount = min(data.count, byteLimit - writtenByteCount)
        do {
            if writableByteCount > 0 {
                try output.write(contentsOf: data.prefix(writableByteCount))
                writtenByteCount += writableByteCount
            }
        } catch {
            controller.requestStop()
            finish(.failure(error))
            return
        }
        if writableByteCount < data.count {
            isTruncated = true
            controller.requestStop()
        }
    }

    private func finish(_ result: Result<Bool, Error>) {
        guard completion == nil else { return }
        completion = result
        reader.readabilityHandler = nil
        try? reader.close()
        try? output.close()
        guard let continuation else { return }
        self.continuation = nil
        resume(continuation, with: result)
    }

    private func resume(
        _ continuation: CheckedContinuation<Bool, Error>,
        with result: Result<Bool, Error>
    ) {
        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

private final class DiagnosticProcessController: @unchecked Sendable {
    private let process: Process
    private let terminationGracePeriod: TimeInterval
    private let lock = NSLock()
    private var launched = false
    private var stopRequested = false
    private var terminationSignalSent = false
    private var terminationStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(process: Process, terminationGracePeriod: TimeInterval) {
        self.process = process
        self.terminationGracePeriod = terminationGracePeriod
    }

    func launch() throws {
        try process.run()

        lock.lock()
        launched = true
        let shouldStop = stopRequested && terminationStatus == nil && !terminationSignalSent
        if shouldStop {
            terminationSignalSent = true
        }
        lock.unlock()

        if shouldStop {
            terminateAndScheduleKill()
        }
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        let shouldStop = launched && terminationStatus == nil && !terminationSignalSent
        if shouldStop {
            terminationSignalSent = true
        }
        lock.unlock()

        if shouldStop {
            terminateAndScheduleKill()
        }
    }

    func processDidTerminate(status: Int32) {
        lock.lock()
        guard terminationStatus == nil else {
            lock.unlock()
            return
        }
        terminationStatus = status
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: status) }
    }

    func waitForTermination() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let terminationStatus {
                lock.unlock()
                continuation.resume(returning: terminationStatus)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func terminateAndScheduleKill() {
        process.terminate()
        let delay = max(0, terminationGracePeriod)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock()
            let processIdentifier = terminationStatus == nil ? process.processIdentifier : 0
            lock.unlock()
            if processIdentifier > 0 {
                Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }
}

struct DiagnosticCommands: Sendable {
    let exportUnifiedLog: @Sendable (URL) async throws -> Void
    let encodePNG: @Sendable (CGImage, URL) throws -> Void
    let zip: @Sendable (URL, URL) async throws -> Void
    let scheduleRemoval: @Sendable (URL, Date) -> Void

    init(
        exportUnifiedLog: @escaping @Sendable (URL) async throws -> Void,
        encodePNG: @escaping @Sendable (CGImage, URL) throws -> Void,
        zip: @escaping @Sendable (URL, URL) async throws -> Void,
        scheduleRemoval: @escaping @Sendable (URL, Date) -> Void
    ) {
        self.exportUnifiedLog = exportUnifiedLog
        self.encodePNG = encodePNG
        self.zip = zip
        self.scheduleRemoval = scheduleRemoval
    }

    static let unifiedLogArguments = [
        "show", "--last", "2h", "--style", "compact", "--info", "--debug",
        "--predicate", "subsystem == \"com.napoleon.Napoleon\""
    ]
    static let unifiedLogMaxBytes = 20 * 1_024 * 1_024

    private static let liveLogRunner = DiagnosticProcessRunner(timeout: 30)
    private static let liveZipRunner = DiagnosticProcessRunner(timeout: 120)

    static let live = Self(
        exportUnifiedLog: { url in
            do {
                let result = try await liveLogRunner.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/log"),
                    arguments: unifiedLogArguments,
                    standardOutputURL: url,
                    maxOutputBytes: unifiedLogMaxBytes
                )
                if result.outputTruncated {
                    throw DiagnosticCommandError.unifiedLogTruncated
                }
                guard result.terminationStatus == 0 else {
                    throw DiagnosticCommandError.processFailed(
                        executable: "/usr/bin/log",
                        status: result.terminationStatus
                    )
                }
            } catch DiagnosticCommandError.unifiedLogTruncated {
                throw DiagnosticCommandError.unifiedLogTruncated
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
            let result = try await liveZipRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [
                    "-c", "-k", "--sequesterRsrc", "--keepParent",
                    directory.path, zipURL.path
                ]
            )
            guard result.terminationStatus == 0 else {
                throw DiagnosticCommandError.processFailed(
                    executable: "/usr/bin/ditto",
                    status: result.terminationStatus
                )
            }
        },
        scheduleRemoval: liveRemovalScheduler
    )

    private static let liveRemovalScheduler: @Sendable (URL, Date) -> Void = { url, deadline in
        let isZIP = url.pathExtension == "zip"
        let stem = isZIP ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        guard UUID(uuidString: stem) != nil else { return }

        let delay = max(0, deadline.timeIntervalSinceNow)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum DiagnosticCommandError: Error {
    case processFailed(executable: String, status: Int32)
    case unifiedLogTruncated
    case couldNotCreatePNGDestination
    case couldNotEncodePNG
}

enum DiagnosticsServiceError: Error, Equatable, Sendable {
    case reportAlreadyInProgress
}

final class SearchDiagnosticStore: @unchecked Sendable {
    let fileURL: URL

    private let directory: URL
    private let now: @Sendable () -> Date
    private let closeAppendFile: @Sendable (FileHandle) throws -> Void
    private let removeOrphanFile: @Sendable (URL) throws -> Void
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
        closeAppendFile: @escaping @Sendable (FileHandle) throws -> Void = { try $0.close() },
        removeOrphanFile: @escaping @Sendable (URL) throws -> Void = { url in
            guard Darwin.unlink(url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    ) {
        self.directory = directory
        self.now = now
        self.closeAppendFile = closeAppendFile
        self.removeOrphanFile = removeOrphanFile
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
            self.removeOrphanTemporaryFiles()
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
            self.removeOrphanTemporaryFiles()
        }
    }

    private static let retentionInterval: TimeInterval = 7_200
    private static let temporaryFilePrefix = ".search-diagnostics-"
    private static let temporaryFileSuffix = ".tmp"

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

    private func removeOrphanTemporaryFiles() {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return
        } catch {
            recordFileError(error)
            return
        }

        for child in children where isManagedTemporaryFileName(child.lastPathComponent) {
            var metadata = stat()
            guard Darwin.lstat(child.path, &metadata) == 0 else {
                if errno != ENOENT {
                    recordFileError(currentPOSIXError())
                }
                continue
            }
            let fileType = metadata.st_mode & S_IFMT
            guard fileType == S_IFREG || fileType == S_IFLNK else { continue }

            do {
                try removeOrphanFile(child)
            } catch let error as POSIXError where error.code == .ENOENT {
                continue
            } catch {
                recordFileError(error)
            }
        }
    }

    private func isManagedTemporaryFileName(_ name: String) -> Bool {
        guard name.hasPrefix(Self.temporaryFilePrefix),
              name.hasSuffix(Self.temporaryFileSuffix) else {
            return false
        }
        let uuidStart = name.index(name.startIndex, offsetBy: Self.temporaryFilePrefix.count)
        let uuidEnd = name.index(name.endIndex, offsetBy: -Self.temporaryFileSuffix.count)
        let uuidString = String(name[uuidStart..<uuidEnd])
        guard let uuid = UUID(uuidString: uuidString) else { return false }
        return uuid.uuidString.caseInsensitiveCompare(uuidString) == .orderedSame
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
            path: "\(Self.temporaryFilePrefix)\(UUID().uuidString)\(Self.temporaryFileSuffix)",
            directoryHint: .notDirectory
        )
        var renamed = false
        var temporaryFileCreated = false
        defer {
            if temporaryFileCreated && !renamed {
                do {
                    try removeOrphanFile(temporaryURL)
                } catch {
                    // The caller records the primary replace error after this secondary cleanup error.
                    recordFileError(error)
                }
            }
        }

        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        temporaryFileCreated = true

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

    nonisolated private static let retentionInterval: TimeInterval = 7_200

    private let directory: URL
    private let snapshot: @MainActor () -> DiagnosticSnapshot
    private let cachedThumbnail: @MainActor (WindowID) -> CGImage?
    private let commands: DiagnosticCommands
    private let searchStore: SearchDiagnosticStore
    private let now: @Sendable () -> Date
    private let startupCleanup: Task<Void, Never>
    private var selectedIssue: DiagnosticIssue = .default
    private var lastWorkingDirectory: URL?
    private var isPreparingReport = false

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
        try beginReportPreparation()
        defer { isPreparingReport = false }
        return try await prepareReportDirectoryUnlocked()
    }

    func prepareReport() async throws -> URL {
        try beginReportPreparation()
        defer { isPreparingReport = false }

        let report = try await prepareReportDirectoryUnlocked()
        let zipURL = report.appendingPathExtension("zip")
        commands.scheduleRemoval(zipURL, now().addingTimeInterval(Self.retentionInterval))
        do {
            try await commands.zip(report, zipURL)
        } catch {
            try? FileManager.default.removeItem(at: zipURL)
            throw error
        }
        return zipURL
    }

    private func beginReportPreparation() throws {
        guard !isPreparingReport else {
            throw DiagnosticsServiceError.reportAlreadyInProgress
        }
        isPreparingReport = true
    }

    private func prepareReportDirectoryUnlocked() async throws -> URL {
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
        let now = now
        let report = try await Task.detached(priority: .utility) {
            try Self.removeExpiredReports(in: rootDirectory, olderThan: cutoff)
            return try await Self.writeReport(
                rootDirectory: rootDirectory,
                issue: issue,
                generatedAt: generatedAt,
                snapshot: snapshot,
                searchEvents: searchEvents,
                thumbnails: thumbnails,
                commands: commands,
                now: now
            )
        }.value
        lastWorkingDirectory = report
        return report
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
        commands: DiagnosticCommands,
        now: @Sendable () -> Date
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let report = rootDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: report, withIntermediateDirectories: false)
        commands.scheduleRemoval(report, now().addingTimeInterval(retentionInterval))

        var errors: [String] = []
        do {
            try await commands.exportUnifiedLog(report.appending(path: "unified.log"))
        } catch DiagnosticCommandError.unifiedLogTruncated {
            errors.append("unified_log_truncated")
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
