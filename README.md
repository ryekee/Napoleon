# Napoleon

A keyboard window switcher for macOS, with live window thumbnails.

> *Every window has its Waterloo.*

macOS's built-in ⌘Tab switches **applications**, and shows you icons. Napoleon switches
**windows**, and shows you what each one actually looks like. It lives in the menu bar, has no
main window, and is built to stay out of the way: no polling while idle, no persistent UI, and
the overlay only appears if you hold the hotkey long enough to want it.

## Features

- **Thumbnail previews.** Each window is a card with a live capture, not an icon. This is the
  whole point of the project.
- **Two hotkeys.** ⌘Tab cycles every window, ⌘\` cycles windows of the current app. Both are
  rebindable.
- **Window or app switching.** Keep every window separate, or group windows by application and
  use ⌘\` to move within the selected app's stack.
- **Quick-switch stays quick.** Tap and release faster than the display delay and Napoleon
  switches straight to your previous window without flashing an overlay.
- **Search.** Start typing to filter by app name or window title. Chinese titles can be matched
  by Pinyin (`gouwu` → 购物清单).
- **Keyboard, mouse, or both.** Tab/⇧Tab, arrow keys for grid navigation, hover and click, Esc
  to cancel.
- **Full-screen aware.** Full-screen apps appear in the list, and while you are inside a
  full-screen space your desktop windows stay reachable, so you can get back out.
- **Localized.** English, 简体中文, 繁體中文, 日本語.

## Requirements

- macOS 14 (Sonoma) or later
- **Accessibility** permission, required. Without it Napoleon cannot intercept the hotkey or
  focus windows, and the menu bar icon shows a warning.
- **Screen Recording** permission, optional. Without it the switcher still works, but cards fall
  back to app icons instead of thumbnails.

## Install

Grab the latest build from [Releases](https://github.com/ryekee/Napoleon/releases), or build it
yourself (below).

Releases are signed but not notarized, so macOS will ask you to approve the app on first launch.
You will also need to grant the two permissions above in System Settings → Privacy & Security.

## Build from source

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Xcode.

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon \
  -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
open build/Build/Products/Debug/Napoleon.app
```

Clone with full history. The build number comes from the commit count, so a shallow clone
(`--depth 1`) would produce a wrong one, and the build stops rather than stamp it.

### Code signing

The project signs with a **fixed self-signed certificate** named `com.ryekee.napoleon` rather
than ad-hoc. This matters more than it sounds: TCC ties granted permissions to the signing
identity, and ad-hoc signing produces a new identity on every build, so macOS would forget your
Accessibility and Screen Recording grants each time you rebuild.

Create your own certificate with that name (Keychain Access → Certificate Assistant → Create a
Certificate → *Code Signing*, self-signed), or point `CODE_SIGN_IDENTITY` in `project.yml` at one
you already have. Verify it exists with:

```bash
security find-identity -v -p codesigning | grep com.ryekee.napoleon
```

If you previously ran an ad-hoc build and granted permissions to it, reset the two TCC entries
after switching identities, then grant them again:

```bash
tccutil reset Accessibility com.napoleon.Napoleon
tccutil reset ScreenCapture com.napoleon.Napoleon
```

### Tests

```bash
xcodebuild -project Napoleon.xcodeproj -scheme NapoleonCore -destination 'platform=macOS' test
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon     -destination 'platform=macOS' test
```

`NapoleonCore` holds the pure logic (window filtering, MRU ordering, selection, the state
reducer) and is unit-tested. The integration layer, meaning Accessibility, ScreenCaptureKit, the
event tap, and Spaces, cannot be meaningfully unit-tested and is verified by hand instead.

## How it works

- A session-level, consuming `CGEventTap` on a dedicated thread intercepts the hotkey and
  swallows keystrokes for the duration of a switching session, so the system switcher never
  appears and your keystrokes don't leak into the app underneath.
- Window enumeration is Accessibility-based, kept warm in a store that is updated incrementally
  by `AXObserver` notifications rather than re-enumerated on every keypress. That is what keeps
  the overlay's appearance immediate.
- Thumbnails come from ScreenCaptureKit, cached under a byte budget with LRU eviction, and
  opportunistically pre-warmed when a window loses focus, the moment a window is most likely to
  become the next thing you switch back to.

### Activation policy

Napoleon runs as a background agent (`.accessory`), and that is load-bearing rather than
cosmetic. Since macOS 14, cooperative activation only lets background agents activate other
apps; a regular app that isn't frontmost cannot. Napoleon always focuses windows from the
background, so promoting it to a regular app would break switching outright.

The settings window is the one exception. While it is frontmost, the process becomes
`.regular` so that it gets a Dock icon like any other window, and drops back to `.accessory` the
moment it stops being frontmost. That is also why the settings window shows up in the switcher
alongside everything else.

### Private APIs

Napoleon uses six private symbols, each resolved with `dlsym` at runtime and each with a defined
fallback if it ever disappears. The app degrades, it does not crash:

| Symbol | Used for | Without it |
|---|---|---|
| `_AXUIElementGetWindow` | map an `AXUIElement` to its `CGWindowID` | falls back to geometry/title scoring |
| `CGSHWCaptureWindowList` | capture minimized windows | those cards show an icon |
| `CGSMainConnectionID` | connection handle for the two below | Space classification disabled |
| `CGSCopyManagedDisplaySpaces` | classify Spaces (desktop vs full-screen) | full-screen windows treated as ordinary cross-Space ones |
| `CGSCopySpacesForWindows` | which Space a window is on | the full-screen escape list falls back to showing all desktop windows |
| `SLPSSetFrontProcessWithOptions` | bring Napoleon itself to the front | picking Napoleon's own settings window may leave it behind the current app |

This is the usual trade-off for a window switcher on macOS. The public APIs alone cannot answer
these questions, and it does mean Napoleon is not App Store material.

## Status

Early but usable daily. Version 0.3.0. Known rough edges:

- Windows on another Space that Accessibility can't reach are focused at app level, so a
  multi-window app may not land on the exact window you picked.
- With a second display parked in a full-screen space for a long time, the "escape" list can go
  stale until you visit a desktop again.
- Unusual toolkits (Java/Swing, SDL games) expose windows inconsistently through Accessibility,
  so results vary.

## License

[GNU AGPL v3.0](LICENSE), Copyright © 2026 Ryekee.

Use it, study it, change it, share it. The one obligation: if you distribute Napoleon or a
derivative, or run a modified version as a network service, you must release your source under
the AGPL too. In other words, improvements stay open, and nobody gets to take this
closed-source.

If you need to build something proprietary on top of it, open an issue and we can discuss a
separate commercial license.
