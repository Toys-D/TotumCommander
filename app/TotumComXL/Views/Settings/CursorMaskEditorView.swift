import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Illustrator-style pen, as geometry: anchors, optional Bézier handles, a close test.
///
/// A CLICK places a corner anchor. A click-DRAG places an anchor and pulls its handles out
/// symmetrically — the classic pen gesture. Segments between anchors use the neighbouring
/// handles as Bézier controls; a segment between two handle-less anchors is a straight line.
/// The path lives in MASK coordinates; the view only converts and draws.
final class PenPath {
    struct Node {
        var anchor: NSPoint
        var handleOut: NSPoint?
        var handleIn: NSPoint?
    }

    private(set) var nodes: [Node] = []
    private(set) var isClosed = false
    /// How close to the first anchor a click must land to close the contour.
    static let closeTolerance: CGFloat = 10

    var isEmpty: Bool { nodes.isEmpty }
    var canClose: Bool { nodes.count >= 3 }

    func begin(at p: NSPoint) {
        guard !isClosed else { return }
        nodes.append(Node(anchor: p, handleOut: nil, handleIn: nil))
    }

    /// Dragging after placement pulls the handles out, mirrored about the anchor.
    func dragLast(to p: NSPoint) {
        guard !isClosed, var last = nodes.last else { return }
        last.handleOut = p
        last.handleIn = NSPoint(x: 2 * last.anchor.x - p.x, y: 2 * last.anchor.y - p.y)
        nodes[nodes.count - 1] = last
    }

    func removeLast() {
        isClosed = false
        if !nodes.isEmpty { nodes.removeLast() }
    }

    func isNearStart(_ p: NSPoint) -> Bool {
        guard canClose, let first = nodes.first else { return false }
        return hypot(p.x - first.anchor.x, p.y - first.anchor.y) <= Self.closeTolerance
    }

    func close() {
        guard canClose else { return }
        isClosed = true
    }

    /// Shift-constrained placement: the new anchor snaps to 45° steps from the previous one.
    func constrained(_ p: NSPoint) -> NSPoint {
        guard let last = nodes.last else { return p }
        let dx = p.x - last.anchor.x, dy = p.y - last.anchor.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return p }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return NSPoint(x: last.anchor.x + cos(angle) * distance,
                       y: last.anchor.y + sin(angle) * distance)
    }

    /// The path as drawn so far; `previewTo` adds the rubber-band segment to the hover point.
    func bezierPath(previewTo hover: NSPoint? = nil) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = nodes.first else { return path }
        path.move(to: first.anchor)
        for i in 1..<nodes.count {
            addSegment(path, from: nodes[i - 1], to: nodes[i])
        }
        if isClosed {
            addSegment(path, from: nodes[nodes.count - 1], to: first)
            path.close()
        } else if let hover {
            path.line(to: hover)
        }
        return path
    }

    private func addSegment(_ path: NSBezierPath, from a: Node, to b: Node) {
        if a.handleOut == nil && b.handleIn == nil {
            path.line(to: b.anchor)
        } else {
            path.curve(to: b.anchor,
                       controlPoint1: a.handleOut ?? a.anchor,
                       controlPoint2: b.handleIn ?? b.anchor)
        }
    }
}

/// The canvas model: a bitmap the brush paints into. Separate from any view so the painting
/// itself — strokes, erasing, clearing, inverting — is plain testable code.
///
/// Convention: WHITE with alpha is the cursor's body, transparent is not-cursor. The bitmap is
/// saved as-is; FeatheredCursor tints it with the live cursor colour, so the drawing carries
/// only the shape.
@MainActor
final class CursorMaskCanvas: ObservableObject {

    /// The COMPOSITED mask: the artwork with the fades applied. This is what the canvas shows,
    /// what the preview pushes and what gets saved — the cursor never sees anything else.
    let rep: NSBitmapImageRep
    /// The artwork ALONE: strokes, a preset, a loaded picture — whatever the user made, before
    /// any fade. Kept apart so a fade is a filter over the drawing instead of a replacement for
    /// it: turn a fade on over a loaded picture and the picture fades; turn it off and the
    /// picture comes back whole.
    let artwork: NSBitmapImageRep
    private var hSpec: GradientSpec?
    private var vSpec: GradientSpec?
    /// Bumped on every change so SwiftUI re-renders the canvas and the preview.
    @Published private(set) var version = 0

