import Foundation
import os

/// 版本号比较（纯逻辑，可单测）——`UpdateChecker` 用它判断 GitHub Release 的 tag 是不是比当前
/// 构建更新。
///
/// **格式假设**：`v0.1.0` / `0.1.0` / `1.2` / `1.2.3-beta.1` 都能解析——去掉前导 `v`，按 `.` 切开，
/// 每段取前导数字（`3-beta` → `3`），缺失的段按 0 补齐（`1.2` == `1.2.0`）。
///
/// **预发布版本刻意不特殊处理**：`1.1.0-beta` 与 `1.1.0` 的数字部分相同，因此判定为「不更新」——
/// 宁可漏推一个 beta，也不要把用户从正式版推去预发布版。等真要发 beta 通道时再单独设计。
enum ReleaseVersion {
    /// `candidate` 是否严格新于 `current`。任一方解析不出任何数字段时返回 `false`
    /// （宁可不提示更新，也不要因为一个畸形 tag 反复弹「有新版本」）。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = numericComponents(candidate)
        let rhs = numericComponents(current)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }

        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false // 完全相等
    }

    /// `"v1.2.3-beta"` → `[1, 2, 3]`。非数字开头的段（`"beta"`）在此终止解析——`"1.2.beta.4"`
    /// 解析成 `[1, 2]`，不会把后面的 `4` 误当成 patch 号。
    static func numericComponents(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed

        var result: [Int] = []
        for part in withoutPrefix.split(separator: ".") {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            result.append(value)
            // 这一段带非数字后缀（`3-beta`）说明版本号的数字部分到此为止，后面是预发布标识
            // （`1.2.3-beta.1` 的 `.1` 是 beta 序号，不是第四位版本号）——继续解析会把它当成
            // 更高的版本，从而把用户从 `1.2.3` 推去 `1.2.3-beta.1`，正是要避免的。
            if digits.count != part.count { break }
        }
        return result
    }
}

/// 检查更新的结果状态。
enum UpdateState: Equatable {
    /// 还没查过。
    case idle
    case checking
    /// 已是最新（附当前版本，供界面显示）。
    case upToDate(current: String)
    /// 有新版本：版本号、更新说明（Release body，可能为空）、Release 页面地址。
    case available(version: String, notes: String, url: URL)
    /// 查询失败（网络、限流、仓库还没有任何 Release 等），附给用户看的原因。
    case failed(String)
    /// 更新源还没配置（`UpdateChecker.repository == nil`）——显式告诉用户，而不是静默失败或
    /// 假装「已是最新」。
    case notConfigured
}

/// 从 Release 附件 update.json 检查正式版本，不使用匿名 REST API 的共享 IP 配额。
/// 旧 Release 没有清单时，仅通过 releases/latest 的网页跳转兼容。
/// 只检查版本并打开 Release 页面，不下载或安装应用。
@MainActor
final class UpdateChecker: ObservableObject {
    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "UpdateChecker")

    /// 更新源仓库（`"owner/repo"`）。置 `nil` 时「检查更新」不发起任何网络请求，界面显示
    /// 「更新源未配置」——发布流程还没跑通时不要让用户看到一个必然失败的按钮。
    static let repository: String? = "ryekee/Napoleon"

    /// 网络超时——检查更新是用户主动触发的前台操作，卡太久不如早点报错让他重试。
    private static let timeout: TimeInterval = 15

    @Published private(set) var state: UpdateState = .idle

    /// 当前构建的版本号（`CFBundleShortVersionString`，如 `0.1.0`）。
    let currentVersion: String
    /// 当前构建号（`CFBundleVersion`）——只用于展示，不参与更新判定（判定看面向用户的版本号）。
    let currentBuild: String

    private let session: URLSession

    init(bundle: Bundle = .main, session: URLSession = .shared) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        self.session = session
    }

    /// 查一次最新 Release，查询中忽略重复点击。
    func check() async {
        guard state != .checking else { return }

        guard let repository = Self.repository else {
            state = .notConfigured
            return
        }
        state = .checking
        do {
            let manifestURL = URL(string: "https://github.com/\(repository)/releases/latest/download/update.json")!
            let (data, response) = try await fetch(manifestURL)
            let version: String
            let notes: String
            let pageURL: URL

            if response.statusCode == 404 {
                // 兼容尚未附带清单的历史正式版；只读取重定向后的 URL，不解析 HTML。
                let latestURL = URL(string: "https://github.com/\(repository)/releases/latest")!
                let (_, latestResponse) = try await fetch(latestURL, method: "HEAD")
                guard latestResponse.statusCode == 200 else {
                    throw UpdateError.http(latestResponse.statusCode)
                }
                guard let url = latestResponse.url,
                      url.scheme == "https", url.host == "github.com",
                      url.query == nil, url.fragment == nil,
                      url.path.hasPrefix("/\(repository)/releases/tag/") else {
                    throw UpdateError.invalid
                }
                let tag = String(url.path.dropFirst("/\(repository)/releases/tag/".count))
                guard Self.isStableVersion(tag) else { throw UpdateError.invalid }
                version = tag
                notes = ""
                pageURL = url
            } else {
                guard response.statusCode == 200 else { throw UpdateError.http(response.statusCode) }
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                guard manifest.schemaVersion == 1, Self.isStableVersion(manifest.version) else {
                    throw UpdateError.invalid
                }
                version = manifest.version
                notes = manifest.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // 下载入口由固定仓库和已校验的版本构造，清单不能提供任意跳转地址。
                pageURL = URL(string: "https://github.com/\(repository)/releases/tag/v\(version.hasPrefix("v") ? String(version.dropFirst()) : version)")!
            }

            if ReleaseVersion.isNewer(version, than: currentVersion) {
                state = .available(version: version, notes: notes, url: pageURL)
            } else {
                state = .upToDate(current: currentVersion)
            }
        } catch let error as UpdateError {
            switch error {
            case .http(let status):
                state = .failed(Self.message(forStatus: status))
                Self.logger.error("update check failed: HTTP \(status, privacy: .public)")
            case .invalid:
                state = .failed(String(localized: "Invalid update information"))
            }
        } catch is DecodingError {
            state = .failed(String(localized: "Invalid update information"))
        } catch {
            state = .failed(error.localizedDescription)
            Self.logger.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetch(_ url: URL, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("Napoleon/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalid }
        return (data, http)
    }

    private static func isStableVersion(_ version: String) -> Bool {
        version.range(of: #"^v?[0-9]+(?:\.[0-9]+){1,3}$"#, options: .regularExpression) != nil
            && ReleaseVersion.numericComponents(version).count == version.split(separator: ".").count
    }

    private static func message(forStatus status: Int) -> String {
        switch status {
        case 404: return String(localized: "No releases published yet")
        case 403: return String(localized: "Update server denied access (HTTP 403)")
        case 429: return String(localized: "Too many update requests — try again later")
        default: return String(localized: "GitHub returned an error (HTTP \(status))")
        }
    }

    private enum UpdateError: Error {
        case http(Int)
        case invalid
    }

    private struct UpdateManifest: Decodable {
        let schemaVersion: Int
        let version: String
        let notes: String?
    }
}
