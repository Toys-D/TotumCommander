import AppKit
import XCTest
@testable import TotumComXLApp

/// Значки файлов: стиль на каждую тему, контур там, где значок сливается с панелью, и свои
/// значки по виду файла. Картинки проверяются по точкам — так, как их увидит человек.
final class FileIconStyleTests: XCTestCase {

    // MARK: - Выбор на каждую тему

    private func themeDefaults() -> UserDefaults {
        let suite = "fcxl.file.icons.theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func test_покаНеВыбраноНичего_значкиMacOSСКонтуром() {
        let d = themeDefaults()
        XCTAssertEqual(FileIconStyle.current(in: d), .macos)
        XCTAssertTrue(FileIconStyle.contour(in: d))
    }

    func test_стильПомнитсяНаКаждуюТему() {
        let d = themeDefaults()
        FileIconStyle.choose(.totum, dark: false, in: d)
        XCTAssertEqual(FileIconStyle.current(in: d), .totum, "на экране — выбранный")
        XCTAssertEqual(d.string(forKey: FileIconStyle.darkKey), "macos", "тёмная — тот, что был")

        FileIconStyle.mirror(dark: true, in: d)
        XCTAssertEqual(FileIconStyle.current(in: d), .macos)
        FileIconStyle.choose(.macos, dark: true, in: d)
        FileIconStyle.mirror(dark: false, in: d)
        XCTAssertEqual(FileIconStyle.current(in: d), .totum, "светлая помнит своё")
        FileIconStyle.mirror(dark: true, in: d)
        XCTAssertEqual(FileIconStyle.current(in: d), .macos, "тёмная — своё")
    }

    func test_контурПомнитсяНаКаждуюТему() {
        let d = themeDefaults()
        FileIconStyle.chooseContour(false, dark: false, in: d)
        XCTAssertFalse(FileIconStyle.contour(in: d))
        FileIconStyle.mirror(dark: true, in: d)
        XCTAssertTrue(FileIconStyle.contour(in: d), "тёмная — какой был")
        FileIconStyle.mirror(dark: false, in: d)
        XCTAssertFalse(FileIconStyle.contour(in: d), "светлая — свой")
    }

    /// «macOS с контуром» был третьим стилем: кто его выбирал — получает macOS с контуром, кто
    /// выбрал macOS — без него; на экране то же, что было.
    func test_прежнийСтильСКонтуром_становитсяКонтуромУMacOS() {
        let d = themeDefaults()
        d.set("macos", forKey: FileIconStyle.storageKey)
        d.set("macos", forKey: FileIconStyle.lightKey)
        d.set("contour", forKey: FileIconStyle.darkKey)
        FileIconStyle.migrateContourStyleIfNeeded(d)
        XCTAssertEqual(d.string(forKey: FileIconStyle.darkKey), "macos")
        XCTAssertEqual(d.object(forKey: FileIconStyle.contourDarkKey) as? Bool, true)
        XCTAssertEqual(d.object(forKey: FileIconStyle.contourLightKey) as? Bool, false)
        XCTAssertFalse(FileIconStyle.contour(in: d), "на экране была светлая без контура")
        FileIconStyle.mirror(dark: true, in: d)
        XCTAssertTrue(FileIconStyle.contour(in: d))
        XCTAssertEqual(FileIconStyle.current(in: d), .macos)
    }

    // MARK: - Облик: от фона зависит только то, что нужно

    func test_значкамMacOSБезКонтура_фонБезразличен() {
        XCTAssertEqual(FileIconLook(style: .macos, backgrounds: [.white]),
                       FileIconLook(style: .macos, backgrounds: [.black]))
    }

    func test_своимЗначкамВажноЛишьСветлыйФонИлиТёмный() {
        XCTAssertEqual(FileIconLook(style: .totum, backgrounds: [.white], contour: true),
                       FileIconLook(style: .totum, backgrounds: [NSColor(white: 0.85, alpha: 1)]))
        XCTAssertNotEqual(FileIconLook(style: .totum, backgrounds: [.white]),
                          FileIconLook(style: .totum, backgrounds: [.black]))
    }

