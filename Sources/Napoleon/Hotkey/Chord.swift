import CoreGraphics

/// 键盘快捷键：keyCode + 归一化后的修饰键位。
struct Chord: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt   // 已按 canonicalMask 归一化的 CGEventFlags.rawValue 子集

    /// 只关心 ⌘⇧⌥⌃ 四个设备无关修饰键；忽略左右变体、数字键盘、Fn、caps 等。
    static let canonicalMask: UInt = UInt(CGEventFlags([.maskCommand, .maskShift, .maskAlternate, .maskControl]).rawValue)

    init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Chord.canonicalMask   // 入口即归一化
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers
    }

    /// 自定义解码：不能用编译器合成的逐字段赋值——那样会绕过 `init(keyCode:modifiers:)` 里的
    /// `canonicalMask` 归一化，一份持久化时带噪声位的 `modifiers`（比如手改配置文件、旧版本残留）
    /// 会让 `matches` 从此静默永远返回 false。这里显式路由回 designated init 重新归一化一次。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let modifiers = try container.decode(UInt.self, forKey: .modifiers)
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    /// 事件命中判定：keyCode 相等且归一化后的修饰键完全一致。
    /// `flags` 传 `event.flags.rawValue`（原始，含噪声位），此处再 mask。
    func matches(keyCode kc: UInt16, flags: UInt) -> Bool {
        kc == keyCode && (flags & Chord.canonicalMask) == modifiers
    }
}
