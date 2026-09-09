import AppKit
import XCTest

@testable import TotumComXLApp

/// The hand-drawn cursor: the canvas the user paints, the store that keeps the drawing, and the
/// bake that turns it into the cursor. The mask carries only the SHAPE — colour and blur remain
/// live settings on top of it.
@MainActor
final class CursorMaskTests: XCTestCase {

    /// Своя папка и свои настройки на каждый прогон. Раньше проверка писала в НАСТОЯЩИЙ
    /// файл человека и стирала его флажок «свой курсор»: после каждого прогона нарисованный
    /// курсор становился простой полосой.
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "cursor.mask.tests.\(UUID().uuidString)"
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-mask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CursorMaskStore.storageOverride = .init(directory: directory,
                                                defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() async throws {
        CursorMaskStore.clearPreview()
        if let directory = CursorMaskStore.storageOverride?.directory {
            try? FileManager.default.removeItem(at: directory)
        }
        CursorMaskStore.storageOverride = nil
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - The canvas the user paints

    func testABrushStrokeLeavesPaint() {
        let canvas = CursorMaskCanvas()
        XCTAssertEqual(canvas.alpha(x: 60, y: 30), 0, "a fresh canvas is empty")

        canvas.stroke(from: NSPoint(x: 60, y: 30), to: NSPoint(x: 60, y: 30),
                      radius: 10, erase: false)

        XCTAssertGreaterThan(canvas.alpha(x: 60, y: 30), 0.9, "the stamp centre is solid paint")
    }

    /// A drag is a LINE, not two dots — the stamps in between are what make it one.
    func testADragPaintsTheWholeLine() {
        let canvas = CursorMaskCanvas()
        canvas.stroke(from: NSPoint(x: 40, y: 30), to: NSPoint(x: 140, y: 30),
                      radius: 8, erase: false)

        for x in stride(from: 45, through: 135, by: 10) {
            XCTAssertGreaterThan(canvas.alpha(x: x, y: 30), 0.9,
                                 "x=\(x): the stroke broke into separate dots")
        }
    }

    func testTheEraserTakesPaintAway() {
        let canvas = CursorMaskCanvas()
        canvas.stroke(from: NSPoint(x: 60, y: 30), to: NSPoint(x: 60, y: 30),
                      radius: 12, erase: false)
        canvas.stroke(from: NSPoint(x: 60, y: 30), to: NSPoint(x: 60, y: 30),
                      radius: 6, erase: true)

        XCTAssertLessThan(canvas.alpha(x: 60, y: 30), 0.1, "the eraser must cut the paint out")
        XCTAssertGreaterThan(canvas.alpha(x: 69, y: 30), 0.5,
                             "outside the eraser the paint survives")
    }

    func testClearEmptiesTheCanvas() {
        let canvas = CursorMaskCanvas()
        canvas.stroke(from: NSPoint(x: 30, y: 30), to: NSPoint(x: 150, y: 30),
                      radius: 10, erase: false)
        canvas.clear()
        XCTAssertEqual(canvas.alpha(x: 60, y: 30), 0)
    }

    func testInvertSwapsPaintedAndEmpty() {
        let canvas = CursorMaskCanvas()
        canvas.stroke(from: NSPoint(x: 60, y: 30), to: NSPoint(x: 60, y: 30),
                      radius: 10, erase: false)
        canvas.invert()

        XCTAssertLessThan(canvas.alpha(x: 60, y: 30), 0.1, "painted became empty")
        XCTAssertGreaterThan(canvas.alpha(x: 300, y: 30), 0.9, "empty became painted")
    }

    /// The editor reopens on the SAVED drawing — losing it on every open would make small
    /// corrections impossible.
    func testTheCanvasStartsFromTheSavedMask() {
        let first = CursorMaskCanvas()
        first.stroke(from: NSPoint(x: 80, y: 30), to: NSPoint(x: 80, y: 30),
                     radius: 12, erase: false)
        XCTAssertTrue(CursorMaskStore.save(first.rep))

        let second = CursorMaskCanvas(startingFrom: CursorMaskStore.loadImage())
        XCTAssertGreaterThan(second.alpha(x: 80, y: 30), 0.9,
                             "the saved stroke must be there when the editor reopens")
    }

    /// A preset replaces the canvas with a recognisable shape the brush can refine.
    func testTheArrowPresetPointsRight() {
        let canvas = CursorMaskCanvas()
        canvas.applyPreset(.arrow)

        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.9, "the body is painted")
        XCTAssertGreaterThan(canvas.alpha(x: 351, y: 30), 0.9, "the tip reaches the right edge")
        XCTAssertLessThan(canvas.alpha(x: 351, y: 6), 0.1,
                          "above the tip is empty — that is what makes it an arrow")
    }

    func testTheCapsulePresetRoundsItsEnds() {
        let canvas = CursorMaskCanvas()
        canvas.applyPreset(.capsule)

        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.9)
        XCTAssertLessThan(canvas.alpha(x: 6, y: 12), 0.1,
                          "the corner is outside the capsule's rounded end")
    }

    func testAPresetReplacesWhatWasThere() {
        let canvas = CursorMaskCanvas()
        canvas.stroke(from: NSPoint(x: 340, y: 6), to: NSPoint(x: 340, y: 6),
                      radius: 5, erase: false)
        canvas.applyPreset(.capsule)
        XCTAssertLessThan(canvas.alpha(x: 340, y: 6), 0.1,
                          "a preset is a fresh start, not an overlay")
    }

