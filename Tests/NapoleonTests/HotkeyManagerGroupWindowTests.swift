import CoreGraphics
import Testing
@testable import Napoleon

@Suite struct HotkeyManagerGroupWindowTests {
    private let command = UInt(CGEventFlags.maskCommand.rawValue)
    private let option = UInt(CGEventFlags.maskAlternate.rawValue)
    private let shift = UInt(CGEventFlags.maskShift.rawValue)

    @Test func currentAppChordStepsInsideAllWindowsSession() {
        let chord = Chord(keyCode: 50, modifiers: command)
        let sessionChord = Chord(keyCode: 48, modifiers: command)

        #expect(HotkeyManager.groupWindowStepDirection(
            currentTrigger: .allWindows,
            sessionChord: sessionChord,
            currentAppChord: chord,
            keyCode: 50,
            flags: command
        ) == .forward)
        #expect(HotkeyManager.groupWindowStepDirection(
            currentTrigger: .allWindows,
            sessionChord: sessionChord,
            currentAppChord: chord,
            keyCode: 50,
            flags: command | shift
        ) == .backward)
    }

    @Test func groupStepKeepsModifiersInheritedFromAllWindowsSession() {
        let currentAppChord = Chord(keyCode: 50, modifiers: command)
        let sessionChord = Chord(keyCode: 48, modifiers: command | option)

        #expect(HotkeyManager.groupWindowStepDirection(
            currentTrigger: .allWindows,
            sessionChord: sessionChord,
            currentAppChord: currentAppChord,
            keyCode: 50,
            flags: command | option
        ) == .forward)
        #expect(HotkeyManager.groupWindowStepDirection(
            currentTrigger: .allWindows,
            sessionChord: sessionChord,
            currentAppChord: currentAppChord,
            keyCode: 50,
            flags: command | option | shift
        ) == .backward)
        #expect(HotkeyManager.groupWindowStepDirection(
            currentTrigger: .allWindows,
            sessionChord: sessionChord,
            currentAppChord: currentAppChord,
            keyCode: 50,
            flags: command
        ) == nil)
    }

    @Test func groupStepDoesNotHijackCurrentAppSessionOrOtherKeys() {
        let chord = Chord(keyCode: 50, modifiers: command)
        let sessionChord = Chord(keyCode: 48, modifiers: command)

        #expect(HotkeyManager.groupWindowStepDirection(
            currentTrigger: .currentApp,
            sessionChord: sessionChord,
            currentAppChord: chord,
            keyCode: 50,
            flags: command
        ) == nil)
        #expect(HotkeyManager.groupWindowStepDirection(
            currentTrigger: .allWindows,
            sessionChord: sessionChord,
            currentAppChord: chord,
            keyCode: 48,
            flags: command
        ) == nil)
    }
}
