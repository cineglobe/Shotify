//
//  SketchEditor.swift
//  Shotify
//

import AppKit
import SwiftUI
import Combine

// MARK: - Window Controller

/// Full-screen overlay that grows the screenshot out of its original spot
/// and lets you draw on it.
@MainActor
final class SketchEditorWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let image: NSImage
    private let imageURL: URL?
    private let sourceRect: CGRect
    private let screen: NSScreen
    private let document = SketchDocument()
    private let window: SketchWindow
    private let canvas: SketchCanvasView
    private let toolbarHost: NSHostingView<SketchToolbar>
    private var isClosing = false
    private var didCopy = false

    /// - Parameters:
    ///   - sourceRect: Where the screenshot was taken, in global AppKit coordinates
    ///   - imageURL: Temporary capture file, deleted when the editor closes
    init(image: NSImage, imageURL: URL?, sourceRect: CGRect, screen: NSScreen) {
        self.image = image
        self.imageURL = imageURL
        self.sourceRect = sourceRect
        self.screen = screen

        window = SketchWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        canvas = SketchCanvasView(image: image, document: document)
        toolbarHost = NSHostingView(rootView: SketchToolbar(document: document, actions: .init()))

        super.init()

        toolbarHost.rootView = SketchToolbar(document: document, actions: .init(
            copy: { [weak self] in self?.copyAndClose() },
            save: { [weak self] in self?.saveAndClose() },
            close: { [weak self] in self?.close() }
        ))

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrame(screen.frame, display: false)

        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        container.addSubview(toolbarHost)
        window.contentView = container

        window.keyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        document.onChange = { [weak self] in
            self?.canvas.needsDisplay = true
        }
    }

    func present() {
        layoutToolbar()

        // Start exactly over the captured region, then grow into place
        let start = sourceRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let target = targetImageRect()
        document.displayScale = target.width / image.size.width
        canvas.imageRect = start
        canvas.backdropOpacity = 0
        toolbarHost.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)

        canvas.animate(to: target, backdropOpacity: 1, duration: 0.32)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toolbarHost.animator().alphaValue = 1
        }
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        document.commitTextEditing()

        // Never lose edits: closing any way copies the marked-up image
        if !didCopy, !document.annotations.isEmpty, let png = document.renderPNG(image: image) {
            copyToPasteboard(png)
        }

        // Shrink back toward where it came from while fading out
        let start = sourceRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        canvas.animate(to: start, backdropOpacity: 0, duration: 0.2)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window.orderOut(nil)
                if let imageURL = self.imageURL {
                    try? FileManager.default.removeItem(at: imageURL)
                }
                self.onClose?()
            }
        }
    }

    // MARK: - Layout

    private var toolbarBottomInset: CGFloat {
        // Stay above the Dock when it's showing
        max(screen.visibleFrame.minY - screen.frame.minY, 0) + 24
    }

    private func layoutToolbar() {
        let size = toolbarHost.fittingSize
        let bounds = window.contentView?.bounds ?? .zero
        toolbarHost.frame = CGRect(
            x: (bounds.width - size.width) / 2,
            y: toolbarBottomInset,
            width: size.width,
            height: size.height
        ).integral
    }

    /// The largest rect the screenshot can grow to while leaving room for the toolbar
    private func targetImageRect() -> CGRect {
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
        let available = CGRect(
            x: bounds.minX + 48,
            y: toolbarHost.frame.maxY + 24,
            width: bounds.width - 96,
            height: bounds.height - menuBarHeight - 40 - (toolbarHost.frame.maxY + 24)
        )

        let size = image.size
        // Fill the space, but don't blow tiny captures up past 4×
        let scale = min(available.width / size.width, available.height / size.height, 4)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: available.midX - fitted.width / 2,
            y: available.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        ).integral
    }

    // MARK: - Actions

    private func copyAndClose() {
        guard let png = document.renderPNG(image: image) else { return }
        copyToPasteboard(png)
        close()
    }

    private func saveAndClose() {
        guard let png = document.renderPNG(image: image) else { return }

        let folder = UserDefaults.standard.string(forKey: "screenshotFolderPath")
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let fileURL = folder.appendingPathComponent("Sketch \(formatter.string(from: Date())).png")

        do {
            try png.write(to: fileURL)
        } catch {
            print("📸 Shotify: Failed to save sketch: \(error)")
            NSSound.beep()
            return
        }

        copyToPasteboard(png)
        close()
    }

    private func copyToPasteboard(_ png: Data) {
        didCopy = true
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        if UserDefaults.standard.bool(forKey: "playSoundOnCopy") {
            NSSound(named: "Pop")?.play()
        }
    }

    // MARK: - Keyboard

    /// Handles every key press in the editor; returns true if consumed
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Shortcuts that work everywhere
        if command {
            switch key {
            case "z":
                shift ? document.redo() : document.undo()
            case "c":
                copyAndClose()
            case "s":
                saveAndClose()
            case "w":
                close()
            case "v" where document.editingTextID != nil:
                if let string = NSPasteboard.general.string(forType: .string) {
                    document.insertText(string)
                }
            default:
                return false
            }
            return true
        }

        // Typing into a text box
        if document.editingTextID != nil {
            switch Int(event.keyCode) {
            case 53: // Esc
                document.commitTextEditing()
            case 36, 76: // Return / Enter
                if shift {
                    document.insertText("\n")
                } else {
                    document.commitTextEditing()
                }
            case 51, 117: // Delete / Forward Delete
                document.deleteBackward()
            default:
                if let characters = event.characters,
                   !characters.isEmpty,
                   characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                    document.insertText(characters)
                }
            }
            return true
        }

        switch Int(event.keyCode) {
        case 53: // Esc
            close()
            return true
        case 36, 76: // Return / Enter
            copyAndClose()
            return true
        default:
            break
        }

        if let tool = SketchTool.allCases.first(where: { String($0.shortcut) == key }) {
            document.tool = tool
            return true
        }
        if let digit = Int(key), (1...SketchDocument.palette.count).contains(digit) {
            document.color = SketchDocument.palette[digit - 1]
            return true
        }
        switch key {
        case "[":
            document.lineWidth = max(1, document.lineWidth - 1)
        case "]":
            document.lineWidth = min(24, document.lineWidth + 1)
        case "-":
            document.fontSize = max(12, document.fontSize - 4)
        case "=", "+":
            document.fontSize = min(96, document.fontSize + 4)
        default:
            return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        document.commitTextEditing()
    }
}

