import Dispatch
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

    @Test func inactiveStoreDoesNotTouchExistingSearchFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "search-diagnostics.jsonl", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: fileURL)

        let store = SearchDiagnosticStore(directory: directory, now: Date.init)
        _ = try await store.events(since: .distantPast)

        #expect(FileManager.default.fileExists(atPath: store.fileURL.path) == true)
    }

    @Test func discardDeletesItsQueuedSensitiveFileAfterStoreIsReleased() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let appendStarted = DispatchSemaphore(value: 0)
        let allowAppendToFinish = DispatchSemaphore(value: 0)
        let now: @Sendable () -> Date = {
            appendStarted.signal()
            allowAppendToFinish.wait()
            return Date(timeIntervalSince1970: 7_201)
        }
        var store: SearchDiagnosticStore? = SearchDiagnosticStore(directory: directory, now: now)
        let fileURL = try #require(store?.fileURL)

        store?.begin()
        store?.append(.fixture(timestamp: Date(timeIntervalSince1970: 7_201), query: "private"))
        #expect(appendStarted.wait(timeout: .now() + 1) == .success)
        store?.discard()
        store = nil
        allowAppendToFinish.signal()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test func discardRemovesDanglingSymbolicLink() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SearchDiagnosticStore(directory: directory, now: Date.init)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: store.fileURL,
            withDestinationURL: directory.appending(path: "missing", directoryHint: .notDirectory)
        )

        store.discard()
        _ = try await store.events(since: .distantPast)

        var linkExists = true
        do {
            _ = try FileManager.default.destinationOfSymbolicLink(atPath: store.fileURL.path)
        } catch {
            linkExists = false
        }
        #expect(linkExists == false)
    }

    @Test func exactTwoHourExpiryRemovesTheEvent() async throws {
        let now = Date(timeIntervalSince1970: 7_200)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SearchDiagnosticStore(directory: directory, now: { now })
        store.begin()
        store.append(.fixture(timestamp: Date(timeIntervalSince1970: 0), query: "expired"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let events = try await store.events(since: .distantPast)
        #expect(events.isEmpty)
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