    /// A blank mask-shaped bitmap: 8 bits per sample, alpha last and PREMULTIPLIED (the default
    /// format) — which is what the raw-byte writing in `load` counts on.
    static func blankRep(_ size: NSSize) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil,
                         pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                         bitsPerSample: 8, samplesPerPixel: 4,
                         hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }

    init(startingFrom saved: NSImage? = nil) {
        let size = CursorMaskStore.maskSize
        rep = Self.blankRep(size)!
        artwork = Self.blankRep(size)!
        if let saved {
            draw { _ in
                saved.draw(in: NSRect(origin: .zero, size: size),
                           from: .zero, operation: .copy, fraction: 1.0)
            }
        } else {
            composite()
        }
    }

    /// Every drawing operation paints into the ARTWORK, then the mask is composited from it.
    private func draw(_ body: (NSGraphicsContext) -> Void) {
        guard let ctx = NSGraphicsContext(bitmapImageRep: artwork) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        body(ctx)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        composite()
    }

    /// Artwork × fades → the mask. The fades multiply the artwork's alpha, so a loaded picture
    /// keeps its shape and merely melts where the fade says so.
    ///
    /// With nothing drawn AND a fade active the artwork stands in as a full bar: a fade switched
    /// on over an empty canvas has to show something, and the whole bar melting is what a fade
    /// meant before the artwork existed as a separate layer. (Which is also why «Очистить» with
    /// a fade on leaves the fading bar rather than an empty square — switch the fades off for a
    /// blank canvas.) With no fades either, empty stays empty.
    private func composite() {
        let size = CursorMaskStore.maskSize
        let band = NSRect(origin: .zero, size: size)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.compositingOperation = .copy
        NSColor.clear.setFill()
        band.fill()
        ctx.compositingOperation = .sourceOver
        let fades = [hSpec, vSpec].compactMap { $0 }
        if artworkHasInk || fades.isEmpty {
            NSImage(size: size, flipped: false) { _ in
                self.artwork.draw(in: band); return true
            }.draw(in: band, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            NSColor.white.setFill()
            band.fill()
        }
        // destination-in multiplies what is already there by the fade's alpha.
        for spec in fades {
            let vertical = spec.axis == .vertical
            let fade = NSImage(size: size, flipped: false) { rect in
                Self.gradient(for: spec)?.draw(in: rect, angle: vertical ? 90 : 0)
                return true
            }
            fade.draw(in: band, from: .zero, operation: .destinationIn, fraction: 1.0)
        }
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        version += 1
    }

    /// Whether the user has drawn, loaded or stamped anything at all.
    var hasArtwork: Bool { artworkHasInk }

    /// Whether anything at all is painted. Scanned rather than tracked with a flag: a flag has
    /// to be right after strokes, erasing, inverting, presets and pictures alike, and the scan
    /// is 21600 bytes.
    private var artworkHasInk: Bool {
        guard let p = artwork.bitmapData else { return false }
        let row = artwork.bytesPerRow, w = artwork.pixelsWide, h = artwork.pixelsHigh
        for y in 0..<h {
            for x in 0..<w where p[y * row + x * 4 + 3] > 6 { return true }
        }
        return false
    }

    /// One stroke segment: stamped circles from `from` to `to`, close enough together that the
    /// line reads as continuous. The eraser is the same stamp cutting alpha out.
    func stroke(from: NSPoint, to: NSPoint, radius: CGFloat, erase: Bool) {
        draw { ctx in
            let distance = hypot(to.x - from.x, to.y - from.y)
            let stamps = max(1, Int(distance / max(1, radius / 3)))
            for i in 0...stamps {
                let t = CGFloat(i) / CGFloat(stamps)
                let p = NSPoint(x: from.x + (to.x - from.x) * t,
                                y: from.y + (to.y - from.y) * t)
                let dot = NSRect(x: p.x - radius, y: p.y - radius,
                                 width: radius * 2, height: radius * 2)
                if erase {
                    ctx.compositingOperation = .destinationOut
                    NSColor.white.setFill()
                } else {
                    ctx.compositingOperation = .sourceOver
                    NSColor.white.setFill()
                }
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    func clear() {
        draw { ctx in
            ctx.compositingOperation = .copy
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: CursorMaskStore.maskSize).fill()
        }
    }

    /// Painted becomes empty and empty becomes painted — cheap to offer, handy for drawing a
    /// cursor as a cut-out.
    func invert() {
        draw { ctx in
            ctx.compositingOperation = .xor
            NSColor.white.setFill()
            NSRect(origin: .zero, size: CursorMaskStore.maskSize).fill()
        }
    }

    // MARK: - Loading a picture as the cursor

    /// Take a picture as the cursor's shape.
    ///
    /// Two kinds of file arrive here, and they must be read differently. A PNG with real
    /// transparency ALREADY is a mask — its alpha channel is the cursor's body. A flat picture
    /// (a JPEG, an opaque PNG) has no alpha to read, so its BRIGHTNESS becomes the alpha; and
    /// when its border is light the picture is a dark shape drawn on light paper, so the
    /// polarity flips and the shape — not the paper — becomes the cursor. Either way the result
    /// is white-with-alpha, the one convention the mask keeps.
    ///
    /// The picture is stretched over the whole mask: the mask itself is stretched over the row,
    /// so filling it is what makes the loaded picture BE the cursor.
    @discardableResult
    func load(_ image: NSImage) -> Bool {
        let size = CursorMaskStore.maskSize
        guard image.size.width > 0, image.size.height > 0,
              let source = Self.blankRep(size) else { return false }
        let band = NSRect(origin: .zero, size: size)

        NSGraphicsContext.saveGraphicsState()
        guard let sctx = NSGraphicsContext(bitmapImageRep: source) else {
            NSGraphicsContext.restoreGraphicsState()
            return false
        }
        NSGraphicsContext.current = sctx
        sctx.compositingOperation = .copy
        NSColor.clear.setFill()
        band.fill()
        sctx.compositingOperation = .sourceOver
        image.draw(in: band, from: .zero, operation: .sourceOver, fraction: 1.0)
        sctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let src = source.bitmapData, let dst = artwork.bitmapData else { return false }
        let w = Int(size.width), h = Int(size.height)
        let srcRow = source.bytesPerRow, dstRow = artwork.bytesPerRow

        // Read once: the alpha channel, the brightness, and how much of the picture is see-through.
        var alphas = [CGFloat](repeating: 0, count: w * h)
        var luma = [CGFloat](repeating: 0, count: w * h)
        var translucent = 0
        for y in 0..<h {
            for x in 0..<w {
                let p = src + y * srcRow + x * 4
                let a = CGFloat(p[3]) / 255
                alphas[y * w + x] = a
                if a < 0.9 { translucent += 1 }
                // Premultiplied bytes, but brightness is only consulted where alpha is 1 —
                // there the stored value IS the plain colour, so no division is needed.
                luma[y * w + x] = (CGFloat(p[0]) * 0.299 + CGFloat(p[1]) * 0.587
                                   + CGFloat(p[2]) * 0.114) / 255
            }
        }

        // A stray translucent pixel does not make a mask; a real cut-out has plenty of them.
        if translucent * 100 < w * h {
            let flip = Self.borderIsLight(luma, width: w, height: h)
            for i in 0..<(w * h) {
                // Multiplied by the pixel's own alpha, never replacing it: a see-through pixel
                // reads as black in a premultiplied bitmap, and a flipped reading would turn
                // exactly those pixels into solid cursor — blobs where the picture has nothing.
                alphas[i] = (flip ? 1 - luma[i] : luma[i]) * alphas[i]
            }
        }

        // A picture that comes out completely empty is not a cursor. Refusing it here keeps a
        // file AppKit could open but not draw (a broken PNG, a zero-page PDF) from silently
        // wiping the drawing the user already had.
        guard alphas.contains(where: { $0 > 0.02 }) else { return false }

        for y in 0..<h {
            for x in 0..<w {
                let a = UInt8(min(max(alphas[y * w + x], 0), 1) * 255)
                let p = dst + y * dstRow + x * 4
                // White, premultiplied: every channel carries the alpha.
                p[0] = a; p[1] = a; p[2] = a; p[3] = a
            }
        }
        // Straight into the artwork, so the active fades shape the picture instead of the
        // picture wiping them out.
        composite()
        return true
    }

    /// A picture whose border is bright is a drawing on light paper — its dark shape is the
    /// cursor, so the brightness-to-alpha reading has to be flipped.
    ///
    /// The border is read as a BAND, and by its median: the outermost pixel ring alone is
    /// exactly what a hairline frame occupies, and one dark pixel line around a white scan
    /// would otherwise invert the whole mask.
    private static func borderIsLight(_ luma: [CGFloat], width w: Int, height h: Int) -> Bool {
        let band = max(2, min(w, h) / 8)
        var samples: [CGFloat] = []
        samples.reserveCapacity((w + h) * band * 2)
        for y in 0..<h {
            for x in 0..<w where x < band || x >= w - band || y < band || y >= h - band {
                samples.append(luma[y * w + x])
            }
        }
        guard !samples.isEmpty else { return false }
        samples.sort()
        return samples[samples.count / 2] > 0.55
    }

    /// The same, from a file. Anything AppKit can read is fair game — PNG, JPEG, TIFF, PDF, HEIC.
    @discardableResult
    func load(contentsOf url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        return load(image)
    }

    /// Ready-made shapes to start from — replace the canvas, then refine with the brush.
    enum Preset: String, CaseIterable {
        case bar, capsule, ellipse, slant, arrow
        case gradientRight, gradientLeft, gradientEdges

        /// The two rows the editor shows: solid shapes, then gradients.
        static var shapes: [Preset] { [.bar, .capsule, .ellipse, .slant, .arrow] }
        static var gradients: [Preset] { [.gradientRight, .gradientLeft, .gradientEdges] }
    }

    func applyPreset(_ preset: Preset) {
        let size = CursorMaskStore.maskSize
        draw { ctx in
            ctx.compositingOperation = .copy
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: size).fill()
            ctx.compositingOperation = .sourceOver
            NSColor.white.setFill()

            let w = size.width, h = size.height
            switch preset {
            case .bar:
                NSBezierPath(roundedRect: NSRect(x: 4, y: 8, width: w - 8, height: h - 16),
                             xRadius: 10, yRadius: 10).fill()
            case .capsule:
                let r = NSRect(x: 4, y: 10, width: w - 8, height: h - 20)
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            case .ellipse:
                NSBezierPath(ovalIn: NSRect(x: 4, y: 6, width: w - 8, height: h - 12)).fill()
            case .slant:
                let path = NSBezierPath()
                let skew: CGFloat = 26
                path.move(to: NSPoint(x: skew, y: h - 10))
                path.line(to: NSPoint(x: w - 6, y: h - 10))
                path.line(to: NSPoint(x: w - 6 - skew, y: 10))
                path.line(to: NSPoint(x: 6, y: 10))
                path.close()
                path.fill()
            case .arrow:
                let path = NSBezierPath()
                let body = h - 20
                let tip: CGFloat = 34
                path.move(to: NSPoint(x: 6, y: (h - body) / 2))
                path.line(to: NSPoint(x: w - 6 - tip, y: (h - body) / 2))
                path.line(to: NSPoint(x: w - 6, y: h / 2))
                path.line(to: NSPoint(x: w - 6 - tip, y: (h + body) / 2))
                path.line(to: NSPoint(x: 6, y: (h + body) / 2))
                path.close()
                path.fill()

            // Gradients go through the parameterized path with its defaults.
            case .gradientRight, .gradientLeft, .gradientEdges:
                break
            }
        }
        if Preset.gradients.contains(preset) {
            applyGradient(preset, position: 0.5, softness: 1.0)
        }
    }

    /// One gradient channel, fully described: which fade, where its boundary sits, how soft it
    /// is, and (for the edges fade) how wide the solid core stays.
    struct GradientSpec {
        enum Axis { case horizontal, vertical }
        var kind: Preset
        var position: CGFloat
        var softness: CGFloat
        var coreWidth: CGFloat
        var axis: Axis = .horizontal
    }

    /// Both channels at once: the horizontal fade runs along X, the vertical along Y, and where
    /// both are active their opacities MULTIPLY — a shape can melt to the right and dissolve at
    /// the top and bottom at the same time.
    ///
    /// The fades do not REPLACE the drawing any more: they are stored and applied over the
    /// artwork, so a loaded picture (or a preset, or a hand-drawn shape) fades instead of being
    /// wiped, and switching a fade off brings the artwork back whole.
    func applyGradients(horizontal: GradientSpec?, vertical: GradientSpec?) {
        hSpec = horizontal.map { var s = $0; s.axis = .horizontal; return s }
        vSpec = vertical.map { var s = $0; s.axis = .vertical; return s }
        composite()
    }

    /// The fade as an NSGradient — stops clamped and kept strictly ascending, which NSGradient
    /// demands when a boundary is pushed against an end.
    private static func gradient(for spec: GradientSpec) -> NSGradient? {
        let solid = NSColor.white, none = NSColor.white.withAlphaComponent(0)
        let c = min(max(spec.position, 0), 1)
        let half = max(0.025, min(spec.softness, 1) / 2)

        func stops(_ raw: [(NSColor, CGFloat)]) -> NSGradient? {
            var out: [(NSColor, CGFloat)] = []
            var floor: CGFloat = 0
            for (colour, loc) in raw {
                let l = min(max(loc, floor), 1)
                out.append((colour, l))
                floor = min(1, l + 0.0001)
            }
            return NSGradient(colors: out.map(\.0),
                              atLocations: out.map { CGFloat($0.1) },
                              colorSpace: .deviceRGB)
        }

        switch spec.kind {
        case .gradientRight:
            return stops([(solid, 0), (solid, c - half), (none, c + half), (none, 1)])
        case .gradientLeft:
            return stops([(none, 0), (none, c - half), (solid, c + half), (solid, 1)])
        case .gradientEdges:
            let plateau = max(0.02, min(0.9, spec.coreWidth)) / 2
            return stops([(none, 0),
                          (none, c - plateau - half), (solid, c - plateau),
                          (solid, c + plateau), (none, c + plateau + half),
                          (none, 1)])
        default:
            return nil
        }
    }

    /// A gradient with its boundary under the user's control.
    ///
    /// `position` (0…1) is where the fade's MIDDLE sits — sliding it moves the boundary toward
    /// either end. `softness` (0.05…1) is the fade's width: 1 is the long melt across the whole
    /// band, small values approach a step. Grey is partial opacity, so all of this lands in the
    /// cursor exactly as drawn.
    func applyGradient(_ preset: Preset, position: CGFloat, softness: CGFloat,
                       coreWidth: CGFloat = 0.4, vertical: Bool = false) {
        guard Preset.gradients.contains(preset) else { return }
        let spec = GradientSpec(kind: preset, position: position,
                                softness: softness, coreWidth: coreWidth)
        applyGradients(horizontal: vertical ? nil : spec, vertical: vertical ? spec : nil)
    }


    /// Fill a closed pen contour into the mask — white adds cursor, the eraser cuts it out.
    func fillPenPath(_ path: NSBezierPath, erase: Bool) {
        draw { ctx in
            ctx.compositingOperation = erase ? .destinationOut : .sourceOver
            NSColor.white.setFill()
            path.fill()
        }
    }

    /// Alpha at a bitmap pixel — what the tests measure.
    func alpha(x: Int, y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    var image: NSImage {
        let img = NSImage(size: CursorMaskStore.maskSize)
        img.addRepresentation(rep)
        return img
    }

    /// A COPY of the current pixels. The live preview holds the mask across runloop turns while
    /// the brush keeps mutating `rep` — an aliased image would show half-finished strokes.
    func snapshotImage() -> NSImage {
        let img = NSImage(size: CursorMaskStore.maskSize)
        if let copy = rep.copy() as? NSBitmapImageRep {
            img.addRepresentation(copy)
        }
        return img
    }
}

// MARK: - The drawing surface

/// AppKit canvas: black background (transparent-to-be), white paint, mouse draws.
private struct MaskCanvasView: NSViewRepresentable {
    let canvas: CursorMaskCanvas
    /// The canvas's change counter. Presets and strokes bump it; carrying it here is what makes
    /// SwiftUI call updateNSView — without it a preset repainted nothing until the next click.
    let version: Int
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let penMode: Bool
    @Binding var brushRadius: CGFloat
    @Binding var erasing: Bool

    /// What a picture dropped on the canvas should do — the editor owns that, because loading
    /// also clears the fade channels.
    let loadPicture: (URL) -> Void

    func makeNSView(context: Context) -> CanvasNSView {
        // Through init(frame:) explicitly — that is where the drop types are registered, and
        // a bare CanvasNSView() is not guaranteed to go through the designated initializer.
        let v = CanvasNSView(frame: .zero)
        v.canvas = canvas
        v.loadPicture = loadPicture
        return v
    }

    func updateNSView(_ v: CanvasNSView, context: Context) {
        v.canvas = canvas
        v.loadPicture = loadPicture
        v.brushRadius = brushRadius
        v.erasing = erasing
        v.widthFraction = widthFraction
        v.heightFraction = heightFraction
        if v.penMode != penMode {
            v.penMode = penMode
            v.pen = PenPath()   // switching tools abandons an unfinished contour
        }
        v.needsDisplay = true
    }

    final class CanvasNSView: NSView {
        weak var canvas: CursorMaskCanvas?
        var loadPicture: ((URL) -> Void)?
        var brushRadius: CGFloat = 8
        var erasing = false
        var penMode = false
        var pen = PenPath()

        /// A picture can also arrive by being dragged onto the canvas — the shortest road from
        /// a file in the panel to a cursor.
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            registerForDraggedTypes([.fileURL])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private var isDropTarget = false {
            didSet { needsDisplay = true }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard droppedPicture(sender) != nil else { return [] }
            isDropTarget = true
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            isDropTarget = false
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            droppedPicture(sender) != nil
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            isDropTarget = false
            guard let url = droppedPicture(sender) else { return false }
            loadPicture?(url)
            return true
        }

        /// The first dragged file that actually is a picture — a folder or a text file has
        /// nothing to become a cursor, and refusing it up front keeps the drop from "succeeding"
        /// into an empty canvas.
        private func droppedPicture(_ info: NSDraggingInfo) -> URL? {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                options: options) as? [URL] else {
                return nil
            }
            return urls.first { url in
                let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                return type?.conforms(to: .image) ?? false
            }
        }
        /// The live width/height fractions: the canvas shows the mask AT the geometry the row
        /// will use, so dragging "narrower/wider" is visible right here while drawing.
        var widthFraction: CGFloat = 1
        var heightFraction: CGFloat = 0.8
        private var lastPoint: NSPoint?

        /// Where the mask actually lives on the canvas at the current geometry.
        private var contentRect: NSRect {
            let w = bounds.width * max(0.01, widthFraction)
            let h = bounds.height * max(0.1, heightFraction)
            return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                          width: w, height: h)
        }

        override var acceptsFirstResponder: Bool { true }

        /// The dialog's window moves when dragged by its background — and every drag on the
        /// canvas was read as exactly that, so painting a stroke dragged the whole window.
        /// The canvas claims its drags for the brush.
        override var mouseDownCanMoveWindow: Bool { false }

        /// View point → bitmap point, through the geometry sub-rect the mask is shown in.
        private func toMask(_ p: NSPoint) -> NSPoint {
            let size = CursorMaskStore.maskSize
            let r = contentRect
            let x = (p.x - r.minX) / r.width * size.width
            let y = (p.y - r.minY) / r.height * size.height
            return NSPoint(x: min(max(x, 0), size.width - 1),
                           y: min(max(y, 0), size.height - 1))
        }

        /// Where the brush hovers, in view coordinates — the circle outline is drawn there.
        private var hoverPoint: NSPoint?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            hoverPoint = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.crosshair.set()
        }

        override func mouseExited(with event: NSEvent) {
            hoverPoint = nil
            NSCursor.arrow.set()
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)   // Enter and Backspace belong to the pen
            let v = convert(event.locationInWindow, from: nil)
            hoverPoint = v
            var p = toMask(v)

            if penMode {
                if pen.isNearStart(p) {
                    closeAndFill()
                } else {
                    if event.modifierFlags.contains(.shift) { p = pen.constrained(p) }
                    pen.begin(at: p)
                }
                needsDisplay = true
                return
            }

            lastPoint = p
            canvas?.stroke(from: p, to: p, radius: brushRadius, erase: erasing)
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            let v = convert(event.locationInWindow, from: nil)
            hoverPoint = v
            let p = toMask(v)

            if penMode {
                // The classic pen gesture: dragging after placing pulls the handles out.
                pen.dragLast(to: p)
                needsDisplay = true
                return
            }

            canvas?.stroke(from: lastPoint ?? p, to: p, radius: brushRadius, erase: erasing)
            lastPoint = p
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) { lastPoint = nil }

        override func keyDown(with event: NSEvent) {
            guard penMode else { return super.keyDown(with: event) }
            switch event.keyCode {
            case 36, 76:   // Return / keypad Enter — close and fill
                closeAndFill()
            case 51:       // Backspace — take the last point back
                pen.removeLast()
                needsDisplay = true
            default:
                super.keyDown(with: event)
            }
        }

        private func closeAndFill() {
            guard pen.canClose else { return }
            pen.close()
            canvas?.fillPenPath(pen.bezierPath(), erase: erasing)
            pen = PenPath()
            needsDisplay = true
        }

        /// Mask point → view point, for the pen overlay.
        private func fromMask(_ p: NSPoint) -> NSPoint {
            let size = CursorMaskStore.maskSize
            let r = contentRect
            return NSPoint(x: r.minX + p.x / size.width * r.width,
                           y: r.minY + p.y / size.height * r.height)
        }

        /// Whole mask path → view coordinates.
        private func viewPath(_ path: NSBezierPath) -> NSBezierPath {
            let size = CursorMaskStore.maskSize
            let r = contentRect
            var transform = AffineTransform(scale: 1)
            transform.translate(x: r.minX, y: r.minY)
            transform.scale(x: r.width / size.width, y: r.height / size.height)
            let copy = path.copy() as! NSBezierPath
            copy.transform(using: transform)
            return copy
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.setFill()
            bounds.fill()
            let r = contentRect
            canvas?.image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            // The geometry's frame, so "narrower" reads as a frame closing in, not a shrinking blob.
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let frame = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            frame.lineWidth = 1
            frame.stroke()
            NSColor.white.withAlphaComponent(0.15).setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()

            // A picture hovering over the canvas: the frame lights up so the drop reads as
            // landing HERE and not on the window behind.
            if isDropTarget {
                NSColor.controlAccentColor.setStroke()
                let drop = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
                drop.lineWidth = 2
                drop.stroke()
            }

            // The brush itself: a circle where the stroke will land, sized like the stamp.
            // Two strokes — dark under light — so it reads on paint and on background alike.
            if penMode {
                drawPenOverlay()
            } else if let hoverPoint {
                let r = brushRadius * (contentRect.width / CursorMaskStore.maskSize.width)
                let circle = NSBezierPath(ovalIn: NSRect(x: hoverPoint.x - r, y: hoverPoint.y - r,
                                                         width: r * 2, height: r * 2))
                NSColor.black.withAlphaComponent(0.7).setStroke()
                circle.lineWidth = 2.5
                circle.stroke()
                NSColor.white.setStroke()
                circle.lineWidth = 1
                circle.stroke()
            }
        }

        /// The pen's working drawing: the contour with its rubber band, the anchors, and the
        /// Bézier handles of the last-placed point. Dark stroke under light so it reads on
        /// paint and background alike.
        private func drawPenOverlay() {
            guard !pen.isEmpty else { return }
            let hoverMask = hoverPoint.map(toMask)
            let outline = viewPath(pen.bezierPath(previewTo: hoverMask))
            NSColor.black.withAlphaComponent(0.6).setStroke()
            outline.lineWidth = 2.5
            outline.stroke()
            NSColor.systemYellow.setStroke()
            outline.lineWidth = 1
            outline.stroke()

            for (i, node) in pen.nodes.enumerated() {
                let a = fromMask(node.anchor)
                // Handles of the freshly dragged point, Illustrator-style.
                if i == pen.nodes.count - 1, let out = node.handleOut, let inn = node.handleIn {
                    let lever = NSBezierPath()
                    lever.move(to: fromMask(inn))
                    lever.line(to: fromMask(out))
                    NSColor.systemYellow.withAlphaComponent(0.7).setStroke()
                    lever.lineWidth = 1
                    lever.stroke()
                    for h in [out, inn] {
                        let hp = fromMask(h)
                        NSColor.systemYellow.setFill()
                        NSBezierPath(ovalIn: NSRect(x: hp.x - 2.5, y: hp.y - 2.5,
                                                    width: 5, height: 5)).fill()
                    }
                }
                // The first anchor grows a ring when the hover is close enough to close.
                let isCloseTarget = i == 0 && hoverMask.map(pen.isNearStart) == true
                let side: CGFloat = isCloseTarget ? 9 : 6
                let square = NSRect(x: a.x - side / 2, y: a.y - side / 2, width: side, height: side)
                NSColor.black.setFill()
                NSBezierPath(rect: square.insetBy(dx: -1, dy: -1)).fill()
                (isCloseTarget ? NSColor.systemGreen : NSColor.white).setFill()
                NSBezierPath(rect: square).fill()
            }
        }
    }
}

