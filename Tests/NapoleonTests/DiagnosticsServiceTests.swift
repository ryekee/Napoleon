import CoreGraphics
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

    @Test func beginRemovesOnlyManagedOrphanTemporaryFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let regularOrphan = managedSearchTemporaryURL(in: directory)
        let symbolicLinkOrphan = managedSearchTemporaryURL(in: directory)
        let symbolicLinkTarget = directory.appending(path: "orphan-target")
        let invalidName = directory.appending(path: ".search-diagnostics-not-a-uuid.tmp")
        let matchingDirectory = managedSearchTemporaryURL(in: directory)
        try Data("private regular".utf8).write(to: regularOrphan)
        try Data("private target".utf8).write(to: symbolicLinkTarget)
        try FileManager.default.createSymbolicLink(at: symbolicLinkOrphan, withDestinationURL: symbolicLinkTarget)
        try Data("unrelated".utf8).write(to: invalidName)
        try FileManager.default.createDirectory(at: matchingDirectory, withIntermediateDirectories: false)

        let store = SearchDiagnosticStore(directory: directory)
        store.begin()
        _ = try await store.events(since: .distantPast)

        #expect(FileManager.default.fileExists(atPath: regularOrphan.path) == false)
        #expect(isSymbolicLink(at: symbolicLinkOrphan) == false)
        #expect(try String(contentsOf: symbolicLinkTarget, encoding: .utf8) == "private target")
        #expect(FileManager.default.fileExists(atPath: invalidName.path))
        #expect(FileManager.default.fileExists(atPath: matchingDirectory.path))
    }

    @Test func discardRemovesManagedOrphanTemporaryFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = managedSearchTemporaryURL(in: directory)
        try Data("private".utf8).write(to: orphan)
        let store = SearchDiagnosticStore(directory: directory)

        store.discard()
        _ = try await store.events(since: .distantPast)

        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
    }

    @Test func orphanCleanupFailureIsReportedExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = managedSearchTemporaryURL(in: directory)
        try Data("private".utf8).write(to: orphan)
        let store = SearchDiagnosticStore(
            directory: directory,
            removeOrphanFile: { _ in throw SearchStoreTestError.injectedOrphanCleanupFailure }
        )

        store.discard()
        var observedCleanupError = false
        do {
            _ = try await store.events(since: .distantPast)
        } catch SearchStoreTestError.injectedOrphanCleanupFailure {
            observedCleanupError = true
        }

        #expect(observedCleanupError)
        #expect(try await store.events(since: .distantPast).isEmpty)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func atomicRewriteReportsPrimaryErrorBeforeTemporaryCleanupFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SearchDiagnosticStore(
            directory: directory,
            now: { .searchDiagnosticTestNow },
            removeOrphanFile: { _ in throw SearchStoreTestError.injectedOrphanCleanupFailure }
        )
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))
        try await waitForSearchQueries(["first"], at: store.fileURL)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)

        store.append(.fixture(timestamp: .searchDiagnosticTestNow.addingTimeInterval(1), query: "second"))
        var observedPrimaryError = false
        do {
            _ = try await store.events(since: .distantPast)
        } catch let error as POSIXError {
            observedPrimaryError = error.code == .EISDIR
        }

        #expect(observedPrimaryError)
        #expect(try managedSearchTemporaryFiles(in: directory).isEmpty == false)
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

    @Test func consecutiveAppendsKeepTheSameFileIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SearchDiagnosticStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        store.begin()
        store.append(.fixture(timestamp: Date(timeIntervalSince1970: 10_000), query: "first"))
        try await waitForSearchLineCount(1, at: store.fileURL)
        let firstInode = try inode(at: store.fileURL)

        store.append(.fixture(timestamp: Date(timeIntervalSince1970: 10_001), query: "second"))
        try await waitForSearchLineCount(2, at: store.fileURL)
        let secondInode = try inode(at: store.fileURL)

        #expect(secondInode == firstInode)
    }

    @Test func deletedSearchFileIsRecoveredByTheSameAppend() async throws {
        let store = makeSearchStore()
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))
        try await waitForSearchQueries(["first"], at: store.fileURL)

        try FileManager.default.removeItem(at: store.fileURL)
        store.append(.fixture(timestamp: .searchDiagnosticTestNow.addingTimeInterval(1), query: "second"))

        try await waitForSearchQueries(["first", "second"], at: store.fileURL)
    }

    @Test func truncatedSearchFileIsRecoveredByTheSameAppend() async throws {
        let store = makeSearchStore()
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))
        try await waitForSearchQueries(["first"], at: store.fileURL)

        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow.addingTimeInterval(1), query: "second"))

        try await waitForSearchQueries(["first", "second"], at: store.fileURL)
    }

    @Test func replacedSearchFileIsRecoveredByTheSameAppend() async throws {
        let store = makeSearchStore()
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))
        try await waitForSearchQueries(["first"], at: store.fileURL)

        try Data("external replacement".utf8).write(to: store.fileURL, options: .atomic)
        store.append(.fixture(timestamp: .searchDiagnosticTestNow.addingTimeInterval(1), query: "second"))

        try await waitForSearchQueries(["first", "second"], at: store.fileURL)
    }

    @Test func symbolicLinkReplacementIsRecoveredWithoutTouchingItsTarget() async throws {
        let store = makeSearchStore()
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))
        try await waitForSearchQueries(["first"], at: store.fileURL)

        let targetURL = store.fileURL.deletingLastPathComponent().appending(path: "external-target")
        try Data("external target".utf8).write(to: targetURL)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: targetURL)
        store.append(.fixture(timestamp: .searchDiagnosticTestNow.addingTimeInterval(1), query: "second"))

        try await waitForSearchQueries(["first", "second"], at: store.fileURL)
        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "external target")
        #expect(isSymbolicLink(at: store.fileURL) == false)
    }

    @Test func recoveredFileErrorIsReportedExactlyOnce() async throws {
        let store = makeSearchStore()
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))
        try await waitForSearchQueries(["first"], at: store.fileURL)

        try FileManager.default.removeItem(at: store.fileURL)
        store.append(.fixture(timestamp: .searchDiagnosticTestNow.addingTimeInterval(1), query: "second"))

        var observedError = false
        do {
            _ = try await store.events(since: .distantPast)
        } catch {
            observedError = true
        }
        #expect(observedError)

        let events = try await store.events(since: .distantPast)
        #expect(events.map(\.query) == ["first", "second"])
    }

    @Test func appendCloseErrorIsReportedAndRecovered() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let closeFailure = OneShotCloseFailure()
        let store = SearchDiagnosticStore(
            directory: directory,
            now: { .searchDiagnosticTestNow },
            closeAppendFile: closeFailure.close
        )
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))

        var observedError = false
        do {
            _ = try await store.events(since: .distantPast)
        } catch {
            observedError = true
        }
        #expect(observedError)

        let events = try await store.events(since: .distantPast)
        #expect(events.map(\.query) == ["first"])
        #expect(try readSearchEvents(at: store.fileURL) == events)
    }

    @Test func pathDeletedDuringAppendCloseIsRecoveredByTheSameAppend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "search-diagnostics.jsonl")
        let closeMutation = DeletePathOnSecondClose(fileURL: fileURL)
        let store = SearchDiagnosticStore(
            directory: directory,
            now: { .searchDiagnosticTestNow },
            closeAppendFile: closeMutation.close
        )
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))
        try await waitForSearchQueries(["first"], at: store.fileURL)

        store.append(.fixture(timestamp: .searchDiagnosticTestNow.addingTimeInterval(1), query: "second"))

        try await waitForSearchQueries(["first", "second"], at: store.fileURL)
    }

    @Test func eventsRecoversAFileChangedAfterTheLastAppend() async throws {
        let store = makeSearchStore()
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))
        try await waitForSearchQueries(["first"], at: store.fileURL)
        try Data("external replacement".utf8).write(to: store.fileURL, options: .atomic)

        var observedError = false
        do {
            _ = try await store.events(since: .distantPast)
        } catch {
            observedError = true
        }
        #expect(observedError)
        try await waitForSearchQueries(["first"], at: store.fileURL)
        #expect(try await store.events(since: .distantPast).map(\.query) == ["first"])
    }

    @Test func eventsWithoutCleanupKeepsTheSameFileIdentity() async throws {
        let store = makeSearchStore()
        store.begin()
        store.append(.fixture(timestamp: .searchDiagnosticTestNow, query: "first"))
        try await waitForSearchQueries(["first"], at: store.fileURL)
        let firstInode = try inode(at: store.fileURL)

        _ = try await store.events(since: .distantPast)

        #expect(try inode(at: store.fileURL) == firstInode)
    }

    @Test func oneThousandAppendsRemainCompleteAndDecodable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = SearchDiagnosticStore(
            directory: directory,
            now: { Date(timeIntervalSince1970: 20_000) }
        )
        store.begin()
        for index in 0..<1_000 {
            store.append(.fixture(
                timestamp: Date(timeIntervalSince1970: 20_000 + Double(index)),
                query: "query-\(index)"
            ))
        }

        try await waitForSearchLineCount(1_000, at: store.fileURL, attempts: 6_000)
        let appendedEvents = try readSearchEvents(at: store.fileURL)
        #expect(appendedEvents.count == 1_000)
        #expect(appendedEvents.first?.query == "query-0")
        #expect(appendedEvents.last?.query == "query-999")

        let events = try await store.events(since: .distantPast)
        #expect(events.count == 1_000)
        #expect(events.first?.query == "query-0")
        #expect(events.last?.query == "query-999")
        #expect(appendedEvents == events)
    }

    @MainActor @Test func generalReportExcludesSensitiveFilesAndTitles() async throws {
        let report = try await makeService(issue: .general).prepareReportDirectory()
        let state = try String(contentsOf: report.appending(path: "state.json"), encoding: .utf8)
        #expect(state.contains("Secret A") == false)
        #expect(FileManager.default.fileExists(atPath: report.appending(path: "search.jsonl").path) == false)
        #expect(FileManager.default.fileExists(atPath: report.appending(path: "thumbnails").path) == false)
    }

    @MainActor @Test func searchReportAddsTitlesButNotThumbnails() async throws {
        let report = try await makeService(issue: .search, query: "f").prepareReportDirectory()
        #expect(try String(contentsOf: report.appending(path: "search.jsonl")).contains("Secret A"))
        #expect(FileManager.default.fileExists(atPath: report.appending(path: "thumbnails").path) == false)
    }

    @MainActor @Test func searchReportWritesOneDecodableEventPerLine() async throws {
        let report = try await makeService(issue: .search, query: "f").prepareReportDirectory()
        let contents = try String(contentsOf: report.appending(path: "search.jsonl"), encoding: .utf8)
        let lines = contents.split(separator: "\n")

        #expect(lines.count == 1)
        let event = try JSONDecoder().decode(DiagnosticSearchEvent.self, from: Data(lines[0].utf8))
        #expect(event.query == "f")
        #expect(event.results.map(\.windowTitle) == ["Secret A"])
    }

    @MainActor @Test func thumbnailReportUsesOnlyCacheHits() async throws {
        let service = try await makeService(issue: .thumbnail, cachedIDs: [42])
        let report = try await service.prepareReportDirectory()
        #expect(FileManager.default.fileExists(atPath: report.appending(path: "thumbnails/42.png").path))
        #expect(try manifest(at: report).missingThumbnailWindowIDs == [43])
    }

    @MainActor @Test func generalModeDoesNotCreateSensitiveSearchStorage() async throws {
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
            now: { Date() }
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

    private enum StubError: Error { case failed }

    @MainActor @Test func unifiedLogFailureStillProducesStateAndManifestError() async throws {
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

    @MainActor @Test func onePNGFailureDoesNotDiscardOtherCacheHits() async throws {
        let commands = DiagnosticCommands(
            exportUnifiedLog: { url in try Data("log".utf8).write(to: url) },
            encodePNG: { image, url in
                if url.lastPathComponent == "42.png" {
                    try Data("partial png".utf8).write(to: url)
                    throw StubError.failed
                }
                try DiagnosticCommands.live.encodePNG(image, url)
            },
            zip: { _, zipURL in try Data("zip".utf8).write(to: zipURL) }
        )
        let service = try await makeService(issue: .thumbnail, cachedIDs: [42, 43], commands: commands)
        let report = try await service.prepareReportDirectory()
        #expect(FileManager.default.fileExists(atPath: report.appending(path: "thumbnails/43.png").path))
        #expect(FileManager.default.fileExists(atPath: report.appending(path: "thumbnails/42.png").path) == false)
        #expect(try manifest(at: report).failedThumbnailWindowIDs == [42])
    }

    @Test func liveLogExportNeverRequestsPrivateExpansion() {
        #expect(DiagnosticCommands.unifiedLogArguments == [
            "show", "--last", "2h", "--style", "compact", "--info", "--debug",
            "--predicate", "subsystem == \"com.napoleon.Napoleon\""
        ])
        #expect(DiagnosticCommands.unifiedLogArguments.contains("--privacy") == false)
    }

    @MainActor @Test func zipFailureKeepsUncompressedDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let service = DiagnosticsService(
            directory: directory,
            snapshot: snapshot,
            cachedThumbnail: { _ in nil },
            commands: .init(
                exportUnifiedLog: { url in try Data("log".utf8).write(to: url) },
                encodePNG: DiagnosticCommands.live.encodePNG,
                zip: { _, zipURL in
                    try Data("partial zip".utf8).write(to: zipURL)
                    throw StubError.failed
                }
            ),
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        await #expect(throws: StubError.self) { try await service.prepareReport() }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(children.contains { $0.hasDirectoryPath })
        #expect(children.contains { $0.pathExtension == "zip" } == false)
    }

    @MainActor @Test func handoffAllowsSearchToBeExplicitlyEnabledAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let searchStore = SearchDiagnosticStore(directory: directory)
        let service = DiagnosticsService(
            directory: directory,
            snapshot: snapshot,
            cachedThumbnail: { _ in nil },
            commands: .init(
                exportUnifiedLog: { url in try Data("log".utf8).write(to: url) },
                encodePNG: DiagnosticCommands.live.encodePNG,
                zip: { _, zipURL in try Data("zip".utf8).write(to: zipURL) }
            ),
            searchStore: searchStore,
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let window = WindowInfo(
            id: 42,
            pid: 10,
            appName: "Finder",
            appBundleID: "com.apple.finder",
            title: "Secret A"
        )

        service.selectIssue(.search)
        service.recordSearch(query: "first", results: [window])
        _ = try await service.prepareReport()
        service.reportWasHandedOff()

        service.selectIssue(.search)
        service.recordSearch(query: "second", results: [window])
        let events = try await searchStore.events(since: .distantPast)
        #expect(events.map(\.query) == ["second"])
    }
}

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