    /// Цвет панели тянут мышью — облик меняется ступенями, а не на каждом шаге.
    func test_контурМеняетсяСтупенямиЯркости() {
        let white = FileIconLook(style: .macos, backgrounds: [.white], contour: true)
        XCTAssertEqual(white, FileIconLook(style: .macos, backgrounds: [NSColor(white: 0.995, alpha: 1)], contour: true))
        XCTAssertNotEqual(white, FileIconLook(style: .macos, backgrounds: [NSColor(white: 0.5, alpha: 1)], contour: true))
    }

    /// Цвет меняет картинку только у контура: свои значки и значки без контура при его смене
    /// не перерисовываются.
    func test_цветВаженТолькоКонтуру() {
        func look(_ style: FileIconStyle, _ contour: Bool, _ color: NSColor) -> FileIconLook {
            FileIconLook(style: style, backgrounds: [.white], contour: contour, contourColor: color)
        }
        XCTAssertNotEqual(look(.macos, true, .systemRed), look(.macos, true, .systemBlue))
        XCTAssertEqual(look(.macos, false, .systemRed), look(.macos, false, .systemBlue))
        XCTAssertEqual(look(.totum, true, .systemRed), look(.totum, true, .systemBlue))
    }

    // MARK: - Контур

    /// Белый лист сливается с белой панелью и с серой полосой; на тёмной он виден и так.
    /// Синий значок виден на белом — его не трогают. Выключен — не трогают ничего.
    func test_контурТолькоТам_гдеЗначокСливается() throws {
        let white = try XCTUnwrap(FileIconArt.edgeLuminance(of: page(.white)))
        let blue = try XCTUnwrap(FileIconArt.edgeLuminance(of: page(.systemBlue)))
        let light = FileIconLook(style: .macos, backgrounds: [.white, NSColor(white: 0.96, alpha: 1)], contour: true)
        let dark = FileIconLook(style: .macos, backgrounds: [NSColor(white: 0.15, alpha: 1)], contour: true)

        XCTAssertTrue(FileIconArt.needsContour(edge: white, look: light))
        XCTAssertFalse(FileIconArt.needsContour(edge: white, look: dark))
        XCTAssertFalse(FileIconArt.needsContour(edge: blue, look: light))
        XCTAssertFalse(FileIconArt.needsContour(edge: white, look: FileIconLook(style: .macos, backgrounds: [.white])),
                       "контур выключен — значки как есть")
    }

    /// Белый лист на белом: без контура на картинке нет ни одной тёмной точки, с контуром — есть.
    func test_контурВиден_наБелом() {
        let plain = page(.white)
        XCTAssertGreaterThan(darkest(plain, on: .white), 0.95, "сам лист на белом не виден")
        let outlined = FileIconArt.contoured(plain, size: 32, darkBackground: false)
        XCTAssertLessThan(darkest(outlined, on: .white), 0.8, "контур проступил")
    }

    /// Обычный документ на светлой панели получает контур, на тёмной остаётся значком macOS.
    func test_документБезРасширения_наСветлойСКонтуром_наТёмнойКакЕсть() {
        let system = FileIcons.icon(forExtension: "", size: 16, look: FileIconLook(style: .macos, backgrounds: []))
        let onDark = FileIcons.icon(forExtension: "", size: 16,
                                    look: FileIconLook(style: .macos, backgrounds: [NSColor(white: 0.14, alpha: 1)],
                                                       contour: true))
        let onLight = FileIcons.icon(forExtension: "", size: 16,
                                     look: FileIconLook(style: .macos, backgrounds: [.white], contour: true))
        XCTAssertTrue(onDark === system)
        XCTAssertFalse(onLight === system)
        XCTAssertTrue(FileIcons.cached(forExtension: "", size: 16,
                                       look: FileIconLook(style: .macos, backgrounds: [.white], contour: true)) === onLight,
                      "второй раз — тот же, из запаса")
    }

