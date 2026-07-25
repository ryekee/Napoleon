import Testing
import CoreGraphics
import Foundation
@testable import Napoleon

@Suite struct ChordTests {
    @Test func codableRoundTrip() throws {
        let chord = Chord(keyCode: 48, modifiers: UInt(CGEventFlags.maskCommand.rawValue))
        let data = try JSONEncoder().encode(chord)
        let decoded = try JSONDecoder().decode(Chord.self, from: data)
        #expect(decoded == chord)
    }

    @Test func matchesExactModifiers() {
        let chord = Chord(keyCode: 48, modifiers: UInt(CGEventFlags.maskCommand.rawValue))
        #expect(chord.matches(keyCode: 48, flags: UInt(CGEventFlags.maskCommand.rawValue)))
    }

    @Test func doesNotMatchWithExtraModifier() {
        let chord = Chord(keyCode: 48, modifiers: UInt(CGEventFlags.maskCommand.rawValue))
        let extra = UInt(CGEventFlags([.maskCommand, .maskShift]).rawValue)
        #expect(!chord.matches(keyCode: 48, flags: extra))
    }

    @Test func doesNotMatchDifferentKeyCode() {
        let chord = Chord(keyCode: 48, modifiers: UInt(CGEventFlags.maskCommand.rawValue))
        #expect(!chord.matches(keyCode: 50, flags: UInt(CGEventFlags.maskCommand.rawValue)))
    }

    @Test func matchesIgnoresNoiseBits() {
        let chord = Chord(keyCode: 48, modifiers: UInt(CGEventFlags.maskCommand.rawValue))
        let noisy = UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskNumericPad.rawValue)
        #expect(chord.matches(keyCode: 48, flags: noisy))
    }

    @Test func initNormalizesModifiersToCanonicalMask() {
        let chord = Chord(keyCode: 48, modifiers: ~UInt(0))
        #expect(chord.modifiers == Chord.canonicalMask)
    }

    @Test func decodeNormalizesModifiersToCanonicalMask() throws {
        // Simulates a persisted config with noise bits in `modifiers` (e.g. hand-edited, or written
        // by an older build) — decode must route through init(keyCode:modifiers:) and re-normalize,
        // not bypass it via synthesized field-by-field assignment (Fix Y1).
        let noisyModifiers = UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskAlphaShift.rawValue)
        let json = """
        {"keyCode": 48, "modifiers": \(noisyModifiers)}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Chord.self, from: json)
        #expect(decoded.modifiers == noisyModifiers & Chord.canonicalMask)
    }
}