// MARK: - The editor dialog

@MainActor
enum CursorMaskEditor {
    /// Open the editor. On save the mask is stored, the custom cursor is switched on, and every
    /// panel repaints (the store bumps its revision, which the panels observe).
    static func show() {
        migrateChannelSwitches()
        // The settings window steps aside while the drawing is on: the editor previews the
        // cursor on the LIVE panels, and the window it was opened from only covers them.
        fcxlHiding((NSApp.delegate as? AppDelegate)?.settingsWindow) {
            _ = FCXLDialog.runModal(size: NSSize(width: 640, height: 700)) { session in
                CursorMaskEditorView(session: session)
            }
        }
    }

    /// Each fade channel got its own on/off switch after the fades themselves existed. Whoever
    /// had a fade tuned keeps it switched on — decided HERE, before the view exists, because a
    /// migration written through @AppStorage inside onAppear would fire onChange and restamp the
    /// gradient over a mask the user had hand-drawn on top of it.
    private static func migrateChannelSwitches() {
        let d = UserDefaults.standard
        // No artwork file yet, but a mask exists: that mask already has its fades baked in, so
        // the channels start OFF — leaving them on would multiply the same fade a second time.
        let bakedIn = CursorMaskStore.loadArtworkImage() == nil
            && FileManager.default.fileExists(atPath: CursorMaskStore.fileURL.path)
        for (onKey, kindKey) in [(CursorMaskEditorView.hOnKey, CursorMaskEditorView.hKindKey),
                                 (CursorMaskEditorView.vOnKey, CursorMaskEditorView.vKindKey)] {
            if bakedIn { d.set(false, forKey: onKey); continue }
            guard d.object(forKey: onKey) == nil else { continue }
            d.set(!(d.string(forKey: kindKey) ?? "").isEmpty, forKey: onKey)
        }
    }
}