    func test_контурАкцентнымЦветом() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let outlined = FileIconArt.contoured(page(.white), size: 32, color: red, darkBackground: false)
        XCTAssertGreaterThan(reddest(outlined, on: .white), 0.6, "контур красный, как акцент")
    }

    // MARK: - Свои значки

    func test_видФайлаПоРасширению() {
        let expected: [String: FileKind] = [
            "jpg": .image, "PNG": .image, "mp4": .video, "mov": .video, "mp3": .audio,
            "zip": .archive, "rar": .archive, "dmg": .diskImage, "iso": .diskImage, "pdf": .pdf,
            "docx": .document, "pages": .document, "xlsx": .spreadsheet, "csv": .spreadsheet,
            "pptx": .presentation, "key": .presentation, "epub": .book, "djvu": .book, "fb2": .book,
            "swift": .code, "json": .data, "py": .code, "txt": .text, "md": .markup, "ttf": .font,
            "": .other, "xyz123": .other,
        ]
        for (ext, kind) in expected {
            XCTAssertEqual(FileKind.of(ext), kind, ".\(ext)")
        }
    }

    func test_подписьНаПолосе() {
        XCTAssertEqual(FileIconArt.label(for: "pdf"), "PDF")
        XCTAssertEqual(FileIconArt.label(for: ".swift"), "SWIFT")
        XCTAssertEqual(FileIconArt.label(for: "torrent"), "TORR")
        XCTAssertEqual(FileIconArt.label(for: ""), "")
    }

    /// PDF: внизу — красная полоса, выше — светлый лист; на тёмной панели лист тёмный.
    func test_свойЗначок_полосаЦветаВида_листПодФон() {
        let light = FileIconArt.totum(extension: "pdf", size: 44, darkBackground: false)
        let band = color(light, x: 22, yFromBottom: 4)
        XCTAssertGreaterThan(band.redComponent, band.greenComponent + 0.4, "полоса красная")
        XCTAssertGreaterThan(ContrastAppearance.luminance(of: color(light, x: 12, yFromBottom: 36)), 0.6,
                             "лист светлый")

        let dark = FileIconArt.totum(extension: "pdf", size: 44, darkBackground: true)
        XCTAssertLessThan(ContrastAppearance.luminance(of: color(dark, x: 12, yFromBottom: 36)), 0.15,
                          "на тёмной панели лист тёмный")
    }

    // MARK: - Чёткость

    /// Растр на каждый масштаб экрана, каждый своего размера в точках, — как у значков macOS.
    func test_свойЗначок_растрНаКаждыйМасштаб() {
        let icon = FileIconArt.totum(extension: "pdf", size: 22, darkBackground: false)
        XCTAssertEqual(icon.representations.map(\.pixelsWide).sorted(), [22, 44])
        XCTAssertEqual(icon.size, NSSize(width: 22, height: 22))
    }

    /// Край листа — целыми точками: в строке Retina-растра от левого края до листа нет ни
    /// одной полупрозрачной точки, лист начинается сразу непрозрачным.
    func test_свойЗначок_крайЛистаЧёткий() throws {
        for size: CGFloat in [16, 22, 30.56] {
            let rep = try XCTUnwrap(retina(FileIconArt.totum(extension: "zip", size: size, darkBackground: false)))
            let row = rep.pixelsHigh / 2
            let left = (0..<rep.pixelsWide / 2).map { alpha(rep, x: $0, y: row) }
            XCTAssertEqual(left.filter { $0 > 0.02 && $0 < 0.98 }.count, 0, "\(size): \(left.prefix(10))")
            XCTAssertTrue(left.contains { $0 >= 0.98 }, "\(size): лист в строке есть")
        }
    }

    /// Значок под контуром — полного размера, а контур — одна точка экрана, без каймы.
    func test_обводка_значокВПолныйРазмер_крайЧёткий() throws {
        let outlined = FileIconArt.contoured(page(.white), size: 32, color: .black, darkBackground: false)
        let rep = try XCTUnwrap(retina(outlined))
        XCTAssertEqual(rep.pixelsWide, 64)
        let row = 32
        // Лист на своём месте, с 12-й точки, как в самом значке: не уменьшен под обводку.
        let first = try XCTUnwrap(rep.colorAt(x: 12, y: row)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(ContrastAppearance.luminance(of: first), 0.95, "край листа — белый")
        let before = try XCTUnwrap(rep.colorAt(x: 11, y: row)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(ContrastAppearance.luminance(of: before), 0.05, "сразу за ним — обводка")
        let left = (0..<12).map { alpha(rep, x: $0, y: row) }
        XCTAssertEqual(left.filter { $0 > 0.02 && $0 < 0.98 }.count, 0, "\(left)")
        XCTAssertEqual(left.filter { $0 >= 0.98 }.count, 1, "контур — самая тонкая линия, одна точка: \(left)")
    }

    // MARK: - Помощники

    private func retina(_ image: NSImage) -> NSBitmapImageRep? {
        image.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
    }

    private func alpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    /// Квадратный значок-лист одного цвета с прозрачными полями, как у значков macOS.
    private func page(_ fill: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
            fill.setFill()
            NSRect(x: 6, y: 2, width: 20, height: 28).fill()
            return true
        }
    }

    private func bitmap(_ image: NSImage, side: Int, on background: NSColor?) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let background {
            background.setFill()
            NSRect(x: 0, y: 0, width: side, height: side).fill()
        }
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Яркость самой тёмной точки картинки на этом фоне.
    private func darkest(_ image: NSImage, on background: NSColor) -> CGFloat {
        let rep = bitmap(image, side: 64, on: background)
        var lowest: CGFloat = 1
        for y in 0..<64 {
            for x in 0..<64 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                lowest = min(lowest, ContrastAppearance.luminance(of: c))
            }
        }
        return lowest
    }

    /// Насколько красная самая красная точка: красный минус зелёный.
    private func reddest(_ image: NSImage, on background: NSColor) -> CGFloat {
        let rep = bitmap(image, side: 64, on: background)
        var best: CGFloat = 0
        for y in 0..<64 {
            for x in 0..<64 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                best = max(best, c.redComponent - c.greenComponent)
            }
        }
        return best
    }

    /// Сколько точек заметно темнее белого фона.
    private func painted(_ image: NSImage, on background: NSColor) -> Int {
        let rep = bitmap(image, side: 64, on: background)
        var count = 0
        for y in 0..<64 {
            for x in 0..<64 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if ContrastAppearance.luminance(of: c) < 0.9 { count += 1 }
            }
        }
        return count
    }

    private func color(_ image: NSImage, x: Int, yFromBottom: Int) -> NSColor {
        let side = Int(image.size.width)
        let rep = bitmap(image, side: side, on: nil)
        return rep.colorAt(x: x, y: side - 1 - yFromBottom)?.usingColorSpace(.sRGB) ?? .clear
    }
}

