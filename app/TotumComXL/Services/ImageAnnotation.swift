import AppKit
import CoreImage
import CoreText
import SwiftUI

/// One mark drawn over a picture: an arrow, a frame, a caption or a blurred patch — what a
/// screenshot gets before it is sent to someone.
///
/// Positions are shares of the FINAL picture (after turning, mirroring and cropping), with y
/// measured from the TOP — the same space as the crop frame, and for the same reason: the
/// mark is drawn on what the person sees. Sizes of lines and letters are shares of the
/// picture too, so the screen's small copy and the full-size file look alike.
struct ImageAnnotation: Equatable {
    enum Tool: String, CaseIterable {
        case arrow, frame, text, blur

        var symbol: String {
            switch self {
            case .arrow: return "arrow.up.right"
            case .frame: return "rectangle"
            case .text: return "textformat"
            case .blur: return "drop.halffull"
            }
        }

        var titleKey: String { "viewer.draw.\(rawValue)" }
    }

    /// A short palette rather than a colour well: marks on screenshots are red nine times out
    /// of ten, and the rest are for a picture where red would not show.
    enum Colour: String, CaseIterable {
        case red, yellow, green, blue, black, white

        var cgColor: CGColor {
            switch self {
            case .red: return CGColor(red: 0.93, green: 0.18, blue: 0.16, alpha: 1)
            case .yellow: return CGColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1)
            case .green: return CGColor(red: 0.20, green: 0.75, blue: 0.30, alpha: 1)
            case .blue: return CGColor(red: 0.10, green: 0.45, blue: 0.95, alpha: 1)
            case .black: return CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
            case .white: return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            }
        }

        var color: Color { Color(cgColor: cgColor) }

        var titleKey: String { "viewer.draw.colour.\(rawValue)" }
    }

    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var colour: Colour = .red
    /// The caption, for `.text`; the rest leave it empty.
    var text: String = ""

    /// The rectangle a frame or a blur covers, whichever way it was dragged.
    var box: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    // MARK: - Sizes, as shares of the picture's longer side

    static let lineShare: CGFloat = 0.005
    static let letterShare: CGFloat = 0.035
    static let blurShare: CGFloat = 0.012

    static func lineWidth(longSide: CGFloat) -> CGFloat { max(2, longSide * lineShare) }
    static func fontSize(longSide: CGFloat) -> CGFloat { max(12, longSide * letterShare) }

    /// A drag this short is a slip of the hand, not an arrow.
    static let shortestDrag: CGFloat = 0.01

    // MARK: - Following the picture

    /// The picture turned a quarter on screen: the mark goes with it.
    func turned(clockwise: Bool) -> ImageAnnotation {
        func map(_ p: CGPoint) -> CGPoint {
            clockwise ? CGPoint(x: 1 - p.y, y: p.x) : CGPoint(x: p.y, y: 1 - p.x)
        }
        var copy = self
        copy.start = map(start); copy.end = map(end)
        return copy
    }

    func flipped(horizontal: Bool) -> ImageAnnotation {
        func map(_ p: CGPoint) -> CGPoint {
            horizontal ? CGPoint(x: 1 - p.x, y: p.y) : CGPoint(x: p.x, y: 1 - p.y)
        }
        var copy = self
        copy.start = map(start); copy.end = map(end)
        return copy
    }

    /// The crop changed from `old` to `new` (nil — the whole picture): the mark stays on the
    /// same spot of the picture, not on the same spot of the frame.
    func recropped(from old: CGRect?, to new: CGRect?) -> ImageAnnotation {
        let before = old ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let after = new ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard after.width > 0, after.height > 0 else { return self }
        func map(_ p: CGPoint) -> CGPoint {
            let whole = CGPoint(x: before.minX + p.x * before.width, y: before.minY + p.y * before.height)
            return CGPoint(x: (whole.x - after.minX) / after.width, y: (whole.y - after.minY) / after.height)
        }
        var copy = self
        copy.start = map(start); copy.end = map(end)
        return copy
    }
}

/// Burning the marks into the picture.
enum ImageAnnotationRenderer {