private struct CursorMaskEditorView: View {
    let session: FCXLDialogSession<Bool>

    // The editor works on the ARTWORK — the drawing without the fades. Falls back to the saved
    // mask for anyone whose artwork file predates this split (the migration switches their
    // fades off, because those fades are already baked into that mask).
    @StateObject private var canvas = CursorMaskCanvas(
        startingFrom: CursorMaskStore.loadArtworkImage() ?? CursorMaskStore.loadImage()
            ?? CursorMaskStore.shippedArtworkImage())
    @State private var brushRadius: CGFloat = 8
    @State private var erasing = false
    @State private var penMode = false
    @State private var previewPush: DispatchWorkItem?

    // The two fade channels. Everything about them is remembered: reopening the editor used to
    // hide these controls, because the active gradient lived only in view state that died with
    // the window. Switching a channel OFF keeps its tuning — only the stamp goes without it.
    static let hOnKey = "fcxl.cursorMaskGradHOn"
    static let hKindKey = "fcxl.cursorMaskGradKind"
    static let vOnKey = "fcxl.cursorMaskGradVOn"
    static let vKindKey = "fcxl.cursorMaskGradKindV"
    @AppStorage(hOnKey) private var horizontalOn = false
    @AppStorage(hKindKey) private var storedHKind = ""
    @AppStorage("fcxl.cursorMaskGradPosition") private var hPosition: Double = 0.5
    @AppStorage("fcxl.cursorMaskGradSoftness") private var hSoftness: Double = 1.0
    @AppStorage("fcxl.cursorMaskGradCore") private var hCore: Double = 0.4
    @AppStorage(vOnKey) private var verticalOn = false
    @AppStorage(vKindKey) private var storedVKind = ""
    @AppStorage("fcxl.cursorMaskGradPositionV") private var vPosition: Double = 0.5
    @AppStorage("fcxl.cursorMaskGradSoftnessV") private var vSoftness: Double = 1.0
    @AppStorage("fcxl.cursorMaskGradCoreV") private var vCore: Double = 0.4

