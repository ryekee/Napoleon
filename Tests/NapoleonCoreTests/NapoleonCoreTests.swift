import Testing
@testable import NapoleonCore

@Suite struct NapoleonCoreSmokeTests {
    @Test func coreModuleLoads() {
        #expect(napoleonCoreLoaded == true)
    }
}
