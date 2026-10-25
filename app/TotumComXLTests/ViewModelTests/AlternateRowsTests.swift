import AppKit
import XCTest

@testable import TotumComXLApp

/// Alternating rows, the way Total Commander stripes its list.
///
/// A switch turns it on; the shade is a separate setting under it, so trying the stripes off and
/// back on never costs the colour that was picked. The stripes are drawn in the same background
/// the cursor glow lives in, strictly before it.
@MainActor
final class AlternateRowsTests: XCTestCase {

    private let enabledKey = PanelAppearanceSettings.alternateRowsEnabledKey
    private var lightKey: String { PanelAppearanceSettings.alternateRowColorHexLightKey }
    private var darkKey: String { PanelAppearanceSettings.alternateRowColorHexDarkKey }

    private var currentKey: String {
        PanelAppearanceSettings.alternateRowColorKey(dark: PanelAppearanceSettings.isDarkAppearance)
    }

    override func setUp() async throws {
        try await super.setUp()
        for key in [enabledKey, lightKey, darkKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in [enabledKey, lightKey, darkKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try await super.tearDown()
    }

    // MARK: - The switch decides

    func testOffMeansNoStripes() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.set("#FF0000FF", forKey: currentKey)
        XCTAssertNil(PanelAppearanceSettings.resolvedAlternateRowColor(),
                     "a remembered colour must not stripe anything while the switch is off")
    }

    /// Switching it on must show something immediately, before any colour is chosen.
    func testOnWithNoColourChosenStillStripes() throws {
        UserDefaults.standard.set(true, forKey: enabledKey)
        XCTAssertNotNil(PanelAppearanceSettings.resolvedAlternateRowColor(),
                        "turning it on and seeing nothing would read as broken")
    }

    func testOnWithAColourUsesIt() throws {
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set("#FF0000FF", forKey: currentKey)

        let colour = try XCTUnwrap(PanelAppearanceSettings.resolvedAlternateRowColor()?
            .usingColorSpace(.sRGB))
        XCTAssertEqual(colour.redComponent, 1.0, accuracy: 0.01)
    }

    /// A reset leaves an empty string behind: that means "use the default", not "black".
    func testAResetShadeFallsBackToTheDefault() throws {
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set("", forKey: currentKey)

        let colour = try XCTUnwrap(PanelAppearanceSettings.resolvedAlternateRowColor()?
            .usingColorSpace(.sRGB))
        XCTAssertLessThan(colour.alphaComponent, 0.15,
                          "the default is a hint for the eye, not a block of paint")
    }

    /// The colour survives the switch — that is why they are two settings.
    func testTheChosenColourOutlivesTheSwitch() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set("#123456FF", forKey: currentKey)

        UserDefaults.standard.set(false, forKey: enabledKey)
        XCTAssertNil(PanelAppearanceSettings.resolvedAlternateRowColor())

        UserDefaults.standard.set(true, forKey: enabledKey)
        XCTAssertEqual(UserDefaults.standard.string(forKey: currentKey), "#123456FF")
    }

    /// Per theme, and the defaults differ per theme too — one shade cannot serve both.
    func testEachThemeKeepsItsOwnShade() {
        XCTAssertNotEqual(lightKey, darkKey)
        XCTAssertEqual(PanelAppearanceSettings.alternateRowColorKey(dark: true), darkKey)
        XCTAssertEqual(PanelAppearanceSettings.alternateRowColorKey(dark: false), lightKey)
        XCTAssertNotEqual(PanelAppearanceSettings.defaultAlternateRowHex(dark: true),
                          PanelAppearanceSettings.defaultAlternateRowHex(dark: false))
    }

    func testBothLabelsAreTranslated() {
        for key in ["design.alternateRows", "design.alternateRows.color"] {
            XCTAssertNotEqual(L(key), key, "\(key) would appear on screen as its own key")
        }
    }
}

/// Цвет, который тянут ползунком, меняется плавно: фон панели, полосы и линии сетки
/// перекрашиваются сразу и без перезагрузки строк, а цвета, которым перезагрузка нужна, —
/// одна на серию шагов, после неё, а не на каждом шаге внутри движения мыши.
@MainActor
final class ColourDragTests: XCTestCase {