    // The cursor's geometry, editable right where the result is visible. These are the SAME
    // settings the Design page owns — one storage, two places to reach it — and the panels
    // behind the editor react to every drag.
    @AppStorage(PanelAppearanceSettings.cursorWidthKey) private var cursorWidth: Double = PanelAppearanceSettings.defaultCursorWidth
    @AppStorage(PanelAppearanceSettings.cursorHeightKey) private var cursorHeight: Double = PanelAppearanceSettings.defaultCursorHeight
    @AppStorage(PanelAppearanceSettings.cursorBlurKey) private var cursorBlur: Double = PanelAppearanceSettings.defaultCursorBlur

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    private var hKind: CursorMaskCanvas.Preset? {
        horizontalOn ? CursorMaskCanvas.Preset(rawValue: storedHKind) : nil
    }
    private var vKind: CursorMaskCanvas.Preset? {
        verticalOn ? CursorMaskCanvas.Preset(rawValue: storedVKind) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("cursorMask.title"), subtitle: sizeAdvice)

            // Scrolls like the settings window: with both fades open the cards outgrow any
            // fixed height, and a dialog that clips its own controls is worse than one that
            // scrolls.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MaskCanvasView(canvas: canvas, version: canvas.version,
                                   widthFraction: cursorWidth, heightFraction: cursorHeight,
                                   penMode: penMode,
                                   brushRadius: $brushRadius, erasing: $erasing,
                                   loadPicture: loadPicture)
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    section(L("cursorMask.section.shape")) { shapeCard }
                    section(L("cursorMask.section.gradient")) { gradientCard }
                    section(L("cursorMask.section.geometry")) { geometryCard }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }

            FCXLDialogButtonBar(
                primaryTitle: L("button.save"),
                primaryEnabled: true,
                primaryAction: save,
                cancelAction: { session.cancel() }
            )
        }
        .tint(accent)
        .onAppear {
            // Migration from the single-channel days: a stored kind with the old vertical
            // switch on belongs to the vertical channel now.
            if CursorMaskStore.isVerticalGradientOn, storedVKind.isEmpty, !storedHKind.isEmpty {
                storedVKind = storedHKind
                storedHKind = ""
                verticalOn = true
                horizontalOn = false
            }
            // Reconcile the blur parking with reality: the flag could be left on with no fade
            // chosen, which would keep the blur parked for nothing. Defaults only — no watched
            // state, no restamp.
            CursorMaskStore.setVerticalGradient(vKind != nil)
            // Safe now that a fade is a filter: this composites the stored fades over the
            // artwork instead of stamping over whatever was drawn.
            restampGradient()
            // And the panels show the drawing THE MOMENT the editor opens. The preview used to
            // start only with the first edit, because only canvas changes pushed it — an open
            // window with a restored canvas gave the panels no reason to move.
            CursorMaskStore.pushPreview(canvas.snapshotImage())
        }
        .onChange(of: hPosition) { _ in restampGradient() }
        .onChange(of: hSoftness) { _ in restampGradient() }
        .onChange(of: hCore) { _ in restampGradient() }
        .onChange(of: vPosition) { _ in restampGradient() }
        .onChange(of: vSoftness) { _ in restampGradient() }
        .onChange(of: vCore) { _ in restampGradient() }
        // The panels show the drawing AS it is drawn. Debounced a touch so a long stroke pushes
        // a handful of previews, not one per stamp.
        .onChange(of: canvas.version) { _ in
            previewPush?.cancel()
            let work = DispatchWorkItem { [weak canvas] in
                guard let canvas else { return }
                CursorMaskStore.pushPreview(canvas.snapshotImage())
            }
            previewPush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        // However the editor closes — Save, Cancel, Esc — the preview ends with it. After a
        // save the saved file is the active mask, so clearing is right in every path.
        .onDisappear {
            previewPush?.cancel()
            CursorMaskStore.clearPreview()
        }
    }

    /// The app's switch: a SwiftUI toggle under the dialog's accent tint. The AppKit FCXLSwitch
    /// takes the SYSTEM accent instead and came out blue among the app's own green controls.
    private func styledSwitch(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }

    /// The header's advice. Every size in it is COUNTED from the mask, doubled and tripled, so
    /// the sentence can never drift from what the loader actually resamples a picture to.
    private var sizeAdvice: String {
        let w = Int(CursorMaskStore.maskSize.width), h = Int(CursorMaskStore.maskSize.height)
        let sizes = [1, 2, 3].map { "\($0 * w) × \($0 * h)" }.joined(separator: ", ")
        return L("cursorMask.subtitle") + " " + String(format: L("cursorMask.sizeHint"), sizes)
    }

    // MARK: - Cards

    /// A titled card, the way the settings window stacks its sections.
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            content()
        }
    }

    private var shapeCard: some View {
        FCXLFormCard {
            FCXLFormRow(label: L("cursorMask.presets")) {
                ForEach(CursorMaskCanvas.Preset.shapes, id: \.self) { preset in
                    Button(L("cursorMask.preset.\(preset.rawValue)")) {
                        // The shape replaces the DRAWING; any active fade keeps shaping it.
                        canvas.applyPreset(preset)
                    }
                    .buttonStyle(FCXLChipButtonStyle(compact: true))
                }
                Spacer()
            }
            FCXLFormRow(label: L("cursorMask.tool")) {
                Text(L("cursorMask.pen")).font(.system(size: 12)).foregroundStyle(.secondary)
                styledSwitch($penMode)
                Text(L("cursorMask.brush")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.leading, 6)
                Slider(value: $brushRadius, in: 1...40)
                Text("\(Int(brushRadius))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .monospacedDigit().frame(width: 20, alignment: .trailing)
                Text(L("cursorMask.eraser")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.leading, 6)
                styledSwitch($erasing)
            }
            if penMode {
                FCXLFormRow {
                    Text(L("cursorMask.penHint"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            FCXLFormRow(label: L("cursorMask.picture"), showDivider: false) {
                // Through a runloop callout: an NSOpenPanel opened straight from a SwiftUI
                // button action inside a modal takes seconds to appear — the house rule.
                Button(L("cursorMask.load")) {
                    fcxlPresentModal {
                        guard let path = DialogService.shared.showFilePicker(
                            title: L("cursorMask.loadTitle"), defaultPath: nil,
                            allowedTypes: [.image]) else { return }
                        loadPicture(URL(fileURLWithPath: path))
                    }
                }
                .buttonStyle(FCXLChipButtonStyle(compact: true))
                .help(L("cursorMask.loadHint"))
                Button(L("cursorMask.invert")) { canvas.invert() }
                    .buttonStyle(FCXLChipButtonStyle(compact: true))
                Button(L("cursorMask.clear")) { canvas.clear() }
                    .buttonStyle(FCXLChipButtonStyle(compact: true))
                Spacer()
            }
        }
    }

    /// Two independent fade channels: their opacities MULTIPLY, so a horizontal and a vertical
    /// fade can shape the cursor at the same time. Each is a switch plus a pop-up — the same
    /// pair of controls the settings pages use, instead of a row of pressed-in buttons.
    private var gradientCard: some View {
        FCXLFormCard {
            channelRow(L("cursorMask.gradH"), on: $horizontalOn, kind: $storedHKind,
                       vertical: false)
            if let hKind {
                sliderRow(L("cursorMask.gradPosition"), value: $hPosition, range: 0...1)
                sliderRow(L("cursorMask.gradSoftness"), value: $hSoftness, range: 0.05...1)
                // The solid core is a property of the edges fade alone — the one-sided fades
                // have no plateau to size.
                if hKind == .gradientEdges {
                    sliderRow(L("cursorMask.gradCore"), value: $hCore, range: 0.05...0.9)
                }
            }
            channelRow(L("cursorMask.gradV"), on: $verticalOn, kind: $storedVKind,
                       vertical: true, showDivider: vKind != nil)
            if let vKind {
                sliderRow(L("cursorMask.gradPosition"), value: $vPosition, range: 0...1)
                sliderRow(L("cursorMask.gradSoftness"), value: $vSoftness, range: 0.05...1,
                          showDivider: vKind == .gradientEdges)
                if vKind == .gradientEdges {
                    sliderRow(L("cursorMask.gradCore"), value: $vCore, range: 0.05...0.9,
                              showDivider: false)
                }
            }
        }
    }

    private var geometryCard: some View {
        FCXLFormCard {
            sliderRow(L("settings.performance.cursorWidth"), value: $cursorWidth,
                      range: 0.01...1.0)
            sliderRow(L("settings.performance.cursorHeight"), value: $cursorHeight,
                      range: 0.3...1.0)
            // The SAME blur the Design page owns — the Gaussian softens the mask's edges exactly
            // like it softened the built-in bar. Here so the drawing and its softness are tuned
            // in one place, live on the panels behind.
            sliderRow(L("settings.performance.cursorBlur"), value: $cursorBlur,
                      range: 0...30, percent: false, showDivider: false)
        }
    }

    // MARK: - Rows

    /// One fade channel: the switch says whether it applies, the pop-up says which fade. A
    /// vertical fade and the blur soften the same edges, so a live V channel parks the blur at
    /// zero and switching it off gives the parked value back.
    private func channelRow(_ label: String, on: Binding<Bool>, kind: Binding<String>,
                            vertical: Bool, showDivider: Bool = true) -> some View {
        let options = CursorMaskCanvas.Preset.gradients.map { preset in
            (value: preset.rawValue,
             label: vertical ? L("cursorMask.preset.\(preset.rawValue).v")
                             : L("cursorMask.preset.\(preset.rawValue)"))
        }
        return FCXLFormRow(label: label, showDivider: showDivider) {
            styledSwitch(Binding(
                get: { on.wrappedValue },
                set: { isOn in
                    let hadKind = !kind.wrappedValue.isEmpty
                    // Switched on with nothing ever chosen: the first fade is the obvious
                    // answer, and it must be stamped or the switch would do nothing visible.
                    if isOn, !hadKind { kind.wrappedValue = options[0].value }
                    on.wrappedValue = isOn
                    if vertical { CursorMaskStore.setVerticalGradient(isOn) }
                    // A fade is a filter over the drawing. Switching the last one off with
                    // NOTHING drawn would leave an empty mask — an invisible cursor — so the
                    // plain bar takes over, which is what the fade was shaping all along.
                    // The fades come off FIRST: the canvas keeps them until told otherwise, and
                    // stamping the bar through the fade the user just switched off made the
                    // switch look dead.
                    restampGradient()
                    if !isOn, !horizontalOn, !verticalOn, !canvas.hasArtwork {
                        canvas.applyPreset(.bar)
                    }
                }))
            FCXLDropdown(selection: Binding(
                get: { kind.wrappedValue.isEmpty ? options[0].value : kind.wrappedValue },
                set: { value in
                    kind.wrappedValue = value
                    // Picking a fade is asking for it — the channel comes on with it.
                    if !on.wrappedValue {
                        on.wrappedValue = true
                        if vertical { CursorMaskStore.setVerticalGradient(true) }
                    }
                    restampGradient()
                }), options: options)
                // Left live while the channel is off — picking a fade there is the shortest way
                // to switch it on, and a dead control would only make the user hunt for the
                // switch first. Dimmed, so "off" still reads as off.
                .frame(width: 160)
                .opacity(on.wrappedValue ? 1 : 0.45)
            Spacer()
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, percent: Bool = true,
                           showDivider: Bool = true) -> some View {
        FCXLFormRow(label: title, showDivider: showDivider) {
            Slider(value: value, in: range)
            Text(percent ? "\(Int(value.wrappedValue * 100))%" : "\(Int(value.wrappedValue))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: - Actions

    /// A picture becomes the cursor — from the file picker or dropped on the canvas. It replaces
    /// the DRAWING; the fades stay on and shape the picture, which is what makes "load a picture,
    /// then fade it" work at all.
    private func loadPicture(_ url: URL) {
        guard canvas.load(contentsOf: url) else {
            DialogService.shared.showError(title: L("cursorMask.loadFailed"),
                                           message: L("cursorMask.loadFailedMessage"))
            return
        }
        // The fades stay exactly as they are: they filter the picture now, which is the whole
        // point of loading one with a fade already switched on.
        restampGradient()
    }

    private func restampGradient() {
        let h = hKind.map { CursorMaskCanvas.GradientSpec(
            kind: $0, position: hPosition, softness: hSoftness, coreWidth: hCore) }
        let v = vKind.map { CursorMaskCanvas.GradientSpec(
            kind: $0, position: vPosition, softness: vSoftness, coreWidth: vCore) }
        // Both channels off means the fades were REMOVED — the identity stamp is a solid bar.
        // Skipped when nothing was ever stamped, so a switch flicked on an empty canvas cannot
        // wipe a hand-drawn mask.
        guard h != nil || v != nil || !storedHKind.isEmpty || !storedVKind.isEmpty else { return }
        canvas.applyGradients(horizontal: h, vertical: v)
    }

    private func save() {
        guard CursorMaskStore.save(canvas.rep) else {
            session.cancel()
            return
        }
        // The drawing itself, so reopening the editor filters the original instead of an
        // already-faded copy.
        CursorMaskStore.saveArtwork(canvas.artwork)
        CursorMaskStore.setEnabled(true)
        session.finish(true)
    }
}
