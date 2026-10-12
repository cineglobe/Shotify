//
//  SketchController.swift
//  Shotify
//

import AppKit
import Carbon.HIToolbox

/// Owns the "Capture & Sketch" hotkey: runs the native ⌘⇧4-style selection,
/// then opens the captured region in the sketch editor, growing out of the
/// spot on screen where it was taken.
@MainActor
final class SketchController {
    static let shared = SketchController()

    /// Keys offered for the ⌘⇧ sketch shortcut, mapped to virtual key codes
    static let availableKeys: [(key: String, keyCode: Int)] = [
        ("9", kVK_ANSI_9),
        ("8", kVK_ANSI_8),
        ("7", kVK_ANSI_7),
        ("0", kVK_ANSI_0),
    ]

    private var hotKey: GlobalHotKey?
    private var captureProcess: Process?
    private var mouseMonitor: Any?
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var editor: SketchEditorWindowController?

    private init() {}

    // MARK: - Hotkey

    /// Registers (or re-registers) the hotkey based on the current settings
    func updateHotKey() {
        hotKey?.unregister()
        hotKey = nil

        let defaults = UserDefaults.standard
        let isEnabled = defaults.object(forKey: "sketchHotKeyEnabled") as? Bool ?? true
        guard isEnabled else { return }

        let key = defaults.string(forKey: "sketchHotKeyKey") ?? "9"
        let keyCode = Self.availableKeys.first { $0.key == key }?.keyCode ?? kVK_ANSI_9

        hotKey = GlobalHotKey(keyCode: keyCode, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.startCapture()
        }
    }

    // MARK: - Capture

    func startCapture() {
        guard captureProcess == nil else { return }
        editor?.close()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shotify-Sketch-\(UUID().uuidString).png")

        // Watch the selection drag so the editor can open from the same spot.
        // Global mouse monitors don't require Accessibility permission.
        dragStart = nil
        dragEnd = nil
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseDown {
                    if self.dragStart == nil { self.dragStart = location }
                } else {
                    self.dragEnd = location
                }
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: the same interactive crosshair as ⌘⇧4 (space toggles window mode)
        process.arguments = ["-i", outputURL.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.captureFinished(outputURL: outputURL)
            }
        }

        do {
            try process.run()
            captureProcess = process
        } catch {
            print("📸 Shotify: Failed to launch screencapture: \(error)")
            removeMouseMonitor()
        }
    }

    private func captureFinished(outputURL: URL) {
        captureProcess = nil
        removeMouseMonitor()

        // No file means the user cancelled with Esc
        guard FileManager.default.fileExists(atPath: outputURL.path),
              let image = NSImage(contentsOf: outputURL),
              let bitmap = image.representations.first else {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }

        let endPoint = dragEnd ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(endPoint, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        // Size the image as it appeared on screen, regardless of file DPI
        let scale = screen.backingScaleFactor
        image.size = CGSize(
            width: CGFloat(bitmap.pixelsWide) / scale,
            height: CGFloat(bitmap.pixelsHigh) / scale
        )

        let sourceRect = selectionRect(for: image.size, endPoint: endPoint, on: screen)

        let editor = SketchEditorWindowController(
            image: image,
            imageURL: outputURL,
            sourceRect: sourceRect,
            screen: screen
        )
        editor.onClose = { [weak self] in
            self?.editor = nil
        }
        self.editor = editor
        editor.present()
    }

    /// Where the captured region was on screen, in global AppKit coordinates
    private func selectionRect(for size: CGSize, endPoint: CGPoint, on screen: NSScreen) -> CGRect {
        if let start = dragStart, let end = dragEnd {
            let dragged = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            // Trust the drag only if it matches what was captured; window
            // captures (space bar) and moved selections fall through.
            if abs(dragged.width - size.width) < 4 && abs(dragged.height - size.height) < 4 {
                return CGRect(origin: dragged.origin, size: size)
            }
        }

        // Fall back to centering on the cursor, kept on screen
        var rect = CGRect(
            x: endPoint.x - size.width / 2,
            y: endPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        let frame = screen.frame
        rect.origin.x = min(max(rect.minX, frame.minX), max(frame.minX, frame.maxX - rect.width))
        rect.origin.y = min(max(rect.minY, frame.minY), max(frame.minY, frame.maxY - rect.height))
        return rect
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
    }

    #if DEBUG
    /// Opens the editor on an existing image without capturing (for testing)
    func openEditorForTesting(imageURL: URL) {
        guard let image = NSImage(contentsOf: imageURL), let screen = NSScreen.main else { return }
        let size = image.size
        let sourceRect = CGRect(
            x: screen.frame.midX - size.width / 4,
            y: screen.frame.midY - size.height / 4,
            width: size.width / 2,
            height: size.height / 2
        )
        let editor = SketchEditorWindowController(image: image, imageURL: nil, sourceRect: sourceRect, screen: screen)
        editor.onClose = { [weak self] in self?.editor = nil }
        self.editor = editor
        editor.present()
    }
    #endif
}
