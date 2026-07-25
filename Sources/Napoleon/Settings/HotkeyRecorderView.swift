import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Task 21：快捷键录制控件——点一下进入录制，按下的下一个「修饰键 + 主键」组合即成为新绑定。
///
/// **为什么必须挂起全局 tap**：Napoleon 自己的 `CGEventTap` 是 session 级、消费型的，用户想录
/// Cmd+Tab 时，那个组合在到达任何 App 之前就被我们吞掉当成一次切换触发，录制器根本收不到。所以
/// 进入录制时通过 `onRecordingChanged(true)` 让 `AppServices` 调 `HotkeyManager.setSuspended(true)`，
/// 录完/取消再恢复。挂起期间 tap 依然活着（只是全部放行），不去折腾 tap 线程的启停竞态。
///
/// **必须带修饰键**：只按 Tab 这种裸键不接受——全局热键抢裸键会让整个系统没法正常打字。要求至少
/// 含 ⌘/⌃/⌥ 之一（单独 ⇧ 不算，⇧+字母就是大写字母）。不满足时保持录制态并给出提示，而不是
/// 静默丢弃让用户以为控件坏了。
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var chord: Chord
    /// 另一个动作当前的绑定——录到相同组合要拒绝（见 `HotkeyRecorderNSView.conflictingChord`）。
    var conflictingChord: Chord
    /// 录制开始/结束的回调——调用方据此挂起/恢复全局 tap。
    var onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.chord = chord
        view.conflictingChord = conflictingChord
        view.onChordRecorded = { newChord in
            chord = newChord
        }
        view.onRecordingChanged = onRecordingChanged
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.conflictingChord = conflictingChord
        // 录制过程中不要用外部值回冲——否则每次 SwiftUI 重绘都会把正在录制的临时显示打回去。
        guard !nsView.isRecording else { return }
        nsView.chord = chord
    }
}