    /// Gradients: grey in the drawing is partial opacity in the cursor, and a fade preset must
    /// actually fade — solid at one end, gone at the other, in between in between.
    func testTheGradientPresetFades() {
        let canvas = CursorMaskCanvas()
        canvas.applyPreset(.gradientRight)

        let left = canvas.alpha(x: 10, y: 30)
        let middle = canvas.alpha(x: 180, y: 30)
        let right = canvas.alpha(x: 350, y: 30)

        XCTAssertGreaterThan(left, 0.9, "the solid end")
        XCTAssertLessThan(right, 0.1, "the faded-out end")
        XCTAssertGreaterThan(middle, 0.25, "and a real ramp in between")
        XCTAssertLessThan(middle, 0.75, "not a hard step")
        XCTAssertGreaterThan(left, middle)
        XCTAssertGreaterThan(middle, right)
    }

    func testTheEdgesGradientDissolvesBothEnds() {
        let canvas = CursorMaskCanvas()
        canvas.applyPreset(.gradientEdges)

        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.9, "solid in the middle")
        XCTAssertLessThan(canvas.alpha(x: 4, y: 30), 0.2, "dissolved on the left")
        XCTAssertLessThan(canvas.alpha(x: 355, y: 30), 0.2, "dissolved on the right")
    }

    /// The boundary slider: the same fade, slid toward either end. At the mask's middle the
    /// opacity must follow the boundary — past it solid, before it gone.
    func testTheGradientBoundarySlides() {
        let canvas = CursorMaskCanvas()

        canvas.applyGradient(.gradientRight, position: 0.8, softness: 0.2)
        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.9,
                             "boundary at 80% — the middle is still inside the solid part")

        canvas.applyGradient(.gradientRight, position: 0.2, softness: 0.2)
        XCTAssertLessThan(canvas.alpha(x: 180, y: 30), 0.1,
                          "boundary at 20% — the middle is already past the fade")
    }

    /// Softness: small is nearly a step, large is the long melt.
    func testTheSoftnessControlsTheFadeWidth() {
        let canvas = CursorMaskCanvas()
        let mid = Int(CursorMaskStore.maskSize.width / 2)

        canvas.applyGradient(.gradientRight, position: 0.5, softness: 0.1)
        let sharpNear = canvas.alpha(x: mid - 30, y: 30)
        let sharpFar = canvas.alpha(x: mid + 30, y: 30)
        XCTAssertGreaterThan(sharpNear, 0.9, "just before a narrow fade — solid")
        XCTAssertLessThan(sharpFar, 0.1, "just after it — gone")

        canvas.applyGradient(.gradientRight, position: 0.5, softness: 1.0)
        let softNear = canvas.alpha(x: mid - 30, y: 30)
        XCTAssertLessThan(softNear, 0.9,
                          "the same point inside a wide fade is already translucent")
    }

    /// The vertical mode: the same fade turned 90° — opacity varies along Y and is uniform
    /// along X.
    func testTheVerticalGradientFadesAlongY() {
        let canvas = CursorMaskCanvas()
        canvas.applyGradient(.gradientRight, position: 0.5, softness: 0.3, vertical: true)

        let top = canvas.alpha(x: 180, y: 5)
        let bottom = canvas.alpha(x: 180, y: 55)
        XCTAssertGreaterThan(abs(top - bottom), 0.7, "one end solid, the other gone")

        let left = canvas.alpha(x: 20, y: 5)
        let right = canvas.alpha(x: 340, y: 5)
        XCTAssertEqual(left, right, accuracy: 0.05, "and no variation along X")
    }

    /// Switching the vertical fade on parks the blur at zero; off gives the parked value back.
    func testVerticalGradientParksTheBlurAndReturnsIt() {
        let d = CursorMaskStore.defaults
        defer {
            CursorMaskStore.setVerticalGradient(false)
            d.removeObject(forKey: PanelAppearanceSettings.cursorBlurKey)
            d.removeObject(forKey: CursorMaskStore.verticalGradientKey)
        }
        d.set(false, forKey: CursorMaskStore.verticalGradientKey)
        d.set(14.0, forKey: PanelAppearanceSettings.cursorBlurKey)

        CursorMaskStore.setVerticalGradient(true)
        XCTAssertEqual(d.object(forKey: PanelAppearanceSettings.cursorBlurKey) as? Double, 0,
                       "the fade and the blur soften the same edges — blur must stand down")

        CursorMaskStore.setVerticalGradient(false)
        XCTAssertEqual(d.object(forKey: PanelAppearanceSettings.cursorBlurKey) as? Double, 14,
                       "and come back exactly as it was")
    }

    /// The edges fade's solid core is sizeable: narrow it and a point that used to be solid
    /// falls into the fade; soften wide and the same point melts further.
    func testTheCoreWidthNarrowsThePlateau() {
        let canvas = CursorMaskCanvas()

        canvas.applyGradient(.gradientEdges, position: 0.5, softness: 0.2, coreWidth: 0.8)
        let wideCore = canvas.alpha(x: 260, y: 30)     // x/w ≈ 0.72 — inside a wide plateau
        XCTAssertGreaterThan(wideCore, 0.9)

        canvas.applyGradient(.gradientEdges, position: 0.5, softness: 0.2, coreWidth: 0.1)
        let narrowCore = canvas.alpha(x: 260, y: 30)   // the same point, core pulled in
        XCTAssertLessThan(narrowCore, 0.3,
                          "narrowing the core must pull this point out of the solid middle")
        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.9,
                             "the centre itself stays solid at any width")
    }

    /// Both channels at once: the horizontal and the vertical fade MULTIPLY. Wherever either
    /// channel is transparent the result is transparent, and in between the combined opacity
    /// is the product of the two — measured against each channel stamped alone.
    func testHorizontalAndVerticalGradientsMultiply() {
        let canvas = CursorMaskCanvas()
        let h = CursorMaskCanvas.GradientSpec(kind: .gradientRight, position: 0.5,
                                              softness: 0.6, coreWidth: 0.4)
        let v = CursorMaskCanvas.GradientSpec(kind: .gradientEdges, position: 0.5,
                                              softness: 0.6, coreWidth: 0.4)
        let probes: [(Int, Int)] = [(20, 30), (120, 30), (180, 8), (180, 30),
                                    (240, 12), (300, 30), (340, 52)]

        canvas.applyGradients(horizontal: h, vertical: nil)
        let hAlpha = probes.map { canvas.alpha(x: $0.0, y: $0.1) }
        canvas.applyGradients(horizontal: nil, vertical: v)
        let vAlpha = probes.map { canvas.alpha(x: $0.0, y: $0.1) }

        canvas.applyGradients(horizontal: h, vertical: v)
        for (i, p) in probes.enumerated() {
            XCTAssertEqual(canvas.alpha(x: p.0, y: p.1), hAlpha[i] * vAlpha[i],
                           accuracy: 0.07,
                           "at (\(p.0), \(p.1)) the two fades must multiply")
        }
    }

    /// Switching the last fade off must actually REMOVE it: with nothing drawn underneath the
    /// mask goes back to empty, because a fade shapes the drawing rather than being one.
    func testRemovingBothFadesTakesTheFadeAwayAgain() {
        let canvas = CursorMaskCanvas()
        let v = CursorMaskCanvas.GradientSpec(kind: .gradientRight, position: 0.5,
                                              softness: 0.3, coreWidth: 0.4)
        canvas.applyGradients(horizontal: nil, vertical: v)
        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 5) + canvas.alpha(x: 180, y: 55), 0.9,
                             "the fade is there to begin with")

        canvas.applyGradients(horizontal: nil, vertical: nil)
        XCTAssertLessThan(canvas.alpha(x: 180, y: 30), 0.1, "and nothing is left behind")
        XCTAssertFalse(canvas.hasArtwork, "there was never any drawing under it")
    }

    /// The editor's rescue when the last fade goes off with nothing drawn: a plain bar. It must
    /// be a PLAIN one — the canvas keeps its fades until told otherwise, and stamping the bar
    /// through the fade just switched off made the switch look dead.
    func testTheRescueBarIsNotStillFaded() {
        let canvas = CursorMaskCanvas()
        canvas.applyGradients(horizontal: CursorMaskCanvas.GradientSpec(
            kind: .gradientRight, position: 0.5, softness: 0.3, coreWidth: 0.4), vertical: nil)
        XCTAssertLessThan(canvas.alpha(x: 330, y: 30), 0.1, "the fade is on to begin with")

        // What the editor does when the switch goes off: drop the fades, then stamp the bar.
        canvas.applyGradients(horizontal: nil, vertical: nil)
        canvas.applyPreset(.bar)

        XCTAssertGreaterThan(canvas.alpha(x: 330, y: 30), 0.9,
                             "the bar must be whole — the fade is off")
        XCTAssertGreaterThan(canvas.alpha(x: 40, y: 30), 0.9)
    }

    // MARK: - A fade shapes what is drawn

    /// The point of the layer split: a loaded picture must FADE, not be wiped. The picture's own
    /// transparent parts stay transparent, and its solid parts melt where the fade says so.
    func testAFadeMeltsALoadedPictureInsteadOfReplacingIt() {
        let canvas = CursorMaskCanvas()
        // Opaque in the middle band, see-through top and bottom.
        let picture = makePicture(width: 90, height: 30) { _, y in
            (white: 1, alpha: (10..<20).contains(y) ? 1 : 0)
        }
        XCTAssertTrue(canvas.load(picture))

        canvas.applyGradients(horizontal: CursorMaskCanvas.GradientSpec(
            kind: .gradientRight, position: 0.5, softness: 0.3, coreWidth: 0.4), vertical: nil)

        XCTAssertGreaterThan(canvas.alpha(x: 30, y: 30), 0.8,
                             "the picture's body survives on the solid side of the fade")
        XCTAssertLessThan(canvas.alpha(x: 330, y: 30), 0.1, "and melts on the faded side")
        XCTAssertLessThan(canvas.alpha(x: 30, y: 4), 0.1,
                          "what the picture left transparent stays transparent")
    }

    /// And switching the fade off brings the picture back whole — the drawing was never touched.
    func testSwitchingTheFadeOffBringsTheWholePictureBack() {
        let canvas = CursorMaskCanvas()
        // Solid everywhere but the bottom rows: an entirely uniform picture has no shape in it
        // at all, and the loader rightly refuses that one.
        let picture = makePicture(width: 90, height: 30) { _, y in (white: 1, alpha: y < 28 ? 1 : 0) }
        XCTAssertTrue(canvas.load(picture))
        canvas.applyGradients(horizontal: CursorMaskCanvas.GradientSpec(
            kind: .gradientRight, position: 0.5, softness: 0.3, coreWidth: 0.4), vertical: nil)
        XCTAssertLessThan(canvas.alpha(x: 330, y: 30), 0.1)

        canvas.applyGradients(horizontal: nil, vertical: nil)
        XCTAssertGreaterThan(canvas.alpha(x: 330, y: 30), 0.9, "the picture is whole again")
    }

    /// The same for a preset and for a hand-drawn stroke: a fade multiplies whatever is there.
    func testAFadeShapesAPresetAndAStrokeToo() {
        let canvas = CursorMaskCanvas()
        canvas.applyPreset(.capsule)
        canvas.applyGradients(horizontal: CursorMaskCanvas.GradientSpec(
            kind: .gradientRight, position: 0.5, softness: 0.3, coreWidth: 0.4), vertical: nil)

        XCTAssertGreaterThan(canvas.alpha(x: 60, y: 30), 0.8, "the capsule's solid side")
        XCTAssertLessThan(canvas.alpha(x: 330, y: 30), 0.1, "its faded side")
        XCTAssertLessThan(canvas.alpha(x: 6, y: 12), 0.2,
                          "and the capsule's rounded corner is still a corner")

        let drawn = CursorMaskCanvas()
        drawn.stroke(from: NSPoint(x: 20, y: 30), to: NSPoint(x: 340, y: 30),
                     radius: 14, erase: false)
        drawn.applyGradients(horizontal: CursorMaskCanvas.GradientSpec(
            kind: .gradientRight, position: 0.5, softness: 0.3, coreWidth: 0.4), vertical: nil)
        XCTAssertGreaterThan(drawn.alpha(x: 40, y: 30), 0.8, "the stroke's solid side")
        XCTAssertLessThan(drawn.alpha(x: 330, y: 30), 0.1, "and its faded side")
        XCTAssertLessThan(drawn.alpha(x: 40, y: 4), 0.1, "outside the stroke stays empty")
    }

    /// A vertical-only stamp through the two-channel API: solid where the fade keeps it,
    /// no horizontal variation — the identity channel must not eat into the other one.
    func testAVerticalOnlyStampLeavesXUniform() {
        let canvas = CursorMaskCanvas()
        let v = CursorMaskCanvas.GradientSpec(kind: .gradientEdges, position: 0.5,
                                              softness: 0.4, coreWidth: 0.4)
        canvas.applyGradients(horizontal: nil, vertical: v)

        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.9, "solid mid-height")
        XCTAssertLessThan(canvas.alpha(x: 180, y: 2), 0.25, "dissolved at one edge")
        XCTAssertLessThan(canvas.alpha(x: 180, y: 58), 0.25, "and at the other")
        XCTAssertEqual(canvas.alpha(x: 20, y: 30), canvas.alpha(x: 340, y: 30),
                       accuracy: 0.05, "no variation along X")
    }

    // MARK: - Loading a picture as the cursor

    /// A test picture, pixel by pixel: `body` gives the brightness and the alpha at (x, y) with
    /// y counted from the TOP, the way NSBitmapImageRep addresses its rows.
    private func makePicture(width: Int, height: Int,
                             _ body: (Int, Int) -> (white: CGFloat, alpha: CGFloat)) -> NSImage {
        let rep = CursorMaskCanvas.blankRep(NSSize(width: width, height: height))!
        let data = rep.bitmapData!
        for y in 0..<height {
            for x in 0..<width {
                let pixel = body(x, y)
                let a = max(0, min(1, pixel.alpha))
                let byteA = UInt8(a * 255)
                let byteC = UInt8(max(0, min(1, pixel.white)) * a * 255)   // premultiplied
                let p = data + y * rep.bytesPerRow + x * 4
                p[0] = byteC; p[1] = byteC; p[2] = byteC; p[3] = byteA
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// A picture with real transparency IS a mask already — its cut-out is the cursor's shape.
    func testLoadingATransparentPictureKeepsItsCutOut() {
        let canvas = CursorMaskCanvas()
        let picture = makePicture(width: 90, height: 30) { x, _ in
            (white: 1, alpha: x < 45 ? 1 : 0)
        }
        XCTAssertTrue(canvas.load(picture))

        XCTAssertGreaterThan(canvas.alpha(x: 40, y: 30), 0.9, "the opaque half is the cursor")
        XCTAssertLessThan(canvas.alpha(x: 330, y: 30), 0.1, "the cut-out half stays empty")
    }

    /// A flat drawing has no alpha to read, so its brightness becomes one — and a dark shape on
    /// light paper must come out as the SHAPE, not as the paper.
    func testLoadingADarkShapeOnLightPaperTakesTheShape() {
        let canvas = CursorMaskCanvas()
        let picture = makePicture(width: 90, height: 30) { x, y in
            let inShape = (30..<60).contains(x) && (8..<22).contains(y)
            return (white: inShape ? 0 : 1, alpha: 1)
        }
        XCTAssertTrue(canvas.load(picture))

        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.9, "the drawn shape is the cursor")
        XCTAssertLessThan(canvas.alpha(x: 10, y: 30), 0.1, "the paper around it is not")
    }

    /// The same picture the other way round — a light shape on a dark background — reads without
    /// flipping. Either polarity, the shape wins.
    func testLoadingALightShapeOnDarkTakesTheShapeToo() {
        let canvas = CursorMaskCanvas()
        let picture = makePicture(width: 90, height: 30) { x, y in
            let inShape = (30..<60).contains(x) && (8..<22).contains(y)
            return (white: inShape ? 1 : 0, alpha: 1)
        }
        XCTAssertTrue(canvas.load(picture))

        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.9, "the drawn shape is the cursor")
        XCTAssertLessThan(canvas.alpha(x: 10, y: 30), 0.1, "the background around it is not")
    }

    /// Loading must land the picture the same way up as the store's own round-trip does —
    /// otherwise a loaded cursor would be mirrored against every drawn one.
    func testALoadedPictureLandsTheSameWayUpAsASavedMask() {
        let picture = makePicture(width: 90, height: 30) { _, y in
            (white: 1, alpha: y < 15 ? 1 : 0)
        }
        let loaded = CursorMaskCanvas()
        XCTAssertTrue(loaded.load(picture))
        let restored = CursorMaskCanvas(startingFrom: picture)

        XCTAssertGreaterThan(abs(restored.alpha(x: 180, y: 5) - restored.alpha(x: 180, y: 55)),
                             0.8, "the probe itself must be able to tell the ends apart")
        XCTAssertEqual(loaded.alpha(x: 180, y: 5), restored.alpha(x: 180, y: 5), accuracy: 0.05)
        XCTAssertEqual(loaded.alpha(x: 180, y: 55), restored.alpha(x: 180, y: 55), accuracy: 0.05)
    }

    /// A bright picture with a few transparent pixels — a rounded icon, a badge — reads by
    /// brightness, and its reading flips. The transparent corners must NOT come back as solid
    /// cursor: in a premultiplied bitmap they read as black, and a flipped black is white.
    func testTransparentCornersNeverBecomeCursorBody() {
        let canvas = CursorMaskCanvas()
        let picture = makePicture(width: 400, height: 300) { x, y in
            let corner = (x < 16 && y < 16)          // under 1% of the picture: brightness path
            let glyph = (150..<250).contains(x) && (120..<180).contains(y)
            return (white: glyph ? 0 : 1, alpha: corner ? 0 : 1)
        }
        XCTAssertTrue(canvas.load(picture))

        XCTAssertLessThan(canvas.alpha(x: 2, y: 2), 0.1,
                          "a see-through corner has nothing to become cursor")
        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.8, "and the glyph still is one")
    }

    /// A scan with a hairline frame around it: the frame sits exactly where the border is read,
    /// and reading only the outermost ring would invert the whole mask.
    func testAThinFrameDoesNotInvertTheReading() {
        let canvas = CursorMaskCanvas()
        let picture = makePicture(width: 400, height: 300) { x, y in
            let frame = x < 2 || y < 2 || x >= 398 || y >= 298
            let glyph = (150..<250).contains(x) && (120..<180).contains(y)
            return (white: (frame || glyph) ? 0 : 1, alpha: 1)
        }
        XCTAssertTrue(canvas.load(picture))

        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.8, "the drawn shape is the cursor")
        XCTAssertLessThan(canvas.alpha(x: 40, y: 30), 0.2, "the paper around it is not")
    }

    /// A file AppKit opens but cannot draw must be refused, not accepted as an empty cursor —
    /// otherwise loading it would silently wipe the drawing that was there.
    func testAnEmptyPictureIsRefusedInsteadOfWipingTheCanvas() {
        let canvas = CursorMaskCanvas()
        canvas.applyPreset(.capsule)
        let blank = makePicture(width: 40, height: 20) { _, _ in (white: 1, alpha: 0) }

        XCTAssertFalse(canvas.load(blank), "nothing to draw is nothing to load")
        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 30), 0.9, "the drawing survives the refusal")
    }

    /// Loading REPLACES what was on the canvas, exactly as a preset does.
    func testLoadingReplacesTheDrawing() {
        let canvas = CursorMaskCanvas()
        canvas.stroke(from: NSPoint(x: 330, y: 30), to: NSPoint(x: 330, y: 30),
                      radius: 10, erase: false)
        let picture = makePicture(width: 90, height: 30) { x, _ in
            (white: 1, alpha: x < 45 ? 1 : 0)
        }
        XCTAssertTrue(canvas.load(picture))

        XCTAssertLessThan(canvas.alpha(x: 330, y: 30), 0.1,
                          "a loaded picture is a fresh start, not an overlay")
    }

    /// From a file: a real image loads, and anything that is not one is refused instead of
    /// leaving a blank cursor behind.
    func testLoadingFromAFileAndRefusingWhatIsNotAPicture() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let picture = makePicture(width: 90, height: 30) { x, _ in
            (white: 1, alpha: x < 45 ? 1 : 0)
        }
        let png = dir.appendingPathComponent("cursor.png")
        let rep = picture.representations.first as! NSBitmapImageRep
        try rep.representation(using: .png, properties: [:])!.write(to: png)

        let canvas = CursorMaskCanvas()
        XCTAssertTrue(canvas.load(contentsOf: png))
        XCTAssertGreaterThan(canvas.alpha(x: 40, y: 30), 0.9)
        XCTAssertLessThan(canvas.alpha(x: 330, y: 30), 0.1)

        let junk = dir.appendingPathComponent("not-a-picture.png")
        try Data("plain text".utf8).write(to: junk)
        XCTAssertFalse(canvas.load(contentsOf: junk), "a non-picture must be refused")
        XCTAssertGreaterThan(canvas.alpha(x: 40, y: 30), 0.9,
                             "and must leave the previous drawing alone")
    }

    /// The advice in the header must state the size the loader ACTUALLY resamples to — it is
    /// built from the mask itself, so a change to the mask cannot leave the text lying.
    func testTheSizeHintSpeaksTheRealMaskSize() {
        let w = Int(CursorMaskStore.maskSize.width), h = Int(CursorMaskStore.maskSize.height)
        let sizes = [1, 2, 3].map { "\($0 * w) × \($0 * h)" }.joined(separator: ", ")
        let hint = String(format: L("cursorMask.sizeHint"), sizes)

        XCTAssertNotEqual(L("cursorMask.sizeHint"), "cursorMask.sizeHint", "the key is translated")
        XCTAssertTrue(hint.contains("360 × 60"), "the size the picture is resampled to")
        XCTAssertTrue(hint.contains("720 × 120"), "and the doubled one, for a crisper drawing")
        XCTAssertTrue(hint.contains("1080 × 180"), "and the tripled one")
    }

    // MARK: - The store

    func testSavingBumpsTheRevision() {
        let canvas = CursorMaskCanvas()
        canvas.stroke(from: NSPoint(x: 50, y: 30), to: NSPoint(x: 50, y: 30),
                      radius: 8, erase: false)
        let before = CursorMaskStore.revision
        XCTAssertTrue(CursorMaskStore.save(canvas.rep))
        XCTAssertEqual(CursorMaskStore.revision, before + 1,
                       "stale bakes are invalidated by the revision — it must move")
    }

    /// Off means off, whatever is on disk: switching the shape away must not delete the drawing.
    func testDisabledMeansNoActiveMaskButTheDrawingSurvives() {
        let canvas = CursorMaskCanvas()
        canvas.stroke(from: NSPoint(x: 50, y: 30), to: NSPoint(x: 50, y: 30),
                      radius: 8, erase: false)
        CursorMaskStore.save(canvas.rep)

        CursorMaskStore.defaults.set(false, forKey: CursorMaskStore.enabledKey)
        XCTAssertNil(CursorMaskStore.activeMask())
        XCTAssertNotNil(CursorMaskStore.loadImage(), "the drawing itself stays on disk")

        CursorMaskStore.defaults.set(true, forKey: CursorMaskStore.enabledKey)
        XCTAssertNotNil(CursorMaskStore.activeMask())
    }

    /// The Design page's corner slider must work on the drawing too: the mask is clipped by the
    /// same rounded rect as the built-in bar, so the radius rounds the drawing's corners off.
    func testTheCornerRadiusRoundsTheMaskToo() throws {
        let canvas = CursorMaskCanvas()
        canvas.invert()   // full white — square corners, the worst case for the clip
        CursorMaskStore.save(canvas.rep)
        CursorMaskStore.defaults.set(true, forKey: CursorMaskStore.enabledKey)

        func cornerAlpha(radius: CGFloat) throws -> CGFloat {
            let img = FeatheredCursor.image(barSize: CursorMaskStore.maskSize,
                                            color: .red, blur: 0, corner: radius)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation)))
            let scale = CGFloat(rep.pixelsWide) / img.size.width
            let pad = FeatheredCursor.padding(for: 0)
            // Two points inside the bar's corner — inside the square, outside a rounded one.
            let x = Int((pad + 2) * scale), y = Int((pad + 2) * scale)
            return try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)).alphaComponent
        }

        XCTAssertGreaterThan(try cornerAlpha(radius: 0), 0.8,
                             "radius 0 keeps the drawing's own square corner")
        XCTAssertLessThan(try cornerAlpha(radius: 18), 0.2,
                          "a large radius must cut the corner off — this slider was dead")
    }

    // MARK: - The live preview

    /// While the editor is open, the panels show the drawing in progress — the preview overrides
    /// both the saved file and the on/off toggle, and vanishes when the editor closes.
    func testThePreviewOverridesEverythingAndThenLetsGo() {
        CursorMaskStore.defaults.set(false, forKey: CursorMaskStore.enabledKey)

        let canvas = CursorMaskCanvas()
        canvas.applyPreset(.capsule)
        let before = CursorMaskStore.previewRevision
        CursorMaskStore.pushPreview(canvas.snapshotImage())

        XCTAssertNotNil(CursorMaskStore.activeMask(),
                        "a preview is for seeing, whatever the toggle says")
        XCTAssertGreaterThan(CursorMaskStore.previewRevision, before,
                             "the panels wake up on the revision — it must move")

        CursorMaskStore.clearPreview()
        XCTAssertNil(CursorMaskStore.activeMask(),
                     "the editor closed with the toggle off — back to no mask")
    }

    /// The snapshot is a COPY: the brush keeps mutating the canvas after the push, and the
    /// preview must not change under the panels' feet.
    func testTheSnapshotDoesNotAliasTheCanvas() throws {
        let canvas = CursorMaskCanvas()
        canvas.applyPreset(.bar)
        let snap = canvas.snapshotImage()
        canvas.clear()

        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(snap.tiffRepresentation)))
        let centre = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        XCTAssertGreaterThan(centre.alphaComponent, 0.9,
                             "clearing the canvas must not empty an already-taken snapshot")
    }

    /// Every editing operation bumps the version — that is what repaints the canvas view and
    /// pushes the preview; a preset that did not bump it sat invisible until the next click.
    func testEveryOperationBumpsTheVersion() {
        let canvas = CursorMaskCanvas()
        var last = canvas.version
        for step in [{ canvas.applyPreset(.arrow) },
                     { canvas.stroke(from: .init(x: 30, y: 30), to: .init(x: 60, y: 30),
                                     radius: 6, erase: false) },
                     { canvas.invert() },
                     { canvas.clear() }] {
            step()
            XCTAssertGreaterThan(canvas.version, last, "an edit nobody notices is a dead canvas")
            last = canvas.version
        }
    }

    /// The reason interactivity kept dying: every mask key is dotted, and UserDefaults KVO
    /// silently never fires for dotted keys. The store therefore POSTS on every change, and
    /// this pins that promise for each path a change can take.
    func testEveryMaskChangePostsTheNotification() {
        let canvas = CursorMaskCanvas()
        canvas.applyPreset(.bar)

        for (name, action) in [
            ("pushPreview", { CursorMaskStore.pushPreview(canvas.snapshotImage()) }),
            ("clearPreview", { CursorMaskStore.clearPreview() }),
            ("save", { _ = CursorMaskStore.save(canvas.rep) }),
            ("setEnabled", { CursorMaskStore.setEnabled(true) }),
        ] as [(String, () -> Void)] {
            let posted = expectation(description: name)
            let token = NotificationCenter.default.addObserver(
                forName: .fcxlCursorMaskChanged, object: nil, queue: nil) { _ in
                posted.fulfill()
            }
            action()
            wait(for: [posted], timeout: 1)
            NotificationCenter.default.removeObserver(token)
        }
        CursorMaskStore.setEnabled(false)
    }

    // MARK: - The bake takes the shape

    /// Paint only the LEFT half, enable the mask, bake: the cursor must be solid where painted
    /// and empty where not — that is the drawing becoming the cursor.
    func testTheBakedCursorFollowsTheDrawing() throws {
        let canvas = CursorMaskCanvas()
        let h = Int(CursorMaskStore.maskSize.height)
        for y in stride(from: 6, to: h - 6, by: 6) {
            canvas.stroke(from: NSPoint(x: 10, y: y), to: NSPoint(x: 170, y: y),
                          radius: 8, erase: false)
        }
        CursorMaskStore.save(canvas.rep)
        CursorMaskStore.defaults.set(true, forKey: CursorMaskStore.enabledKey)

        // Blur 0: the shape must come through crisp. Bar 360×60 = mask 1:1.
        let img = FeatheredCursor.image(barSize: CursorMaskStore.maskSize,
                                        color: .red, blur: 0, corner: 6)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation)))
        let scaleX = CGFloat(rep.pixelsWide) / img.size.width
        let scaleY = CGFloat(rep.pixelsHigh) / img.size.height
        let pad = FeatheredCursor.padding(for: 0)

        func at(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            rep.colorAt(x: Int((pad + x) * scaleX), y: Int((pad + y) * scaleY))?
                .usingColorSpace(.sRGB)
        }

        let painted = try XCTUnwrap(at(90, 30))
        XCTAssertGreaterThan(painted.alphaComponent, 0.8, "painted area must be cursor")
        XCTAssertGreaterThan(painted.redComponent, 0.9,
                             "and it must wear the CURSOR's colour, not the mask's white")

        let empty = try XCTUnwrap(at(300, 30))
        XCTAssertLessThan(empty.alphaComponent, 0.1, "unpainted area must stay empty")
    }
}