    static func draw(_ marks: [ImageAnnotation], over picture: CIImage) -> CIImage {
        let extent = picture.extent
        let size = extent.size
        guard !marks.isEmpty, size.width >= 1, size.height >= 1 else { return picture }
        let longSide = max(size.width, size.height)
        var result = picture

        // Blur first, so a frame or an arrow drawn across a blurred patch stays sharp.
        let sigma = max(4, longSide * ImageAnnotation.blurShare)
        for mark in marks where mark.tool == .blur {
            let box = rect(mark.box, in: extent)
            guard box.width >= 1, box.height >= 1 else { continue }
            let blurred = result.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: box)
            result = blurred.composited(over: result)
        }

        let strokes = marks.filter { $0.tool != .blur }
        if !strokes.isEmpty, let layer = strokeLayer(strokes, size: size) {
            let placed = CIImage(cgImage: layer)
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            result = placed.composited(over: result)
        }
        return result.cropped(to: extent)
    }

    /// A share-rectangle (y from the top) in Core Image's space (y from the bottom).
    static func rect(_ share: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + share.minX * extent.width,
               y: extent.minY + (1 - share.maxY) * extent.height,
               width: share.width * extent.width,
               height: share.height * extent.height)
    }

    /// A share-point in a context whose y grows upwards.
    private static func point(_ share: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: share.x * size.width, y: (1 - share.y) * size.height)
    }

    /// Arrows, frames and captions on a transparent sheet the size of the picture.
    private static func strokeLayer(_ marks: [ImageAnnotation], size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let longSide = max(size.width, size.height)
        let lineWidth = ImageAnnotation.lineWidth(longSide: longSide)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for mark in marks {
            context.setStrokeColor(mark.colour.cgColor)
            context.setFillColor(mark.colour.cgColor)
            switch mark.tool {
            case .arrow:
                drawArrow(from: point(mark.start, in: size), to: point(mark.end, in: size),
                          lineWidth: lineWidth, in: context)
            case .frame:
                let box = rect(mark.box, in: CGRect(origin: .zero, size: size))
                context.addPath(CGPath(roundedRect: box, cornerWidth: lineWidth, cornerHeight: lineWidth,
                                       transform: nil))
                context.strokePath()
            case .text:
                drawCaption(mark.text, colour: mark.colour, topLeft: point(mark.start, in: size),
                            fontSize: ImageAnnotation.fontSize(longSide: longSide), in: context)
            case .blur:
                break
            }
        }
        return context.makeImage()
    }

    /// The shaft stops where the head begins, or its round end pokes through the point.
    static func arrowHead(from start: CGPoint, to end: CGPoint,
                          lineWidth: CGFloat) -> (shaftEnd: CGPoint, left: CGPoint, right: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = hypot(end.x - start.x, end.y - start.y)
        let head = min(max(lineWidth * 4.5, 10), length * 0.6)
        let spread: CGFloat = .pi / 7
        let left = CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread))
        let right = CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread))
        let shaftEnd = CGPoint(x: end.x - head * 0.8 * cos(angle), y: end.y - head * 0.8 * sin(angle))
        return (shaftEnd, left, right)
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat,
                                  in context: CGContext) {
        let head = arrowHead(from: start, to: end, lineWidth: lineWidth)
        context.move(to: start)
        context.addLine(to: head.shaftEnd)
        context.strokePath()
        context.move(to: end)
        context.addLine(to: head.left)
        context.addLine(to: head.right)
        context.closePath()
        context.fillPath()
    }

    /// Bold letters with a soft shadow of the opposite brightness, so a caption reads on a
    /// busy screenshot whatever is under it.
    private static func drawCaption(_ text: String, colour: ImageAnnotation.Colour, topLeft: CGPoint,
                                    fontSize: CGFloat, in context: CGContext) {
        guard !text.isEmpty else { return }
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour.cgColor,
        ]
        let light = colour == .white || colour == .yellow
        context.saveGState()
        context.setShadow(offset: .zero, blur: fontSize * 0.25,
                          color: light ? CGColor(gray: 0, alpha: 0.8) : CGColor(gray: 1, alpha: 0.8))
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let leading = (ascent + descent) * 1.15
        var baseline = topLeft.y - ascent
        for line in text.components(separatedBy: .newlines) {
            let typeset = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
            context.textPosition = CGPoint(x: topLeft.x, y: baseline)
            CTLineDraw(typeset, context)
            baseline -= leading
        }
        context.restoreGState()
    }
}
