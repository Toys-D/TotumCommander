import AppKit
import XCTest

@testable import TotumComXLApp

/// The canvas as a citizen of the window: it may draw anything it likes, but only inside itself.
///
/// Since macOS 14 a view no longer clips its own drawing, and this one paints a picture scaled
/// to whatever size it was last fitted to — so a zoomed or stale drawing ran out over the
/// program's own toolbars. Both rules below are measured off real pixels rather than argued.
@MainActor
final class DXFCanvasTests: XCTestCase {

    /// One tall, narrow rectangle — enough to see where the ink lands.
    private let drawing = """
    0
    SECTION
    2
    ENTITIES
    0
    LINE
    10
    0.0
    20
    0.0
    11
    0.0
    21
    500.0
    0
    LINE
    10
    0.0
    20
    500.0
    11
    50.0
    21
    500.0
    0
    ENDSEC
    """

    /// A canvas inside a parent twice its size. Anything painted on the parent is ink that,
    /// in the program, would have landed on the window.
    private func measure(_ canvas: DXFCanvas, in parent: NSView)
        -> (inside: Int, outside: Int, box: NSRect) {
        parent.layoutSubtreeIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        guard let rep = parent.bitmapImageRepForCachingDisplay(in: parent.bounds) else {
            return (0, 0, .zero)
        }
        parent.cacheDisplay(in: parent.bounds, to: rep)
        // The bitmap is in device pixels; everything else here is in points.
        let scale = CGFloat(rep.pixelsHigh) / parent.bounds.height
        var inside = 0, outside = 0
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.05,
                      colour.brightnessComponent > 0.3 else { continue }
                let point = CGPoint(x: CGFloat(x) / scale,
                                    y: CGFloat(rep.pixelsHigh - 1 - y) / scale)
                if canvas.frame.insetBy(dx: -1, dy: -1).contains(point) { inside += 1 }
                else { outside += 1 }
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
        }
        let box = inside + outside == 0 ? .zero
            : NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return (inside, outside, box)
    }

    private func makeCanvas(_ frame: NSRect) -> (DXFCanvas, NSView) {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let canvas = DXFCanvas(frame: frame)
        parent.addSubview(canvas)
        canvas.document = DXFDocument.read(text: drawing)
        canvas.ink = .white
        return (canvas, parent)
    }

    private func press(_ key: String, _ canvas: DXFCanvas, times: Int = 1) {
        for _ in 0..<times {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { continue }
            canvas.keyDown(with: event)
        }
    }

    func testDrawingStaysInsideTheCanvasWhenZoomedIn() {
        let (canvas, parent) = makeCanvas(NSRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertEqual(measure(canvas, in: parent).outside, 0, "вписанный чертёж не выходит за холст")

        press("+", canvas, times: 9)     // far past the edges of the canvas
        let zoomed = measure(canvas, in: parent)
        XCTAssertGreaterThan(zoomed.inside, 0, "приближенный чертёж всё ещё виден")
        XCTAssertEqual(zoomed.outside, 0, "и не рисуется поверх окна")
    }

    /// SwiftUI lays a hosted view out more than once, so the first fit is often made for a size
    /// the view never keeps. The fit has to follow the size until the person moves it themselves.
    func testFitFollowsTheSizeUntilThePersonMovesTheDrawing() {
        let (canvas, parent) = makeCanvas(NSRect(x: 100, y: 100, width: 200, height: 200))
        let big = measure(canvas, in: parent).box

        canvas.frame = NSRect(x: 150, y: 150, width: 80, height: 80)
        let small = measure(canvas, in: parent)
        XCTAssertEqual(small.outside, 0, "после сжатия чертёж внутри нового холста")
        XCTAssertLessThan(small.box.height, big.height, "и вписан в него, а не остался прежним")

        canvas.frame = NSRect(x: 100, y: 100, width: 200, height: 200)
        let again = measure(canvas, in: parent)
        XCTAssertEqual(Int(again.box.height), Int(big.height), "вернули размер — вернулся вид")

        // Once the person has zoomed, the view is theirs: a resize must not throw it away.
        // A fit always leaves a margin, so a drawing still touching both edges is still theirs.
        press("+", canvas, times: 6)
        canvas.frame = NSRect(x: 100, y: 100, width: 210, height: 210)
        let afterResize = measure(canvas, in: parent).box
        XCTAssertGreaterThan(afterResize.height, 205,
                             "масштаб, выбранный человеком, переживает изменение размера")
    }
}