/// The Illustrator-style pen: anchors, symmetric handles, closing, and the fill that turns a
/// contour into cursor.
@MainActor
final class PenPathTests: XCTestCase {

    func testClicksPlaceCornerAnchors() {
        let pen = PenPath()
        pen.begin(at: NSPoint(x: 10, y: 10))
        pen.begin(at: NSPoint(x: 100, y: 10))
        XCTAssertEqual(pen.nodes.count, 2)
        XCTAssertNil(pen.nodes[0].handleOut, "a plain click is a corner — no handles")
    }

    /// The classic gesture: dragging after the click pulls the handles out, mirrored.
    func testDraggingPullsSymmetricHandles() throws {
        let pen = PenPath()
        pen.begin(at: NSPoint(x: 50, y: 30))
        pen.dragLast(to: NSPoint(x: 70, y: 40))

        let node = try XCTUnwrap(pen.nodes.first)
        XCTAssertEqual(node.handleOut, NSPoint(x: 70, y: 40))
        XCTAssertEqual(node.handleIn, NSPoint(x: 30, y: 20),
                       "the inner handle mirrors the outer about the anchor")
    }

    func testClosingNeedsThreePointsAndCloseness() {
        let pen = PenPath()
        pen.begin(at: NSPoint(x: 10, y: 10))
        pen.begin(at: NSPoint(x: 100, y: 10))
        XCTAssertFalse(pen.isNearStart(NSPoint(x: 11, y: 11)), "two points close nothing")

        pen.begin(at: NSPoint(x: 50, y: 50))
        XCTAssertTrue(pen.isNearStart(NSPoint(x: 14, y: 13)), "within tolerance of the start")
        XCTAssertFalse(pen.isNearStart(NSPoint(x: 40, y: 40)), "far from the start")
    }

