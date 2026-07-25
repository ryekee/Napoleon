import Carbon.HIToolbox
import CoreGraphics

extension Chord {
    /// 形如 "⌘⇧A"、"⌘Tab"。修饰键用符号前缀，主键用当前键盘布局的字符（特殊键给可读名）。
    var displayString: String {
        var result = ""
        if modifiers & UInt(CGEventFlags.maskControl.rawValue) != 0 { result += "⌃" }
        if modifiers & UInt(CGEventFlags.maskAlternate.rawValue) != 0 { result += "⌥" }
        if modifiers & UInt(CGEventFlags.maskShift.rawValue) != 0 { result += "⇧" }
        if modifiers & UInt(CGEventFlags.maskCommand.rawValue) != 0 { result += "⌘" }
        result += Chord.keyName(for: keyCode)
        return result
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "Esc"
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "Enter"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        default:
            return translatedCharacter(for: keyCode) ?? "?"
        }
    }

    /// 用当前键盘输入源把 keyCode 转成显示字符（不含死键处理）。底层 UCKeyTranslate 封装见
    /// `KeyTranslator.translate`（与 session 内实际按键转换共用，只是修饰键状态不同）。
    ///
    /// action 用 `kUCKeyActionDown` 而不是 `kUCKeyActionDisplay`：Apple 建议即使是纯展示用途也用
    /// Down，部分布局下 Display 的行为不一致（Y7）。
    private static func translatedCharacter(for keyCode: UInt16) -> String? {
        // 只取主键面字符、不叠加修饰键，再转大写作为展示用的按键名。
        KeyTranslator.shared.translate(keyCode: keyCode, action: kUCKeyActionDown, modifierKeyState: 0)?.uppercased()
    }
}
