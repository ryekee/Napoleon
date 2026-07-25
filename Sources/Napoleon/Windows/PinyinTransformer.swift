import Foundation

/// 中文（含日韩汉字）标题 → 拼音，供窗口搜索按拼音匹配。用系统 `CFStringTransform`：
/// 先 `kCFStringTransformMandarinLatin` 把汉字转成带声调拼音（音节间空格分隔），
/// 再 `kCFStringTransformStripDiacritics` 去声调，得到形如 `"gou wu qing dan"` 的串。
///
/// 输入不含任何汉字（CJK 统一表意文字及其扩展区）时直接返回 nil——纯英文/数字标题
/// 没必要额外存一份拼音，`WindowInfo.pinyinTitle` 留空即可。
enum PinyinTransformer {
    static func pinyin(for text: String) -> String? {
        guard containsHanCharacter(text) else { return nil }

        let mutable = NSMutableString(string: text)
        var range = CFRangeMake(0, CFStringGetLength(mutable))
        guard CFStringTransform(mutable, &range, kCFStringTransformMandarinLatin, false) else { return nil }

        range = CFRangeMake(0, CFStringGetLength(mutable))
        CFStringTransform(mutable, &range, kCFStringTransformStripDiacritics, false)

        let result = (mutable as String).lowercased()
        guard !result.isEmpty else { return nil }
        return result
    }

    /// 粗粒度判断：字符串里是否含有汉字。只覆盖常见/扩展 A/兼容/扩展 B 区——够用于
    /// “要不要跑一遍拼音转换”这个判断，不追求覆盖全部生僻扩展区。
    private static func containsHanCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0x20000...0x2A6DF: // CJK Unified Ideographs Extension B
                return true
            default:
                return false
            }
        }
    }
}