    private let keys = [PanelAppearanceSettings.alternateRowsEnabledKey,
                        PanelAppearanceSettings.alternateRowColorHexLightKey,
                        PanelAppearanceSettings.alternateRowColorHexDarkKey,
                        PanelAppearanceSettings.panelBackgroundColorHexLightKey,
                        PanelAppearanceSettings.panelBackgroundColorHexDarkKey,
                        PanelAppearanceSettings.fileNameColorHexKey]
    private var saved: [String: Any] = [:]
    private var folder = ""

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        folder = NSTemporaryDirectory() + "цвет-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for n in 1...20 {
            FileManager.default.createFile(atPath: folder + "/файл \(n).txt", contents: Data("x".utf8))
        }
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(atPath: folder)
        try await super.tearDown()
    }

    private func panel() async throws -> PanelViewController {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.цвет.\(id)",
                                viewModeDefaultsKey: "panel.mode.цвет.\(id)",
                                showHiddenFiles: false)
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        let tabs = PanelTabsViewModel(panelKey: "tabs.цвет.\(id)", initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabs, side: .left)
        vc.loadViewIfNeeded()
        vm.loadDirectory(at: folder)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, vm.items.count < 20 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Загрузка сама могла поставить перезагрузку вида — пусть пройдёт до замеров.
        try await Task.sleep(nanoseconds: 200_000_000)
        return vc
    }

    private func hex(_ colour: NSColor?) -> String {
        colour.map { PanelAppearanceSettings.hexString(from: $0) } ?? "нет"
    }

    func testStripesAndBackgroundFollowTheDragAtOnceWithoutReloading() async throws {
        let dark = PanelAppearanceSettings.isDarkAppearance
        UserDefaults.standard.set(true, forKey: PanelAppearanceSettings.alternateRowsEnabledKey)
        let vc = try await panel()
        let reloads = vc.appearanceReloadCount

        for step in 0..<30 {
            let shade = String(format: "#%02X%02X%02XFF", step * 8, 64, 255 - step * 8)
            UserDefaults.standard.set(shade, forKey: PanelAppearanceSettings.alternateRowColorKey(dark: dark))
            XCTAssertEqual(hex(vc.tableView.alternateRowColor),
                           hex(PanelAppearanceSettings.resolvedAlternateRowColor()),
                           "полосы перекрашены сразу, шаг \(step)")

            let background = String(format: "#%02X%02X%02X", 20, step * 6, 40)
            UserDefaults.standard.set(background, forKey: PanelAppearanceSettings.panelBackgroundKey(dark: dark))
            XCTAssertEqual(hex(vc.tableView.backgroundColor), hex(PanelAppearanceSettings.nsColor(
                from: background, fallback: .black)), "фон перекрашен сразу, шаг \(step)")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(vc.appearanceReloadCount, reloads, "ни одной перезагрузки строк за всё перетаскивание")
    }

    /// Цвет интерфейса и заголовка — дело окна: панели на него не перезагружаются. Смена темы —
    /// перезагружаются, как раньше.
    func testTheWindowColourIsNoneOfThePanelsBusiness() async throws {
        let vc = try await panel()
        let reloads = vc.appearanceReloadCount
        for _ in 0..<10 {
            NotificationCenter.default.post(name: .fcxlAppearanceChanged, object: nil,
                                            userInfo: [PanelAppearanceSettings.chromeOnlyChangeKey: true])
        }
        XCTAssertEqual(vc.appearanceReloadCount, reloads)
        NotificationCenter.default.post(name: .fcxlAppearanceChanged, object: nil)
        XCTAssertEqual(vc.appearanceReloadCount, reloads + 1, "смена темы — перечитать")
    }

    func testANameColourDragReloadsOnceAfterTheStepsNotOnEachOne() async throws {
        let vc = try await panel()
        let reloads = vc.appearanceReloadCount

        for step in 0..<20 {
            UserDefaults.standard.set(String(format: "#%02X8040", step * 10),
                                      forKey: PanelAppearanceSettings.fileNameColorHexKey)
        }
        XCTAssertEqual(vc.appearanceReloadCount, reloads, "внутри движения — ни одной")

        try await Task.sleep(nanoseconds: UInt64(PanelViewController.appearanceReloadDelay * 4 * 1e9))
        XCTAssertEqual(vc.appearanceReloadCount, reloads + 1, "после — одна, с последним цветом")
    }
}

