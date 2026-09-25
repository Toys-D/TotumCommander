import CoreGraphics
import Foundation
import XCTest

@testable import TotumComXLApp

/// Reading a DXF. The format is a flat list of code/value pairs, so every rule below can be
/// written out as text — no file, no CAD program, no guessing what a real drawing contains.
final class DXFDocumentTests: XCTestCase {

    /// The smallest drawing that is still a drawing: one line, in the ENTITIES section.
    private let oneLine = """
    0
    SECTION
    2
    ENTITIES
    0
    LINE
    8
    контур
    10
    0.0
    20
    0.0
    11
    100.0
    21
    50.0
    0
    ENDSEC
    0
    EOF
    """

    func test_pairsAreCodeThenValue() {
        let pairs = DXFDocument.pairs(in: "  0\nSECTION\n2\nENTITIES\n")
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].code, 0)
        XCTAssertEqual(pairs[0].value, "SECTION")
        XCTAssertEqual(pairs[1].value, "ENTITIES")
    }

    func test_aLineIsRead_withItsLayer() {
        let document = DXFDocument.read(text: oneLine)
        XCTAssertEqual(document.entities.count, 1)
        guard case .line(let from, let to, let layer) = document.entities[0] else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(from, CGPoint(x: 0, y: 0))
        XCTAssertEqual(to, CGPoint(x: 100, y: 50))
        XCTAssertEqual(layer, "контур")
        XCTAssertEqual(document.layerNames, ["контур"])
    }

    /// Entities OUTSIDE the entities section are furniture — the header's own coordinates
    /// would otherwise turn into stray lines all over the drawing.
    func test_onlyTheEntitiesSectionIsDrawn() {
        let text = """
        0
        SECTION
        2
        HEADER
        0
        LINE
        10
        5.0
        20
        5.0
        11
        9.0
        21
        9.0
        0
        ENDSEC
        0
        EOF
        """
        XCTAssertTrue(DXFDocument.read(text: text).isEmpty)
    }

    func test_circleArcAndPointAreRead() {
        let text = """
        0
        SECTION
        2
        ENTITIES
        0
        CIRCLE
        10
        10.0
        20
        10.0
        40
        5.0
        0
        ARC
        10
        0.0
        20
        0.0
        40
        2.0
        50
        30.0
        51
        90.0
        0
        POINT
        10
        7.0
        20
        8.0
        0
        ENDSEC
        """
        let document = DXFDocument.read(text: text)
        XCTAssertEqual(document.entities.count, 3)
        guard case .circle(let centre, let radius, _) = document.entities[0] else {
            return XCTFail("expected a circle")
        }
        XCTAssertEqual(centre, CGPoint(x: 10, y: 10))
        XCTAssertEqual(radius, 5)
        guard case .arc(_, _, let start, let end, _) = document.entities[1] else {
            return XCTFail("expected an arc")
        }
        XCTAssertEqual(start, 30, "angles stay in degrees, as the format states them")
        XCTAssertEqual(end, 90)
    }

    /// A polyline repeats codes 10 and 20 once per vertex — the one place order matters.
    func test_polylineKeepsItsVerticesInOrder() {
        let text = """
        0
        SECTION
        2
        ENTITIES
        0
        LWPOLYLINE
        70
        1
        10
        0.0
        20
        0.0
        10
        10.0
        20
        0.0
        10
        10.0
        20
        10.0
        0
        ENDSEC
        """
        let document = DXFDocument.read(text: text)
        guard case .polyline(let points, let closed, _) = document.entities.first else {
            return XCTFail("expected a polyline")
        }
        XCTAssertEqual(points, [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)])
        XCTAssertTrue(closed, "flag 1 means the shape closes")
    }

    /// MTEXT carries its formatting inline; the words are what a viewer shows.
    func test_textLosesItsFormattingCodes() {
        XCTAssertEqual(DXFDocument.plainText("{\\fArial|b1;Чертёж}"), "Чертёж")
        XCTAssertEqual(DXFDocument.plainText("\\pxqc;Вид сверху"), "Вид сверху")
        XCTAssertEqual(DXFDocument.plainText("Просто текст"), "Просто текст")
        XCTAssertEqual(DXFDocument.plainText("A\\PB"), "A B")
    }

    func test_layerColoursComeFromTheTable() {
        let text = """
        0
        SECTION
        2
        TABLES
        0
        LAYER
        2
        размеры
        62
        1
        0
        ENDSEC
        """
        XCTAssertEqual(DXFDocument.read(text: text).layerColours["размеры"], 1)
    }

    // MARK: - Fitting it on screen

    func test_boundsCoverEveryShape_includingWhatCirclesReachTo() {
        let document = DXFDocument.read(text: oneLine)
        XCTAssertEqual(document.bounds, CGRect(x: 0, y: 0, width: 100, height: 50))

        let withCircle = DXFDocument.read(text: """
        0
        SECTION
        2
        ENTITIES
        0
        CIRCLE
        10
        0.0
        20
        0.0
        40
        7.0
        0
        ENDSEC
        """)
        XCTAssertEqual(withCircle.bounds, CGRect(x: -7, y: -7, width: 14, height: 14),
                       "a circle reaches its radius in every direction")
    }

    func test_anEmptyDrawingHasNoBounds_ratherThanNonsense() {
        XCTAssertEqual(DXFDocument().bounds, .zero)
        XCTAssertTrue(DXFDocument().isEmpty)
    }

    // MARK: - What it refuses

    /// The binary flavour is rare and unread — but it must be NAMED, not drawn as an empty
    /// window.
    func test_binaryFilesAreRecognisedNotMisread() {
        var data = Data("AutoCAD Binary DXF".utf8)
        data.append(contentsOf: [0x0D, 0x0A, 0x1A, 0x00])
        let document = DXFDocument.read(data: data)
        XCTAssertTrue(document.isBinary)
        XCTAssertTrue(document.isEmpty)
    }

    func test_rubbishIsAnEmptyDrawing_notACrash() {
        XCTAssertTrue(DXFDocument.read(text: "это не чертёж вовсе").isEmpty)
        XCTAssertTrue(DXFDocument.read(data: Data([0xFF, 0xFE, 0x00])).isEmpty)
    }

    /// An entity kind we do not draw yet must not take the ones we do with it.
    func test_anUnknownEntityIsSkipped_andItsNeighboursSurvive() {
        let text = """
        0
        SECTION
        2
        ENTITIES
        0
        HATCH
        10
        1.0
        20
        1.0
        0
        LINE
        10
        0.0
        20
        0.0
        11
        4.0
        21
        4.0
        0
        ENDSEC
        """
        let document = DXFDocument.read(text: text)
        XCTAssertEqual(document.entities.count, 1, "the line survives the hatch")
    }

    // MARK: - Reaching the viewer at all

    /// The reading above is worthless if nothing ever asks for it. A .dxf was listed among the
    /// opaque binaries — DWG, STEP, IGES — so every viewer saw `.other` and drew an icon.
    func testDXFIsADrawingAndNotAnOpaqueBinary() {
        XCTAssertEqual(fileCategory(extension: "dxf"), .drawing)
        XCTAssertEqual(fileCategory(extension: "DXF"), .drawing, "the case of the name means nothing")
        XCTAssertEqual(fileCategory(extension: ".dxf"), .drawing, "a leading dot means nothing")
        XCTAssertEqual(autoMode(for: .drawing), .drawing,
                       "opening one shows the drawing, not a hex dump")
        XCTAssertEqual(fileCategory(extension: "dwg"), .other,
                       "the formats we cannot read stay as they were")
    }

}
