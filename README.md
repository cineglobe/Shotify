# Shotify

Shotify is a lightweight macOS menu bar app that automatically copies new screenshots to your clipboard while keeping the files in your chosen screenshots folder.

![Shotify menu bar](/Shotify/Images/shotify1.png)

## Features
- Auto-copy newly saved screenshots to the clipboard
- Menu bar controls to enable/disable, open the screenshots folder, and quit
- Folder selection with auto-detection of the macOS screenshot location
- Optional notifications and sound feedback on copy
- Launch at login toggle
- Toggle macOS screenshot thumbnails (to avoid the 5-second delay)
- **Capture & Sketch (⌘⇧9):** select an area as with ⌘⇧4, then draw on the capture (pen, highlighter, arrow, line, box, oval, text) before it's copied. The shortcut can be changed or turned off in Settings.

## How It Works
- Monitors your screenshot folder using Spotlight metadata (`kMDItemIsScreenCapture`) for efficient detection.
- Copies the screenshot image to the clipboard and also writes the file URL for apps that prefer file references.

## Requirements
- macOS
- Xcode (to build and run)

## Install
The normal way to install Shotify is to download the latest `.app` from GitHub Releases.

## Build & Run
1. Open `Shotify.xcodeproj` in Xcode.
2. Select the `Shotify` scheme.
3. Build and Run.

## Usage
- Use the menu bar icon to toggle auto-copy on/off.
- Open Settings from the menu bar to configure behavior and folders.

## Settings
- Enable/disable auto-copy
- Show notifications
- Play sound on copy
- Launch at login
- Toggle macOS screenshot thumbnail
- Choose or detect the screenshot folder

![Shotify menu bar](/Shotify/Images/shotify2.png)

## Notes
- If no custom folder is set, Shotify tries to read the macOS screenshot location and falls back to Desktop.
- The app runs in the menu bar (no Dock icon).

## License
No license file is included yet. Add a `LICENSE` file to clarify reuse.
