import Testing
@testable import Napoleon

// `CFStringTransform` (kCFStringTransformMandarinLatin then kCFStringTransformStripDiacritics) is a
// system API — no need to fake it, this exercises the real transform.
@Suite struct PinyinTransformerTests {
    @Test func chineseTitleProducesLowercasePinyinContainingExpectedSyllables() throws {
        let result = PinyinTransformer.pinyin(for: "购物清单")

        let pinyin = try #require(result)
        #expect(pinyin == pinyin.lowercased())
        #expect(pinyin.contains("gou"))
        #expect(pinyin.contains("wu"))
        #expect(pinyin.contains("qing"))
        #expect(pinyin.contains("dan"))
    }

    @Test func nonChineseTextReturnsNil() {
        #expect(PinyinTransformer.pinyin(for: "Safari") == nil)
    }

    @Test func localizedFinderNameProducesSearchableInitial() throws {
        let result = try #require(PinyinTransformer.pinyin(for: "访达"))
        #expect(result.contains("fang"))
        #expect(result.hasPrefix("f"))
    }
}