// MARK: - Window

final class SketchWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        // Route keys to the editor even if a toolbar control took focus
        if event.type == .keyDown, let keyHandler, keyHandler(event) {
            return
        }
        super.sendEvent(event)
    }
}

// MARK: - Canvas

final class SketchCanvasView: NSView {
    private let image: NSImage
    private let document: SketchDocument
    private var current: SketchAnnotation?
    private var cancellables = Set<AnyCancellable>()

    /// Where the screenshot is drawn, in view coordinates
    var imageRect: CGRect = .zero {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var backdropOpacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    private var animationTimer: Timer?

    init(image: NSImage, document: SketchDocument) {
        self.image = image
        self.document = document
        super.init(frame: .zero)

        document.$tool
            .sink { [weak self] _ in
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scale: CGFloat {
        image.size.width > 0 ? imageRect.width / image.size.width : 1
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (point.x - imageRect.minX) / scale, y: (point.y - imageRect.minY) / scale)
    }

    // MARK: Animation

    func animate(to target: CGRect, backdropOpacity targetOpacity: CGFloat, duration: TimeInterval) {
        animationTimer?.invalidate()
        let startRect = imageRect
        let startOpacity = backdropOpacity
        let startTime = CACurrentMediaTime()

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let progress = min((CACurrentMediaTime() - startTime) / duration, 1)
                // Ease-out with a touch of overshoot so it feels like it pops
                let t = 1 + 2.2 * pow(progress - 1, 3) + 1.2 * pow(progress - 1, 2)
                let eased = CGFloat(progress >= 1 ? 1 : t)
                self.imageRect = CGRect(
                    x: startRect.minX + (target.minX - startRect.minX) * eased,
                    y: startRect.minY + (target.minY - startRect.minY) * eased,
                    width: startRect.width + (target.width - startRect.width) * eased,
                    height: startRect.height + (target.height - startRect.height) * eased
                )
                self.backdropOpacity = startOpacity + (targetOpacity - startOpacity) * CGFloat(min(progress * 1.4, 1))
                if progress >= 1 {
                    timer.invalidate()
                    self.imageRect = target
                }
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.6 * backdropOpacity).setFill()
        bounds.fill()

        guard imageRect.width > 0, imageRect.height > 0 else { return }

        // Drop shadow behind the screenshot
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5 * backdropOpacity)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = CGSize(width: 0, height: -8)
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: imageRect)

        // Annotations live in image coordinates
        let transform = NSAffineTransform()
        transform.translateX(by: imageRect.minX, yBy: imageRect.minY)
        transform.scale(by: scale)
        transform.concat()

        for annotation in document.annotations {
            annotation.draw()
        }
        current?.draw()

        if let editing = document.editingText {
            drawTextEditingChrome(for: editing)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawTextEditingChrome(for annotation: SketchAnnotation) {
        let bounds = annotation.textBounds
        let pad = 4 / scale

        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: -pad * 1.5, dy: -pad), xRadius: pad, yRadius: pad)
        box.lineWidth = 1 / scale
        box.setLineDash([4 / scale, 3 / scale], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.85).setStroke()
        box.stroke()

