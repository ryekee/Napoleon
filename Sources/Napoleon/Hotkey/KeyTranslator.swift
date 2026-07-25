import Carbon.HIToolbox
import Foundation
import os

/// keyCode(+修饰键) → 字符串。用于 HotkeyManager session 内把「其它可打印键」转成搜索字符，
/// 以及 `Chord+Display.swift` 的按键名显示。
///
/// 线程模型（TIS 线程安全约束）：
/// - `TISCopyCurrentKeyboardLayoutInputSource` / `TISGetInputSourceProperty` / `LMGetKbdType` 这类
///   TextInputSources API 官方文档标注为主线程调用；本类把它们全部收敛进 `refreshLayout()`，只在
///   初始化（由 `AppDelegate.applicationDidFinishLaunching` 在主线程首次触达 `shared` 触发）和输入法
///   切换通知（`kTISNotifySelectedKeyboardInputSourceChanged`，回调不保证在主线程，转发一次到主队列）
///   两个时机调用，且都在主线程执行。
/// - 刷新结果（`layoutData` + `kbdType`）是一份不可变快照，写入时用 `OSAllocatedUnfairLock` 保护
///   （与 `HotkeyManager.chordState` 同一模式）。
/// - `character(keyCode:shift:)` 只读快照 + 调用 `UCKeyTranslate`（纯函数，Apple 文档未声明线程限制，
///   可在任意线程调用），因此可以安全地在 HotkeyManager 的 tap 线程里调用，不会触发任何 TIS API。
final class KeyTranslator {
    static let shared = KeyTranslator()

    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "KeyTranslator")

    private struct LayoutSnapshot {
        var layoutData: Data
        var kbdType: UInt32
    }

    private let state: OSAllocatedUnfairLock<LayoutSnapshot?>

    private init() {
        self.state = OSAllocatedUnfairLock(initialState: nil)
        refreshLayout()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // 通知可能不在主线程送达（DistributedNotificationCenter 不保证），TIS 调用必须转发到主线程。
            DispatchQueue.main.async {
                self?.refreshLayout()
            }
        }
    }

    /// 重新读取键盘布局并缓存快照。调用 TIS API，必须在主线程执行。
    ///
    /// 需求：session 内敲字母只取「最干净的原始键盘输入」——始终是 ASCII 拉丁字母，
    /// **忽略中文等所有输入法、也忽略俄语/AZERTY 等非 ASCII 布局**（搜索只匹配英文 App 名 + ASCII 拼音）。
    /// 因此首选 `TISCopyCurrentASCIICapableKeyboardLayoutInputSource`：无论当前激活的是 IME 还是
    /// 非 ASCII 键盘布局，它都返回一个可产出拉丁字母的 ASCII-capable 键盘布局。
    /// 极端兜底才退回当前键盘布局输入源。
    func refreshLayout() {
        guard let layoutData = Self.currentLayoutData() else {
            Self.logger.error("refreshLayout: no usable ASCII-capable keyboard layout data")
            return
        }
        let kbdType = UInt32(LMGetKbdType())
        state.withLock { $0 = LayoutSnapshot(layoutData: layoutData, kbdType: kbdType) }
    }

    private static func currentLayoutData() -> Data? {
        // 首选 ASCII-capable 布局：IME / 非 ASCII 布局激活时也强制拿到英文字母布局。
        if let inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let data = layoutData(from: inputSource) {
            return data
        }
        // 极端兜底：当前键盘布局输入源。
        if let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let data = layoutData(from: inputSource) {
            return data
        }
        return nil
    }

    private static func layoutData(from inputSource: TISInputSource) -> Data? {
        guard let layoutDataRaw = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(layoutDataRaw).takeUnretainedValue() as Data
    }

    /// 用缓存的键盘布局把 keyCode 转成字符串（跟随实际输入源，随 Shift 影响大小写/上档符号）。
    /// 控制字符（Tab/Return/Esc/…）、功能键私有区字符、或转换失败一律返回 nil。
    /// 只读锁保护的快照 + 调用纯函数 `UCKeyTranslate`，可在任意线程（含 tap 线程）安全调用。
    func character(keyCode: UInt16, shift: Bool) -> String? {
        // Carbon modifierKeyState 是 EventRecord 风格的修饰键位右移 8 位；shiftKey = 0x0200 → 0x02。
        let modifierKeyState: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
        guard let translated = translate(keyCode: keyCode, action: kUCKeyActionDown, modifierKeyState: modifierKeyState) else {
            return nil
        }
        guard let scalar = translated.unicodeScalars.first else { return nil }
        let value = scalar.value
        // 过滤 ASCII 控制字符（Tab=0x09/Return=0x0D/Esc=0x1B/Backspace=0x08/…）以及 Cocoa 用来表示
        // 功能键（方向键/F 区等）的私有使用区（U+F700–U+F8FF）。
        if value < 0x20 || value == 0x7F || (0xF700...0xF8FF).contains(value) {
            return nil
        }
        return translated
    }

    /// 通用底层封装：用缓存的键盘布局 Unicode 数据调用 UCKeyTranslate（纯函数，无 TIS 调用）。
    /// - Parameters:
    ///   - action: `kUCKeyActionDown` 等（Y7：统一用 Down，Display 在部分布局下行为不一致）。
    ///   - modifierKeyState: Carbon 风格（EventRecord.modifiers >> 8）的修饰键状态，0 表示不叠加。
    func translate(keyCode: UInt16, action: Int, modifierKeyState: UInt32) -> String? {
        guard let snapshot = state.withLock({ $0 }) else { return nil }

        return snapshot.layoutData.withUnsafeBytes { rawBuffer -> String? in
            guard let keyLayoutPtr = rawBuffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                keyLayoutPtr,
                keyCode,
                UInt16(action),
                modifierKeyState,
                snapshot.kbdType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