    func testBackspaceTakesTheLastPointBack() {
        let pen = PenPath()
        pen.begin(at: NSPoint(x: 10, y: 10))
        pen.begin(at: NSPoint(x: 50, y: 50))
        pen.removeLast()
        XCTAssertEqual(pen.nodes.count, 1)
        pen.removeLast()
        pen.removeLast()   // на пустом — не падает
        XCTAssertTrue(pen.isEmpty)
    }

    func testShiftSnapsToFortyFiveDegrees() {
        let pen = PenPath()
        pen.begin(at: NSPoint(x: 100, y: 100))
        let snapped = pen.constrained(NSPoint(x: 200, y: 108))
        XCTAssertEqual(snapped.y, 100, accuracy: 0.01, "8pt of drift snaps to the horizontal")
    }

    /// The whole point: a closed triangle becomes cursor inside and stays empty outside.
    func testAClosedContourFillsTheMask() {
        let pen = PenPath()
        pen.begin(at: NSPoint(x: 40, y: 10))
        pen.begin(at: NSPoint(x: 320, y: 10))
        pen.begin(at: NSPoint(x: 180, y: 55))
        pen.close()

        let canvas = CursorMaskCanvas()
        canvas.fillPenPath(pen.bezierPath(), erase: false)

        XCTAssertGreaterThan(canvas.alpha(x: 180, y: 20), 0.9, "inside the triangle")
        XCTAssertLessThan(canvas.alpha(x: 15, y: 50), 0.1, "outside it")
    }

