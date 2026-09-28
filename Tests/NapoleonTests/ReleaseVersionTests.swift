import Testing
@testable import Napoleon

@Suite struct ReleaseVersionTests {
    @Test func parsesLeadingVPrefixAndDottedComponents() {
        #expect(ReleaseVersion.numericComponents("v1.2.3") == [1, 2, 3])
        #expect(ReleaseVersion.numericComponents("1.2.3") == [1, 2, 3])
        #expect(ReleaseVersion.numericComponents("V0.1") == [0, 1])
    }

    @Test func stopsAtFirstNonNumericComponent() {
        // "1.2.beta.4" 里的 4 不能被误当成 patch 号。
        #expect(ReleaseVersion.numericComponents("1.2.beta.4") == [1, 2])
        // 但同一段内的前导数字要取到（"3-beta" → 3）。
        #expect(ReleaseVersion.numericComponents("1.2.3-beta.1") == [1, 2, 3])
    }

    @Test func garbageParsesToEmpty() {
        #expect(ReleaseVersion.numericComponents("") == [])
        #expect(ReleaseVersion.numericComponents("nightly") == [])
    }

    @Test func comparesComponentwiseNotLexicographically() {
        // 字符串比较会说 "0.9" > "0.10"，数字比较必须说反过来。
        #expect(ReleaseVersion.isNewer("0.10.0", than: "0.9.0"))
        #expect(!ReleaseVersion.isNewer("0.9.0", than: "0.10.0"))
        #expect(ReleaseVersion.isNewer("2.0.0", than: "1.99.99"))
    }

    @Test func missingComponentsCountAsZero() {
        #expect(!ReleaseVersion.isNewer("1.2", than: "1.2.0"))
        #expect(ReleaseVersion.isNewer("1.2.1", than: "1.2"))
    }

    @Test func equalVersionsAreNotNewer() {
        #expect(!ReleaseVersion.isNewer("1.0.0", than: "1.0.0"))
        #expect(!ReleaseVersion.isNewer("v1.0.0", than: "1.0.0"))
    }

    @Test func prereleaseIsNotConsideredNewerThanSameRelease() {
        // 刻意的取舍：不把用户从正式版推去预发布版（见 ReleaseVersion 文档）。
        #expect(!ReleaseVersion.isNewer("1.1.0-beta", than: "1.1.0"))
        // 带序号的预发布同理——`.1` 是 beta 序号，不能被当成第四位版本号。
        #expect(!ReleaseVersion.isNewer("1.1.0-beta.1", than: "1.1.0"))
        // 但 1.2.0-beta 的数字部分确实更大，仍会判定为更新——真正挡住预发布版的是
        // 更新检查的正式版本校验，不是这个宽松的版本比较函数。
        #expect(ReleaseVersion.isNewer("1.2.0-beta", than: "1.1.0"))
    }

    @Test func malformedVersionNeverTriggersUpdatePrompt() {
        // 畸形 tag 不能让用户反复看到「有新版本」。
        #expect(!ReleaseVersion.isNewer("nightly", than: "1.0.0"))
        #expect(!ReleaseVersion.isNewer("1.0.0", than: "nightly"))
    }
}

// 隔离的 URLProtocol fixture：验证真实请求路径、错误分支与旧版兼容。
import Foundation

private final class UpdateFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct UpdateCheckerTests {
    private func run(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) async -> UpdateState {
        UpdateFixtureProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            UpdateFixtureProtocol.handler = nil
        }
        let checker = UpdateChecker(session: session)
        await checker.check()
        return checker.state
    }

    private static func response(_ request: URLRequest, status: Int = 200, body: String = "", url: URL? = nil) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    @Test func staticManifestDetectsUpdateWithoutAPI() async {
        let state = await run { request in
            #expect(request.url?.absoluteString == "https://github.com/ryekee/Napoleon/releases/latest/download/update.json")
            #expect(request.httpMethod == "GET")
            return Self.response(request, body: #"{"schemaVersion":1,"version":"999.0.0","notes":" Changes "}"#)
        }
        #expect(state == .available(version: "999.0.0", notes: "Changes", url: URL(string: "https://github.com/ryekee/Napoleon/releases/tag/v999.0.0")!))
    }

    @Test func missingManifestUsesWebRedirect() async {
        var requests = 0
        let state = await run { request in
            requests += 1
            #expect(request.url?.host == "github.com")
            if requests == 1 { return Self.response(request, status: 404) }
            #expect(request.httpMethod == "HEAD")
            #expect(request.url?.path == "/ryekee/Napoleon/releases/latest")
            return Self.response(request, url: URL(string: "https://github.com/ryekee/Napoleon/releases/tag/v999.0.0")!)
        }
        #expect(requests == 2)
        #expect(state == .available(version: "v999.0.0", notes: "", url: URL(string: "https://github.com/ryekee/Napoleon/releases/tag/v999.0.0")!))
    }

    @Test func olderManifestIsUpToDate() async {
        let state = await run { Self.response($0, body: #"{"schemaVersion":1,"version":"0.0.0"}"#) }
        guard case .upToDate = state else { Issue.record("Expected upToDate, got \(state)"); return }
    }

    @Test(arguments: [403, 429, 500])
    func httpErrorsDoNotFallbackOrMislabel403(_ status: Int) async {
        var requests = 0
        let state = await run { request in
            requests += 1
            return Self.response(request, status: status)
        }
        #expect(requests == 1)
        guard case .failed(let message) = state else { Issue.record("Expected failure"); return }
        if status == 403 {
            #expect(message == String(localized: "Update server denied access (HTTP 403)"))
        }
        if status == 429 {
            #expect(message == String(localized: "Too many update requests — try again later"))
        }
    }

    @Test(arguments: [
        "{}",
        #"{"schemaVersion":2,"version":"999.0.0"}"#,
        #"{"schemaVersion":1,"version":"999.0.0-beta"}"#,
        #"{"schemaVersion":1,"version":"garbage"}"#,
        #"{"schemaVersion":1,"version":"999.999999999999999999999999999999999"}"#,
        "<html>error</html>"
    ])
    func invalidManifestFails(_ body: String) async {
        let state = await run { Self.response($0, body: body) }
        #expect(state == .failed(String(localized: "Invalid update information")))
    }

    @Test(arguments: [
        "https://example.com/ryekee/Napoleon/releases/tag/v999.0.0",
        "https://github.com/ryekee/other/releases/tag/v999.0.0",
        "https://github.com/ryekee/Napoleon/releases/latest",
        "https://github.com/ryekee/Napoleon/releases/tag/v999.0.0-beta"
    ])
    func invalidFallbackFails(_ url: String) async {
        let state = await run { request in
            if request.httpMethod == "GET" { return Self.response(request, status: 404) }
            return Self.response(request, url: URL(string: url)!)
        }
        #expect(state == .failed(String(localized: "Invalid update information")))
    }

    @Test func networkFailureIsNotUpToDate() async {
        let state = await run { _ in throw URLError(.notConnectedToInternet) }
        guard case .failed = state else { Issue.record("Expected network failure"); return }
    }
}
