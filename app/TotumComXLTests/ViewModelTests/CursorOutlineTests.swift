import AppKit
import XCTest

@testable import TotumComXLApp

/// The cursor's outline: a crisp rim around the soft body, the way the mask box is drawn.
@MainActor
final class CursorOutlineTests: XCTestCase {

    private let keys = [PanelAppearanceSettings.cursorOutlineEnabledKey,
                        PanelAppearanceSettings.cursorOutlineWidthKey,
                        PanelAppearanceSettings.cursorOutlineColorHexKey,
                        PanelAppearanceSettings.cursorUsesCustomColorKey,
                        PanelAppearanceSettings.cursorBackgroundColorHexKey]

    override func tearDown() async throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try await super.tearDown()
    }

    func testTheWidthIsHeldToASaneRange() {
        let d = UserDefaults.standard
        d.set(0.0, forKey: PanelAppearanceSettings.cursorOutlineWidthKey)
        XCTAssertEqual(PanelAppearanceSettings.resolvedCursorOutlineWidth, 0.5,
                       "an invisible line still costs a bake")
        d.set(99.0, forKey: PanelAppearanceSettings.cursorOutlineWidthKey)
        XCTAssertEqual(PanelAppearanceSettings.resolvedCursorOutlineWidth, 6)
        d.removeObject(forKey: PanelAppearanceSettings.cursorOutlineWidthKey)
        XCTAssertEqual(PanelAppearanceSettings.resolvedCursorOutlineWidth,
                       CGFloat(PanelAppearanceSettings.defaultCursorOutlineWidth))
    }

    /// Unset, the rim takes the cursor's own colour brightened — which is what makes it read as
    /// "the same colour, only sharper" rather than as a second, unrelated line.
    func testWithoutAColourTheRimFollowsTheCursor() {
        let d = UserDefaults.standard
        d.set(true, forKey: PanelAppearanceSettings.cursorUsesCustomColorKey)
        d.set("#2E6FF2", forKey: PanelAppearanceSettings.cursorBackgroundColorHexKey)

        let rim = PanelAppearanceSettings.resolvedCursorOutlineColor()
        let body = PanelAppearanceSettings.resolvedCursorBackground()

        XCTAssertNotEqual(rim, body, "the rim must stand out from the body")
        XCTAssertGreaterThan(rim.usingColorSpace(.sRGB)?.brightnessComponent ?? 0,
                             body.usingColorSpace(.sRGB)?.brightnessComponent ?? 1,
                             "and it is the brighter of the two")
    }

    func testAChosenColourWins() {
        UserDefaults.standard.set("#FF2D95", forKey: PanelAppearanceSettings.cursorOutlineColorHexKey)
        let rim = PanelAppearanceSettings.resolvedCursorOutlineColor().usingColorSpace(.sRGB)

        XCTAssertEqual(rim?.redComponent ?? 0, 1.0, accuracy: 0.02)
        XCTAssertEqual(rim?.greenComponent ?? 1, 0.176, accuracy: 0.03)
    }

    /// The bake is cached, so the drawn cursor MUST change when the rim does — a cache key that
    /// ignored the outline would keep serving the old picture.
    func testTurningTheOutlineOnRedrawsTheCursor() {
        let d = UserDefaults.standard
        let size = NSSize(width: 120, height: 24)
        d.set(false, forKey: PanelAppearanceSettings.cursorOutlineEnabledKey)
        let plain = FeatheredCursor.image(barSize: size, color: .systemBlue, blur: 0, corner: 6)
        let plainData = plain.tiffRepresentation

        d.set(true, forKey: PanelAppearanceSettings.cursorOutlineEnabledKey)
        d.set("#FFFFFF", forKey: PanelAppearanceSettings.cursorOutlineColorHexKey)
        d.set(3.0, forKey: PanelAppearanceSettings.cursorOutlineWidthKey)
        let outlined = FeatheredCursor.image(barSize: size, color: .systemBlue, blur: 0, corner: 6)

        XCTAssertNotEqual(plainData, outlined.tiffRepresentation,
                          "the outlined cursor must not come out of the cache as the plain one")
    }

    /// And it survives the feathering: the rim is drawn after the blur, so a blurred cursor
    /// still has a sharp edge.
    func testTheRimSurvivesTheBlur() {
        let d = UserDefaults.standard
        d.set(true, forKey: PanelAppearanceSettings.cursorOutlineEnabledKey)
        d.set("#FFFFFF", forKey: PanelAppearanceSettings.cursorOutlineColorHexKey)
        d.set(3.0, forKey: PanelAppearanceSettings.cursorOutlineWidthKey)

        let blurred = FeatheredCursor.image(barSize: NSSize(width: 120, height: 24),
                                            color: .systemBlue, blur: 8, corner: 6)
        guard let rep = NSBitmapImageRep(data: blurred.tiffRepresentation ?? Data()) else {
            return XCTFail("no bitmap")
        }
        // Whiteness, not brightness: a saturated blue reads as "bright" too, and the question
        // here is whether the WHITE rim is distinguishable from the blue body beside it.
        func whiteness(x: Int, y: Int) -> CGFloat {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return min(c.redComponent, min(c.greenComponent, c.blueComponent))
        }
        let pad = Int(FeatheredCursor.padding(for: 8))
        let scale = max(1, rep.pixelsWide / Int(blurred.size.width))
        let mid = rep.pixelsHigh / 2
        let edge = whiteness(x: (pad + 2) * scale, y: mid)
        let inside = whiteness(x: (pad + 16) * scale, y: mid)

        XCTAssertGreaterThan(edge, inside + 0.2, "the rim must read as an edge, not as a smear")
    }
}
