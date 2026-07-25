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

/// Task 21+：通过 GitHub Releases API 检查是否有新版本。
///
/// **只检查，不下载安装**——发现新版只提供「前往下载」打开 Release 页面。真正的自动更新
/// （下载 + 校验签名 + 替换 App + 重启）是独立的一块，需要 Sparkle 或自写更新器 + 公证/签名
/// 配套，等发布流程稳定后再做；本类型给那一步打好基础（版本比较、Release 元数据获取）。
///
/// **无鉴权调用**：GitHub 对未鉴权请求限流 60 次/小时/IP。手动点按钮的量级完全够用，因此不
/// 引入 token（也就不必处理 token 的存储与泄漏问题）。
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

    /// 查一次最新 Release。重复点击时若已在查询中直接忽略（避免并发请求把限流额度打光）。
    func check() async {
        guard state != .checking else { return }

        guard let repository = Self.repository else {
            state = .notConfigured
            return
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            state = .failed(String(localized: "Invalid update source: \(repository)"))
            return
        }

        state = .checking

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub 要求带 User-Agent，否则可能被拒。
        request.setValue("Napoleon/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.timeout

        do {
            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                state = .failed(Self.message(forStatus: http.statusCode))
                Self.logger.error("update check failed: HTTP \(http.statusCode, privacy: .public)")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            // 不需要自己过滤草稿/预发布：GitHub 的 `/releases/latest` 端点**按定义**返回的就是
            // 最新的非 draft、非 prerelease release（这也是选它而不是 `/releases` 的原因）。
            // 之前这里有一个 `guard !draft, !prerelease` 的死判断，而且一旦命中还会谎报「已是
            // 最新」——真要改用 `/releases`，得挑出最新的正式版，而不是在这里 return。

            let latest = release.tagName
            guard ReleaseVersion.isNewer(latest, than: currentVersion) else {
                state = .upToDate(current: currentVersion)
                return
            }
            guard let pageURL = URL(string: release.htmlURL) else {
                state = .failed(String(localized: "Invalid release page URL"))
                return
            }

            state = .available(
                version: latest,
                notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                url: pageURL
            )
        } catch is DecodingError {
            state = .failed(String(localized: "Could not read GitHub’s response"))
            Self.logger.error("update check: decoding failed")
        } catch {
            // 网络不可达/超时/被取消都会落到这里——原样把系统给的描述展示出来，用户能据此
            // 判断是自己断网还是服务端问题。
            state = .failed(error.localizedDescription)
            Self.logger.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func message(forStatus status: Int) -> String {
        switch status {
        case 404: return String(localized: "No releases published yet")
        // 403 = primary rate limit，429 = secondary rate limit，对用户是同一件事。
        case 403, 429: return String(localized: "Too many requests — try again later (GitHub rate limit)")
        default: return String(localized: "GitHub returned an error (HTTP \(status))")
        }
    }

    /// GitHub Releases API 响应里我们用到的字段（其余忽略）。
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, draft, prerelease
        }
    }
}