        // Caret after the last character
        let lines = annotation.text.components(separatedBy: "\n")
        let lastLine = (lines.last ?? "") as NSString
        let lineWidth = lastLine.size(withAttributes: annotation.textAttributes).width
        let font = annotation.textAttributes[.font] as? NSFont
        let lineHeight = font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? annotation.fontSize
        let caretX = bounds.minX + lineWidth + 1 / scale
        let caret = NSBezierPath()
        caret.move(to: CGPoint(x: caretX, y: bounds.minY))
        caret.line(to: CGPoint(x: caretX, y: bounds.minY + lineHeight))
        caret.lineWidth = max(2 / scale, annotation.fontSize / 14)
        annotation.color.setStroke()
        caret.stroke()
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor = document.tool == .text ? .iBeam : .crosshair
        addCursorRect(imageRect, cursor: cursor)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = imagePoint(for: event)

        if document.tool == .text {
            if let existing = document.textAnnotation(at: point) {
                if existing.id != document.editingTextID {
                    document.editText(existing.id)
                }
            } else {
                document.beginText(at: point)
            }
            return
        }

        document.commitTextEditing()
        let width = document.tool == .highlighter ? max(document.lineWidth * 3, 12) : document.lineWidth
        current = SketchAnnotation(
            tool: document.tool,
            color: document.color,
            lineWidth: width / scale,
            points: [point]
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var annotation = current, let start = annotation.points.first else { return }
        var point = imagePoint(for: event)

        switch annotation.tool {
        case .pen, .highlighter:
            if let last = annotation.points.last, hypot(point.x - last.x, point.y - last.y) < 1 / scale {
                return
            }
            annotation.points.append(point)
        default:
            if event.modifierFlags.contains(.shift) {
                point = constrained(point, from: start, tool: annotation.tool)
            }
            annotation.points = [start, point]
        }
        current = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let annotation = current else { return }
        current = nil

        // Ignore accidental clicks with shape tools
        if annotation.tool != .pen && annotation.tool != .highlighter {
            guard let start = annotation.points.first, let end = annotation.points.last,
                  hypot(end.x - start.x, end.y - start.y) * scale > 3 else {
                needsDisplay = true
                return
            }
        }
        document.add(annotation)
    }

    /// Shift snaps lines to 45° and makes boxes/ovals square
    private func constrained(_ point: CGPoint, from start: CGPoint, tool: SketchTool) -> CGPoint {
        let dx = point.x - start.x
        let dy = point.y - start.y
        switch tool {
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        default:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
    }
}

// MARK: - Toolbar

struct SketchToolbar: View {
    struct Actions {
        var copy: () -> Void = {}
        var save: () -> Void = {}
        var close: () -> Void = {}
    }

    @ObservedObject var document: SketchDocument
    let actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(SketchTool.allCases) { tool in
                    ToolbarIconButton(
                        symbol: tool.symbol,
                        help: "\(tool.title) (\(tool.shortcut.uppercased()))",
                        isSelected: document.tool == tool
                    ) {
                        document.tool = tool
                    }
                }
            }

            ToolbarDivider()

            HStack(spacing: 6) {
                ForEach(Array(SketchDocument.palette.enumerated()), id: \.offset) { index, color in
                    ColorSwatch(color: Color(nsColor: color), isSelected: document.color == color) {
                        document.color = color
                    }
                    .help("Color (\(index + 1))")
                }
            }

            ToolbarDivider()

            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: document.color))
                    .frame(width: max(4, min(document.lineWidth, 20)), height: max(4, min(document.lineWidth, 20)))
                    .frame(width: 20, height: 20)
                Slider(value: $document.lineWidth, in: 1...24)
                    .frame(width: 84)
                    .controlSize(.small)
            }
            .help("Thickness ( [ and ] )")

            HStack(spacing: 8) {
                Image(systemName: "textformat.size")
                    .frame(width: 20)
                Slider(value: $document.fontSize, in: 12...96)
                    .frame(width: 84)
                    .controlSize(.small)
            }
            .help("Text size ( - and + )")

            ToolbarDivider()

            HStack(spacing: 2) {
                ToolbarIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", action: document.undo)
                    .disabled(!document.canUndo)
                ToolbarIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: document.redo)
                    .disabled(!document.canRedo)
                ToolbarIconButton(symbol: "trash", help: "Clear All", action: document.clear)
                    .disabled(document.annotations.isEmpty)
            }

            ToolbarDivider()

            HStack(spacing: 8) {
                ToolbarIconButton(symbol: "xmark", help: "Close (Esc)", action: actions.close)
                ToolbarIconButton(symbol: "square.and.arrow.down", help: "Save to Screenshots Folder & Copy (⌘S)", action: actions.save)
                Button(action: actions.copy) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Copy to Clipboard (Return)")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    var isSelected = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.22) : (isHovering && isEnabled ? Color.white.opacity(0.1) : .clear))
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct ColorSwatch: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 22)
    }
}
