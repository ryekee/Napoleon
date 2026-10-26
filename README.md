# Napoleon

A native macOS window switcher with window previews, app grouping, and Pinyin search.

> *Every window has its Waterloo.*

[Website](https://napoleon.ryekee.workers.dev/) ·
[Download](https://github.com/ryekee/Napoleon/releases/latest) ·
[FAQ](https://napoleon.ryekee.workers.dev/faqs/) ·
[Changelog](https://napoleon.ryekee.workers.dev/changelog/)

Napoleon lives in the menu bar. Hold a shortcut to see your windows, choose the one you
want, and release to switch. A quick tap takes you straight to the previous window
without showing the overlay.

## Install

1. Download the DMG from [the latest release](https://github.com/ryekee/Napoleon/releases/latest).
2. Open it and drag Napoleon into Applications.
3. Launch Napoleon and grant **Accessibility** access in System Settings → Privacy & Security.
4. Enable **Screen Recording** if you want window previews. Without it, Napoleon uses app icons.

Requires **macOS 14 Sonoma or later**. The current release, **0.3.3**, supports Apple Silicon
and Intel, uses Developer ID signing, and is notarized by Apple.

## Switch, group, and search

| Action | Default control |
| --- | --- |
| Switch between all windows | Hold ⌘ and press Tab |
| Switch within the current app | Hold ⌘ and press the backtick key (\`) |
| Move through the switcher | Tab / ⇧Tab or arrow keys |
| Filter windows | Type an app name or window title |
| Activate a window | Release the shortcut modifier, or click a card |
| Cancel | Esc |

Both switching shortcuts are configurable in Settings.

- **Window previews.** See the contents of each window, with app icons as a fallback
  when a preview is unavailable.
- **Optional app grouping.** Keep windows separate or group them by app. In grouped mode,
  use the current-app shortcut to cycle through the selected app's windows.
- **Quick switching.** Release before the display delay to switch without flashing the
  overlay. The default delay is 100 ms and can be adjusted.
- **Pinyin search.** Match Chinese app names and window titles by Pinyin, such as
  `gouwu` for 购物清单.
- **Keyboard and mouse.** Navigate the grid with keys or select a window with the pointer.
- **Spaces and full-screen windows.** Reach windows across Spaces, including desktop
  windows while working in a full-screen Space. See the limitations below.
- **Four app languages.** English, 简体中文, 繁體中文, and 日本語.

The website is also available in [French](https://napoleon.ryekee.workers.dev/fr/),
[Simplified Chinese](https://napoleon.ryekee.workers.dev/zh-hans/),
[Traditional Chinese](https://napoleon.ryekee.workers.dev/zh-hant/), and
[Japanese](https://napoleon.ryekee.workers.dev/ja/). French is currently available on
the website only.

## Permissions and privacy

**Accessibility** lets Napoleon handle switching shortcuts and focus windows.
**Screen Recording** lets it capture window previews; switching still works without it.

Window previews and diagnostic reports stay on your Mac. Update checks fetch release
metadata from GitHub. If you choose to export a diagnostic report, you decide whether
to share it; Napoleon does not upload it automatically.

## Known limitations

- When Accessibility cannot reach a window on another Space, Napoleon may activate its
  app without focusing the exact window you selected.
- With a second display left in a full-screen Space, the list of desktop windows can
  become stale until you visit a desktop again.
- Some Java, SDL, and other apps expose incomplete window information to Accessibility.
- Some window and Space operations use private macOS APIs. Their behavior can change
  with macOS updates.

For a reproducible problem, [open an issue](https://github.com/ryekee/Napoleon/issues)
with your macOS version, Napoleon version, affected app, and steps to reproduce it.
Review any diagnostic report before attaching it.

## Build from source

The default maintainer workflow requires Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and the project's Developer ID certificate with its private key.

```sh
git clone https://github.com/ryekee/Napoleon.git
cd Napoleon
brew install xcodegen
./script/build_and_run.sh --verify
```

Use a full clone. The build number comes from the Git commit count, and shallow clones
are rejected. `project.yml` is the build configuration source; the helper regenerates
the Xcode project before building.

Debug and Release use the same signing identity:

```text
Developer ID Application: Shenzhen Hiko Technology Co., Ltd. (JQTFJ8P2T7)
Bundle ID: com.napoleon.Napoleon
```

The helper builds into `build/`, verifies the signature and, when present, the installed
`/Applications/Napoleon.app` designated requirement, then replaces the running instance.
If the build or signature check fails, it leaves the existing instance running. It does
not overwrite the installed app in `/Applications`.

The default helper cannot run without that signing identity. Contributors without access
to it need their own signing setup for a separate fork. Do not substitute a self-signed or
ad-hoc identity for the maintainer workflow, or reset privacy permissions to bypass a
signature mismatch. Matching signatures does not by itself verify Accessibility or Screen
Recording access; check both in the running app.

### Tests

```sh
xcodegen generate
xcodebuild -project Napoleon.xcodeproj -scheme NapoleonCore -destination 'platform=macOS' test
xcodebuild -project Napoleon.xcodeproj -scheme Napoleon -destination 'platform=macOS' test
```

`NapoleonCore` contains window filtering, ordering, selection, and registry logic.
Automated tests cover these rules and parts of the app layer. Accessibility, capture,
hotkeys, and Spaces also need checks in a running app; see the
[manual test matrix](docs/test-matrix.md).

For signed distribution builds and notarization, see [RELEASING.md](RELEASING.md).
Packaging does not publish a GitHub Release.

## License

[GNU AGPL v3.0](LICENSE). Copyright © 2026 Ryekee.
