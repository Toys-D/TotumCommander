import AppKit
import SwiftUI
import XCTest

@testable import TotumComXLApp

/// How the ACTIVE disk reads in the volume bar.
///
/// It used to be a tint on the name plus a soft bloom that only beauty mode drew — in the light
/// theme that left "which disk am I on" almost invisible. The disk now sits on the panel's own
/// cursor: a chip in the cursor colour with the name in the cursor's name colour.
@MainActor
final class VolumeBarActiveDiskTests: XCTestCase {

    private let keys = [PanelAppearanceSettings.cursorUsesCustomColorKey,
                        PanelAppearanceSettings.cursorBackgroundColorHexKey,
                        PanelAppearanceSettings.cursorNameColorHexKey,
                        PanelAppearanceSettings.accentColorHexKey]

    override func tearDown() async throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try await super.tearDown()
    }

    private func useCursorColours(background: String, name: String?) {
        let d = UserDefaults.standard
        d.set(true, forKey: PanelAppearanceSettings.cursorUsesCustomColorKey)
        d.set(background, forKey: PanelAppearanceSettings.cursorBackgroundColorHexKey)
        d.set(name ?? "", forKey: PanelAppearanceSettings.cursorNameColorHexKey)
    }

    /// The chip IS the panel cursor's colour — one setting, one look, wherever the cursor shows.
    /// Чип диска целиком — значок, имя, кнопка извлечения — в обеих темах, в папку
    /// FCXL_LOOK_DIR: посмотреть глазами. Раньше кнопка извлечения торчала за чипом.
    @MainActor
    func test_чипДискаСохраняетсяДляПросмотра() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.chip.look.\(id)",
                                viewModeDefaultsKey: "panel.mode.chip.look.\(id)",
                                showHiddenFiles: false)
        let bar = PanelVolumeBar(viewModel: vm)
        let network = VolumeButtonModel(label: "SERVER_SO:E", path: "/Volumes/SERVER_SO",
                                        icon: "externaldrive.connected.to.line.below",
                                        isEjectable: true, isNetwork: true)
        let local = VolumeButtonModel(label: "D: DATA", path: "/Volumes/DATA",
                                      icon: "externaldrive", isEjectable: true)
        let plain = VolumeButtonModel(label: "C: dimas", path: NSHomeDirectory(),
                                      icon: "internaldrive", isEjectable: false)
        for (name, scheme, back) in [("chip-light", ColorScheme.light, Color(white: 0.93)),
                                     ("chip-dark", .dark, Color(white: 0.16))] {
            let strip = HStack(spacing: 4) {
                bar.volumeButtonView(plain, forceActive: false)
                bar.volumeButtonView(network, forceActive: true)
                bar.volumeButtonView(local, forceActive: true)
                bar.volumeButtonView(local, forceActive: false)
            }
            .padding(12)
            .background(back)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: strip)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.nsImage)
            let data = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
    }

    func testTheChipTakesThePanelCursorColour() {
        useCursorColours(background: "#2E6FF2", name: "#FFFFFF")
        XCTAssertEqual(PanelVolumeBar.activeFillColor(isNetwork: false),
                       PanelAppearanceSettings.resolvedCursorBackground())
    }

    /// The name under the cursor is the name on the chip — the user's choice, kept, as long as
    /// it reads there.
    func testTheLabelIsTheCursorNameColourWhenItReads() {
        useCursorColours(background: "#14345C", name: "#FFE08A")   // amber on deep blue: 8.4
        let label = PanelVolumeBar.activeLabelColor(isNetwork: false)

        XCTAssertEqual(label.usingColorSpace(.sRGB)?.redComponent ?? 0, 1.0, accuracy: 0.02)
        XCTAssertEqual(label.usingColorSpace(.sRGB)?.blueComponent ?? 0, 0.54, accuracy: 0.05)
    }

    /// …unless that name would land on a chip of nearly its own colour. A pale name on a pale
    /// chip is exactly the light-theme complaint, so black or white takes over.
    func testANameTooCloseToTheChipIsReplacedByAReadableOne() {
        useCursorColours(background: "#EFEFEF", name: "#F4F4F4")
        let label = PanelVolumeBar.activeLabelColor(isNetwork: false)

        XCTAssertGreaterThan(
            PanelAppearanceSettings.contrast(between: label,
                                             and: PanelVolumeBar.activeFillColor(isNetwork: false)),
            4.5, "the name must be readable on the chip")
    }

    /// …and the replacement is the app's OWN black-or-white, not a second opinion the bar keeps
    /// to itself. The chip and a file row under the cursor are the same colour, so they must put
    /// the same ink on it; the bar carried its own copy of the contrast maths only while the
    /// shared helper was still guessing by a brightness threshold.
    func testTheReadableFallbackIsTheAppWideOne() {
        useCursorColours(background: "#FF2D95", name: "#FF3D9F")   // pink on pink: 1.1, unreadable
        XCTAssertEqual(PanelVolumeBar.activeLabelColor(isNetwork: false),
                       PanelAppearanceSettings.contrastingTextColor(
                        on: PanelVolumeBar.activeFillColor(isNetwork: false)))
    }

    /// Whatever the cursor colour, in either theme, the name is as readable as that colour
    /// ALLOWS. A mid-tone chip caps what any label can reach (hot pink tops out at 3.5, no
    /// matter what is written on it), so the bar is held to the best available rather than to a
    /// number no colour could meet.
    func testEveryCursorColourGivesTheMostReadablePairAvailable() {
        for hex in ["#FFFFFF", "#000000", "#EFEFEF", "#2E6FF2", "#8AE68A", "#FF2D95", "#333333"] {
            useCursorColours(background: hex, name: nil)
            let (fill, label) = PanelVolumeBar.activeChipColors(isNetwork: false)
            let best = max(PanelAppearanceSettings.contrast(between: .black, and: fill),
                           PanelAppearanceSettings.contrast(between: .white, and: fill))

            XCTAssertGreaterThanOrEqual(
                PanelAppearanceSettings.contrast(between: label, and: fill), min(4.5, best) - 0.01,
                "cursor colour \(hex) leaves the disk name harder to read than it needs to be")
        }
    }

    /// A network place keeps its red, and its name is picked for readability on red.
    func testTheNetworkChipStaysRed() {
        let (fill, label) = PanelVolumeBar.activeChipColors(isNetwork: true)
        XCTAssertEqual(fill, .systemRed)
        XCTAssertGreaterThan(PanelAppearanceSettings.contrast(between: label, and: fill), 3.0)
    }

    /// The dark theme keeps what it had: the feathered glow, with the name white on it. The
    /// chip is for the cases where no glow is drawn — the light theme, and beauty mode off.
    func testTheDarkGlowKeepsItsOldLook() {
        XCTAssertFalse(PanelVolumeBar.showsChip(beauty: true, isDark: true),
                       "dark + beauty: the glow already marks the disk")
        XCTAssertTrue(PanelVolumeBar.showsChip(beauty: true, isDark: false),
                      "light + beauty: the glow washes out — this is what the chip is for")
        XCTAssertTrue(PanelVolumeBar.showsChip(beauty: false, isDark: true),
                      "beauty off draws no glow at all, in either theme")
        XCTAssertTrue(PanelVolumeBar.showsChip(beauty: false, isDark: false))

        useCursorColours(background: "#2E6FF2", name: "#FFE08A")
        XCTAssertEqual(PanelVolumeBar.activeLabelColor(isNetwork: false, onChip: false), .white,
                       "on the glow the name stays white, the way it always was")
    }

    // The contrast maths the assertions above measure with lives in PanelAppearanceSettings now,
    // and is checked against its own definition in PanelAppearanceColorTests.
}
