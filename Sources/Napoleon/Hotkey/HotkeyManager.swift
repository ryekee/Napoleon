import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// 触发类型：全局窗口切换 vs 当前 App 窗口切换。
/// pid 由主线程 Controller 解析（Task 8+），tap 回调不查、保持廉价。
enum HotkeyTrigger {
    case allWindows
    case currentApp
}

/// HotkeyManager 的语义化输出：session 触发/提交（Task 7）+ session 内 Tab 循环/字符/方向键/取消（Task 8）。
protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyDidTrigger(_ trigger: HotkeyTrigger)
    func hotkeyDidStepForward()
    func hotkeyDidStepBackward()
    func hotkeyDidReceiveChar(_ s: String)
    func hotkeyDidDeleteChar()
    func hotkeyDidMove(dx: Int, dy: Int)
    func hotkeyDidCancel()
    func hotkeyDidCommit()
}

/// CGEventTap 封装：在专用线程上拦截并吞掉配置的触发快捷键（默认 Cmd+Tab / Cmd+`），
/// session 激活期间吞掉全部按键（语义化留给 Task 8），修饰键释放时提交。
///
/// 线程模型：
/// - tap 本身、其 CFMachPort/RunLoopSource、以及 session 状态机（`sessionActive`/`currentTrigger`/
///   `currentChord`）只在专用 `Thread`（"com.napoleon.hotkey-tap"）里创建和读写 —— 因为 CGEventTap
///   回调本就同步运行在建它的那个线程的 run loop 上，绝不能挂主线程（会拖慢/丢失全系统键盘输入）。
/// - `allWindowsChord`/`currentAppChord`（合并存于 `chordState`）是唯一跨线程共享的可变状态（主线程
///   `updateChords` 写，tap 线程回调读），用 `OSAllocatedUnfairLock` 保护；每次 session-外判定读取时
///   做一次性快照，避免持锁跨越两次比较。
/// - delegate 回调一律 `DispatchQueue.main.async`，tap 线程不直接碰 delegate / UI。
final class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private static let logger = Logger(subsystem: "com.napoleon.Napoleon", category: "HotkeyManager")

    // MARK: - Shared chord state (main thread writes via updateChords; tap thread reads in callback)

    private let chordState: OSAllocatedUnfairLock<(allWindows: Chord, currentApp: Chord)>

    /// Task 21：录制快捷键期间「挂起拦截」。主线程写（设置界面的录制器按下/结束录制），tap 线程
    /// 在回调开头读。挂起期间 tap 仍然活着（不去折腾线程与 CFMachPort 的生命周期，那条路径有
    /// 已知的启停竞态，见 `start()`/`stop()` 的注释），只是**一律放行**、不匹配 chord、不维护
    /// session——否则用户在设置里想录 Cmd+Tab 时，按下的那一刻就被我们自己的 tap 吞掉当成一次
    /// 切换触发，录制器永远收不到这个组合键。
    private let suspendedState = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Tap thread lifecycle (touched from main thread in start()/stop(); the CFMachPort/RunLoop
    // fields themselves are only written on the tap thread, and only read back on the main thread after
    // that start() call's readiness semaphore has signaled — establishing a happens-before so stop()
    // never races the tap thread's own setup).

    private var tapThread: Thread?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThreadRunLoop: CFRunLoop?

    // Per-cycle "the tap thread has fully torn down and returned" signal (Fix O1). Fresh instance
    // every start(), same lifetime rules as readySemaphore below — stop() waits on it so its caller
    // only sees stop() return once the old thread's teardown writes to tap/runLoopSource/
    // tapThreadRunLoop have already happened, establishing happens-before against a subsequent
    // start()'s setup writes to those same fields.
    private var stoppedSemaphore: DispatchSemaphore?

    // MARK: - Session state — mutated ONLY inside the tap callback, i.e. only on the tap thread.

    private var sessionActive = false
    private var currentTrigger: HotkeyTrigger?
    private var currentChord: Chord?

    // MARK: - Session watchdog (Task 9) — a session-scoped repeating CFRunLoopTimer, created and
    // invalidated ONLY on the tap thread (same thread that owns the session state above, so no lock
    // is needed). It exists solely to guard against a lost commit-flagsChanged event (e.g. suppressed
    // by secure input, or dropped under system jitter) leaving `sessionActive` stuck true, which would
    // make the tap swallow every keystroke forever. It is NOT a permanent/idle-polling timer — it is
    // only ever alive while `sessionActive == true`.

    private static let watchdogInterval: CFTimeInterval = 0.18
    private var watchdogTimer: CFRunLoopTimer?

    init(allWindowsChord: Chord, currentAppChord: Chord) {
        self.chordState = OSAllocatedUnfairLock(initialState: (allWindows: allWindowsChord, currentApp: currentAppChord))
    }

    /// 主线程调用，更新触发快捷键（例如用户在设置里改了绑定）。tap 线程下次判定时会读到新值。
    func updateChords(allWindows: Chord, currentApp: Chord) {
        chordState.withLock { state in
            state = (allWindows, currentApp)
        }
    }

    private func snapshotChords() -> (allWindows: Chord, currentApp: Chord) {
        chordState.withLock { $0 }
    }

    /// Task 21：设置界面开始/结束录制快捷键时调用（主线程）。挂起期间所有键盘事件原样放行，
    /// 见 `suspendedState` 的说明。幂等，重复调用安全。
    func setSuspended(_ suspended: Bool) {
        suspendedState.withLock { $0 = suspended }
    }

    private func isSuspended() -> Bool {
        suspendedState.withLock { $0 }
    }

    /// 建 tap、挂专用线程 run loop、tapEnable。若辅助功能未授权，不建 tap（只记警告日志——
    /// 权限引导 UI 在 Task 20）。阻塞调用线程至多 2s 直到 tap 线程完成设置（成功或失败都会返回），
    /// 保证 start() 返回后 stop() 读取 tap/run loop 引用是安全的。
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard tapThread == nil else { return }
        guard AXIsProcessTrusted() else {
            Self.logger.warning("Accessibility permission not granted — HotkeyManager will not create a tap. Grant access in System Settings > Privacy & Security > Accessibility, then relaunch.")
            return
        }

        // Fresh per-call semaphores — never reused across start/stop/start cycles, so there is no way
        // for a stale signal from a previous cycle to let a wait return early.
        let readySemaphore = DispatchSemaphore(value: 0)
        let stoppedSemaphore = DispatchSemaphore(value: 0)
        self.stoppedSemaphore = stoppedSemaphore
        let thread = Thread { [weak self] in
            self?.runOnTapThread(readySemaphore: readySemaphore, stoppedSemaphore: stoppedSemaphore)
        }
        thread.name = "com.napoleon.hotkey-tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        _ = readySemaphore.wait(timeout: .now() + 2.0)

        // tap is written on the tap thread on both the success path (before the readiness signal is
        // scheduled onto the running loop) and left nil on the tapCreate-failure path (signaled
        // immediately) — the semaphore wait establishes happens-before, so this read is safe here on
        // the calling thread. If it's still nil (creation failed, e.g. Accessibility was revoked between
        // the AXIsProcessTrusted() check above and tapCreate, or setup timed out), clear tapThread so a
        // later start() call can retry instead of being permanently blocked by the `tapThread == nil`
        // guard above.
        if tap == nil {
            tapThread = nil
        }
    }

    /// 关 tap、停专用线程；阻塞调用线程直到 tap 线程完全退出（teardown 写完 tap/runLoopSource/
    /// tapThreadRunLoop 之后才返回，至多等 2s），这样紧接着的 start() 不会和上一轮线程的 teardown
    /// 写产生 data race（Fix O1）。可在 tap 从未成功建立时安全调用（no-op）。
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let runLoop = tapThreadRunLoop else {
            tapThread = nil
            return
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        let stoppedSemaphore = self.stoppedSemaphore
        CFRunLoopStop(runLoop)
        if let stoppedSemaphore {
            let result = stoppedSemaphore.wait(timeout: .now() + 2.0)
            if result == .timedOut {
                Self.logger.error("HotkeyManager stop() timed out waiting for tap thread to exit — possible orphan tap")
            }
        }
        self.stoppedSemaphore = nil
        tapThread = nil
    }

    // MARK: - Tap thread entry point

    private func runOnTapThread(readySemaphore: DispatchSemaphore, stoppedSemaphore: DispatchSemaphore) {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: refcon
        ) else {
            Self.logger.error("CGEvent.tapCreate failed — Accessibility permission missing or revoked?")
            readySemaphore.signal()
            return
        }

        tap = createdTap
        let source = CFMachPortCreateRunLoopSource(nil, createdTap, 0)
        runLoopSource = source
        let runLoop = CFRunLoopGetCurrent()
        tapThreadRunLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)

        Self.logger.info("HotkeyManager tap running on dedicated thread")

        // Signal readiness from INSIDE the run loop instead of before CFRunLoopRun(), so start() only
        // unblocks once the loop is truly running. Without this, start() could return in the gap between
        // the old pre-run signal and CFRunLoopRun() actually starting; a stop() landing in that gap would
        // call CFRunLoopStop() on a not-yet-running loop, the stop would be lost, and the subsequent
        // CFRunLoopRun() below would then block forever.
        CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue) {
            readySemaphore.signal()
        }
        CFRunLoopWakeUp(CFRunLoopGetCurrent())

        CFRunLoopRun()

        // Reached only after stop() calls CFRunLoopStop(runLoop) on this same run loop.
        // Defensive: if stop() lands mid-session, the watchdog timer would otherwise leak (harmless
        // since this run loop no longer spins, but tidy up anyway — we're still on the tap thread here).
        invalidateWatchdog()
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(createdTap)
        tap = nil
        runLoopSource = nil
        tapThreadRunLoop = nil
        Self.logger.info("HotkeyManager tap thread stopped")
        // Fix O1: signal AFTER teardown writes above, so stop()'s wait establishes happens-before
        // against a subsequent start()'s setup writes to the same fields (tap/runLoopSource/
        // tapThreadRunLoop) — no more race between this thread's teardown and the next start().
        stoppedSemaphore.signal()
    }

    // MARK: - Callback logic (invoked from the C trampoline below; always runs on the tap thread)

    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.logger.warning("Tap disabled (rawValue=\(type.rawValue, privacy: .public)) — re-enabling")
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        // Task 21：录制期挂起——一律放行。若挂起时恰好有活跃 session（正常路径下不会发生：设置
        // 窗口要成为 key window，用户不可能同时按住 Cmd+Tab；这里防的是异常时序），先把它干净地
        // 结束掉，避免 session 卡在 active 状态导致挂起解除后所有按键继续被吞。
        if isSuspended() {
            if sessionActive {
                dispatch { $0.hotkeyDidCancel() }
                endSession()
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = UInt(event.flags.rawValue)

        if !sessionActive {
            let chords = snapshotChords()
            if type == .keyDown {
                if chords.allWindows.matches(keyCode: keyCode, flags: flags) {
                    beginSession(trigger: .allWindows, chord: chords.allWindows)
                    return nil
                }
                if chords.currentApp.matches(keyCode: keyCode, flags: flags) {
                    beginSession(trigger: .currentApp, chord: chords.currentApp)
                    return nil
                }
                // Fix O2: intercept "<chord> + Shift" (e.g. Cmd+Shift+Tab when the configured chord
                // is Cmd+Tab) as an immediate reverse-step, instead of letting it pass through to the
                // system's own reverse app-switcher. The session still begins on the BASE chord so
                // commit still fires on the base chord's modifier release, exactly like the exact-match
                // path above. Skipped for a chord that already includes Shift in its own modifiers, so
                // a user-configured Shift chord isn't given a second, redundant Shift-augmented meaning.
                if let (trigger, chord) = shiftAugmentedMatch(chords: chords, keyCode: keyCode, flags: flags) {
                    beginSession(trigger: trigger, chord: chord)
                    dispatch { $0.hotkeyDidStepBackward() }
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Session active.
        if type == .flagsChanged {
            // Commit when the triggering chord's modifiers are no longer all held.
            if let chord = currentChord, (flags & chord.modifiers) != chord.modifiers {
                endSession()
            }
            // Fix Y2: pass through ALL in-session flagsChanged events (committing or not), not just
            // the commit one. Swallowing a non-commit flagsChanged (e.g. Shift-up while Cmd is still
            // held — reachable via the O2 Cmd+Shift+Tab interception above, which begins the session
            // on the BASE chord while Shift is already down) would leave the frontmost app never
            // having seen the matching Shift-down, i.e. an orphan modifier-up. Passing all of them
            // through avoids that while leaving commit semantics unchanged.
            return Unmanaged.passUnretained(event)
        }

        // Everything else inside a session is swallowed unconditionally (this is what keeps e.g.
        // Cmd+W/Cmd+Q from leaking to the foreground app while the switcher's modal session is
        // active) — keyUp dispatches nothing, keyDown gets semantic dispatch below.
        if type == .keyDown {
            dispatchSessionKeyDown(keyCode: keyCode, flags: flags)
        }
        return nil
    }

    /// Fix O2: if `flags` matches a configured chord's modifiers augmented with Shift (and that
    /// chord doesn't already include Shift itself), returns the trigger + BASE (non-augmented) chord
    /// to begin the session with.
    private func shiftAugmentedMatch(
        chords: (allWindows: Chord, currentApp: Chord),
        keyCode: UInt16,
        flags: UInt
    ) -> (HotkeyTrigger, Chord)? {
        let shiftBit = UInt(CGEventFlags.maskShift.rawValue)
        for (trigger, chord) in [(HotkeyTrigger.allWindows, chords.allWindows), (HotkeyTrigger.currentApp, chords.currentApp)] {
            guard chord.modifiers & shiftBit == 0 else { continue }
            let shiftVariant = Chord(keyCode: chord.keyCode, modifiers: chord.modifiers | shiftBit)
            if shiftVariant.matches(keyCode: keyCode, flags: flags) {
                return (trigger, chord)
            }
        }
        return nil
    }

    /// session 内 keyDown 的语义化派发。调用方（`handleTapEvent`）已经 `return nil` 吞掉了这个事件——
    /// 这里只决定该回调 delegate 的哪个方法，不影响吞键与否。
    ///
    /// Tab autorepeat（长按连续翻页）：这个函数只在 `sessionActive == true` 时被调用（见上方
    /// `handleTapEvent` 的 session-外/session-内分流），所以无论触发键的这次 keyDown 是首次按下还是
    /// autorepeat 重复触发，都走同一条 `keyCode == currentChord?.keyCode` 分支，天然会重复派发
    /// forward/backward——同时也天然不可能重新触达上面 session-外的 `hotkeyDidTrigger` 判定。
    private func dispatchSessionKeyDown(keyCode: UInt16, flags: UInt) {
        let shift = flags & UInt(CGEventFlags.maskShift.rawValue) != 0

        if keyCode == currentChord?.keyCode {
            dispatch { delegate in
                shift ? delegate.hotkeyDidStepBackward() : delegate.hotkeyDidStepForward()
            }
            return
        }

        switch Int(keyCode) {
        case kVK_Escape:
            // Cancel ends the session locally (no hotkeyDidCommit) so the next key press outside
            // this callback passes straight through to the session-outside trigger detection above.
            invalidateWatchdog()
            sessionActive = false
            currentTrigger = nil
            currentChord = nil
            dispatch { $0.hotkeyDidCancel() }
        case kVK_Delete:
            dispatch { $0.hotkeyDidDeleteChar() }
        case kVK_LeftArrow:
            dispatch { $0.hotkeyDidMove(dx: -1, dy: 0) }
        case kVK_RightArrow:
            dispatch { $0.hotkeyDidMove(dx: 1, dy: 0) }
        case kVK_DownArrow:
            dispatch { $0.hotkeyDidMove(dx: 0, dy: 1) }
        case kVK_UpArrow:
            dispatch { $0.hotkeyDidMove(dx: 0, dy: -1) }
        default:
            if let s = KeyTranslator.shared.character(keyCode: keyCode, shift: shift), !s.isEmpty {
                dispatch { $0.hotkeyDidReceiveChar(s) }
            }
        }
    }

    private func dispatch(_ call: @escaping (HotkeyManagerDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let delegate = self?.delegate else { return }
            call(delegate)
        }
    }

    private func beginSession(trigger: HotkeyTrigger, chord: Chord) {
        sessionActive = true
        currentTrigger = trigger
        currentChord = chord

        if InputSafetyMonitor.isSecureInputEnabled {
            Self.logger.warning("secure input active — key events may be suppressed")
        }

        scheduleWatchdog()

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.hotkeyDidTrigger(trigger)
        }
    }

    private func endSession() {
        invalidateWatchdog()
        sessionActive = false
        currentTrigger = nil
        currentChord = nil
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.hotkeyDidCommit()
        }
    }

    // MARK: - Session watchdog (Task 9)

    /// 在 tap 线程当前的 run loop 上调度一个重复 timer——`beginSession` 总是在 tap 回调内被调用，
    /// 所以 `CFRunLoopGetCurrent()` 此刻就是 `tapThreadRunLoop`。
    private func scheduleWatchdog() {
        invalidateWatchdog()
        let interval = Self.watchdogInterval
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + interval,
            interval,
            0,
            0
        ) { [weak self] _ in
            self?.watchdogTick()
        }
        guard let timer else { return }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        watchdogTimer = timer
    }

    private func invalidateWatchdog() {
        guard let watchdogTimer else { return }
        CFRunLoopTimerInvalidate(watchdogTimer)
        self.watchdogTimer = nil
    }

    /// 定时 tick（tap 线程）：读真实修饰键状态，若触发 chord 的修饰键其实已经不再全部按住却没能走到
    /// `handleTapEvent` 里的 flagsChanged 提交分支（commit 事件被丢/被 secure input 抑制/系统抖动），
    /// 就当作提交事件丢失来强制解锁——否则 `sessionActive` 会永远卡在 true，tap 吞掉所有按键。
    ///
    /// 正常 session 期间（Cmd 真的按住）不会误触发：`real` 里 Cmd 位仍是 1，
    /// `(real & chord.modifiers) == chord.modifiers` 成立，本次 tick 什么也不做。
    private func watchdogTick() {
        guard sessionActive, let chord = currentChord else {
            invalidateWatchdog()
            return
        }
        let real = UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
        if (real & chord.modifiers) != chord.modifiers {
            Self.logger.warning("watchdog force-commit — trigger chord modifiers released without a flagsChanged commit event")
            endSession()
        }
    }
}

// MARK: - C callback trampoline
//
// Must be a global function (or static method) with no captures so it satisfies the `@convention(c)`
// CGEventTapCallBack type — the HotkeyManager instance is recovered from `refcon`, which was seeded with
// `Unmanaged.passUnretained(self).toOpaque()` when the tap was created.

private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.handleTapEvent(type: type, event: event)
}
