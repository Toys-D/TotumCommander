import AppKit
import XCTest

@testable import TotumComXLApp

/// Tests for the pure colour helpers in PanelAppearanceSettings — the engine behind the
/// per-theme accent / folder / file / cursor colours: hex ⇄ NSColor parsing, the WCAG
/// contrast ratio and the black-or-white text colour measured with it (cursor name colour,
/// tab labels, every accent-filled control), and the HSB round-trip used by the custom
/// colour picker. All deterministic, no UserDefaults, no UI.
final class PanelAppearanceColorTests: XCTestCase {

    private func srgb(_ c: NSColor) -> NSColor { c.usingColorSpace(.sRGB) ?? c }

    private func assertComponents(_ color: NSColor, r: CGFloat, g: CGFloat, b: CGFloat,
                                  accuracy: CGFloat = 0.02, file: StaticString = #filePath, line: UInt = #line) {
        let c = srgb(color)
        XCTAssertEqual(c.redComponent, r, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.greenComponent, g, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.blueComponent, b, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - hexString(from:)

    func test_hexString_fromNSColor_includesAlpha() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(PanelAppearanceSettings.hexString(from: red), "#FF0000FF")
    }

    func test_hexString_roundTripThroughParse() {
        let orig = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        let hex = PanelAppearanceSettings.hexString(from: orig)
        let parsed = try! XCTUnwrap(PanelAppearanceSettings.optionalNSColor(from: hex))
        assertComponents(parsed, r: 0.2, g: 0.6, b: 0.9)
    }

    // MARK: - optionalNSColor(from:)

    func test_optionalNSColor_emptyIsNil() {
        XCTAssertNil(PanelAppearanceSettings.optionalNSColor(from: ""))
        XCTAssertNil(PanelAppearanceSettings.optionalNSColor(from: "   "))
    }

    func test_optionalNSColor_parsesSixDigitHex() throws {
        let c = try XCTUnwrap(PanelAppearanceSettings.optionalNSColor(from: "#00FF00"))
        assertComponents(c, r: 0, g: 1, b: 0)
    }

    func test_optionalNSColor_worksWithoutHashPrefix() throws {
        let c = try XCTUnwrap(PanelAppearanceSettings.optionalNSColor(from: "0000FF"))
        assertComponents(c, r: 0, g: 0, b: 1)
    }

    func test_optionalNSColor_invalidIsNil() {
        XCTAssertNil(PanelAppearanceSettings.optionalNSColor(from: "not-a-color"))
    }

    // MARK: - contrast(between:and:)

    /// The ruler everything else in this file is measured with, checked against its own
    /// definition: the WCAG ratio runs from 1 (a colour on itself) to 21 (black on white).
    func test_contrast_isTheStandardWCAGRatio() {
        XCTAssertEqual(PanelAppearanceSettings.contrast(between: .black, and: .white), 21, accuracy: 0.1)
        XCTAssertEqual(PanelAppearanceSettings.contrast(between: .white, and: .white), 1, accuracy: 0.01)
    }

    /// Contrast belongs to the PAIR, not to an order: callers pass the ink first in one place
    /// and the fill first in another, and both must get the same number back.
    func test_contrast_readsTheSameBothWaysRound() {
        let pink = NSColor(srgbRed: 1, green: 0.176, blue: 0.584, alpha: 1)
        XCTAssertEqual(PanelAppearanceSettings.contrast(between: pink, and: .white),
                       PanelAppearanceSettings.contrast(between: .white, and: pink), accuracy: 0.0001)
    }

    // MARK: - contrastingTextColor(on:)

    func test_contrastingText_onLightIsBlack() {
        assertComponents(PanelAppearanceSettings.contrastingTextColor(on: NSColor.white), r: 0, g: 0, b: 0)
        // Light yellow → black text.
        let yellow = NSColor(srgbRed: 1, green: 1, blue: 0.3, alpha: 1)
        assertComponents(PanelAppearanceSettings.contrastingTextColor(on: yellow), r: 0, g: 0, b: 0)
    }

    func test_contrastingText_onDarkIsWhite() {
        assertComponents(PanelAppearanceSettings.contrastingTextColor(on: NSColor.black), r: 1, g: 1, b: 1)
        // Saturated purple accent (default) is dark → white text.
        let purple = NSColor(srgbRed: 0.4, green: 0.1, blue: 0.7, alpha: 1)
        assertComponents(PanelAppearanceSettings.contrastingTextColor(on: purple), r: 1, g: 1, b: 1)
    }

    /// The mid-tones are where a weighted-average brightness threshold guessed wrong. Hot pink
    /// falls just under the old cut-off and so was handed white, which reads on it at 3.5 —
    /// where black reads at 6.1. A colour is bright enough to carry dark text long before it
    /// looks "light" to a formula that never linearised its channels.
    func test_contrastingText_onMidToneHotPinkIsBlack() {
        let hotPink = NSColor(srgbRed: 1, green: 0.176, blue: 0.584, alpha: 1)   // #FF2D95
        assertComponents(PanelAppearanceSettings.contrastingTextColor(on: hotPink), r: 0, g: 0, b: 0)
    }

    /// Same story for a saturated red, which is an entirely ordinary thing to pick as an accent.
    /// White on red is the habit; black is the more legible of the two (5.3 against 4.0).
    func test_contrastingText_onSaturatedRedIsBlack() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        assertComponents(PanelAppearanceSettings.contrastingTextColor(on: red), r: 0, g: 0, b: 0)
    }