/// Значки на настоящей панели: обычный документ на белой панели обведён, на тёмной — значок
/// macOS как есть, и перекраска фона меняет значки на экране сразу, без перезагрузки списка.
@MainActor
final class FileIconPanelTests: XCTestCase {

    private let keys = [FileIconStyle.storageKey,
                        FileIconStyle.contourKey,
                        PanelAppearanceSettings.accentColorHexKey,
                        PanelAppearanceSettings.alternateRowsEnabledKey,
                        PanelAppearanceSettings.panelBackgroundColorHexLightKey,
                        PanelAppearanceSettings.panelBackgroundColorHexDarkKey]
    private var saved: [String: Any] = [:]
    private var folder = ""

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        folder = NSTemporaryDirectory() + "значки-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in ["документ", "заметки", "ещё один"] {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("x".utf8))
        }
        UserDefaults.standard.set(false, forKey: PanelAppearanceSettings.alternateRowsEnabledKey)
        UserDefaults.standard.set(FileIconStyle.macos.rawValue, forKey: FileIconStyle.storageKey)
        UserDefaults.standard.set(true, forKey: FileIconStyle.contourKey)
        setBackground("#FFFFFFFF")
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(atPath: folder)
        try await super.tearDown()
    }

    private func setBackground(_ hex: String) {
        UserDefaults.standard.set(hex, forKey: PanelAppearanceSettings.panelBackgroundColorHexLightKey)
        UserDefaults.standard.set(hex, forKey: PanelAppearanceSettings.panelBackgroundColorHexDarkKey)
    }

    private func panel() async throws -> (PanelViewController, NSWindow) {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.значки.\(id)",
                                viewModeDefaultsKey: "panel.mode.значки.\(id)",
                                showHiddenFiles: false)
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        let tabs = PanelTabsViewModel(panelKey: "tabs.значки.\(id)", initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabs, side: .left)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = vc.view
        addTeardownBlock { window.orderOut(nil) }
        vm.loadDirectory(at: folder)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, vm.items.filter({ !$0.isDirectory }).count < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        return (vc, window)
    }

    /// Значки файлов в строках списка, какими их рисует панель.
    private func fileIcons(_ vc: PanelViewController) throws -> [NSImage] {
        let table = try XCTUnwrap(vc.tableView)
        let column = try XCTUnwrap(table.tableColumns.firstIndex { $0.identifier.rawValue == "icon" })
        return vc.viewModel.items.indices.compactMap { row -> NSImage? in
            guard !vc.viewModel.items[row].isDirectory else { return nil }
            return (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?
                .imageView?.image
        }
    }

    func test_наБелойПанелиОбведены_наТёмнойКакЕсть() async throws {
        let plain = FileIcons.icon(forExtension: "", size: 16, look: FileIconLook(style: .macos, backgrounds: []))
        let (vc, _) = try await panel()

        let onWhite = try fileIcons(vc)
        XCTAssertEqual(onWhite.count, 3)
        for icon in onWhite {
            XCTAssertFalse(icon === plain, "на белой панели белый лист обведён")
        }

        setBackground("#202124FF")
        let onDark = try fileIcons(vc)
        XCTAssertEqual(onDark.count, 3)
        for icon in onDark {
            XCTAssertTrue(icon === plain, "на тёмной панели — значок macOS как есть, сразу после перекраски")
        }
    }

    func test_контурВыключен_значкиКакЕсть() async throws {
        UserDefaults.standard.set(false, forKey: FileIconStyle.contourKey)
        let plain = FileIcons.icon(forExtension: "", size: 16, look: FileIconLook(style: .macos, backgrounds: []))
        let (vc, _) = try await panel()
        for icon in try fileIcons(vc) {
            XCTAssertTrue(icon === plain)
        }
    }

    /// Акцентный цвет и выключатель контура доходят до панели: значки перерисовываются.
    func test_акцентИВыключательДоходятДоПанели() async throws {
        UserDefaults.standard.set("#FF0000FF", forKey: PanelAppearanceSettings.accentColorHexKey)
        let (vc, _) = try await panel()
        let red = try fileIcons(vc)
        XCTAssertEqual(red.count, 3)

        UserDefaults.standard.set("#0000FFFF", forKey: PanelAppearanceSettings.accentColorHexKey)
        try await Task.sleep(nanoseconds: UInt64(PanelViewController.appearanceReloadDelay * 4 * 1e9))
        let blue = try fileIcons(vc)
        XCTAssertEqual(blue.count, 3)
        for (before, after) in zip(red, blue) {
            XCTAssertFalse(before === after, "акцент сменился — контур перекрашен")
        }

        UserDefaults.standard.set(false, forKey: FileIconStyle.contourKey)
        try await Task.sleep(nanoseconds: UInt64(PanelViewController.appearanceReloadDelay * 4 * 1e9))
        let plain = FileIcons.icon(forExtension: "", size: 16, look: FileIconLook(style: .macos, backgrounds: []))
        for icon in try fileIcons(vc) {
            XCTAssertTrue(icon === plain, "контур выключили — значки macOS как есть")
        }
    }

    /// Выбор стиля в настройках доходит до панели: панель перечитывает его, как стиль папок.
    func test_сменаСтиляДоходитДоПанели() async throws {
        let (vc, _) = try await panel()
        UserDefaults.standard.set(FileIconStyle.totum.rawValue, forKey: FileIconStyle.storageKey)
        try await Task.sleep(nanoseconds: UInt64(PanelViewController.appearanceReloadDelay * 4 * 1e9))
        let icons = try fileIcons(vc)
        XCTAssertEqual(icons.count, 3)
        let totum = FileIconArt.totum(extension: "", size: 16, darkBackground: false)
        for icon in icons {
            XCTAssertEqual(icon.size, totum.size, "свой значок — квадрат размера строки")
            XCTAssertFalse(icon === FileIcons.icon(forExtension: "", size: 16,
                                                   look: FileIconLook(style: .macos, backgrounds: [])))
        }
    }
}
