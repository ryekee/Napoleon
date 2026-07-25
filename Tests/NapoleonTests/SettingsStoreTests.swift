import Testing
import CoreGraphics
import Foundation
@testable import Napoleon

@MainActor
@Suite struct SettingsStoreTests {
    private func makeSuite() -> (UserDefaults, String) {
        let name = "napoleon.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func persistsShowDelayMsAcrossInstances() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store1 = SettingsStore(defaults: defaults)
        store1.showDelayMs = 250

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.showDelayMs == 250)
    }

    @Test func persistsAllWindowsChordAcrossInstances() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store1 = SettingsStore(defaults: defaults)
        let newChord = Chord(keyCode: 49, modifiers: UInt(CGEventFlags([.maskCommand, .maskShift]).rawValue))
        store1.allWindowsChord = newChord

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.allWindowsChord == newChord)
    }

    @Test func defaultsMatchSpec() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.allWindowsChord == Chord(keyCode: 48, modifiers: UInt(CGEventFlags.maskCommand.rawValue)))
        #expect(store.currentAppChord == Chord(keyCode: 50, modifiers: UInt(CGEventFlags.maskCommand.rawValue)))
        #expect(store.scope == .init(includeOtherSpaces: false))
        #expect(store.showDelayMs == 100)
        #expect(store.thumbnailMaxCacheBytes == 32 * 1024 * 1024)
        #expect(store.pinyinSearchEnabled == true)
        // Task 21 新增项的默认值：显示窗口标题（用户要求默认开）、中等卡片、不跟随系统明暗
        // （= 始终深色，保持 Phase 5 起验证过的观感）。
        #expect(store.showWindowTitle == true)
        #expect(store.cardSize == .medium)
        #expect(store.followSystemAppearance == false)
    }

    @Test func persistsShowWindowTitleAndCardSizeAcrossInstances() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store1 = SettingsStore(defaults: defaults)
        store1.showWindowTitle = false
        store1.cardSize = .large
        store1.followSystemAppearance = true

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.showWindowTitle == false)
        #expect(store2.cardSize == .large)
        #expect(store2.followSystemAppearance == true)
    }

    @Test func unknownPersistedCardSizeFallsBackToDefault() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        // 手改 plist / 降级安装留下的未知档位值不能让卡片尺寸崩坏——回落默认档。
        defaults.set("gigantic", forKey: "napoleon.cardSize")
        #expect(SettingsStore(defaults: defaults).cardSize == .medium)
    }
}
