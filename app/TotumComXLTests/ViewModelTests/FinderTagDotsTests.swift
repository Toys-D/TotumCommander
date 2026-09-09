import XCTest
import AppKit
@testable import TotumComXLApp

/// The dots have to survive two things that already broke them once: being drawn too small to read,
/// and being clipped by the line they sit on. Both are pure geometry, so both can be pinned down.
final class FinderTagDotsTests: XCTestCase {

    /// The panel font is a user setting, so the whole configurable range matters — not just 12pt.
    private let fonts = [9, 10, 11, 12, 13, 14, 16, 18, 24].map { NSFont.systemFont(ofSize: CGFloat($0)) }

    func test_noTagsTakeNoRoomAndDrawNothing() {
        for font in fonts {
            XCTAssertEqual(FinderTagDots.width([], font: font), 0)
            XCTAssertNil(FinderTagDots.attributed([], font: font))
            XCTAssertNil(FinderTagDots.image([], font: font))
        }
    }

    /// A dot taller than the ascender is cut off by the line box — that is the "half circle"
    /// the glyph version produced.
    func test_dotAlwaysFitsInsideTheLineBox() {
        for font in fonts {
            let d = FinderTagDots.diameter(for: font)
            let top = (font.capHeight - d) / 2 + d
            let bottom = (font.capHeight - d) / 2
            XCTAssertLessThanOrEqual(top, font.ascender,
                                     "\(font.pointSize)pt: dot reaches above the ascender, it will be clipped")
            XCTAssertGreaterThanOrEqual(bottom, font.descender,
                                        "\(font.pointSize)pt: dot reaches below the descender")
        }
    }

    /// It was tiny before because the glyph only filled part of its em. Never again below 8pt.
    func test_dotStaysBigEnoughToRead() {
        for font in fonts {
            XCTAssertGreaterThanOrEqual(FinderTagDots.diameter(for: font), 8,
                                        "\(font.pointSize)pt: dot too small to tell the colour")
        }
    }

    func test_widthGrowsWithEachTagAndMatchesTheImage() {
        let font = NSFont.systemFont(ofSize: 12)
        var previous = FinderTagDots.width([.red], font: font)
        XCTAssertGreaterThan(previous, FinderTagDots.diameter(for: font),
                             "a single dot must include the gap that separates it from the name")

        for count in 2...FinderTag.allCases.count {
            let tags = Array(FinderTag.allCases.prefix(count))
            let width = FinderTagDots.width(tags, font: font)
            XCTAssertGreaterThan(width, previous, "\(count) tags must reserve more room than \(count - 1)")
            // Reserved room and drawn room must agree, or the dots are cut off or float away.
            XCTAssertEqual(FinderTagDots.image(tags, font: font)?.size.width ?? -1, width, accuracy: 0.01)
            previous = width
        }
    }

    func test_attachmentIsSizedFromTheImageItCarries() {
        let font = NSFont.systemFont(ofSize: 12)
        let tags: [FinderTag] = [.purple, .blue]
        guard let text = FinderTagDots.attributed(tags, font: font),
              let attachment = text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        else { return XCTFail("no attachment produced") }
        XCTAssertEqual(attachment.bounds.width, FinderTagDots.width(tags, font: font), accuracy: 0.01)
        XCTAssertEqual(attachment.bounds.height, FinderTagDots.diameter(for: font), accuracy: 0.01)
        XCTAssertEqual(attachment.image?.size.width ?? -1, attachment.bounds.width, accuracy: 0.01)
    }

    /// Every colour must be distinct, or two tags read as one.
    func test_theSevenColoursAreAllDifferent() {
        let colors = FinderTag.allCases.compactMap {
            $0.color.usingColorSpace(.sRGB).map { c in "\(c.redComponent),\(c.greenComponent),\(c.blueComponent)" }
        }
        XCTAssertEqual(Set(colors).count, FinderTag.allCases.count)
    }
}