    /// The promise the helper makes, held across the span of colours a user can actually land
    /// on: of the two inks it is allowed to return, it returns the one that MEASURES better.
    /// Never the other one, and never by a threshold that merely correlates with the answer.
    func test_contrastingText_neverReturnsTheLessLegibleOfTheTwo() {
        for hex in ["#FFFFFF", "#000000", "#FF2D95", "#FF0000", "#00FF00", "#00C2A8",
                    "#EFEFEF", "#333333", "#8AE68A", "#FFE08A", "#7F7F7F", "#2E6FF2", "#14345C"] {
            let background = PanelAppearanceSettings.nsColor(from: hex, fallback: .gray)
            let ink = PanelAppearanceSettings.contrastingTextColor(on: background)
            let best = max(PanelAppearanceSettings.contrast(between: .black, and: background),
                           PanelAppearanceSettings.contrast(between: .white, and: background))

            XCTAssertEqual(PanelAppearanceSettings.contrast(between: ink, and: background), best,
                           accuracy: 0.0001, "\(hex) was given the less readable of black and white")
        }
    }

    /// A fill with no sRGB reading at all — a pattern, a colour from a space that will not
    /// convert — must not quietly measure as "black background, so black ink". Unmeasurable
    /// keeps the answer the old guard gave: white.
    func test_contrastingText_onUnmeasurableColourFallsBackToWhite() {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 4, height: 4)))
        assertComponents(PanelAppearanceSettings.contrastingTextColor(on: pattern), r: 1, g: 1, b: 1)
    }

    // MARK: - HSB round-trip (colour picker)

    func test_hsb_hexRoundTrip() throws {
        // Well-saturated colour so hue is stable through 8-bit quantization.
        let hex = PanelAppearanceSettings.hexString(hue: 0.33, saturation: 0.8, brightness: 0.9)
        let hsb = try XCTUnwrap(PanelAppearanceSettings.hsbComponents(fromHex: hex))
        XCTAssertEqual(hsb.hue, 0.33, accuracy: 0.02)
        XCTAssertEqual(hsb.saturation, 0.8, accuracy: 0.02)
        XCTAssertEqual(hsb.brightness, 0.9, accuracy: 0.02)
    }

    // MARK: - fallback behaviour

    func test_nsColor_emptyUsesFallback() {
        let fallback = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let c = PanelAppearanceSettings.nsColor(from: "", fallback: fallback)
        assertComponents(c, r: 0.5, g: 0.5, b: 0.5)
    }

    // MARK: - fileNameColor (cursor vs selection priority)

    private let cursorC = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)   // white
    private let selectC = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)   // red = "marked"
    private let normalC = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)   // blue = plain

    /// The cursor is a solid filled bar, so the name must stay readable against it: the cursor
    /// colour wins for the TEXT even when the row is also marked. The mark itself is not lost —
    /// it shows as an accent wash the row background paints over the cursor bar (verified by
    /// eye, not here). Using the accent for the text instead made the name blend into the bar.
    func test_fileNameColor_cursorWinsForReadabilityWhenAlsoSelected() {
        let c = PanelAppearanceSettings.fileNameColor(
            isCursor: true, isSelected: true, cursor: cursorC, selected: selectC, normal: normalC)
        assertComponents(c, r: 1, g: 1, b: 1, accuracy: 0.001)   // readable cursor colour, not accent
    }

    func test_fileNameColor_cursorOnlyUsesCursorColour() {
        let c = PanelAppearanceSettings.fileNameColor(
            isCursor: true, isSelected: false, cursor: cursorC, selected: selectC, normal: normalC)
        assertComponents(c, r: 1, g: 1, b: 1, accuracy: 0.001)
    }

    func test_fileNameColor_selectedOnlyUsesMarkColour() {
        let c = PanelAppearanceSettings.fileNameColor(
            isCursor: false, isSelected: true, cursor: cursorC, selected: selectC, normal: normalC)
        assertComponents(c, r: 1, g: 0, b: 0, accuracy: 0.001)
    }

    func test_fileNameColor_plainRowUsesNormalColour() {
        let c = PanelAppearanceSettings.fileNameColor(
            isCursor: false, isSelected: false, cursor: cursorC, selected: selectC, normal: normalC)
        assertComponents(c, r: 0, g: 0, b: 1, accuracy: 0.001)
    }

    // MARK: - Выбор цвета: ползунки следуют за готовым цветом

    /// Готовый цвет, пипетка, поле hex — двигают ползунки; свой же цвет ползунков — нет. Флаг,
    /// который это делал раньше, застревал после перетаскивания на тот же цвет, и следующий
    /// готовый цвет ставился в программе, а ползунки не двигались.
    func test_ползункиПерезагружаютсяТолькоОтЧужогоЦвета() {
        XCTAssertTrue(FCXLColorPickerPanel.needsSliderReload(hex: "#FF8800", sliders: "#4F5B62"),
                      "готовый цвет двигает ползунки")
        XCTAssertFalse(FCXLColorPickerPanel.needsSliderReload(hex: "#4F5B62", sliders: "#4F5B62"),
                       "цвет самих ползунков — нечего перезагружать")
        XCTAssertFalse(FCXLColorPickerPanel.needsSliderReload(hex: "#4f5b62", sliders: "#4F5B62"),
                       "регистр hex не делает цвет другим")
        // Перетаскивание, закончившееся на прежнем цвете, ничего не «взводит»: следующий
        // готовый цвет всё равно двигает ползунки.
        let afterDrag = PanelAppearanceSettings.hexString(hue: 0.56, saturation: 0.2, brightness: 0.39)
        XCTAssertFalse(FCXLColorPickerPanel.needsSliderReload(hex: afterDrag, sliders: afterDrag))
        XCTAssertTrue(FCXLColorPickerPanel.needsSliderReload(hex: "#FF8800", sliders: afterDrag))
    }

    // MARK: - Колонки типа, даты и размера

    /// Цвет курсора у метаданных — только в АКТИВНОЙ панели: в неактивной курсорной полосы
    /// нет, и строка с чёрным именем и зелёными типом, датой и размером была ошибкой.
    func test_метаданныеБерутЦветКурсораТолькоВАктивнойПанели() {
        let cursor = NSColor.systemGreen, file = NSColor.black
        let active = PanelViewController.metadataTextColor(isCursor: true, isActivePanel: true, cursor: cursor, file: file)
        XCTAssertEqual(active.usingColorSpace(.sRGB)?.greenComponent, cursor.usingColorSpace(.sRGB)?.greenComponent)
        let inactive = PanelViewController.metadataTextColor(isCursor: true, isActivePanel: false, cursor: cursor, file: file)
        XCTAssertEqual(inactive.usingColorSpace(.sRGB)?.greenComponent, 0, "в неактивной панели — цвет файла, не курсора")
        XCTAssertEqual(inactive.alphaComponent, 0.7, accuracy: 0.01)
        let plain = PanelViewController.metadataTextColor(isCursor: false, isActivePanel: true, cursor: cursor, file: file)
        XCTAssertEqual(plain.usingColorSpace(.sRGB)?.greenComponent, 0)
    }

    // MARK: - Размер миниатюр

    /// Свой ползунок для режима миниатюр: по умолчанию прежние 100, границы держат значение.
    func test_размерМиниатюрОтдельныйИВГраницах() {
        let key = PanelAppearanceSettings.thumbnailSizeKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(PanelAppearanceSettings.resolvedThumbnailSize, 100, "как было до настройки")
        UserDefaults.standard.set(160.0, forKey: key)
        XCTAssertEqual(PanelAppearanceSettings.resolvedThumbnailSize, 160)
        UserDefaults.standard.set(5.0, forKey: key)
        XCTAssertEqual(PanelAppearanceSettings.resolvedThumbnailSize, 60, "ниже минимума — минимум")
        UserDefaults.standard.set(9999.0, forKey: key)
        XCTAssertEqual(PanelAppearanceSettings.resolvedThumbnailSize, 240, "выше максимума — максимум")
        XCTAssertNotEqual(key, PanelAppearanceSettings.iconScaleKey, "не масштаб иконок списка")
        XCTAssertFalse(key.contains("."), "ключ без точки — за ним следит KVO панели")
    }

    // MARK: - Один курсор на панель

    /// Полоса перерисовки красит только строки между прежним и новым курсором, и после
    /// переключения режима отображения подсвеченная строка оставалась вне полосы — панель
    /// показывала два курсора. Правило: из видимых строк подсветку сохраняет только курсорная.
    func test_подсветкуТеряютВсеСтрокиКромеКурсорной() {
        // Строки 2 и 7 подсвечены, курсор на 2 — гасим 7.
        let lit: Set<Int> = [2, 7]
        XCTAssertEqual(PanelViewController.staleCursorRows(visible: 0..<20, cursor: 2,
                                                           carriesCursor: { lit.contains($0) }), [7])
        // Курсор на 7 — гасим 2.
        XCTAssertEqual(PanelViewController.staleCursorRows(visible: 0..<20, cursor: 7,
                                                           carriesCursor: { lit.contains($0) }), [2])
        // Курсор вообще вне видимой части — гаснут обе.
        XCTAssertEqual(PanelViewController.staleCursorRows(visible: 0..<20, cursor: 40,
                                                           carriesCursor: { lit.contains($0) }), [2, 7])
        // Всё как надо — гасить нечего, и невидимые строки не трогаем.
        XCTAssertTrue(PanelViewController.staleCursorRows(visible: 0..<20, cursor: 2,
                                                          carriesCursor: { $0 == 2 }).isEmpty)
        XCTAssertTrue(PanelViewController.staleCursorRows(visible: 0..<5, cursor: 2,
                                                          carriesCursor: { lit.contains($0) }).isEmpty,
                      "строка 7 за пределами видимого — не наша забота")
    }
}