/// Where the stripes are drawn: in the background under the transparent rows and cells, never by
/// a row or a cell itself — a row is a subview, and anything it paints sits ABOVE the background
/// glow and would shear its halo off. That was the first deleted attempt.
@MainActor
final class AlternateRowsDrawingSiteTests: XCTestCase {

    func testTheDetailedTableCarriesTheStripeColour() {
        let table = PanelNSTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertNil(table.alternateRowColor, "off until the setting says otherwise")
        table.alternateRowColor = .red
        XCTAssertEqual(table.alternateRowColor, .red)
    }

    func testTheBriefCollectionCarriesTheBands() {
        let cv = BriefCollectionView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertNil(cv.alternateRowColor)
        cv.alternateRowColor = .red
        cv.alternateRowHeight = 26
        cv.alternateRowCount = 5
        XCTAssertEqual(cv.alternateRowColor, .red)
    }

    /// A row must paint nothing of its own — the guard on the lesson from the deleted branch.
    func testARowPaintsNothing() throws {
        let row = FileListRowView()
        row.frame = NSRect(x: 0, y: 0, width: 40, height: 10)
        row.isCursor = false
        row.isItemSelected = false

        let image = NSImage(size: row.frame.size)
        image.lockFocus()
        NSColor.white.setFill()
        row.bounds.fill()
        row.drawBackground(in: row.bounds)
        image.unlockFocus()

        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let painted = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.sRGB))
        XCTAssertEqual(painted.redComponent, 1.0, accuracy: 0.02)
        XCTAssertEqual(painted.greenComponent, 1.0, accuracy: 0.02)
        XCTAssertEqual(painted.blueComponent, 1.0, accuracy: 0.02)
    }
}

/// The icon-lift wave: the cursor row's icon grows fully, neighbours grow less with distance —
/// each between normal size and the cursor's — and the reach slider says how far it carries.
@MainActor
final class IconZoomWaveTests: XCTestCase {

