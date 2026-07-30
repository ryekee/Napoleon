import Testing
@testable import NapoleonCore

@Suite struct WindowInfoTests {
    @Test func searchHaystackLowercasesAndConcatenates() {
        let x = WindowInfo(
            id: 1,
            pid: 9,
            appName: "访达",
            appBundleID: "com.apple.finder",
            title: "Apple 官网",
            pinyinAppName: "fang da",
            pinyinTitle: "Apple guanwang"
        )
        #expect(x.searchHaystack.contains("访达"))
        #expect(x.searchHaystack.contains("fang da"))
        #expect(x.searchHaystack.contains("guanwang"))
    }
}
