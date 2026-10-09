import AppKit
import XCTest
@testable import TotumComXLApp

/// Знак «новое внутри» у папки: в ней, на любой глубине, появились файлы за срок правила
/// «любое имя». Что нового — говорит Spotlight; здесь проверяется всё, что вокруг ответа.
@MainActor
final class FolderNewsTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Акцент в тестах — бирюзовый: так знак легко узнать.
    private let teal = NSColor(red: 0, green: 0xC7 / 255.0, blue: 0xBE / 255.0, alpha: 1)
    private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    // MARK: - Ответ Spotlight → подпапки

    func test_новоеНаЛюбойГлубине_считаетсяПодпапкеВерхнегоУровня() {
        let found: [(path: String, added: Date)] = [
            ("/Users/me/Work/Проект/src/main.swift", ago(3)),
            ("/Users/me/Work/Проект/README.md", ago(1)),
            ("/Users/me/Work/Фото/2026/лето/1.jpg", ago(5)),
        ]
        let news = FolderNews.newsByChild(of: "/Users/me/Work", found: found)
        XCTAssertEqual(news["/Users/me/Work/Проект"], FolderNews.Inside(count: 2, newest: ago(1)),
                       "у каждой подпапки — сколько нового и самое свежее")
        XCTAssertEqual(news["/Users/me/Work/Фото"], FolderNews.Inside(count: 1, newest: ago(5)))
        XCTAssertEqual(news.count, 2)
    }

    func test_файлПрямоВПапке_неНовоеВнутри() {
        let found: [(path: String, added: Date)] = [("/Users/me/Work/заметка.txt", ago(1))]
        XCTAssertTrue(FolderNews.newsByChild(of: "/Users/me/Work", found: found).isEmpty,
                      "его и так видно: имя красится само")
    }

    func test_скрытоеИЧужоеНеСчитается() {
        let found: [(path: String, added: Date)] = [
            ("/Users/me/Work/Проект/.DS_Store", ago(1)),
            ("/Users/me/Work/Проект/.git/objects/ab", ago(1)),
            ("/Users/me/Work/.cache/x/y", ago(1)),
            ("/Users/me/Workshop/a/b", ago(1)),         // похоже начинается, но не та папка
            ("/Users/other/a/b", ago(1)),
        ]
        XCTAssertTrue(FolderNews.newsByChild(of: "/Users/me/Work", found: found).isEmpty)
        XCTAssertEqual(FolderNews.newsByChild(of: "/Users/me/Work/", found: [("/Users/me/Work/a/b", ago(1))]),
                       ["/Users/me/Work/a": FolderNews.Inside(count: 1, newest: ago(1))],
                       "косая черта в конце пути не мешает")
    }

    /// Spotlight отдаёт настоящие пути, а панель могла прийти по ссылке: /tmp — это /private/tmp.
    func test_путьЧерезСсылку_подпапкиПоПутиПанели() throws {
        let folder = "/tmp/fcxl-news-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let real = FolderNews.realPath(folder)
        XCTAssertTrue(real.hasPrefix("/private/tmp/"), real)
        let news = FolderNews.newsByChild(of: folder, found: [(real + "/a/b.txt", ago(1))])
        XCTAssertEqual(news, [folder + "/a": FolderNews.Inside(count: 1, newest: ago(1))],
                       "подпапка — по пути панели, не по настоящему")
    }

    func test_новыеНаходкиСкладываются() {
        let before = ["/w/a": FolderNews.Inside(count: 3, newest: ago(5)),
                      "/w/b": FolderNews.Inside(count: 1, newest: ago(1))]
        let after = FolderNews.adding(before, ["/w/a": FolderNews.Inside(count: 2, newest: ago(2)),
                                               "/w/c": FolderNews.Inside(count: 1, newest: ago(3))])
        XCTAssertEqual(after["/w/a"], FolderNews.Inside(count: 5, newest: ago(2)), "счёт сложился, дата — свежайшая")
        XCTAssertEqual(after["/w/b"], before["/w/b"])
        XCTAssertEqual(after["/w/c"], FolderNews.Inside(count: 1, newest: ago(3)))
    }

    // MARK: - Правило и знак

    private func rule(mask: String = "", minutes: Double? = 24 * 60, fades: Bool = true,
                      enabled: Bool = true) -> FileColorRule {
        FileColorRule(mask: mask, colorHex: "#00C7BE", darkColorHex: "#63E6E2",
                      isEnabled: enabled, freshMinutes: minutes, fades: fades)
    }

    func test_новизнаПоПервомуВключённомуПравилуЛюбоеИмяСоСроком() {
        let masked = rule(mask: "*.pdf")
        let disabled = rule(enabled: false)
        let noPeriod = rule(minutes: nil)
        let wanted = rule(minutes: 60)
        XCTAssertEqual(FolderNews.rule(in: [masked, disabled, noPeriod, wanted])?.id, wanted.id)
        XCTAssertNil(FolderNews.rule(in: [masked, disabled, noPeriod]), "нет такого правила — нет и знака")
    }

    private func folder(newest: Date?, count: Int = 3, name: String = "Проект",
                        directory: Bool = true) -> FileItem {
        var item = FileItem(path: "/Users/me/Work/" + name, name: name, fileExtension: "", size: 0,
                            isDirectory: directory, isHidden: false, isSymlink: false,
                            permissions: "755", dateModified: ago(100))
        item.newestInside = newest
        item.newInsideCount = newest == nil ? 0 : count
        return item
    }

    func test_знакТолькоУПапкиСНовымВСрок() {
        let r = rule()
        func sign(_ item: FileItem, rule: FileColorRule? = nil, enabled: Bool = true) -> FolderNews.Mark? {
            FolderNews.mark(for: item, rule: rule ?? r, enabled: enabled, color: teal, now: now)
        }
        XCTAssertNotNil(sign(folder(newest: ago(1))))
        XCTAssertNil(sign(folder(newest: nil)))
        XCTAssertNil(sign(folder(newest: ago(1), count: 0)), "нечего считать — нечего показывать")
        XCTAssertNil(sign(folder(newest: ago(25))), "срок вышел")
        XCTAssertNil(sign(folder(newest: ago(1)), enabled: false), "выключено")
        XCTAssertNil(FolderNews.mark(for: folder(newest: ago(1)), rule: nil, enabled: true, color: teal, now: now),
                     "нет правила")
        XCTAssertNil(sign(folder(newest: ago(1), name: "..")))
        XCTAssertNil(sign(folder(newest: ago(1), name: "a.txt", directory: false)))
        XCTAssertNil(sign(folder(newest: ago(1), name: "Почта.app")), "программа — не папка: знака нет")
    }

    func test_знакГаснетКакПравилоИКрасится_акцентом() throws {
        let fading = try XCTUnwrap(FolderNews.mark(for: folder(newest: ago(12)), rule: rule(), enabled: true,
                                                   color: teal, now: now))
        XCTAssertEqual(fading.strength, 0.5, accuracy: 0.001, "гаснущее правило: полсрока — полсилы")
        XCTAssertLessThan(fading.opacity, 1)
        XCTAssertGreaterThan(fading.opacity, 0.4, "к концу срока тише, но читается")
        XCTAssertEqual(FolderNews.mark(for: folder(newest: ago(12)), rule: rule(fades: false), enabled: true,
                                       color: teal, now: now)?.strength, 1, "негаснущее — в полную силу до конца срока")
        let purple = try XCTUnwrap(FolderNews.mark(for: folder(newest: ago(1)), rule: rule(), enabled: true,
                                                   color: .systemPurple, now: now))
        XCTAssertEqual(purple.color, .systemPurple, "цвет — тот, что дали (акцентный), а не цвет правила")
    }

    // MARK: - О каких папках спрашивать

    func test_оКакихПапкахСпрашиватьSpotlight() {
        XCTAssertTrue(FolderNews.canWatch("/Users/me/Downloads"))
        XCTAssertFalse(FolderNews.canWatch("/"), "ответом был бы весь диск")
        XCTAssertFalse(FolderNews.canWatch(NSTemporaryDirectory()), "системную временную он не индексирует")
        XCTAssertFalse(FolderNews.canWatch(NSTemporaryDirectory() + "x/y"))
        XCTAssertFalse(FolderNews.canWatch("/var/folders/ab/cd/T/x"))
        XCTAssertFalse(FolderNews.canWatch("/Users/me/.config/x"), "скрытое не индексируется")
        XCTAssertFalse(FolderNews.canWatch("STACK"), "не путь")
    }

    // MARK: - Счётчик

    func test_счётчикПишетСколькоНового() {
        XCTAssertEqual(FolderNewsChip.text(count: 12), "+12")
        XCTAssertEqual(FolderNewsChip.text(count: 1), "+1")
        XCTAssertEqual(FolderNewsChip.text(count: 25_000), "+999", "длиннее плашке быть незачем")
    }

    func test_безНовогоШиринаНулевая_именемНичегоНеОтнято() throws {
        let font = NSFont.systemFont(ofSize: 12)
        XCTAssertEqual(FolderNewsChip.width(count: 0, font: font), 0)
        let mark = FolderNews.Mark(color: teal, strength: 1)
        XCTAssertNil(FolderNewsChip.image(count: 0, mark: mark, font: font, nameColor: teal))
        let chip = try XCTUnwrap(FolderNewsChip.image(count: 12, mark: mark, font: font, nameColor: teal))
        XCTAssertEqual(chip.size.width, FolderNewsChip.width(count: 12, font: font), accuracy: 0.5,
                       "ширина колонки — ровно по плашке")
        XCTAssertGreaterThan(FolderNewsChip.width(count: 123, font: font),
                             FolderNewsChip.width(count: 1, font: font), "больше цифр — шире")
        XCTAssertNotNil(FolderNewsChip.plaqueImage(count: 12, mark: mark, font: font))
    }

    /// Под курсором плашка растёт вместе с именем: на каждом кадре в том же масштабе и ровно за
    /// последней буквой. Прижатая к краю колонки (имя обрезано) — растёт на месте.
    func test_плашкаРастётВместеСИменем() {
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let label = NSView(frame: NSRect(x: 10, y: 2, width: 200, height: 20))
        let chip = NSView(frame: NSRect(x: 90, y: 2, width: 40, height: 20))
        chip.wantsLayer = true
        cell.addSubview(label)
        cell.addSubview(chip)
        func left(_ view: NSView) -> CGFloat {
            let shift = CATransform3DGetAffineTransform(view.layer?.transform ?? CATransform3DIdentity)
            return view.frame.minX + CGPoint(x: 0, y: 10).applying(shift).x
        }

        FolderNewsChip.follow(chip, label: label, textEnd: 80, scale: 0.8)
        XCTAssertEqual(left(chip), 10 + 80 * 0.8, accuracy: 0.01, "за последней буквой этого кадра")
        let height = CGPoint(x: 0, y: 20).applying(CATransform3DGetAffineTransform(chip.layer!.transform)).y
            - CGPoint(x: 0, y: 0).applying(CATransform3DGetAffineTransform(chip.layer!.transform)).y
        XCTAssertEqual(height, 16, accuracy: 0.01, "в масштабе букв")

        FolderNewsChip.follow(chip, label: label, textEnd: 80, scale: 1)
        XCTAssertTrue(CATransform3DIsIdentity(chip.layer!.transform), "рост окончен — на месте")

        FolderNewsChip.follow(chip, label: label, textEnd: 250, scale: 0.8)
        XCTAssertEqual(left(chip), 90, accuracy: 0.01, "имя обрезано, плашка у края — не уезжает на буквы")
    }

    /// Поле имени сообщает о каждом кадре роста — с первого (прежний размер) до последнего.
    func test_полеИмениСообщаетКадрыРоста() {
        let field = MarqueeTextField(labelWithString: "Downloads")
        var scales: [CGFloat] = []
        field.onGrowthFrame = { scales.append(field.currentGrowthScale) }
        field.animateGrowth(fromRatio: 0.8, duration: 0.15)
        XCTAssertEqual(scales.first ?? 0, 0.8, accuracy: 0.02, "первый кадр — прежний размер")
        field.stopGrowth()
        XCTAssertEqual(scales.last, 1, "последний — настоящий")
    }

    /// Цифры — цветом имени рядом, а не акцентом: под курсором имя в цвете курсора, и цифры в
    /// нём же. Акцентом их было не прочитать ни на тёмном курсоре, ни рядом с именем другого цвета.
    func test_цифрыЦветомИмени() throws {
        let mark = FolderNews.Mark(color: teal, strength: 1)
        let font = NSFont.systemFont(ofSize: 13)
        let red = NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        let digits = try XCTUnwrap(digitsColor(try XCTUnwrap(
            FolderNewsChip.image(count: 64, mark: mark, font: font, nameColor: red))))
        XCTAssertGreaterThan(digits.redComponent, 0.6, "цвет имени, а не акцент")
        XCTAssertLessThan(digits.greenComponent, 0.3)
    }

    /// Цифры плашки — тонкие (light), на пункт меньше имени; ширина для раскладки считается
    /// тем же шрифтом, что и картинка. На миниатюре — обычные.
    func test_цифрыПлашкиТонкие() throws {
        let base = NSFont.systemFont(ofSize: 13)
        let font = FolderNewsChip.listFont(for: base)
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = try XCTUnwrap(traits?[.weight] as? CGFloat)
        XCTAssertEqual(weight, NSFont.Weight.light.rawValue, accuracy: 0.01)
        XCTAssertEqual(font.pointSize, 12)
        let chip = try XCTUnwrap(FolderNewsChip.image(count: 409, mark: FolderNews.Mark(color: .systemBlue, strength: 1),
                                                      font: base, nameColor: .black))
        XCTAssertEqual(chip.size.width, FolderNewsChip.width(count: 409, font: base), accuracy: 0.5)

        // На миниатюре — обычные: белые тонкие на светлом акценте пропадали бы.
        let plaque = FolderNewsChip.plaqueFont(for: .systemFont(ofSize: 11))
        let plaqueTraits = plaque.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        XCTAssertEqual(try XCTUnwrap(plaqueTraits?[.weight] as? CGFloat), NSFont.Weight.regular.rawValue, accuracy: 0.01)
    }

    /// Строка с плашкой — на фоне панели и на тёмном и светлом курсоре, с именем того цвета, что
    /// у него там, — в папку FCXL_LOOK_DIR, посмотреть глазами.
    func test_плашкаНаКурсорахДляПросмотра() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        let slate = NSColor(srgbRed: 0x6B / 255.0, green: 0x77 / 255.0, blue: 0x85 / 255.0, alpha: 1)
        let font = NSFont.systemFont(ofSize: 15)
        // Фон строки (панель или курсор) и цвет имени на нём.
        let rows: [(ground: String, name: NSColor)] = [
            ("#EDEDEDFF", NSColor(srgbRed: 0.17, green: 0.24, blue: 0.31, alpha: 1)),
            ("#59676FFF", NSColor(srgbRed: 0.35, green: 0.78, blue: 0.98, alpha: 1)),
            ("#FFE680FF", .black),
            ("#2B2F33FF", NSColor(white: 0.85, alpha: 1)),
            ("#C9D3DBFF", .black),
        ]
        let rowHeight = 30, width = 260, scale = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: rowHeight * rows.count * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: rowHeight * rows.count)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (index, row) in rows.enumerated() {
            let ground = try XCTUnwrap(PanelAppearanceSettings.optionalNSColor(from: row.ground))
            let rect = NSRect(x: 0, y: (rows.count - 1 - index) * rowHeight, width: width, height: rowHeight)
            ground.setFill()
            rect.fill()
            let name = NSAttributedString(string: "Downloads",
                                          attributes: [.font: font, .foregroundColor: row.name])
            let nameSize = name.size()
            name.draw(at: NSPoint(x: 12, y: rect.midY - nameSize.height / 2))
            let chip = try XCTUnwrap(FolderNewsChip.image(count: 64, mark: FolderNews.Mark(color: slate, strength: 1),
                                                          font: font, nameColor: row.name))
            chip.draw(at: NSPoint(x: 12 + ceil(nameSize.width), y: rect.midY - chip.size.height / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("folder-news-chip.png"))
    }

    /// Цвет цифр плашки: самая непрозрачная точка — буквы, подложка под ними прозрачнее.
    private func digitsColor(_ image: NSImage) -> NSColor? {
        let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        }
        NSGraphicsContext.restoreGraphicsState()
        var best: NSColor?
        for y in 0..<height {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y),
                      color.alphaComponent > (best?.alphaComponent ?? 0) else { continue }
                best = color
            }
        }
        return best
    }

    // MARK: - Пришло по журналу диска (не дожидаясь Spotlight)

    /// Папка с подпапкой «Проект» и файлами внутри — свежими (дата добавления — сейчас).
    private func freshTree() throws -> (root: URL, inner: URL) {
        let fm = FileManager.default
        let top = fm.temporaryDirectory.appendingPathComponent("fcxl-arrive-\(UUID().uuidString)")
        let inner = top.appendingPathComponent("Проект")
        try fm.createDirectory(at: inner.appendingPathComponent("глубже"), withIntermediateDirectories: true)
        try Data("новое".utf8).write(to: inner.appendingPathComponent("отчёт.docx"))
        try Data().write(to: inner.appendingPathComponent(".DS_Store"))
        try Data().write(to: top.appendingPathComponent("в-самой-папке.txt"))
        return (top, inner)
    }

    /// Крутить главный цикл, пока не сбудется (FSEvents и ответы приходят не сразу).
    private func wait(_ seconds: TimeInterval = 10, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func test_пришедшийФайлЗапоминается_ушедшийЗабывается() throws {
        let arrivals = FolderNewsArrivals()
        let (top, inner) = try freshTree()
        defer { try? FileManager.default.removeItem(at: top) }
        let report = inner.appendingPathComponent("отчёт.docx").path
        arrivals.note([report, inner.appendingPathComponent(".DS_Store").path,
                       inner.appendingPathComponent("глубже").path])
        let since = Date().addingTimeInterval(-3600)
        XCTAssertEqual(arrivals.entries(under: top.path, since: since).map(\.path), [report],
                       "файл — да; скрытое и папка — нет")
        XCTAssertTrue(arrivals.entries(under: top.path, since: Date().addingTimeInterval(3600)).isEmpty,
                      "раньше срока — не в счёт")

        var gone: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: FolderNewsArrivals.changed, object: nil,
                                                              queue: nil) { note in
            gone += note.userInfo?["gone"] as? [String] ?? []
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try FileManager.default.removeItem(atPath: report)
        arrivals.note([report])
        XCTAssertTrue(arrivals.entries(under: top.path, since: since).isEmpty, "ушёл — забыт")
        XCTAssertEqual(gone, [report], "и сказано, что его на месте нет — Spotlight может ещё числить")
    }

    /// Документ-пакет (.pages, программа) — одна новость, а не сотни файлов внутри.
    func test_пакетСчитаетсяЦеликом() throws {
        let arrivals = FolderNewsArrivals()
        let (top, inner) = try freshTree()
        defer { try? FileManager.default.removeItem(at: top) }
        let app = inner.appendingPathComponent("Программа.app")
        let inside = app.appendingPathComponent("Contents/MacOS/Программа")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: inside)
        arrivals.note([app.path, inside.path])
        XCTAssertEqual(arrivals.entries(under: top.path, since: Date().addingTimeInterval(-3600)).map(\.path),
                       [app.path])
    }

    /// Брошенное, пока ни одна панель здесь не стояла (через Finder, программа в фоне), — из
    /// журнала диска при входе. Spotlight временную папку не индексирует: счёт — только по журналу.
    func test_журналДочитываетсяПриВходе_иДальшеВживую() throws {
        FolderNewsArrivals.shared.forgetAll()
        defer { FolderNewsArrivals.shared.forgetAll() }
        let (top, inner) = try freshTree()
        defer { try? FileManager.default.removeItem(at: top) }
        let deep = inner.appendingPathComponent("глубже/далеко.txt")
        try Data().write(to: deep)
        Thread.sleep(forTimeInterval: 1.5)   // журнал пишется с задержкой

        let query = FolderNewsQuery()
        defer { query.stop() }
        var answer: [String: FolderNews.Inside] = [:]
        query.onUpdate = { _, news in answer = news }
        query.follow(top.path, period: 3600)
        wait { answer[inner.path]?.count == 2 }
        XCTAssertEqual(answer[inner.path]?.count, 2, "отчёт и файл глубже; скрытое и файл в самой папке — нет")

        try Data().write(to: inner.appendingPathComponent("ещё.pdf"))
        wait { answer[inner.path]?.count == 3 }
        XCTAssertEqual(answer[inner.path]?.count, 3, "брошенное потом — тоже сразу")

        try FileManager.default.moveItem(at: deep, to: top.appendingPathComponent("унёс.txt"))
        wait { answer[inner.path]?.count == 2 }
        XCTAssertEqual(answer[inner.path]?.count, 2, "унесли — счёт меньше")
    }

    /// Вернулся в папку — журнал дочитывается с места, где остановился, а не за весь срок заново.
    func test_возвратВПапку_журналСТогоЖеМеста() throws {
        FolderNewsArrivals.shared.forgetAll()
        defer { FolderNewsArrivals.shared.forgetAll() }
        let (top, _) = try freshTree()
        defer { try? FileManager.default.removeItem(at: top) }
        let queue = DispatchQueue(label: "test")
        let first = try XCTUnwrap(FolderNewsStream(folder: top.path, period: 3600, queue: queue))
        first.stop()
        queue.sync {}
        let read = try XCTUnwrap(FolderNewsArrivals.shared.readRange(of: top.path))
        let wanted = FolderNewsStream.eventID(before: Date().addingTimeInterval(-3600), on: top.path)
        XCTAssertLessThanOrEqual(read.from, wanted, "прочитано с начала срока")

        let second = try XCTUnwrap(FolderNewsStream(folder: top.path, period: 3600, queue: queue))
        second.stop()
        queue.sync {}
        XCTAssertEqual(FolderNewsArrivals.shared.readRange(of: top.path)?.from, read.from,
                       "дочитано после прежнего — начало то же")
    }

    func test_одинПутьСчитаетсяОдинРаз() throws {
        FolderNewsArrivals.shared.forgetAll()
        defer { FolderNewsArrivals.shared.forgetAll() }
        let (top, inner) = try freshTree()
        defer { try? FileManager.default.removeItem(at: top) }
        let report = inner.appendingPathComponent("отчёт.docx").path
        let tally = FolderNewsTally(folder: top.path, since: Date().addingTimeInterval(-3600))
        // Spotlight пишет путь настоящим (/private/var/…), а журнал мог — путём панели.
        tally.take([(FolderNews.realPath(report), Date())])
        FolderNewsArrivals.shared.note([report])
        XCTAssertNotEqual(FolderNews.realPath(report), report, "временная папка — за ссылкой /var")
        XCTAssertEqual(tally.recount()?[inner.path]?.count, 1, "знает и Spotlight, и журнал — один файл")
        XCTAssertNil(tally.recount(), "ничего не поменялось — перерисовывать нечего")
    }

    /// Spotlight о переносе узнаёт с опозданием и числит файл там, откуда его унесли, — такое
    /// не считается.
    func test_устаревшийОтветSpotlightНеСчитается() throws {
        FolderNewsArrivals.shared.forgetAll()
        defer { FolderNewsArrivals.shared.forgetAll() }
        let (top, inner) = try freshTree()
        defer { try? FileManager.default.removeItem(at: top) }
        let report = FolderNews.realPath(inner.appendingPathComponent("отчёт.docx").path)
        let tally = FolderNewsTally(folder: top.path, since: Date().addingTimeInterval(-3600))
        tally.take([(report, Date()), (inner.appendingPathComponent("унесённый.docx").path, Date())])
        XCTAssertEqual(tally.recount()?[inner.path]?.count, 1, "файла, которого нет на месте, не считать")
        XCTAssertTrue(tally.forget([report]), "журнал сказал: ушёл")
        XCTAssertNil(tally.recount()?[inner.path])
    }

    // MARK: - В панели

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fcxl-news-\(UUID().uuidString)")
        for sub in ["Проект/src", "Фото"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("заметка.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func panel() -> PanelViewModel {
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: root.path,
                                pathDefaultsKey: "news.\(UUID().uuidString)",
                                viewModeDefaultsKey: "newsm.\(UUID().uuidString)", showHiddenFiles: true)
        let deadline = Date().addingTimeInterval(5)
        while vm.allItems.count < 3, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return vm
    }

    private func news(_ vm: PanelViewModel, _ name: String) -> FolderNews.Inside? {
        guard let item = vm.allItems.first(where: { $0.name == name }), let newest = item.newestInside else { return nil }
        return FolderNews.Inside(count: item.newInsideCount, newest: newest)
    }

    func test_ответSpotlightРасходитсяПоПапкамИПереживаетПеречитку() throws {
        let vm = panel()
        XCTAssertNil(vm.folderNewsQuery, "модель без экрана Spotlight не спрашивает")
        let project = root.appendingPathComponent("Проект").path
        let inside = FolderNews.Inside(count: 4, newest: ago(2))
        vm.applyFolderNews([project: inside], in: vm.currentPath)
        XCTAssertEqual(news(vm, "Проект"), inside)
        XCTAssertNil(news(vm, "Фото"))
        XCTAssertNil(news(vm, "заметка.txt"))

        vm.reloadKeepingCursor()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(news(vm, "Проект"), inside, "перечитка той же папки знак не гасит")

        vm.applyFolderNews([:], in: vm.currentPath)
        XCTAssertNil(news(vm, "Проект"), "нового больше нет — знак гаснет")
        XCTAssertEqual(vm.allItems.first { $0.name == "Проект" }?.newInsideCount, 0)
    }

    func test_ответОДругойПапкеОтбрасывается() {
        let vm = panel()
        vm.applyFolderNews([root.appendingPathComponent("Проект").path: FolderNews.Inside(count: 1, newest: ago(1))],
                           in: "/Users/me/Elsewhere")
        XCTAssertNil(news(vm, "Проект"))
    }

    func test_размерПапкиНеСтираетЗнак() {
        let item = folder(newest: ago(1), count: 7)
        XCTAssertEqual(item.withSize(1024).newestInside, ago(1))
        XCTAssertEqual(item.withSize(1024).newInsideCount, 7)
        XCTAssertEqual(item.withSize(1024).size, 1024)
    }
}
