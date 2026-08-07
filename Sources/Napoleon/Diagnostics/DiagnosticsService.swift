import Combine
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import ImageIO
import NapoleonCore
import OSLog
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
                included: ["napoleon.log", "state.json", "manifest.json"],
                excluded: ["search.jsonl", "thumbnails"]
            )
        case .search:
            contents = .init(
                included: ["napoleon.log", "state.json", "search.jsonl", "manifest.json"],
                excluded: ["thumbnails"]
            )
        case .thumbnail:
            contents = .init(
                included: ["napoleon.log", "state.json", "thumbnails", "manifest.json"],
                excluded: ["search.jsonl"]
            )
        }
        return (contents.included, contents.excluded)
    }
}

struct DiagnosticProcessResult: Equatable, Sendable {
    let terminationStatus: Int32
    let outputTruncated: Bool
    let maxPendingOutputBytes: Int
}

enum DiagnosticProcessRunnerError: Error, Equatable, Sendable {
    case timedOut
}

struct DiagnosticProcessRunner: Sendable {
    static let outputChunkBytes = 64 * 1_024

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
                chunkBytes: Self.outputChunkBytes,
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
            let outputResult = try await outputPump?.result() ?? .empty
            try Task.checkCancellation()
            return .init(
                terminationStatus: waitResult.status,
                outputTruncated: outputResult.isTruncated,
                maxPendingOutputBytes: outputResult.maxPendingBytes
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

private struct DiagnosticOutputResult: Sendable {
    static let empty = Self(isTruncated: false, maxPendingBytes: 0)

    let isTruncated: Bool
    let maxPendingBytes: Int
}

private final class DiagnosticOutputPump: @unchecked Sendable {
    private let reader: FileHandle
    private let outputFileDescriptor: Int32
    private let byteLimit: Int
    private let chunkBytes: Int
    private let controller: DiagnosticProcessController
    private let readerQueue = DispatchQueue(label: "com.ryekee.napoleon.diagnostic-output", qos: .utility)
    private let stateLock = NSLock()
    private var drainDeadline: DispatchTime?
    private var isFinishing = false
    private var completion: Result<DiagnosticOutputResult, Error>?
    private var continuation: CheckedContinuation<DiagnosticOutputResult, Error>?

    init(
        reader: FileHandle,
        outputURL: URL,
        maxBytes: Int,
        chunkBytes: Int,
        controller: DiagnosticProcessController
    ) throws {
        let outputFileDescriptor = try Self.openNewRegularFile(at: outputURL)

        let inputFileDescriptor = reader.fileDescriptor
        let currentFlags = Darwin.fcntl(inputFileDescriptor, F_GETFL)
        guard currentFlags >= 0,
              Darwin.fcntl(inputFileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(outputFileDescriptor)
            throw error
        }

        self.reader = reader
        self.outputFileDescriptor = outputFileDescriptor
        byteLimit = max(0, maxBytes)
        self.chunkBytes = max(1, chunkBytes)
        self.controller = controller
    }

    private static func openNewRegularFile(at url: URL) throws -> Int32 {
        let parentURL = url.deletingLastPathComponent()
        let parentDescriptor = parentURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(parentDescriptor) }

        let descriptor = url.lastPathComponent.withCString { name in
            Darwin.openat(
                parentDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let error = currentPOSIXError()
            Darwin.close(descriptor)
            throw error
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard Darwin.fchmod(descriptor, DiagnosticFileSecurity.fileMode) == 0 else {
            let error = currentPOSIXError()
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    func start() {
        readerQueue.async { [self] in
            runReaderLoop()
        }
    }

    func finishAfterDrainPeriod(_ drainPeriod: TimeInterval) {
        let nanoseconds = UInt64(max(0, drainPeriod) * 1_000_000_000)
        let deadline = DispatchTime.now() + .nanoseconds(Int(clamping: nanoseconds))
        stateLock.withLock {
            if drainDeadline == nil || deadline < drainDeadline! {
                drainDeadline = deadline
            }
        }
    }

    func finishImmediately() {
        stateLock.withLock {
            drainDeadline = .now()
        }
    }

    func result() async throws -> DiagnosticOutputResult {
        try await withCheckedThrowingContinuation { continuation in
            let completed = stateLock.withLock { () -> Result<DiagnosticOutputResult, Error>? in
                if let completion { return completion }
                self.continuation = continuation
                return nil
            }
            if let completed {
                resume(continuation, with: completed)
            }
        }
    }

    private func runReaderLoop() {
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        var writtenByteCount = 0
        var maxPendingBytes = 0

        while true {
            if drainPeriodExpired {
                finish(.success(.init(
                    isTruncated: true,
                    maxPendingBytes: maxPendingBytes
                )))
                return
            }

            var descriptor = pollfd(
                fd: reader.fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, pollTimeoutMilliseconds)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                finish(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
                return
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                finish(.failure(POSIXError(.EBADF)))
                return
            }

            let readByteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(reader.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if readByteCount == 0 {
                finish(.success(.init(
                    isTruncated: false,
                    maxPendingBytes: maxPendingBytes
                )))
                return
            }
            if readByteCount < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                finish(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
                return
            }

            let pendingByteCount = Int(readByteCount)
            maxPendingBytes = max(maxPendingBytes, pendingByteCount)
            let writableByteCount = min(pendingByteCount, byteLimit - writtenByteCount)
            do {
                if writableByteCount > 0 {
                    try writeAll(buffer, count: writableByteCount)
                    writtenByteCount += writableByteCount
                }
            } catch {
                controller.requestStop()
                finish(.failure(error))
                return
            }
            if writableByteCount < pendingByteCount {
                controller.requestStop()
                finish(.success(.init(
                    isTruncated: true,
                    maxPendingBytes: maxPendingBytes
                )))
                return
            }
        }
    }

    private var drainPeriodExpired: Bool {
        stateLock.withLock {
            guard let drainDeadline else { return false }
            return drainDeadline <= .now()
        }
    }

    private var pollTimeoutMilliseconds: Int32 {
        stateLock.withLock {
            guard let drainDeadline else { return 50 }
            let now = DispatchTime.now()
            guard drainDeadline > now else { return 0 }
            let remainingNanoseconds = drainDeadline.uptimeNanoseconds - now.uptimeNanoseconds
            let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
            return Int32(min(50, roundedMilliseconds))
        }
    }

    private func writeAll(_ buffer: [UInt8], count: Int) throws {
        try buffer.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < count {
                let written = Darwin.write(
                    outputFileDescriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private func finish(_ result: Result<DiagnosticOutputResult, Error>) {
        let shouldFinish = stateLock.withLock {
            guard completion == nil, !isFinishing else { return false }
            isFinishing = true
            return true
        }
        guard shouldFinish else { return }
        try? reader.close()
        Darwin.close(outputFileDescriptor)
        let continuation = stateLock.withLock {
            completion = result
            defer { self.continuation = nil }
            return self.continuation
        }
        if let continuation {
            resume(continuation, with: result)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<DiagnosticOutputResult, Error>,
        with result: Result<DiagnosticOutputResult, Error>
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

struct DiagnosticArtifactIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let fileType: mode_t

    static func atPath(_ url: URL) throws -> Self? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return .init(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            fileType: metadata.st_mode & S_IFMT
        )
    }
}

private enum DiagnosticFileSecurity {
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600

    static func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, directoryMode) == 0 else { throw currentPOSIXError() }
    }

    static func secureRegularFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw currentPOSIXError() }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard Darwin.fchmod(descriptor, fileMode) == 0 else { throw currentPOSIXError() }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

final class DiagnosticRetentionScheduler: @unchecked Sendable {
    typealias Schedule = @Sendable (Date, @escaping @Sendable () -> Void) -> Void

    private struct Entry {
        let token: UUID
        let deadline: Date
        let identity: DiagnosticArtifactIdentity
    }

    private static let logger = Logger(
        subsystem: "com.napoleon.Napoleon",
        category: "diagnostic-retention"
    )

    static let live = DiagnosticRetentionScheduler(
        now: { Date() },
        retryDelays: [1, 5, 30],
        identityAtPath: { try DiagnosticArtifactIdentity.atPath($0) },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        schedule: { deadline, action in
            let delay = max(0, deadline.timeIntervalSinceNow)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + delay,
                execute: action
            )
        },
        logError: { _ in
            logger.error("diagnostic_retention_delete_failed")
        }
    )

    private let now: @Sendable () -> Date
    private let retryDelays: [TimeInterval]
    private let identityAtPath: @Sendable (URL) throws -> DiagnosticArtifactIdentity?
    private let removeItem: @Sendable (URL) throws -> Void
    private let schedule: Schedule
    private let logError: @Sendable (String) -> Void
    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    init(
        now: @escaping @Sendable () -> Date,
        retryDelays: [TimeInterval],
        identityAtPath: @escaping @Sendable (URL) throws -> DiagnosticArtifactIdentity? = {
            try DiagnosticArtifactIdentity.atPath($0)
        },
        removeItem: @escaping @Sendable (URL) throws -> Void,
        schedule: @escaping Schedule,
        logError: @escaping @Sendable (String) -> Void
    ) {
        self.now = now
        self.retryDelays = retryDelays
        self.identityAtPath = identityAtPath
        self.removeItem = removeItem
        self.schedule = schedule
        self.logError = logError
    }

    func scheduleRemoval(_ url: URL, deadline: Date) {
        guard let expectedFileType = Self.expectedFileType(for: url) else { return }

        let identity: DiagnosticArtifactIdentity
        do {
            guard let captured = try identityAtPath(url) else { return }
            guard captured.fileType == expectedFileType else {
                logError("diagnostic_retention_invalid_artifact")
                return
            }
            identity = captured
        } catch {
            logError("diagnostic_retention_identity_read_failed")
            return
        }

        let token: UUID? = lock.withLock {
            if let current = entries[url],
               current.identity == identity,
               current.deadline <= deadline {
                return nil
            }
            let token = UUID()
            entries[url] = .init(token: token, deadline: deadline, identity: identity)
            return token
        }
        guard let token else { return }
        enqueueAttempt(for: url, at: deadline, retryIndex: 0, token: token)
    }

    private func enqueueAttempt(for url: URL, at deadline: Date, retryIndex: Int, token: UUID) {
        schedule(deadline) { [self] in
            attemptRemoval(of: url, retryIndex: retryIndex, token: token)
        }
    }

    private func attemptRemoval(of url: URL, retryIndex: Int, token: UUID) {
        guard let entry = currentEntry(url: url, token: token) else { return }
        do {
            guard let currentIdentity = try identityAtPath(url) else {
                clear(url: url, token: token)
                return
            }
            guard currentIdentity == entry.identity else {
                clear(url: url, token: token)
                logError("diagnostic_retention_identity_changed")
                return
            }
            try removeItem(url)
            clear(url: url, token: token)
        } catch {
            if Self.isFileNotFound(error) {
                clear(url: url, token: token)
            } else if retryIndex < retryDelays.count {
                let delay = max(0, retryDelays[retryIndex])
                enqueueAttempt(
                    for: url,
                    at: now().addingTimeInterval(delay),
                    retryIndex: retryIndex + 1,
                    token: token
                )
            } else {
                clear(url: url, token: token)
                logError("diagnostic_retention_delete_failed")
            }
        }
    }

    private func currentEntry(url: URL, token: UUID) -> Entry? {
        lock.withLock {
            guard let entry = entries[url], entry.token == token else { return nil }
            return entry
        }
    }

    private func clear(url: URL, token: UUID) {
        lock.withLock {
            if entries[url]?.token == token {
                entries.removeValue(forKey: url)
            }
        }
    }

    private static func expectedFileType(for url: URL) -> mode_t? {
        let isZIP = url.pathExtension == "zip"
        let stem = isZIP ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        guard UUID(uuidString: stem) != nil else { return nil }
        return isZIP ? S_IFREG : S_IFDIR
    }

    private static func isFileNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
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
        scheduleRemoval: { url, deadline in
            DiagnosticRetentionScheduler.live.scheduleRemoval(url, deadline: deadline)
        }
    )
}

enum DiagnosticCommandError: Error {
    case processFailed(executable: String, status: Int32)
    case unifiedLogTruncated
    case couldNotCreatePNGDestination
    case couldNotEncodePNG
}

enum DiagnosticsServiceError: Error, Equatable, LocalizedError, Sendable {
    case reportAlreadyInProgress
    case zipTimedOut
    case zipFailed

    var errorDescription: String? {
        switch self {
        case .reportAlreadyInProgress:
            String(localized: "A diagnostic report is already being prepared.")
        case .zipTimedOut:
            String(localized: "Creating the diagnostic ZIP timed out. Try again; the uncompressed report is still available.")
        case .zipFailed:
            String(localized: "Could not create the diagnostic ZIP. Try again; the uncompressed report is still available.")
        }
    }
}

final class SearchDiagnosticStore: @unchecked Sendable {
    typealias FileRemovalRetrySchedule = @Sendable (
        TimeInterval,
        @escaping @Sendable () -> Void
    ) -> Void

    let fileURL: URL

    private let directory: URL
    private let now: @Sendable () -> Date
    private let closeAppendFile: @Sendable (FileHandle) throws -> Void
    private let removeOrphanFile: @Sendable (URL) throws -> Void
    private let removeSearchFile: @Sendable (URL) throws -> Void
    private let scheduleFileRemovalRetry: FileRemovalRetrySchedule
    private let logSearchFileRemovalFailure: @Sendable (String) -> Void
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
    private var fileRemovalToken: UUID?

    init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        closeAppendFile: @escaping @Sendable (FileHandle) throws -> Void = { try $0.close() },
        removeOrphanFile: @escaping @Sendable (URL) throws -> Void = { url in
            guard Darwin.unlink(url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        },
        removeSearchFile: @escaping @Sendable (URL) throws -> Void = { url in
            guard Darwin.unlink(url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        },
        scheduleFileRemovalRetry: @escaping FileRemovalRetrySchedule = { delay, action in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0, delay),
                execute: action
            )
        },
        logSearchFileRemovalFailure: @escaping @Sendable (String) -> Void = { _ in
            SearchDiagnosticStore.logger.error("search_diagnostics_delete_failed")
        }
    ) {
        self.directory = directory
        self.now = now
        self.closeAppendFile = closeAppendFile
        self.removeOrphanFile = removeOrphanFile
        self.removeSearchFile = removeSearchFile
        self.scheduleFileRemovalRetry = scheduleFileRemovalRetry
        self.logSearchFileRemovalFailure = logSearchFileRemovalFailure
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
    private static let fileRemovalRetryDelays: [TimeInterval] = [1, 5, 30]
    private static let temporaryFilePrefix = ".search-diagnostics-"
    private static let temporaryFileSuffix = ".tmp"
    private static let logger = Logger(
        subsystem: "com.napoleon.Napoleon",
        category: "search-diagnostics"
    )

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let length: Int64
    }

    private struct FileRemovalIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let fileType: mode_t
    }

    private enum FileError: Error {
        case unexpectedFile
    }

    private func createDirectory() {
        do {
            try DiagnosticFileSecurity.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            recordFileError(error)
        }
    }

    @discardableResult
    private func removeFile() -> Bool {
        let token = UUID()
        fileRemovalToken = token

        let expectedIdentity: FileRemovalIdentity
        do {
            guard let identity = try fileRemovalIdentity() else {
                clearFileRemoval(token: token)
                return true
            }
            expectedIdentity = identity
        } catch {
            recordFileError(error)
            clearFileRemoval(token: token)
            logSearchFileRemovalFailure("search_diagnostics_delete_failed")
            return false
        }

        return attemptFileRemoval(
            expectedIdentity: expectedIdentity,
            retryIndex: 0,
            token: token
        )
    }

    @discardableResult
    private func attemptFileRemoval(
        expectedIdentity: FileRemovalIdentity,
        retryIndex: Int,
        token: UUID
    ) -> Bool {
        guard fileRemovalToken == token else { return false }

        do {
            guard let currentIdentity = try fileRemovalIdentity() else {
                clearFileRemoval(token: token)
                return true
            }
            guard currentIdentity == expectedIdentity else {
                clearFileRemoval(token: token)
                return true
            }
            try removeSearchFile(fileURL)
            clearFileRemoval(token: token)
            return true
        } catch {
            if Self.isFileNotFound(error) {
                clearFileRemoval(token: token)
                return true
            }

            recordFileError(error)
            if retryIndex < Self.fileRemovalRetryDelays.count {
                let delay = Self.fileRemovalRetryDelays[retryIndex]
                scheduleFileRemovalRetry(delay) { [self] in
                    queue.async { [self] in
                        _ = attemptFileRemoval(
                            expectedIdentity: expectedIdentity,
                            retryIndex: retryIndex + 1,
                            token: token
                        )
                    }
                }
            } else {
                clearFileRemoval(token: token)
                logSearchFileRemovalFailure("search_diagnostics_delete_failed")
            }
            return false
        }
    }

    private func fileRemovalIdentity() throws -> FileRemovalIdentity? {
        var metadata = stat()
        guard Darwin.lstat(fileURL.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw currentPOSIXError()
        }
        let fileType = metadata.st_mode & S_IFMT
        guard fileType == S_IFREG || fileType == S_IFLNK else {
            throw FileError.unexpectedFile
        }
        return .init(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            fileType: fileType
        )
    }

    private func clearFileRemoval(token: UUID) {
        if fileRemovalToken == token {
            fileRemovalToken = nil
        }
    }

    private static func isFileNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
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
        guard Darwin.fchmod(descriptor, DiagnosticFileSecurity.fileMode) == 0 else {
            throw currentPOSIXError()
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
        guard Darwin.fchmod(descriptor, DiagnosticFileSecurity.fileMode) == 0 else {
            let error = currentPOSIXError()
            Darwin.close(descriptor)
            throw error
        }

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
    typealias ReportResourceValues = @Sendable (URL) throws -> URLResourceValues

    nonisolated static let defaultDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )
        .first!
        .appending(path: "Napoleon/Diagnostics", directoryHint: .isDirectory)

    nonisolated private static let retentionInterval: TimeInterval = 7_200

    private let directory: URL
    private let snapshot: @MainActor () -> DiagnosticSnapshot
    private let cachedThumbnail: @MainActor (WindowID) -> CGImage?
    private let commands: DiagnosticCommands
    private let searchStore: SearchDiagnosticStore
    private let now: @Sendable () -> Date
    private let reportResourceValues: ReportResourceValues
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
        now: @escaping @Sendable () -> Date = { Date() },
        reportResourceValues: @escaping ReportResourceValues = { url in
            try url.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isRegularFileKey
            ])
        }
    ) {
        self.directory = directory
        self.snapshot = snapshot
        self.cachedThumbnail = cachedThumbnail
        self.commands = commands
        self.searchStore = searchStore ?? SearchDiagnosticStore(directory: directory, now: now)
        self.now = now
        self.reportResourceValues = reportResourceValues

        self.searchStore.discard()
        let startupDate = now()
        let scheduleRemoval = commands.scheduleRemoval
        startupCleanup = Task.detached(priority: .utility) {
            try? Self.reconcileReports(
                in: directory,
                at: startupDate,
                scheduleRemoval: scheduleRemoval,
                resourceValues: reportResourceValues
            )
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
        try Task.checkCancellation()
        let zipURL = report.appendingPathExtension("zip")
        let zipDeadline = now().addingTimeInterval(Self.retentionInterval)
        do {
            try await commands.zip(report, zipURL)
            let scheduleRemoval = commands.scheduleRemoval
            try await Task.detached(priority: .utility) {
                try DiagnosticFileSecurity.secureRegularFile(at: zipURL)
                scheduleRemoval(zipURL, zipDeadline)
            }.value
        } catch is CancellationError {
            let scheduleRemoval = commands.scheduleRemoval
            let cleanupDate = now()
            await Task.detached(priority: .utility) {
                scheduleRemoval(zipURL, cleanupDate)
            }.value
            throw CancellationError()
        } catch {
            let scheduleRemoval = commands.scheduleRemoval
            let cleanupDate = now()
            await Task.detached(priority: .utility) {
                scheduleRemoval(zipURL, cleanupDate)
            }.value
            if error as? DiagnosticProcessRunnerError == .timedOut {
                throw DiagnosticsServiceError.zipTimedOut
            }
            throw DiagnosticsServiceError.zipFailed
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
        try Task.checkCancellation()
        let rootDirectory = directory
        let commands = commands
        let now = now
        let reportResourceValues = reportResourceValues
        let writer = Task.detached(priority: .utility) {
            try Self.reconcileReports(
                in: rootDirectory,
                at: generatedAt,
                scheduleRemoval: commands.scheduleRemoval,
                resourceValues: reportResourceValues
            )
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
        }
        let report = try await withTaskCancellationHandler {
            try await writer.value
        } onCancel: {
            writer.cancel()
        }
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
        try DiagnosticFileSecurity.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let report = rootDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try DiagnosticFileSecurity.createDirectory(
            at: report,
            withIntermediateDirectories: false
        )
        commands.scheduleRemoval(report, now().addingTimeInterval(retentionInterval))

        var errors: [String] = []
        try Task.checkCancellation()
        let logURL = report.appending(path: "napoleon.log")
        do {
            try await commands.exportUnifiedLog(logURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch DiagnosticCommandError.unifiedLogTruncated {
            errors.append("unified_log_truncated")
        } catch {
            errors.append("unified_log_export_failed")
        }
        if fileManager.fileExists(atPath: logURL.path) {
            try DiagnosticFileSecurity.secureRegularFile(at: logURL)
        }
        try Task.checkCancellation()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stateURL = report.appending(path: "state.json")
        try encoder.encode(snapshot).write(to: stateURL, options: .atomic)
        try DiagnosticFileSecurity.secureRegularFile(at: stateURL)

        if issue.includesSearch {
            try Task.checkCancellation()
            let searchURL = report.appending(path: "search.jsonl")
            let searchData = try await encodeSearchEvents(searchEvents)
            try Task.checkCancellation()
            try searchData.write(to: searchURL, options: .atomic)
            try DiagnosticFileSecurity.secureRegularFile(at: searchURL)
        }

        let allWindowIDs = Set(snapshot.apps.flatMap(\.windowIDs))
        let missingThumbnailWindowIDs = issue.includesThumbnails
            ? allWindowIDs.subtracting(thumbnails.keys).sorted()
            : []
        var failedThumbnailWindowIDs: [WindowID] = []
        if issue.includesThumbnails {
            let thumbnailDirectory = report.appending(path: "thumbnails", directoryHint: .isDirectory)
            try DiagnosticFileSecurity.createDirectory(
                at: thumbnailDirectory,
                withIntermediateDirectories: false
            )
            for windowID in thumbnails.keys.sorted() {
                try Task.checkCancellation()
                guard let image = thumbnails[windowID] else { continue }
                let imageURL = thumbnailDirectory.appending(path: "\(windowID).png")
                do {
                    try commands.encodePNG(image, imageURL)
                    try DiagnosticFileSecurity.secureRegularFile(at: imageURL)
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
        try Task.checkCancellation()
        let manifestURL = report.appending(path: "manifest.json")
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try DiagnosticFileSecurity.secureRegularFile(at: manifestURL)
        return report
    }

    nonisolated static func encodeSearchEvents(
        _ searchEvents: [DiagnosticSearchEvent]
    ) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for (index, event) in searchEvents.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
                await Task.yield()
            }
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try Task.checkCancellation()
        return data
    }

    nonisolated private static func reconcileReports(
        in directory: URL,
        at referenceDate: Date,
        scheduleRemoval: @Sendable (URL, Date) -> Void,
        resourceValues: ReportResourceValues
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }

        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isRegularFileKey
            ],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let isZIP = child.pathExtension == "zip"
            let stem = isZIP ? child.deletingPathExtension().lastPathComponent : child.lastPathComponent
            guard UUID(uuidString: stem) != nil else { continue }

            let values: URLResourceValues
            do {
                values = try resourceValues(child)
            } catch {
                if Self.isFileNotFound(error) { continue }
                scheduleRemoval(child, referenceDate)
                continue
            }
            guard (isZIP && values.isRegularFile == true)
                    || (!isZIP && values.isDirectory == true) else { continue }

            let originDate = values.creationDate ?? values.contentModificationDate ?? .distantPast
            let deadline = originDate.addingTimeInterval(retentionInterval)
            scheduleRemoval(child, deadline <= referenceDate ? referenceDate : deadline)
        }
    }

    nonisolated private static func isFileNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError
                    || error.code == NSFileReadNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
