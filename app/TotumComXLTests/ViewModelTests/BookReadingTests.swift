import FCXLBridgeObjC
import FCXLDjVuUI
import PDFKit
import XCTest

@testable import TotumComXLApp

/// Разбор книг проверяется на настоящих файлах: выдуманный FB2 из трёх строчек не поймает
/// ни кодировку windows-1251, ни картинки в base64 с переводами строк, ни книгу из одной
/// исполинской секции.
@MainActor
final class BookReadingTests: XCTestCase {
    private var root = ""

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "fcxl-book-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func makeFB2(_ name: String, encoding: String.Encoding = .utf8,
                         declared: String = "utf-8", body: String) -> String {
        let xml = """
        <?xml version="1.0" encoding="\(declared)"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" \
        xmlns:l="http://www.w3.org/1999/xlink">
        <description><title-info><book-title>Проба книги</book-title>
        <author><first-name>Иван</first-name><last-name>Петров</last-name></author>
        </title-info></description>
        <body>\(body)</body>
        </FictionBook>
        """
        let path = (root as NSString).appendingPathComponent(name)
        try? xml.data(using: encoding)?.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testAPlainBookBecomesChapters() throws {
        let file = makeFB2("книга.fb2", body: """
        <section><title><p>Глава первая</p></title>
        <p>Текст первой главы.</p><empty-line/><p>Ещё абзац.</p></section>
        <section><title><p>Глава вторая</p></title><p>Текст второй.</p></section>
        """)
        let out = URL(fileURLWithPath: root + "/выход")
        let book = try FB2Parser.build(from: file, sourcePath: file, into: out)

        XCTAssertEqual(book.title, "Проба книги")
        XCTAssertEqual(book.author, "Иван Петров")
        XCTAssertEqual(book.chapters.count, 2, "две секции — две главы")
        XCTAssertEqual(book.chapters.map(\.title), ["Глава первая", "Глава вторая"])

        let html = try String(contentsOf: book.chapters[0].file, encoding: .utf8)
        XCTAssertTrue(html.contains("Текст первой главы"))
        XCTAssertTrue(html.contains("<p class=\"empty\">"), "пустая строка сохранена")
        XCTAssertFalse(html.contains("&nbsp;"),
                       "HTML-сущность уронила бы страницу целиком при строгом разборе")
        XCTAssertTrue(html.contains("book.css"), "стиль подключён")
    }

    /// Русские FB2 сплошь и рядом в windows-1251 — и объявляют это честно.
    func testWindows1251IsReadAsText() throws {
        let file = makeFB2("старая.fb2", encoding: .windowsCP1251, declared: "windows-1251",
                           body: "<section><p>Съешь ещё этих мягких булок</p></section>")
        let out = URL(fileURLWithPath: root + "/выход1251")
        let book = try FB2Parser.build(from: file, sourcePath: file, into: out)
        let html = try String(contentsOf: book.chapters[0].file, encoding: .utf8)
        XCTAssertTrue(html.contains("Съешь ещё этих мягких булок"),
                      "кодировка прочитана, а не превращена в кракозябры")
    }

    /// Декларация врёт: написано utf-8, а байты — 1251. Так тоже бывает.
    func testALyingDeclarationIsSurvived() throws {
        let file = makeFB2("врунья.fb2", encoding: .windowsCP1251, declared: "utf-8",
                           body: "<section><p>Проверка кодировки</p></section>")
        let out = URL(fileURLWithPath: root + "/выходврун")
        let book = try FB2Parser.build(from: file, sourcePath: file, into: out)
        let html = try String(contentsOf: book.chapters[0].file, encoding: .utf8)
        XCTAssertTrue(html.contains("Проверка кодировки"), "текст восстановлен")
    }

    func testPicturesAreWrittenAsFiles() throws {
        // Настоящий PNG 1×1, base64 разбит переводами строк — как в живых книгах.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM\nIQAAAABJRU5ErkJggg=="
        let file = makeFB2("скартинкой.fb2", body: """
        <section><p>До картинки</p><image l:href="#pic1.png"/></section>
        </body><binary id="pic1.png" content-type="image/png">\(png)</binary><body>
        """)
        let out = URL(fileURLWithPath: root + "/выходкартинка")
        let book = try FB2Parser.build(from: file, sourcePath: file, into: out)

        let picture = out.appendingPathComponent("img/pic1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path),
                      "картинка записана отдельным файлом, а не осталась в памяти")
        let bytes = try Data(contentsOf: picture)
        XCTAssertEqual(bytes.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "и это настоящий PNG")

        let html = try String(contentsOf: book.chapters[0].file, encoding: .utf8)
        XCTAssertTrue(html.contains("<img src=\"img/pic1.png\""))
    }

    /// Книга из одной исполинской секции не должна стать одним чудовищным файлом.
    func testAHugeSectionIsCutIntoPieces() throws {
        let paragraphs = (0..<4000).map { "<p>Абзац номер \($0), и ещё немного текста для веса.</p>" }
            .joined()
        let file = makeFB2("огромная.fb2", body: "<section><title><p>Всё сразу</p></title>"
                           + paragraphs + "</section>")
        let out = URL(fileURLWithPath: root + "/выходогромный")
        let book = try FB2Parser.build(from: file, sourcePath: file, into: out)
        XCTAssertGreaterThan(book.chapters.count, 1,
                             "разрезано на куски — иначе браузеру дали бы мегабайты разом")
    }

    func testFootnotesDoNotBecomeChapters() throws {
        let file = makeFB2("сосносками.fb2", body: """
        <section><title><p>Повесть</p></title><p>Текст повести.</p></section>
        </body><body name="notes">
        <section id="n1"><title><p>1</p></title><p>Первая сноска.</p></section>
        <section id="n2"><title><p>2</p></title><p>Вторая сноска.</p></section>
        <section id="n3"><title><p>3</p></title><p>Третья сноска.</p></section>
        """)
        let out = URL(fileURLWithPath: root + "/сноски")
        let book = try FB2Parser.build(from: file, sourcePath: file, into: out)

        XCTAssertEqual(book.chapters.count, 2,
                       "повесть и ОДНИ примечания — а не повесть и три обрывка по строчке")
        XCTAssertEqual(book.chapters[0].title, "Повесть")
        XCTAssertEqual(book.chapters[1].title, L("viewer.book.notes"))
        let notes = try String(contentsOf: book.chapters[1].file, encoding: .utf8)
        XCTAssertTrue(notes.contains("Первая сноска") && notes.contains("Третья сноска"),
                      "все сноски внутри одной главы")
    }

    /// Закладка обязана пережить закрытие просмотрщика — иначе она бесполезна.
    func testABookmarkSurvivesAClosedViewer() throws {
        let file = (root as NSString).appendingPathComponent("документ.djvu")
        FileManager.default.createFile(atPath: file, contents: Data(repeating: 7, count: 4096))
        let storeFile = URL(fileURLWithPath: root + "/marks.json")

        // Сеанс первый: поставили закладку и закрыли просмотрщик.
        let first = ReaderMarksStore(fileURL: storeFile)
        let added = first.toggleMark(at: ReaderLocation(page: 41), label: "Страница 42",
                                     for: file)
        XCTAssertTrue(added)
        first.flush()

        // Сеанс второй: открыли заново — закладка на месте.
        let second = ReaderMarksStore(fileURL: storeFile)
        let marks = second.marks(for: file)
        XCTAssertEqual(marks.count, 1, "закладка пережила закрытие")
        XCTAssertEqual(marks.first?.location.page, 41)
        XCTAssertEqual(marks.first?.label, "Страница 42")

        // И «где остановился» — тоже.
        second.rememberPosition(ReaderLocation(page: 100), for: file)
        second.flush()
        XCTAssertEqual(ReaderMarksStore(fileURL: storeFile).lastPosition(for: file)?.page, 100)
    }

    /// Подменили файл — закладки прячутся, но не уничтожаются.
    func testMarksHideForAChangedFileButAreNotDestroyed() throws {
        let file = (root as NSString).appendingPathComponent("сменный.djvu")
        FileManager.default.createFile(atPath: file, contents: Data(repeating: 1, count: 100))
        let storeFile = URL(fileURLWithPath: root + "/marks2.json")
        let store = ReaderMarksStore(fileURL: storeFile)
        store.toggleMark(at: ReaderLocation(page: 5), label: "Стр. 6", for: file)
        store.flush()

        // Файл подменили другим — прежние закладки к нему не относятся.
        try Data(repeating: 2, count: 999).write(to: URL(fileURLWithPath: file))
        XCTAssertTrue(ReaderMarksStore(fileURL: storeFile).marks(for: file).isEmpty,
                      "чужому файлу чужие закладки не показываются")

        // Но в файле хранилища они остались — вернётся прежний файл, вернутся и они.
        let raw = try String(contentsOf: storeFile, encoding: .utf8)
        XCTAssertTrue(raw.contains("Стр. 6"), "молча уничтожать чужую работу нельзя")
    }

    // MARK: - EPUB

    /// Книги в жизни сплошь и рядом нумеруют главы «0», «1», «2» в оглавлении, а на самой
    /// странице написано «ГЛАВА 1». Показывать номер из файла — честно и бесполезно.
    func testANumberedChapterTakesItsNameFromThePage() throws {
        let file = URL(fileURLWithPath: root + "/Chapter0.html")
        try """
        <html><body><h1>ГЛАВА 1</h1><p>Люди. Шум. Атмосфера надежды.</p></body></html>
        """.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(EPUBParser.usefulTitle("0", in: file), "ГЛАВА 1",
                       "вместо номера из оглавления — заголовок со страницы")
        XCTAssertEqual(EPUBParser.usefulTitle("", in: file), "ГЛАВА 1",
                       "пустое название — тоже повод заглянуть в текст")
        XCTAssertEqual(EPUBParser.usefulTitle("Похищение чародея", in: file),
                       "Похищение чародея", "настоящее название не трогаем")
    }

    func testAChapterWithoutAnyHeadingKeepsWhatItHad() throws {
        let file = URL(fileURLWithPath: root + "/Chapter9.html")
        try "<html><body><p>Просто текст без заголовка.</p></body></html>"
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(EPUBParser.usefulTitle("7", in: file), "7",
                       "заголовка нет — остаётся то, что было, а не пустота")
    }

    /// Полный круг EPUB: собрать книгу руками, прочитать её нашим разбором.
    func testARealEPUBIsReadInSpineOrder() throws {
        let epub = (root as NSString).appendingPathComponent("книга.epub")
        let build = (root as NSString).appendingPathComponent("сборка")
        let meta = (build as NSString).appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(atPath: meta, withIntermediateDirectories: true)
        try "application/epub+zip".write(toFile: (build as NSString)
            .appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?><container version="1.0"         xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
        """.write(toFile: (meta as NSString).appendingPathComponent("container.xml"),
                  atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0">
        <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Проба EPUB</dc:title>
        <dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">Автор Пробный</dc:creator>
        </metadata>
        <manifest><item id="c1" href="one.html" media-type="application/xhtml+xml"/>
        <item id="c2" href="two.html" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c2"/><itemref idref="c1"/></spine></package>
        """.write(toFile: (build as NSString).appendingPathComponent("book.opf"),
                  atomically: true, encoding: .utf8)
        try "<html><body><h1>Вторая по файлу</h1><p>Текст.</p></body></html>"
            .write(toFile: (build as NSString).appendingPathComponent("one.html"),
                   atomically: true, encoding: .utf8)
        try "<html><body><h1>Первая по чтению</h1><p>Текст.</p></body></html>"
            .write(toFile: (build as NSString).appendingPathComponent("two.html"),
                   atomically: true, encoding: .utf8)

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-r", "-q", epub, "."]
        zip.currentDirectoryURL = URL(fileURLWithPath: build)
        try zip.run(); zip.waitUntilExit()

        let unpacked = URL(fileURLWithPath: root + "/распакованное")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try CoreBridgeService().extractArchiveAll(
            archivePath: epub, destinationPath: unpacked.path,
            overwriteExisting: true, progress: { _, _, _, _, _, _ in })

        let book = try EPUBParser.build(unpacked: unpacked, sourcePath: epub)
        XCTAssertEqual(book.title, "Проба EPUB")
        XCTAssertEqual(book.author, "Автор Пробный")
        XCTAssertEqual(book.chapters.map(\.title), ["Первая по чтению", "Вторая по файлу"],
                       "порядок ЧТЕНИЯ из spine, а не порядок файлов в архиве")
    }

    /// Счётчик обязан называть ту страницу, которая перед глазами, а не следующую: по
    /// середине окна номер перескакивал на единицу раньше времени.
    func testTheCurrentPageIsTheOneMostlyOnScreen() throws {
        let path = NSHomeDirectory() + "/Downloads/Nimcovich_Moya-sistema.573625.djvu"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "нет книги djvu")
        let reader = try FCXLDjVuReader(path: path)
        let pages = DjVuPagesView(reader: reader)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.documentView = pages
        pages.layoutSubtreeIfNeeded()

        // Встаём ровно на страницу 5 (индекс 4) и проверяем, что её же и называют.
        pages.scrollToPage(4)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(pages.currentPageIndex, 4,
                       "перешли на пятую — счётчик обязан сказать пятую, а не шестую")

        pages.scrollToPage(0)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(pages.currentPageIndex, 0, "в начале книги — первая страница")
    }

    // MARK: - Тяжёлые PDF

    /// Тяжесть документа обязана измеряться, а не угадываться по размеру файла: 3-мегабайтный
    /// вектор с прозрачностью рисуется в десять раз дольше 50-мегабайтного скана.
    func testHeavinessIsMeasuredNotGuessed() throws {
        let heavy = "/Users/dimas/Documents/AC PRO Exam Objectives Illustrator 0923 (1).pdf"
        let plain = NSHomeDirectory() + "/Downloads/Булычев Кир - Любимец - 1993.pdf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: heavy)
                          && FileManager.default.fileExists(atPath: plain),
                          "нужных pdf на этой машине нет")

        let heavyDoc = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: heavy)))
        let plainDoc = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: plain)))
        let heavySeconds = PDFWeight.secondsPerPage(heavyDoc)
        let plainSeconds = PDFWeight.secondsPerPage(plainDoc)
        print(String(format: "ТЯЖЕСТЬ: сложный %.0f мс (%.1f МБ), обычный %.0f мс",
                     heavySeconds * 1000,
                     Double((try FileManager.default.attributesOfItem(atPath: heavy)[.size]
                             as? Int) ?? 0) / 1_048_576,
                     plainSeconds * 1000))

        XCTAssertTrue(PDFWeight.isSlow(heavyDoc), "сложный вектор опознан как медленный")
        XCTAssertFalse(PDFWeight.isSlow(plainDoc), "обычный документ медленным не считается")
        XCTAssertGreaterThan(heavySeconds, plainSeconds * 3,
                             "разница не случайная, а кратная")
    }

    /// Главное обещание: страницу, которую уже показали, второй раз не строят заново.
    /// Именно из-за этого возврат назад в тяжёлом документе был ожиданием с чистого листа.
    func testAHeavyPageIsBuiltOnceAndThenComesBackInstantly() throws {
        let heavy = "/Users/dimas/Documents/AC PRO Exam Objectives Illustrator 0923 (1).pdf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: heavy), "нет тяжёлого pdf")
        let document = try XCTUnwrap(PDFCachingDocument(url: URL(fileURLWithPath: heavy)))
        let page = try XCTUnwrap(document.page(at: 1))
        XCTAssertTrue(page is PDFCachedPage, "страницы документа умеют запоминаться картинкой")

        let first = drawSeconds(page)
        let second = drawSeconds(page)
        print(String(format: "КЭШ: первый показ %.0f мс, повторный %.0f мс",
                     first * 1000, second * 1000))

        XCTAssertGreaterThan(first, 0.1, "тяжёлая страница и правда строится долго")
        XCTAssertLessThan(second, first / 10, "повторный показ — из картинки, а не сборка заново")
        XCTAssertGreaterThan(document.cache.pageCount, 0, "страница осталась в кэше")
        XCTAssertGreaterThan(document.cache.usedBytes, 0, "и занимает память, а не пустую запись")
    }

    /// Текст остаётся текстом: картинка подменяет ТОЛЬКО рисование. Ради этого и оставлен
    /// один режим вместо двух — «быстро, но без текста» больше не нужен.
    func testThePictureDoesNotTakeTheTextAway() throws {
        let heavy = "/Users/dimas/Documents/AC PRO Exam Objectives Illustrator 0923 (1).pdf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: heavy), "нет тяжёлого pdf")
        let document = try XCTUnwrap(PDFCachingDocument(url: URL(fileURLWithPath: heavy)))
        let page = try XCTUnwrap(document.page(at: 1))
        _ = drawSeconds(page)      // страница уже показана картинкой
        XCTAssertGreaterThan(page.string?.count ?? 0, 100,
                             "текст выделяется и копируется, как и раньше")
        XCTAssertGreaterThan(page.numberOfCharacters, 100, "и знаки на месте")
    }

    /// Кэш обязан отпускать память, но не тот кусок, к которому только что возвращались:
    /// вытесняется давно не показанное, а не далёкое по номеру.
    func testTheCacheForgetsTheLongUnseenFirst() {
        let cache = PDFRasterCache(byteLimit: 3 * pictureBytes)
        for index in 0..<3 { cache.put(entry(), for: index) }
        XCTAssertEqual(cache.pageCount, 3)

        _ = cache.entry(for: 0)              // вернулись на первую — она снова свежая
        cache.put(entry(), for: 3)           // и место кончилось

        XCTAssertNotNil(cache.entry(for: 0), "к ней только что возвращались — она остаётся")
        XCTAssertNil(cache.entry(for: 1), "а забыта самая давняя")
        XCTAssertLessThanOrEqual(cache.usedBytes, 3 * pictureBytes, "лимит соблюдён")
    }

    /// Лёгкому документу кэш не нужен: PDFKit рисует его быстрее, чем это можно заметить,
    /// и память лучше оставить файлам. Обычный PDFDocument остаётся обычным.
    func testAnOrdinaryDocumentIsLeftAlone() throws {
        let plain = NSHomeDirectory() + "/Downloads/Булычев Кир - Любимец - 1993.pdf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: plain), "нет обычного pdf")
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: plain)))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertFalse(page is PDFCachedPage, "лишнего кэша у лёгкого документа нет")
    }

    /// Закрыли просмотрщик — память вернулась. Сотни мегабайт картинок не имеют права
    /// пережить закрытый файл: это ровно тот случай, когда файловый менеджер незаметно
    /// съедает половину машины.
    func testClosingTheDocumentGivesTheMemoryBack() throws {
        let heavy = "/Users/dimas/Documents/AC PRO Exam Objectives Illustrator 0923 (1).pdf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: heavy), "нет тяжёлого pdf")

        let before = footprintMB()
        weak var closed: PDFCachingDocument?
        var cached = 0

        try autoreleasepool {
            let document = try XCTUnwrap(PDFCachingDocument(url: URL(fileURLWithPath: heavy)))
            closed = document
            for index in 0..<document.pageCount {
                _ = drawSeconds(try XCTUnwrap(document.page(at: index)), scale: 2.9)
            }
            cached = document.cache.usedBytes
            XCTAssertGreaterThan(cached, 10 << 20, "картинки страниц и правда весят")
            print(String(format: "ПАМЯТЬ: до %.0f МБ, с открытым документом %.0f МБ (кэш %.0f МБ)",
                         before, footprintMB(), Double(cached) / 1_048_576))
            // Закрытие просмотрщика: кэш отпускается сразу, не дожидаясь смерти документа.
            document.cache.purge()
            XCTAssertEqual(document.cache.pageCount, 0, "кэш пуст")
            XCTAssertEqual(document.cache.usedBytes, 0, "и памяти за ним не числится")
        }

        XCTAssertNil(closed, "документ отпущен целиком, ничего его не держит")

        let after = footprintMB()
        print(String(format: "ПАМЯТЬ: после закрытия %.0f МБ", after))
        XCTAssertLessThan(after - before, Double(cached) / 1_048_576 / 2,
                          "вернулась хотя бы половина того, что заняли картинки")
    }

    /// Открыть и закрыть один и тот же тяжёлый документ несколько раз: память не должна
    /// расти от просмотра к просмотру. Один возвращённый мегабайт ничего не значит, если
    /// каждый следующий файл добавляет к программе ещё сотню.
    func testWatchingTheSameFileAgainAndAgainDoesNotPileUp() throws {
        let heavy = "/Users/dimas/Documents/AC PRO Exam Objectives Illustrator 0923 (1).pdf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: heavy), "нет тяжёлого pdf")

        var afterEachRound: [Double] = []
        for _ in 0..<4 {
            try autoreleasepool {
                let document = try XCTUnwrap(PDFCachingDocument(url: URL(fileURLWithPath: heavy)))
                for index in 0..<document.pageCount {
                    _ = drawSeconds(try XCTUnwrap(document.page(at: index)), scale: 2.9)
                }
                document.cache.purge()
            }
            afterEachRound.append(footprintMB())
        }

        print("ПАМЯТЬ по кругам: "
              + afterEachRound.map { String(format: "%.0f", $0) }.joined(separator: " → ") + " МБ")
        let growth = afterEachRound.last! - afterEachRound.first!
        XCTAssertLessThan(growth, 40, "четыре просмотра подряд не оставляют за собой гору")
    }

    // MARK: - Найдено на ревью

    /// Указали «эта страница первая» — и автоматические имена закладок обязаны поехать
    /// следом. Иначе список говорит «Страница 9», а счётчик на том же месте — «Страница 6».
    func testRenumberingMovesTheAutomaticNamesToo() throws {
        let file = (root as NSString).appendingPathComponent("перенумерация.djvu")
        FileManager.default.createFile(atPath: file, contents: Data("скан".utf8))
        let store = ReaderMarksStore(fileURL: URL(fileURLWithPath: root + "/перенумерация.json"))

        XCTAssertTrue(store.toggleMark(at: ReaderLocation(page: 8), label: "Страница 8",
                                       autoTitle: nil, for: file))
        XCTAssertTrue(store.toggleMark(at: ReaderLocation(page: 20), label: "Страница 20",
                                       autoTitle: nil, for: file))
        let handNamed = try XCTUnwrap(store.marks(for: file).first)
        store.renameMark(id: handNamed.id, to: "Тут про коня", for: file)

        // Сдвиг на четыре листа: обложка, издательский, пустая, титул.
        store.renumberMarks(for: file) { mark in
            BookmarkName.compose(number: PageNumbering.printed(index: mark.location.page,
                                                               start: 4),
                                 title: mark.autoTitle)
        }
        let names = store.marks(for: file).map(\.label)
        XCTAssertEqual(names, ["Тут про коня", "Страница 17"],
                       "автоматическое имя переехало, названное рукой — нет")
    }

    /// Уточнение имени приходит из фона позже самой закладки — и не имеет права затереть
    /// имя, которое человек успел дать сам.
    func testALateAutomaticNameNeverOverwritesAHandGivenOne() throws {
        let file = (root as NSString).appendingPathComponent("позднее-имя.pdf")
        FileManager.default.createFile(atPath: file, contents: Data("документ".utf8))
        let store = ReaderMarksStore(fileURL: URL(fileURLWithPath: root + "/позднее.json"))

        XCTAssertTrue(store.toggleMark(at: ReaderLocation(page: 1), label: "Страница 2",
                                       for: file))
        let mark = try XCTUnwrap(store.marks(for: file).first)
        store.renameMark(id: mark.id, to: "Моё место", for: file)
        store.updateAutoName(id: mark.id, label: "Стр. 2 — Определения",
                             title: "Определения", for: file)
        XCTAssertEqual(store.marks(for: file).first?.label, "Моё место",
                       "слово человека главнее")
    }

    /// «Книга.fb2.zip» — обычный способ хранить FB2, и расширение у неё «zip». Читать её мы
    /// умеем, а вот доходило ли до чтения — зависело от того, по чему определяют формат.
    func testAZippedFB2IsStillABook() {
        XCTAssertEqual(fileCategory(forFileName: "Булычев.fb2.zip"), .book)
        XCTAssertEqual(fileCategory(forFileName: "Булычев.fb2"), .book)
        XCTAssertEqual(fileCategory(forFileName: "книга.fbz"), .book)
        XCTAssertEqual(fileCategory(forFileName: "книга.epub"), .book)
        XCTAssertNotEqual(fileCategory(forFileName: "фотографии.zip"), .book,
                          "обычный архив книгой не становится")
    }

    // MARK: - Одна книга, два потока

    /// Полоса миниатюр и лента страниц читают ОДНУ книгу каждая в своём потоке. Очередь
    /// сообщений djvulibre одна на документ, и раньше они воровали сообщения друг у друга:
    /// открыл вторую книгу — и программа встала намертво, главный поток внутри
    /// ddjvu_message_wait. Если это вернётся, тест не упадёт, а повиснет — и таймаут скажет
    /// то же самое.
    func testTwoReadersOfOneBookDoNotFreeze() throws {
        let djvu = NSHomeDirectory() + "/Downloads/Nimcovich_Moya-sistema.573625.djvu"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: djvu), "нет книги djvu")
        let reader = try FCXLDjVuReader(path: djvu)

        let done = expectation(description: "обе стороны дочитали")
        done.expectedFulfillmentCount = 2
        var pages = 0, thumbs = 0
        let counter = NSLock()

        DispatchQueue.global(qos: .userInitiated).async {      // лента страниц
            for index in 0..<6 where DjVuPagesView.render(reader: reader, index: index,
                                                          scale: 0.35) != nil {
                counter.lock(); pages += 1; counter.unlock()
            }
            done.fulfill()
        }
        DispatchQueue.global(qos: .utility).async {            // полоса миниатюр
            for index in 0..<6 {
                _ = reader.pageSize(at: index)
                if DjVuPagesView.render(reader: reader, index: index, scale: 0.1) != nil {
                    counter.lock(); thumbs += 1; counter.unlock()
                }
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 90)
        XCTAssertEqual(pages, 6, "страницы отрисованы все")
        XCTAssertEqual(thumbs, 6, "и миниатюры тоже")
    }

    // MARK: - Нумерация страниц в сканах

    /// Обложка — не страница. В файле она первый лист, а в книге номера не имеет: счёт
    /// начинается со следующего листа, и «стр. 9 из 282» перестаёт расходиться с тем, что
    /// напечатано на самой странице.
    func testTheCoverIsNotPageOne() {
        XCTAssertNil(PageNumbering.printed(index: 0, start: 1), "обложка номера не имеет")
        XCTAssertEqual(PageNumbering.printed(index: 1, start: 1), 1, "первая — следующая за ней")
        XCTAssertEqual(PageNumbering.printed(index: 8, start: 1), 8, "и дальше со сдвигом")
        XCTAssertEqual(PageNumbering.numberedCount(total: 282, start: 1), 281,
                       "в счёт книги обложка тоже не идёт")

        // Скан, у которого перед нумерацией лежат обложка, издательский лист, пустая
        // страница и титул — как в «Моей системе».
        XCTAssertNil(PageNumbering.printed(index: 3, start: 4), "титул — всё ещё не страница")
        XCTAssertEqual(PageNumbering.printed(index: 4, start: 4), 1, "первая напечатанная")
    }

    /// Пока про файл не решали: у DjVu первый лист — обложка, у остальных счёт как в файле.
    func testDjVuStartsAfterTheCoverByDefault() {
        XCTAssertEqual(PageNumbering.defaultStart(forFile: "/книга.djvu"), 1)
        XCTAssertEqual(PageNumbering.defaultStart(forFile: "/книга.djv"), 1)
        XCTAssertEqual(PageNumbering.defaultStart(forFile: "/документ.pdf"), 0)
    }

    /// Указание «эта страница — первая» живёт вместе с закладками файла.
    func testWhereTheNumberingStartsIsRemembered() {
        let file = (root as NSString).appendingPathComponent("нумерация.djvu")
        FileManager.default.createFile(atPath: file, contents: Data("скан".utf8))
        let store = ReaderMarksStore(fileURL: URL(fileURLWithPath: root + "/нумерация.json"))
        XCTAssertNil(store.numberingStart(for: file), "про этот файл ещё не решали")

        store.setNumberingStart(4, for: file)
        store.flush()
        XCTAssertEqual(store.numberingStart(for: file), 4, "решение записано, а не забыто")

        store.setNumberingStart(0, for: file)
        XCTAssertEqual(store.numberingStart(for: file), 0, "и его можно вернуть как в файле")
    }

    /// Счётчик и закладка обязаны называть одно место одним номером.
    func testTheCounterAndTheBookmarkAgree() {
        let start = 1
        let index = 8
        let printed = PageNumbering.printed(index: index, start: start)
        XCTAssertEqual(printed, 8)
        XCTAssertEqual(BookmarkName.compose(number: printed, title: nil), "Страница 8")
        XCTAssertEqual(BookmarkName.compose(number: nil, title: nil), "Обложка",
                       "на обложке закладка так и называется")
    }

    // MARK: - Имена закладок

    /// «Страница 9» через неделю не говорит ничего. Имя берётся с самой страницы, а
    /// нумерация пунктов впереди только съедает место.
    func testABookmarkNamesItselfFromThePage() {
        XCTAssertEqual(BookmarkName.pick(from: "1.1 Identify the purpose of the work"),
                       "Identify the purpose of the work",
                       "нумерация пункта отброшена, название осталось")
        XCTAssertEqual(BookmarkName.pick(from: "  \n42\n\nГлава вторая. Центр\n"),
                       "Глава вторая. Центр",
                       "колонцифра пропущена, заголовок найден")
        XCTAssertNil(BookmarkName.pick(from: "7\n. . .\n12"), "из одних цифр имени не выйдет")
    }

    /// Длинное название режется по слову: обрывок посреди слова читается хуже.
    func testALongNameIsCutAtAWord() {
        let long = "Центр и фланги в позиционной борьбе против изолированной пешки"
        let short = BookmarkName.shorten(long, limit: 30)
        XCTAssertLessThanOrEqual(short.count, 31, "уместилось")
        XCTAssertTrue(short.hasSuffix("…"), "видно, что продолжение есть")
        XCTAssertFalse(short.dropLast().hasSuffix(" "), "хвостовой пробел не остаётся")
        XCTAssertTrue(long.hasPrefix(String(short.dropLast())), "резали, а не пересказывали")
        XCTAssertEqual(BookmarkName.shorten("Голые люди", limit: 30), "Голые люди",
                       "короткое имя не трогается")
    }

    /// На настоящем PDF пользователя: имя приходит из текстового слоя страницы.
    func testTheNameComesFromARealPDFPage() throws {
        let heavy = "/Users/dimas/Documents/AC PRO Exam Objectives Illustrator 0923 (1).pdf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: heavy), "нет тяжёлого pdf")
        let title = try XCTUnwrap(BookmarkName.title(ofFile: heavy, page: 1),
                                  "у страницы есть текст — значит есть и название")
        let name = BookmarkName.compose(number: 2, title: title)
        print("ИМЯ ЗАКЛАДКИ (pdf): \(name)")
        XCTAssertTrue(name.contains("2"), "номер страницы в имени остаётся")
        XCTAssertGreaterThan(name.count, 12, "не одно «Страница 2»")
    }

    /// Скан имени НЕ получает — и это решение, а не недоделка. У двухколоночной книги
    /// распознавание сшивает колонки, и любая «первая строка» оказывается серединой чужой
    /// фразы: «Крез Кре6 13. Kpi4» — настоящий улов с настоящей страницы. Честное
    /// «Страница 9» лучше уверенного вранья.
    func testAScannedPageIsNotGivenAMadeUpName() throws {
        let djvu = NSHomeDirectory() + "/Downloads/Nimcovich_Moya-sistema.573625.djvu"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: djvu), "нет книги djvu")
        XCTAssertNil(BookmarkName.title(ofFile: djvu, page: 8),
                     "имя со скана не выдумывается")
        XCTAssertEqual(BookmarkName.compose(number: 9, title: nil), "Страница 9",
                       "остаётся честный номер, а назвать место можно самому")
    }

    /// Строки, которые распознавание принесло с настоящих страниц скана: ни одна из них не
    /// имеет права стать именем.
    func testTheMiddleOfASentenceIsNeverAName() {
        for line in ["териальный урон. Вы увидите му». Но этот пример в его твор-",
                     "честве, к сожалению, не един-",
                     "11",
                     "завлечь"] {
            XCTAssertNil(BookmarkName.pick(from: line), "«\(line)» — не название")
        }
    }

    /// Своё имя дороже угаданного и переживает всё остальное.
    func testAHandGivenNameStays() throws {
        let file = (root as NSString).appendingPathComponent("имена-закладок.djvu")
        FileManager.default.createFile(atPath: file, contents: Data("книга".utf8))
        // Своё хранилище, не общее: тесты не имеют права писать в настоящие закладки
        // пользователя — и в работающей программе они друг другу мешают.
        let store = ReaderMarksStore(fileURL: URL(fileURLWithPath: root + "/имена.json"))

        XCTAssertTrue(store.toggleMark(at: ReaderLocation(page: 8),
                                       label: "Страница 9", for: file))
        let mark = try XCTUnwrap(store.marks(for: file).first)
        store.renameMark(id: mark.id, to: "Тут про коня", for: file)
        XCTAssertEqual(store.marks(for: file).first?.label, "Тут про коня")

        store.flush()
        XCTAssertEqual(store.marks(for: file).first?.label, "Тут про коня",
                       "имя записано, а не только показано")
    }

    // MARK: Подручное для тестов кэша

    /// Память процесса — та самая, что видна в «Мониторинге системы».
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }


    private var pictureBytes: Int { 64 * 64 * 4 }

    private func entry() -> PDFRasterCache.Entry {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return PDFRasterCache.Entry(image: context.makeImage()!, scale: 1)
    }

    /// Нарисовать страницу так, как её рисует экран, и засечь время.
    private func drawSeconds(_ page: PDFPage, scale: CGFloat = 2) -> TimeInterval {
        let rect = page.bounds(for: .mediaBox)
        let context = CGContext(data: nil,
                                width: Int(rect.width * scale), height: Int(rect.height * scale),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        let started = Date()
        page.draw(with: .mediaBox, to: context)
        return Date().timeIntervalSince(started)
    }

    // MARK: - На настоящих книгах пользователя

    /// Настоящий EPUB пользователя: главы, названные в оглавлении цифрами, обязаны
    /// показаться человеческими заголовками со своих страниц.
    func testTheRealEPUBGetsReadableChapterNames() throws {
        let epub = NSHomeDirectory() + "/Downloads/iskusenie.epub"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: epub), "нет epub на машине")
        let out = URL(fileURLWithPath: root + "/настоящий-epub")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try CoreBridgeService().extractArchiveAll(
            archivePath: epub, destinationPath: out.path,
            overwriteExisting: true, progress: { _, _, _, _, _, _ in })
        let book = try EPUBParser.build(unpacked: out, sourcePath: epub)

        let numeric = book.chapters.filter { $0.title.allSatisfy(\.isNumber) && !$0.title.isEmpty }
        print("EPUB: «\(book.title)» — \(book.author); глав: \(book.chapters.count)")
        print("первые названия: \(book.chapters.prefix(6).map(\.title))")
        XCTAssertTrue(numeric.count < book.chapters.count / 2,
                      "большинство глав получили человеческие названия, а не номера")
    }

    func testARealBookOnThisMachine() throws {
        let candidates = [
            NSHomeDirectory() + "/Downloads/kir-bulihev_-sobranie-sohineniy-v-18-tomah_-t_3.fb2",
            NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads/Soznanie-i-Lichnost.fb2",
        ]
        guard let real = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        else { throw XCTSkip("настоящих книг на этой машине не нашлось") }

        let out = URL(fileURLWithPath: root + "/настоящая")
        let started = Date()
        let book = try FB2Parser.build(from: real, sourcePath: real, into: out)
        let seconds = Date().timeIntervalSince(started)

        XCTAssertFalse(book.chapters.isEmpty, "главы нашлись")
        XCTAssertFalse(book.title.isEmpty, "название прочитано")
        XCTAssertLessThan(seconds, 20, "разбор укладывается в разумное время")

        let firstHTML = try String(contentsOf: book.chapters[0].file, encoding: .utf8)
        XCTAssertFalse(firstHTML.isEmpty)
        XCTAssertTrue(firstHTML.contains("<body>"))
        print("КНИГА: «\(book.title)» — \(book.author); глав: \(book.chapters.count); "
              + String(format: "разбор %.1f с", seconds))
    }
}