    private let keys = [PanelAppearanceSettings.cursorIconZoomEnabledKey,
                        PanelAppearanceSettings.cursorIconZoomAmountKey,
                        PanelAppearanceSettings.cursorIconZoomSpreadKey]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.set(true, forKey: PanelAppearanceSettings.cursorIconZoomEnabledKey)
        UserDefaults.standard.set(1.5, forKey: PanelAppearanceSettings.cursorIconZoomAmountKey)
    }

    override func tearDown() async throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try await super.tearDown()
    }

    func testSpreadZeroLiftsOnlyTheCursorRow() {
        UserDefaults.standard.set(0, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        XCTAssertEqual(CursorIconZoom.scale(atDistance: 0), 1.5, accuracy: 0.001)
        XCTAssertEqual(CursorIconZoom.scale(atDistance: 1), 1.0, "the classic single-row lift")
    }

    /// The request, verbatim: the neighbour sits BETWEEN normal size and the cursor's.
    func testNeighboursGetTheInBetweenSizes() {
        UserDefaults.standard.set(2, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        let cursor = CursorIconZoom.scale(atDistance: 0)
        let near = CursorIconZoom.scale(atDistance: 1)
        let far = CursorIconZoom.scale(atDistance: 2)
        let out = CursorIconZoom.scale(atDistance: 3)

        XCTAssertEqual(cursor, 1.5, accuracy: 0.001)
        XCTAssertGreaterThan(near, far, "the wave eases down with distance")
        XCTAssertGreaterThan(far, 1.0)
        XCTAssertLessThan(near, cursor)
        XCTAssertEqual(out, 1.0, "past the reach the row is untouched")
    }

    func testDisabledMeansNoWaveAtAll() {
        UserDefaults.standard.set(false, forKey: PanelAppearanceSettings.cursorIconZoomEnabledKey)
        UserDefaults.standard.set(3, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        XCTAssertEqual(CursorIconZoom.scale(atDistance: 0), 1.0)
        XCTAssertEqual(CursorIconZoom.scale(atDistance: 1), 1.0)
    }

    func testTheReachLabelIsTranslated() {
        XCTAssertNotEqual(L("settings.folders.iconZoomSpread"), "settings.folders.iconZoomSpread")
    }
}

/// The same wave under the NAMES: the cursor row's text grows fully, the neighbours grow part of
/// the way — and how far it carries is the folders page's reach, one setting for both.
@MainActor
final class CursorFontWaveTests: XCTestCase {

    private let keys = [PanelAppearanceSettings.cursorFontZoomEnabledKey,
                        PanelAppearanceSettings.cursorFontZoomAmountKey,
                        PanelAppearanceSettings.cursorIconZoomSpreadKey]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.set(true, forKey: PanelAppearanceSettings.cursorFontZoomEnabledKey)
        UserDefaults.standard.set(1.5, forKey: PanelAppearanceSettings.cursorFontZoomAmountKey)
    }

    override func tearDown() async throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try await super.tearDown()
    }

    func testSpreadZeroEnlargesOnlyTheCursorRow() {
        UserDefaults.standard.set(0, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        XCTAssertEqual(PanelAppearanceSettings.cursorFontScale(atDistance: 0), 1.5, accuracy: 0.001)
        XCTAssertEqual(PanelAppearanceSettings.cursorFontScale(atDistance: 1), 1.0,
                       "the classic single-row enlargement")
    }

    /// The point of the request: the neighbouring names sit BETWEEN the plain size and the
    /// cursor's, easing down with distance.
    func testNeighbouringNamesGetTheInBetweenSizes() {
        UserDefaults.standard.set(2, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        let cursor = PanelAppearanceSettings.cursorFontScale(atDistance: 0)
        let near = PanelAppearanceSettings.cursorFontScale(atDistance: 1)
        let far = PanelAppearanceSettings.cursorFontScale(atDistance: 2)

        XCTAssertEqual(cursor, 1.5, accuracy: 0.001)
        XCTAssertGreaterThan(near, far, "the wave eases down with distance")
        XCTAssertGreaterThan(far, 1.0)
        XCTAssertLessThan(near, cursor)
        XCTAssertEqual(PanelAppearanceSettings.cursorFontScale(atDistance: 3), 1.0,
                       "past the reach the name is untouched")
    }

    /// The reach is TAKEN FROM the folders setting — one slider governs both lifts.
    func testTheReachComesFromTheIconSetting() {
        UserDefaults.standard.set(4, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        XCTAssertGreaterThan(PanelAppearanceSettings.cursorFontScale(atDistance: 3), 1.0)
        UserDefaults.standard.set(1, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        XCTAssertEqual(PanelAppearanceSettings.cursorFontScale(atDistance: 3), 1.0,
                       "shrinking the folders' reach shrinks the names' reach with it")
    }

    func testTheFontItselfFollowsTheWave() {
        UserDefaults.standard.set(2, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        let plain = PanelAppearanceSettings.resolvedListFont(atDistance: Int.max).pointSize
        let cursor = PanelAppearanceSettings.resolvedListFont(atDistance: 0).pointSize
        let near = PanelAppearanceSettings.resolvedListFont(atDistance: 1).pointSize

        XCTAssertGreaterThan(cursor, near)
        XCTAssertGreaterThan(near, plain)
        XCTAssertEqual(PanelAppearanceSettings.resolvedListFont(cursor: true).pointSize, cursor,
                       "the old cursor flag still means distance zero")
        XCTAssertEqual(PanelAppearanceSettings.resolvedListFont(cursor: false).pointSize, plain)
    }

    func testDisabledMeansNoWaveAtAll() {
        UserDefaults.standard.set(false, forKey: PanelAppearanceSettings.cursorFontZoomEnabledKey)
        UserDefaults.standard.set(3, forKey: PanelAppearanceSettings.cursorIconZoomSpreadKey)
        XCTAssertEqual(PanelAppearanceSettings.cursorFontScale(atDistance: 0), 1.0)
        XCTAssertEqual(PanelAppearanceSettings.cursorFontScale(atDistance: 1), 1.0)
    }
}