    /// With the eraser on, the same contour cuts out of what is already painted.
    func testAContourCanCutInstead() {
        let canvas = CursorMaskCanvas()
        canvas.invert()   // full white

        let pen = PenPath()
        pen.begin(at: NSPoint(x: 100, y: 15))
        pen.begin(at: NSPoint(x: 260, y: 15))
        pen.begin(at: NSPoint(x: 180, y: 50))
        pen.close()
        canvas.fillPenPath(pen.bezierPath(), erase: true)

        XCTAssertLessThan(canvas.alpha(x: 180, y: 25), 0.1, "the contour cut a hole")
        XCTAssertGreaterThan(canvas.alpha(x: 20, y: 30), 0.9, "around it the paint stays")
    }
}

/// The orientation contract: what is at the TOP of the editor's canvas is at the top of the
/// cursor in the row. The panels draw in FLIPPED views, and the short NSImage.draw(in:) ignores
/// flippedness — the first asymmetric mask came out upside down.
@MainActor
final class CursorMaskOrientationTests: XCTestCase {

    func testAFlippedViewShowsTheMaskTheWayTheEditorDoes() throws {
        // A mask solid at ONE vertical end: the vertical fade, boundary in the middle.
        let canvas = CursorMaskCanvas()
        canvas.applyGradient(.gradientRight, position: 0.5, softness: 0.2, vertical: true)
        let repTopAlpha = canvas.alpha(x: 180, y: 5)
        let repBottomAlpha = canvas.alpha(x: 180, y: 55)
        XCTAssertGreaterThan(abs(repTopAlpha - repBottomAlpha), 0.7, "the probe needs asymmetry")

        CursorMaskStore.save(canvas.rep)
        CursorMaskStore.defaults.set(true, forKey: CursorMaskStore.enabledKey)
        defer { CursorMaskStore.defaults.removeObject(forKey: CursorMaskStore.enabledKey) }

        // Render through FeatheredCursor.draw INTO A FLIPPED CONTEXT — the same situation as
        // the detailed table and both collection views.
        let size = NSSize(width: CursorMaskStore.maskSize.width + 20,
                          height: CursorMaskStore.maskSize.height + 20)
        let rendered = NSImage(size: size, flipped: true) { rect in
            FeatheredCursor.draw(cellFrame: rect.insetBy(dx: 10, dy: 10),
                                 color: .red, blur: 0, corner: 0,
                                 widthFraction: 1, heightFraction: 1,
                                 anchorX: 0.5, anchorY: 0.5, offsetX: 0, offsetY: 0)
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(rendered.tiffRepresentation)))
        let sx = CGFloat(rep.pixelsWide) / size.width
        let sy = CGFloat(rep.pixelsHigh) / size.height
        func alpha(atMaskY y: CGFloat) -> CGFloat {
            rep.colorAt(x: Int(size.width / 2 * sx), y: Int((10 + y) * sy))?.alphaComponent ?? -1
        }