/// 录制控件的 AppKit 本体。自绘（一个圆角框 + 居中文字），不用 `NSButton`——需要完全接管 keyDown
/// 且不希望空格/回车被按钮的默认行为吃掉。
final class HotkeyRecorderNSView: NSView {
    var chord: Chord = SettingsStore.defaultAllWindowsChord {
        didSet { needsDisplay = true }
    }
    /// 另一个动作当前的绑定。两个动作绑同一个组合时，tap 回调永远先匹配「切换所有窗口」
    /// （见 `HotkeyManager.handleTapEvent`），后者从此不可达，界面上却看不出任何异常——
    /// 所以在录制这一步就拒绝掉。
    var conflictingChord: Chord?
    var onChordRecorded: ((Chord) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            needsDisplay = true
            onRecordingChanged?(isRecording)
        }
    }

    /// 上一次按键被拒的原因（`nil` = 没有被拒）——显示在控件里，让用户知道为什么没录上。
    private var rejection: RejectionReason?

    enum RejectionReason {
        /// 没带 ⌘/⌃/⌥ —— 裸键当全局热键会让整个系统没法正常打字。
        case needsModifier
        /// 与另一个动作的绑定重复。
        case duplicate
        /// 属于「绝不能被全局吞掉」的系统级常用组合。
        case reserved

        var message: String {
            switch self {
            case .needsModifier: return String(localized: "Needs ⌘/⌃/⌥")
            case .duplicate: return String(localized: "Already used")
            case .reserved: return String(localized: "Reserved by the system")
            }
        }
    }

    /// 拒绝录制的保留组合：Napoleon 的 tap 是**消费型**的，一旦绑上这些，全系统所有 App 的
    /// 对应操作都会被吞掉（绑了 ⌘W 就再也关不掉任何窗口，绑了 ⌘Q 就退不出任何 App），而用户
    /// 多半意识不到是 Napoleon 干的、更难找回设置界面改回来。这些组合也不可能是切换器的合理
    /// 绑定，直接在录制这一步挡掉。
    private static let reservedChords: [(keyCode: Int, requiresCommandOnly: Bool)] = [
        (kVK_ANSI_Q, true),   // 退出 App
        (kVK_ANSI_W, true),   // 关闭窗口
        (kVK_ANSI_C, true),   // 复制
        (kVK_ANSI_V, true),   // 粘贴
        (kVK_ANSI_X, true),   // 剪切
        (kVK_ANSI_Z, true),   // 撤销
        (kVK_ANSI_A, true),   // 全选
        (kVK_ANSI_S, true)    // 保存
    ]

    private static func isReserved(_ chord: Chord) -> Bool {
        let commandOnly = chord.modifiers == UInt(CGEventFlags.maskCommand.rawValue)
        return reservedChords.contains { entry in
            Int(chord.keyCode) == entry.keyCode && (!entry.requiresCommandOnly || commandOnly)
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            endRecording()
        } else {
            window?.makeFirstResponder(self)
            rejection = nil
            isRecording = true
        }
    }

    override func resignFirstResponder() -> Bool {
        // 失去 first responder（点了同窗口内别的控件）等于取消录制。**但这条路径远不够**——
        // 见下面 `viewWillMove(toWindow:)` / 窗口通知：关窗口和切到别的 App 都不会 resign。
        endRecording()
        return true
    }

    // MARK: - 结束录制的兜底路径（C1）
    //
    // 录制期间全局 tap 是挂起的（所有快捷键失效），所以「结束录制」这件事必须万无一失。
    // `resignFirstResponder` 只覆盖「同窗口内点了别的控件」；以下两类常见操作 AppKit **不会**
    // 调用它，一旦漏掉就会让 tap 永久挂起、Napoleon 的快捷键全部失效且没有任何提示，只能重启：
    //   ① 点标题栏红色按钮关掉设置窗口（first responder 不变；SwiftUI 的 `Settings` 场景关窗后
    //      内容视图仍保持挂载，`NSViewRepresentable` 也不会被 dismantle）；
    //   ② 切到别的 App（first responder 是窗口内的状态，窗口失去 key 不会 resign）。
    // 因此这里显式监听窗口的 willClose / didResignKey，并在视图被移出窗口层级时也收尾。
    // 另有一层与本文件无关的兜底：`AppServices` 对挂起状态有超时自动解除（见那里）。

    private var windowObservers: [NSObjectProtocol] = []

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // 视图正在离开当前窗口（被移除/窗口销毁）——先收尾，再退订旧窗口的通知。
        endRecording()
        removeWindowObservers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endRecording() }
            }
            windowObservers.append(token)
        }
    }

    private func removeWindowObservers() {
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
        windowObservers.removeAll()
    }

    deinit {
        // `deinit` 不能碰 `isRecording`（会触发 `didSet` → 主 actor 回调），但退订是纯清理，安全。
        // 真正的「结束录制」已经由 `viewWillMove(toWindow:)` 在视图离开窗口时做过了。
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Esc 取消录制，保留原绑定（这也意味着 Esc 本身没法被录成快捷键——它是切换器会话里的
        // 取消键，本来就不该拿去当触发键）。
        if Int(event.keyCode) == kVK_Escape {
            endRecording()
            return
        }

        // `NSEvent.ModifierFlags` 与 `CGEventFlags` 的位定义逐位一致（⇧=1<<17、⌃=1<<18、
        // ⌥=1<<19、⌘=1<<20），可以直接传原始值；`Chord.init` 内部还会再按 `canonicalMask`
        // 归一化一次，滤掉左右变体/Fn/CapsLock 等噪声位。
        let candidate = Chord(keyCode: event.keyCode, modifiers: UInt(event.modifierFlags.rawValue))

        // 三道护栏，任一不过就保持录制态并告诉用户原因（不静默丢弃，也不静默接受）。
        let required = UInt(CGEventFlags([.maskCommand, .maskControl, .maskAlternate]).rawValue)
        if candidate.modifiers & required == 0 {
            reject(.needsModifier)
            return
        }
        if Self.isReserved(candidate) {
            reject(.reserved)
            return
        }
        if let conflictingChord, candidate == conflictingChord {
            reject(.duplicate)
            return
        }

        chord = candidate
        onChordRecorded?(candidate)
        endRecording()
    }

    /// 只按修饰键不产生 `keyDown`，会走到这里——不做任何事（等真正的主键），但要吃掉事件，
    /// 免得 ⌘ 之类冒泡出去触发菜单。
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
    }

    /// 录制期间必须吞掉 `performKeyEquivalent`——否则 ⌘W/⌘Q 这类组合会先被菜单栏当成快捷键
    /// 执行（把设置窗口关掉甚至退出 App），根本轮不到 `keyDown`。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    /// 拒绝这次按键：显示原因，**保持录制态**等用户重按一个合法组合。
    private func reject(_ reason: RejectionReason) {
        rejection = reason
        needsDisplay = true
    }

    private func endRecording() {
        rejection = nil
        isRecording = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        if let rejection {
            text = rejection.message
        } else if isRecording {
            text = String(localized: "Press a hotkey…")
        } else {
            text = chord.displayString
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
            .foregroundColor: rejection != nil
                ? NSColor.systemRed
                : (isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