@MainActor
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

private extension Date {
    static let searchDiagnosticTestNow = Date(timeIntervalSince1970: 20_000)
}

private enum SearchStoreTestError: Error {
    case injectedOrphanCleanupFailure
    case missingInode
    case injectedCloseFailure
    case timedOutWaitingForLineCount(Int)
}

private final class OneShotCloseFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func close(_ handle: FileHandle) throws {
        let failsNow = lock.withLock {
            defer { shouldFail = false }
            return shouldFail
        }
        if failsNow {
            throw SearchStoreTestError.injectedCloseFailure
        }
        try handle.close()
    }
}

private final class DeletePathOnSecondClose: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var closeCount = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func close(_ handle: FileHandle) throws {
        try handle.close()
        let shouldDelete = lock.withLock {
            closeCount += 1
            return closeCount == 2
        }
        if shouldDelete {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

private func makeSearchStore() -> SearchDiagnosticStore {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    return SearchDiagnosticStore(directory: directory, now: { .searchDiagnosticTestNow })
}

private func managedSearchTemporaryURL(in directory: URL) -> URL {
    directory.appending(path: ".search-diagnostics-\(UUID().uuidString).tmp")
}

private func managedSearchTemporaryFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(".search-diagnostics-") && $0.pathExtension == "tmp" }
}

private func inode(at fileURL: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    guard let inode = attributes[.systemFileNumber] as? NSNumber else {
        throw SearchStoreTestError.missingInode
    }
    return inode.uint64Value
}

private func waitForSearchLineCount(
    _ expectedCount: Int,
    at fileURL: URL,
    attempts: Int = 200
) async throws {
    for _ in 0..<attempts {
        if let contents = try? String(contentsOf: fileURL, encoding: .utf8),
           contents.split(separator: "\n").count == expectedCount {
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw SearchStoreTestError.timedOutWaitingForLineCount(expectedCount)
}

private func readSearchEvents(at fileURL: URL) throws -> [DiagnosticSearchEvent] {
    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    return try contents.split(separator: "\n").map {
        try JSONDecoder().decode(DiagnosticSearchEvent.self, from: Data($0.utf8))
    }
}

private func waitForSearchQueries(_ queries: [String], at fileURL: URL) async throws {
    for _ in 0..<200 {
        if let events = try? readSearchEvents(at: fileURL), events.map(\.query) == queries {
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw SearchStoreTestError.timedOutWaitingForLineCount(queries.count)
}

private func isSymbolicLink(at fileURL: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)) != nil
}