        // The rendered rows must line up with the mask's own rows, not with their mirror.
        XCTAssertEqual(alpha(atMaskY: 5), repTopAlpha, accuracy: 0.15,
                       "the flipped view mirrored the mask — the editor and the row disagree")
        XCTAssertEqual(alpha(atMaskY: 55), repBottomAlpha, accuracy: 0.15)
    }
}

/// The editor takes the settings window off screen while it is open — it previews the cursor on
/// the live panels, and the window it was opened from sits right on top of them.
@MainActor
final class DialogWindowHidingTests: XCTestCase {

    func testTheWindowIsHiddenForTheDialogAndComesBackAfter() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // A programmatic window releases itself on close, which the test would then touch.
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)

        var seenWhileOpen: Bool?
        fcxlHiding(window) { seenWhileOpen = window.isVisible }

        XCTAssertEqual(seenWhileOpen, false, "the window must be off screen while the dialog runs")
        XCTAssertTrue(window.isVisible, "and back afterwards")
        window.close()
    }

    /// A window that was already hidden must stay hidden — restoring one the user never had open
    /// would pop the settings window up out of nowhere.
    func testAHiddenWindowIsLeftAlone() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(window.isVisible)

        fcxlHiding(window) { }

        XCTAssertFalse(window.isVisible)
        window.close()
    }

    func testNoWindowIsNotAProblem() {
        var ran = false
        fcxlHiding(nil) { ran = true }
        XCTAssertTrue(ran, "the dialog must still open when there is no window to hide")
    }

    /// Включение маски — по теме: в светлой нарисованный курсор, в тёмной нет, и смена темы
    /// подтягивает нужное значение в общий ключ и будит панели.
    @MainActor
    func test_маскаВключаетсяПоТеме() {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: CursorMaskStore.enabledKey), d.object(forKey: CursorMaskStore.enabledLightKey),
                     d.object(forKey: CursorMaskStore.enabledDarkKey), d.object(forKey: "appearanceMode"))
        defer {
            d.set(saved.0, forKey: CursorMaskStore.enabledKey); d.set(saved.1, forKey: CursorMaskStore.enabledLightKey)
            d.set(saved.2, forKey: CursorMaskStore.enabledDarkKey); d.set(saved.3, forKey: "appearanceMode")
        }
        d.set(true, forKey: CursorMaskStore.enabledLightKey)
        d.set(false, forKey: CursorMaskStore.enabledDarkKey)
        d.set(true, forKey: CursorMaskStore.enabledKey)

        var woke = 0
        let token = NotificationCenter.default.addObserver(forName: .fcxlCursorMaskChanged, object: nil, queue: nil) { _ in woke += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        d.set(2, forKey: "appearanceMode")   // тёмная
        PanelAppearanceSettings.syncThemedColorsToEffective()
        XCTAssertFalse(d.bool(forKey: CursorMaskStore.enabledKey), "в тёмной теме маска выключена")
        XCTAssertEqual(woke, 1, "панели узнали")

        d.set(1, forKey: "appearanceMode")   // светлая
        PanelAppearanceSettings.syncThemedColorsToEffective()
        XCTAssertTrue(d.bool(forKey: CursorMaskStore.enabledKey), "в светлой — снова нарисованный")
        XCTAssertEqual(woke, 2)
    }
}
