import AppKit
import SwiftUI

/// Drawing a DXF on screen: fit it to the window, then let the person zoom and drag.
///
/// AppKit rather than SwiftUI shapes — a drawing is thousands of segments, and one draw call
/// over a transformed context is the difference between a picture that pans smoothly and a
/// view that rebuilds a thousand Paths per frame.
final class DXFCanvas: NSView {

    var document = DXFDocument() {
        didSet { touched = false; fittedFor = .zero; needsDisplay = true }
    }
    /// Colour for everything: a viewer, not a CAD program, so the drawing takes the theme's
    /// ink rather than AutoCAD's palette on a black background.
    var ink: NSColor = .labelColor { didSet { needsDisplay = true } }

    private var scale: CGFloat = 1
    private var offset = CGPoint.zero
    /// The size the current fit was computed for, and whether the person has since moved the
    /// drawing themselves.
    private var fittedFor = CGSize.zero
    private var touched = false

    override var isFlipped: Bool { false }   // drawings count Y upward, like the format does
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Since macOS 14 a view no longer clips its own drawing, and this one paints a picture
        // scaled to whatever it was last fitted to — without this the drawing runs out over the
        // window's own controls.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    override func layout() {
        super.layout()
        // Refit on every resize until the person moves the drawing themselves: a fit made for
        // an earlier size is the wrong size, and SwiftUI lays a view out more than once.
        if !touched, bounds.size != fittedFor { fitToWindow() }
    }

    /// Show the whole drawing, with a small margin so nothing touches the edge.
    func fitToWindow() {
        let box = document.bounds
        guard box.width > 0 || box.height > 0, bounds.width > 4, bounds.height > 4 else { return }
        let margin: CGFloat = 16
        let usable = CGSize(width: max(1, bounds.width - margin * 2),
                            height: max(1, bounds.height - margin * 2))
        let byWidth = box.width > 0 ? usable.width / box.width : .greatestFiniteMagnitude
        let byHeight = box.height > 0 ? usable.height / box.height : .greatestFiniteMagnitude
        scale = max(0.0001, min(byWidth, byHeight))
        offset = CGPoint(x: bounds.midX - (box.midX * scale),
                         y: bounds.midY - (box.midY * scale))
        fittedFor = bounds.size
        touched = false
        needsDisplay = true
    }

    // MARK: - Zoom and pan

    override func scrollWheel(with event: NSEvent) {
        // A pinch or a wheel zooms around the pointer, so the thing under it stays put.
        let factor = event.hasPreciseScrollingDeltas ? 1 + event.scrollingDeltaY / 300
                                                     : 1 + event.deltaY / 20
        zoom(by: factor, around: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    private func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let wanted = max(0.00001, min(100_000, scale * max(0.2, min(5, factor))))
        guard wanted != scale else { return }
        // Keep the point under the cursor where it is: the drawing grows away from it.
        offset.x = anchor.x - (anchor.x - offset.x) * (wanted / scale)
        offset.y = anchor.y - (anchor.y - offset.y) * (wanted / scale)
        scale = wanted
        touched = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        offset.x += event.deltaX
        offset.y -= event.deltaY          // the view is not flipped; the event is
        touched = true
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "0", "=": fitToWindow()
        case "+": zoom(by: 1.25, around: CGPoint(x: bounds.midX, y: bounds.midY))
        case "-": zoom(by: 0.8, around: CGPoint(x: bounds.midX, y: bounds.midY))
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }

        context.translateBy(x: offset.x, y: offset.y)
        context.scaleBy(x: scale, y: scale)
        // One hairline whatever the zoom: a drawing is read by its shapes, and a line that
        // thickens with the zoom turns a dense area into a blot.
        context.setLineWidth(1 / scale)
        context.setStrokeColor(ink.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for entity in document.entities {
            switch entity {
            case .line(let from, let to, _):
                context.move(to: from)
                context.addLine(to: to)
                context.strokePath()

            case .circle(let centre, let radius, _):
                context.addArc(center: centre, radius: radius, startAngle: 0,
                               endAngle: .pi * 2, clockwise: false)
                context.strokePath()

            case .arc(let centre, let radius, let start, let end, _):
                // DXF states angles in degrees, counter-clockwise; Core Graphics wants radians.
                context.addArc(center: centre, radius: radius,
                               startAngle: start * .pi / 180, endAngle: end * .pi / 180,
                               clockwise: false)
                context.strokePath()

            case .polyline(let points, let closed, _):
                guard let first = points.first else { continue }
                context.move(to: first)
                for point in points.dropFirst() { context.addLine(to: point) }
                if closed { context.closePath() }
                context.strokePath()

            case .point(let at, _):
                let r = 1.5 / scale
                context.fillEllipse(in: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))

            case .text(let string, let at, let height, let rotation, _):
                draw(text: string, at: at, height: height, rotation: rotation, in: context)
            }
        }
    }

    private func draw(text: String, at origin: CGPoint, height: CGFloat, rotation: CGFloat,
                      in context: CGContext) {
        // Text is drawn at the drawing's own size, so it grows and shrinks with everything
        // else rather than floating at a screen size of its own.
        let size = max(0.01, height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: ink,
        ]
        let line = NSAttributedString(string: text, attributes: attributes)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if rotation != 0 { context.rotate(by: rotation * .pi / 180) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        line.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

/// The SwiftUI face of the canvas, with the caption the viewer shows underneath.
struct DXFView: NSViewRepresentable {
    let document: DXFDocument
    let ink: Color

    func makeNSView(context: Context) -> DXFCanvas {
        let canvas = DXFCanvas()
        canvas.document = document
        canvas.ink = NSColor(ink)
        return canvas
    }

    func updateNSView(_ canvas: DXFCanvas, context: Context) {
        canvas.ink = NSColor(ink)
    }
}
