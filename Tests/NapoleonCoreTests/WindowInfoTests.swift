import Testing
@testable import NapoleonCore

@Suite struct WindowInfoTests {
    @Test func searchHaystackLowercasesAndConcatenates() {
        let x = WindowInfo(id: 1, pid: 9, appName: "Safari", appBundleID: "com.apple.Safari", title: "Apple 官网", pinyinTitle: "Apple guanwang")
        #expect(x.searchHaystack.contains("safari"))
        #expect(x.searchHaystack.contains("guanwang"))
    }
}
