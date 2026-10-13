# Shotify

A lightweight macOS menu bar app (no Dock icon) that copies every new screenshot to the clipboard while keeping the file, plus **Capture & Sketch** (⌘⇧9): a native area selection followed by a drawing editor before copying. SwiftUI + AppKit, macOS 15.7+, team `NUAS7PNFBF`, version 1.1. Distributed as an `.app` on GitHub Releases (`cineglobe/Shotify`).

## Build

Open `Shotify.xcodeproj` (hand-maintained, not generated), scheme `Shotify`, or:

```bash
xcodebuild -project Shotify.xcodeproj -scheme Shotify -configuration Debug build
xcodebuild -project Shotify.xcodeproj -scheme Shotify test
```

## How it works

- `ScreenshotMonitor.swift`: finds the screenshot folder (`defaults read com.apple.screencapture location`, falling back to the Desktop) and watches it with an `NSMetadataQuery` on `kMDItemIsScreenCapture`, so only real screenshots trigger a copy. It writes both the image and the file URL to the pasteboard.
- `GlobalHotKey.swift`: system-wide shortcuts through Carbon `RegisterEventHotKey`, which needs **no Accessibility permission**. Keep it that way rather than switching to `NSEvent` global monitors.
- `SketchController.swift` runs `/usr/sbin/screencapture` for the native selection, then opens `SketchEditor` (tools, colours, undo and redo in `SketchDocument`). Return or ⌘C copies, ⌘S saves and copies, and closing any other way still copies the image if it was edited.
- `SettingsView.swift`: auto-copy, notifications, sound, launch at login, the screenshot-thumbnail toggle, the folder, and the Sketch shortcut.

## Rules

- Stay lightweight: no polling. Detection comes from Spotlight metadata updates.
- Never delete or move the user's screenshot files; Shotify only reads them.
- Update the README's features list when adding a user-visible feature.
