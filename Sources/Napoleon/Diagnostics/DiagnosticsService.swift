import Dispatch
import Foundation
import NapoleonCore

enum DiagnosticIssue: String, CaseIterable, Identifiable, Codable {
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

final class SearchDiagnosticStore {
    let fileURL: URL

    private let directory: URL
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.ryekee.napoleon.search-diagnostics", qos: .utility)
    private var isActive = false
    private var storedEvents: [DiagnosticSearchEvent] = []
    private var expiryTimer: DispatchSourceTimer?
    private var mostRecentFileError: Error?

    init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
        fileURL = directory.appending(path: "search-diagnostics.jsonl", directoryHint: .notDirectory)
        queue.async { [weak self] in
            self?.removeFile()
        }
    }

    func begin() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isActive = true
            self.storedEvents.removeAll()
            self.cancelExpiryTimer()
            self.mostRecentFileError = nil
            self.removeFile()
            self.createDirectory()
        }
    }

    func append(_ event: DiagnosticSearchEvent) {
        queue.async { [weak self] in
            guard let self, self.isActive else { return }

            self.storedEvents.append(event)
            if let newestTimestamp = self.storedEvents.map(\.timestamp).max() {
                self.removeEvents(olderThan: newestTimestamp.addingTimeInterval(-Self.retentionInterval))
            }
            self.writeEvents()
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
                    if let error = self.mostRecentFileError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: [])
                    }
                    return
                }

                self.removeEvents(olderThan: cutoff)
                self.writeEvents()
                self.scheduleNextExpiry()

                if let error = self.mostRecentFileError {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: self.storedEvents)
                }
            }
        }
    }

    func discard() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isActive = false
            self.storedEvents.removeAll()
            self.cancelExpiryTimer()
            self.removeFile()
        }
    }

    private static let retentionInterval: TimeInterval = 7_200

    private func createDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            mostRecentFileError = error
        }
    }

    private func removeFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            mostRecentFileError = error
        }
    }

    // ponytail: 搜索诊断由用户临时启用，事件量按低千级上限处理；只有现场数据证明更大时才改分段文件。
    private func writeEvents() {
        guard !storedEvents.isEmpty else {
            removeFile()
            return
        }

        createDirectory()

        do {
            let encoder = JSONEncoder()
            let lines = try storedEvents.map { event in
                String(decoding: try encoder.encode(event), as: UTF8.self)
            }
            let data = Data(lines.joined(separator: "\n").utf8)
            try data.write(to: fileURL, options: .atomic)
            mostRecentFileError = nil
        } catch {
            mostRecentFileError = error
        }
    }

    private func removeEvents(olderThan cutoff: Date) {
        storedEvents.removeAll { $0.timestamp < cutoff }
    }

    private func scheduleNextExpiry() {
        cancelExpiryTimer()

        guard let earliestTimestamp = storedEvents.map(\.timestamp).min() else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let delay = max(0, earliestTimestamp.addingTimeInterval(Self.retentionInterval).timeIntervalSince(now()))
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.removeEvents(olderThan: self.now().addingTimeInterval(-Self.retentionInterval))
            self.writeEvents()
            self.scheduleNextExpiry()
        }
        expiryTimer = timer
        timer.resume()
    }

    private func cancelExpiryTimer() {
        expiryTimer?.setEventHandler {}
        expiryTimer?.cancel()
        expiryTimer = nil
    }
}
