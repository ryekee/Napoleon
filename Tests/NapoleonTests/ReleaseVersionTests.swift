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
        // `/releases/latest` 端点本身（按定义只返回正式版），不是版本号字符串。
        #expect(ReleaseVersion.isNewer("1.2.0-beta", than: "1.1.0"))
    }

    @Test func malformedVersionNeverTriggersUpdatePrompt() {
        // 畸形 tag 不能让用户反复看到「有新版本」。
        #expect(!ReleaseVersion.isNewer("nightly", than: "1.0.0"))
        #expect(!ReleaseVersion.isNewer("1.0.0", than: "nightly"))
    }
}
