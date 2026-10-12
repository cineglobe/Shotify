//
//  SketchDocument.swift
//  Shotify
//

import AppKit
import SwiftUI
import Combine

enum SketchTool: String, CaseIterable, Identifiable {
    case pen, highlighter, arrow, line, rectangle, ellipse, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Box"
        case .ellipse: "Oval"
        case .text: "Text"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        }
    }

    /// Single-key shortcut used in the editor
    var shortcut: Character {
        switch self {
        case .pen: "p"
        case .highlighter: "h"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        }
    }
}

/// A single mark on the screenshot. Geometry is stored in image points so
/// marks stay put when the view resizes and export at full resolution.
struct SketchAnnotation: Identifiable, Equatable {
    let id = UUID()
    var tool: SketchTool
    var color: NSColor
    var lineWidth: CGFloat
    var points: [CGPoint]
    var text: String = ""
    var fontSize: CGFloat = 0

    // MARK: - Text

    var textAttributes: [NSAttributedString.Key: Any] {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
        return [.font: font, .foregroundColor: color]
    }

    /// Text is anchored at its top-left corner (`points[0]`)
    var textBounds: CGRect {
        guard let origin = points.first else { return .zero }
        let measured = (text.isEmpty ? " " : text) as NSString
        let size = measured.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes
        ).size
        return CGRect(x: origin.x, y: origin.y - ceil(size.height), width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: - Drawing

    /// Draws into the current graphics context, in image coordinates
    func draw() {
        switch tool {
        case .pen, .highlighter:
            drawFreehand()
        case .arrow:
            drawArrow()
        case .line:
            guard let start = points.first, let end = points.last else { return }
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            stroke(path)
        case .rectangle:
            stroke(NSBezierPath(roundedRect: shapeRect, xRadius: lineWidth, yRadius: lineWidth))
        case .ellipse:
            stroke(NSBezierPath(ovalIn: shapeRect))
        case .text:
            guard !text.isEmpty, points.first != nil else { return }
            (text as NSString).draw(
                with: textBounds,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: textAttributes
            )
        }
    }

    private var strokeColor: NSColor {
        tool == .highlighter ? color.withAlphaComponent(0.4) : color
    }

    private var shapeRect: CGRect {
        guard let start = points.first, let end = points.last else { return .zero }
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func stroke(_ path: NSBezierPath) {
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        strokeColor.setStroke()
        path.stroke()
    }

    private func drawFreehand() {
        guard let first = points.first else { return }

        if points.count == 1 {
            let radius = lineWidth / 2
            strokeColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)).fill()
            return
        }

        // Smooth the stroke by curving through the midpoints of each segment
        let path = NSBezierPath()
        path.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.curve(to: mid, controlPoint: previous)
        }
        path.line(to: points[points.count - 1])
        stroke(path)
    }

    private func drawArrow() {
        guard let start = points.first, let end = points.last else { return }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }

        let angle = atan2(dy, dx)
        let headLength = min(lineWidth * 4 + 4, length)
        let headAngle: CGFloat = .pi / 7

        // Stop the shaft inside the head so the round cap doesn't poke out
        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * headLength * 0.6,
            y: end.y - sin(angle) * headLength * 0.6
        )
        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: shaftEnd)
        stroke(shaft)

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(
            x: end.x - cos(angle - headAngle) * headLength,
            y: end.y - sin(angle - headAngle) * headLength
        ))
        head.line(to: CGPoint(
            x: end.x - cos(angle + headAngle) * headLength,
            y: end.y - sin(angle + headAngle) * headLength
        ))
        head.close()
        head.lineJoinStyle = .round
        head.lineWidth = lineWidth / 2
        strokeColor.setFill()
        strokeColor.setStroke()
        head.fill()
        head.stroke()
    }
}

