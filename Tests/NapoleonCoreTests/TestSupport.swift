@testable import NapoleonCore

func w(_ id: WindowID, pid: ProcessID = 1, minimized: Bool = false, hidden: Bool = false,
       onCurrentSpace: Bool = true, pinyin: String? = nil, fullscreen: Bool = false) -> WindowInfo {
    WindowInfo(id: id, pid: pid, appName: "A\(id)", appBundleID: nil, title: "T\(id)",
               isMinimized: minimized, isHiddenApp: hidden, isOnCurrentSpace: onCurrentSpace, pinyinTitle: pinyin,
               isFullscreen: fullscreen)
}