/// Editor state shared between the canvas and the SwiftUI toolbar
@MainActor
final class SketchDocument: ObservableObject {
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
        NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1), // black
    ]

    @Published var tool: SketchTool = .pen {
        didSet {
            if tool != .text { commitTextEditing() }
            UserDefaults.standard.set(tool.rawValue, forKey: "sketchTool")
        }
    }
    @Published var color: NSColor = SketchDocument.palette[0] {
        didSet {
            updateEditingText { $0.color = color }
            if let index = Self.palette.firstIndex(of: color) {
                UserDefaults.standard.set(index, forKey: "sketchColorIndex")
            }
        }
    }
    /// Stroke thickness in on-screen points
    @Published var lineWidth: CGFloat = 4 {
        didSet { UserDefaults.standard.set(Double(lineWidth), forKey: "sketchLineWidth") }
    }
    /// Text size in on-screen points
    @Published var fontSize: CGFloat = 24 {
        didSet {
            updateEditingText { $0.fontSize = fontSize / displayScale }
            UserDefaults.standard.set(Double(fontSize), forKey: "sketchFontSize")
        }
    }

    @Published private(set) var annotations: [SketchAnnotation] = []
    @Published private(set) var editingTextID: UUID?
    @Published private(set) var undoStack: [[SketchAnnotation]] = []
    @Published private(set) var redoStack: [[SketchAnnotation]] = []

    /// On-screen points per image point; converts toolbar sizes to image units
    var displayScale: CGFloat = 1
    /// Called whenever the canvas needs to redraw
    var onChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "sketchTool"), let saved = SketchTool(rawValue: raw) {
            tool = saved
        }
        if let index = defaults.object(forKey: "sketchColorIndex") as? Int, Self.palette.indices.contains(index) {
            color = Self.palette[index]
        }
        if let width = defaults.object(forKey: "sketchLineWidth") as? Double {
            lineWidth = CGFloat(width)
        }
        if let size = defaults.object(forKey: "sketchFontSize") as? Double {
            fontSize = CGFloat(size)
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Edits

    func add(_ annotation: SketchAnnotation) {
        commitTextEditing()
        recordUndo()
        annotations.append(annotation)
        onChange?()
    }

    func undo() {
        commitTextEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        onChange?()
    }

    func redo() {
        commitTextEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        onChange?()
    }

    func clear() {
        commitTextEditing()
        guard !annotations.isEmpty else { return }
        recordUndo()
        annotations.removeAll()
        onChange?()
    }

    private func recordUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    // MARK: - Text Editing

    var editingText: SketchAnnotation? {
        annotations.first { $0.id == editingTextID }
    }

    /// Starts a new text box at `point` (image coordinates)
    func beginText(at point: CGPoint) {
        commitTextEditing()
        recordUndo()
        let annotation = SketchAnnotation(
            tool: .text,
            color: color,
            lineWidth: 0,
            points: [point],
            fontSize: fontSize / displayScale
        )
        annotations.append(annotation)
        editingTextID = annotation.id
        onChange?()
    }

    /// Re-opens an existing text box for editing
    func editText(_ id: UUID) {
        commitTextEditing()
        recordUndo()
        editingTextID = id
        onChange?()
    }

    func textAnnotation(at point: CGPoint) -> SketchAnnotation? {
        annotations.last { $0.tool == .text && $0.textBounds.insetBy(dx: -4, dy: -4).contains(point) }
    }

    func insertText(_ string: String) {
        updateEditingText { $0.text += string }
    }

    func deleteBackward() {
        updateEditingText { if !$0.text.isEmpty { $0.text.removeLast() } }
    }

    func commitTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if let index = annotations.firstIndex(where: { $0.id == id }),
           annotations[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.remove(at: index)
        }
        // Drop the undo step if editing didn't change anything
        if undoStack.last == annotations {
            undoStack.removeLast()
        }
        onChange?()
    }

    private func updateEditingText(_ update: (inout SketchAnnotation) -> Void) {
        guard let id = editingTextID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        update(&annotations[index])
        onChange?()
    }

    // MARK: - Export

    /// Renders the screenshot with all annotations at full pixel resolution
    func renderPNG(image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: cgImage.width,
                pixelsHigh: cgImage.height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return nil }

        // Draw in image points; the bitmap scales up to pixels
        bitmap.size = image.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        for annotation in annotations {
            annotation.draw()
        }
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }
}
