import XCTest
@testable import TotumComXLApp

/// Поиск по тексту в просмотре (F3): само вхождение, счётчик, модель полосы и поиск в тексте
/// просмотра — простом и большом, который показывается порциями. Раньше в просмотре поиска
/// не было вовсе: ⌘F открывал поиск файлов.
@MainActor
final class ViewerFindTests: XCTestCase {

    private func query(_ text: String, matchCase: Bool = false, wholeWord: Bool = false) -> ViewerFindQuery {
        ViewerFindQuery(text: text, matchCase: matchCase, wholeWord: wholeWord)
    }

    private func found(_ text: String, in haystack: String, matchCase: Bool = false,
                       wholeWord: Bool = false) -> [String] {
        let source = haystack as NSString
        return ViewerTextSearch.ranges(of: query(text, matchCase: matchCase, wholeWord: wholeWord), in: source)
            .map { "\($0.location):\(source.substring(with: $0))" }
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.02) }
    }

    // MARK: - Вхождения

    func test_безРегистра_поУмолчанию_иКириллица() {
        XCTAssertEqual(found("привод", in: "Привод и ПРИВОД, полный привод"), ["0:Привод", "9:ПРИВОД", "24:привод"])
        XCTAssertEqual(found("привод", in: "Привод и ПРИВОД, полный привод", matchCase: true), ["24:привод"])
    }

    func test_совпаденияНеНакладываются() {
        XCTAssertEqual(found("аа", in: "ааааа"), ["0:аа", "2:аа"])
        XCTAssertEqual(found("", in: "текст"), [], "пустой запрос ничего не находит")
        XCTAssertEqual(found("нет", in: ""), [])
    }

    func test_словоЦеликом() {
        let text = "код, кодекс, штрих-код, код_1, 4код, КОД."
        XCTAssertEqual(found("код", in: text, wholeWord: true), ["0:код", "19:код", "37:КОД"],
                       "буква, цифра и подчёркивание по краю — это часть другого слова")
        XCTAssertEqual(found("код", in: text).count, 6)
    }

    func test_пределИГраница() {
        let text = String(repeating: "ab ", count: 100) as NSString
        XCTAssertEqual(ViewerTextSearch.ranges(of: query("ab"), in: text, limit: 7).count, 7)
        XCTAssertEqual(ViewerTextSearch.ranges(of: query("ab"), in: text, upTo: 9).count, 3,
                       "дальше границы не ищем — там ссылка «Показать дальше»")
    }

    func test_поискНачинаетсяОтВидимогоМеста() {
        let ranges = [NSRange(location: 5, length: 3), NSRange(location: 40, length: 3), NSRange(location: 90, length: 3)]
        XCTAssertEqual(ViewerTextSearch.firstIndex(in: ranges, atOrAfter: 0), 0)
        XCTAssertEqual(ViewerTextSearch.firstIndex(in: ranges, atOrAfter: 41), 1, "совпадение ещё видно краем")
        XCTAssertEqual(ViewerTextSearch.firstIndex(in: ranges, atOrAfter: 50), 2)
        XCTAssertEqual(ViewerTextSearch.firstIndex(in: ranges, atOrAfter: 500), 0, "ниже ничего нет — с начала")
    }

    // MARK: - Байты

    func test_запросБайтами() {
        XCTAssertEqual(ViewerTextSearch.hexBytes("FF D8 ff"), [0xFF, 0xD8, 0xFF])
        XCTAssertEqual(ViewerTextSearch.hexBytes("0xFF,0xD8"), [0xFF, 0xD8])
        XCTAssertEqual(ViewerTextSearch.hexBytes("ffd8"), [0xFF, 0xD8])
        XCTAssertNil(ViewerTextSearch.hexBytes("привет"))
        XCTAssertNil(ViewerTextSearch.hexBytes("F"), "полбайта — не байты")
        XCTAssertNil(ViewerTextSearch.hexBytes("FFD"), "нечётное число знаков — не байты")
        XCTAssertNil(ViewerTextSearch.hexBytes("JPEG"))
    }

    func test_поискВБайтах() {
        var data = Data([0x00, 0xFF, 0xD8, 0xFF, 0x10])
        data.append(Data("JFIF jfif".utf8))
        data.append("Привет".data(using: .windowsCP1251)!)
        data.append("мир".data(using: .utf16LittleEndian)!)

        XCTAssertEqual(ViewerTextSearch.byteMatches(of: query("FF D8 FF"), in: data), [1..<4])
        XCTAssertEqual(ViewerTextSearch.byteMatches(of: query("jfif"), in: data), [5..<9, 10..<14],
                       "латиница — без учёта регистра")
        XCTAssertEqual(ViewerTextSearch.byteMatches(of: query("jfif", matchCase: true), in: data), [10..<14])
        XCTAssertEqual(ViewerTextSearch.byteMatches(of: query("Привет"), in: data), [14..<20],
                       "текст в Windows-1251")
        XCTAssertEqual(ViewerTextSearch.byteMatches(of: query("мир"), in: data), [20..<26], "текст в UTF-16")
        XCTAssertEqual(ViewerTextSearch.byteMatches(of: query("нет такого"), in: data), [])
        // «face» — и слово, и байты FA CE: ищется и так и так, байты — строго как записаны.
        let both = Data([0xFA, 0xCE, 0x20]) + Data("Face".utf8) + Data([0xFA, 0xEE])
        XCTAssertEqual(ViewerTextSearch.byteMatches(of: query("face"), in: both), [0..<2, 3..<7])
    }

    func test_строкиHex_знаютСвоиБайты() {
        let engine = HexFindEngine(bytesPerLine: 16)
        engine.data = Data((0..<40).map { UInt8($0) })
        var answer: ViewerFindResult?
        engine.search(query("0E 0F 10 11")) { answer = $0 }
        wait { answer != nil }
        XCTAssertEqual(answer, ViewerFindResult(count: 1, position: 1))
        XCTAssertEqual(engine.marks(forLine: 0)?.found, [14, 15], "хвост первой строки")
        XCTAssertEqual(engine.marks(forLine: 1)?.found, [0, 1], "и начало второй")
        XCTAssertEqual(engine.marks(forLine: 1)?.current, [0, 1])
        XCTAssertNil(engine.marks(forLine: 2))
        XCTAssertEqual(engine.scrollTarget?.line, 0, "прокрутка — к строке, где совпадение начинается")

        engine.clear()
        XCTAssertNil(engine.marks(forLine: 0))
    }

    // MARK: - Счётчик

    func test_счётчик() {
        func text(_ result: ViewerFindResult, query: String = "код", searching: Bool = false) -> String {
            ViewerFindModel.counterText(result: result, query: query, isSearching: searching)
        }
        XCTAssertEqual(text(ViewerFindResult(), query: ""), "", "пока не ищем — пусто")
        XCTAssertEqual(text(ViewerFindResult(count: 8, position: 3)), String(format: L("viewer.find.counter"), 3, "8"))
        XCTAssertEqual(text(ViewerFindResult(count: 8, position: 0)), String(format: L("viewer.find.total"), "8"))
        XCTAssertEqual(text(ViewerFindResult(count: 8, position: 8, more: true)),
                       String(format: L("viewer.find.counter"), 8, "8+"), "дальше в файле может быть ещё")
        XCTAssertEqual(text(ViewerFindResult()), L("editor.find.none"))
        XCTAssertEqual(text(ViewerFindResult(more: true)), L("viewer.find.noneHere"))
        XCTAssertEqual(text(ViewerFindResult(), searching: true), L("viewer.find.searching"))
        XCTAssertEqual(text(ViewerFindResult(note: "нет текста")), "нет текста")
    }

    // MARK: - Модель полосы

    /// Движок-заглушка: помнит, что у него спросили.
    private final class FakeEngine: ViewerFindEngine {
        var searched: [ViewerFindQuery] = []
        var steps: [Int] = []
        var cleared = 0
        var count = 3
        private var position = 0
        /// Отвечать на шаг не сразу, как страница: ответы копятся здесь, пока их не отпустят.
        var holdsSteps = false
        var heldSteps: [() -> Void] = []
        func search(_ query: ViewerFindQuery, completion: @escaping (ViewerFindResult) -> Void) {
            searched.append(query)
            position = count > 0 ? 1 : 0
            completion(ViewerFindResult(count: count, position: position))
        }
        func step(_ direction: Int, completion: @escaping (ViewerFindResult) -> Void) {
            steps.append(direction)
            let answer = { [self] in
                position = (position - 1 + direction + count) % count + 1
                completion(ViewerFindResult(count: count, position: position))
            }
            if holdsSteps { heldSteps.append(answer) } else { answer() }
        }
        func clear() { cleared += 1 }
    }

    private func model(_ engine: FakeEngine?) -> ViewerFindModel {
        let model = ViewerFindModel()
        model.typingDelay = 0
        model.resolveEngine = { engine }
        return model
    }

    func test_модель_ищетПоМереВвода_иХодитПоНайденному() {
        let engine = FakeEngine()
        let model = model(engine)
        model.query = "рано"
        XCTAssertTrue(engine.searched.isEmpty, "полоса закрыта — не ищем")

        model.open()
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(engine.searched.map(\.text), ["рано"], "открыли с готовым запросом — он и ищется")
        model.query = "код"
        model.wholeWord = true
        XCTAssertEqual(engine.searched.last, ViewerFindQuery(text: "код", matchCase: false, wholeWord: true))
        XCTAssertEqual(model.result, ViewerFindResult(count: 3, position: 1))
        XCTAssertTrue(model.canStep)

        model.next()
        model.next()
        model.next()
        model.previous()
        XCTAssertEqual(engine.steps, [1, 1, 1, -1])
        XCTAssertEqual(model.result.position, 3, "за последним — снова первое, назад — последнее")
    }

    /// Страница отвечает на шаг не сразу. Два быстрых «Далее» — это два шага подряд, второй
    /// от места, куда привёл первый; а не два шага от одного и того же места.
    func test_модель_быстрыеШаги_идутПоОчереди() {
        let engine = FakeEngine()
        engine.count = 5
        let model = model(engine)
        model.open()
        model.query = "код"
        engine.holdsSteps = true

        model.next()
        model.next()
        model.previous()
        XCTAssertEqual(engine.steps, [1], "второй шаг ждёт ответа на первый")
        engine.heldSteps.removeFirst()()
        XCTAssertEqual(model.result.position, 2)
        XCTAssertEqual(engine.steps, [1, 1])
        engine.heldSteps.removeFirst()()
        XCTAssertEqual(model.result.position, 3)
        engine.heldSteps.removeFirst()()
        XCTAssertEqual(model.result.position, 2)
        XCTAssertEqual(engine.steps, [1, 1, -1])

        // Новый запрос отменяет шаги, что ещё ждали очереди.
        model.next()
        model.next()
        model.query = "другой"
        engine.heldSteps.removeAll()
        XCTAssertEqual(engine.steps.count, 4, "шаг из очереди прежнего запроса не выполняется")
    }

    func test_модель_закрытиеУбираетПодсветкуИВозвращаетКлавиатуру() {
        let engine = FakeEngine()
        let model = model(engine)
        var returned = 0
        model.onClose = { returned += 1 }
        model.open()
        model.query = "код"
        model.close()
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(engine.cleared, 1)
        XCTAssertEqual(model.result, ViewerFindResult())
        XCTAssertEqual(returned, 1)
        model.close()
        XCTAssertEqual(returned, 1, "уже закрыта — второй раз ничего")
    }

    func test_модель_пустойЗапросСнимаетПодсветку() {
        let engine = FakeEngine()
        let model = model(engine)
        model.open()
        model.query = "код"
        model.query = ""
        XCTAssertEqual(engine.cleared, 1)
        XCTAssertEqual(model.result, ViewerFindResult())
        XCTAssertFalse(model.canStep)
    }

    /// Курсор панели ушёл на другой файл при открытой полосе: тот же запрос ищется в новом
    /// файле, как только он загрузился.
    func test_модель_другойФайл_тотЖеЗапросИщетсяВНём() {
        let first = FakeEngine()
        let second = FakeEngine()
        second.count = 7
        var onScreen: FakeEngine? = first
        let model = ViewerFindModel()
        model.typingDelay = 0
        model.resolveEngine = { onScreen }
        model.open()
        model.query = "код"
        XCTAssertEqual(model.result.count, 3)

        onScreen = nil                      // новый файл ещё грузится
        model.contentChanged()
        XCTAssertEqual(first.cleared, 1, "прежний файл отпущен")
        XCTAssertEqual(model.result, ViewerFindResult())
        spin(0.3)
        XCTAssertTrue(second.searched.isEmpty)
        onScreen = second                   // загрузился
        wait { !second.searched.isEmpty }
        XCTAssertEqual(second.searched.map(\.text), ["код"])
        XCTAssertEqual(model.result.count, 7)
    }

    /// У картинки текста нет и не будет — полоса говорит об этом сразу.
    func test_модель_искатьНеВЧем() {
        let model = model(nil)
        model.canSearch = { false }
        model.open()
        model.query = "код"
        XCTAssertEqual(model.result.note, L("viewer.find.nothingToSearch"))
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.canStep)
    }

    /// Поиск открыли, пока файл ещё читается с диска: полоса не отвечает «не найдено» раньше
    /// времени, а ждёт текст и ищет, как только он на месте.
    func test_модель_содержимоеЕщёГрузится_поискЖдётЕго() {
        let engine = FakeEngine()
        var loaded: FakeEngine?
        let model = ViewerFindModel()
        model.typingDelay = 0
        model.resolveEngine = { loaded }
        model.canSearch = { true }
        model.open()
        model.query = "код"
        XCTAssertTrue(model.isSearching, "ищем, а не «не найдено»")
        XCTAssertNil(model.result.note)
        XCTAssertEqual(model.counterText, L("viewer.find.searching"))

        loaded = engine
        wait { !engine.searched.isEmpty }
        XCTAssertEqual(engine.searched.map(\.text), ["код"])
        XCTAssertEqual(model.result.count, 3)
        XCTAssertFalse(model.isSearching)
    }

    // MARK: - Команда «Поиск»

    /// Команда «Поиск» (⌘F) при открытом просмотре с текстом открывает поиск в нём; нет
    /// такого просмотра — команда остаётся поиском файлов.
    func test_командаПоиск_открываетПоискВПросмотре() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.close() }

        let picture = model(nil)
        picture.canSearch = { false }
        picture.window = { window }
        XCTAssertFalse(ViewerFindModel.openInViewer(), "на экране картинка — искать не в чем, команда ищет файлы")
        XCTAssertFalse(picture.isVisible)

        let text = model(FakeEngine())
        text.canSearch = { true }
        text.window = { window }
        XCTAssertTrue(ViewerFindModel.openInViewer())
        XCTAssertTrue(text.isVisible)
        let focus = text.focusToken
        XCTAssertTrue(ViewerFindModel.openInViewer(), "повторное нажатие возвращает клавиатуру в поле")
        XCTAssertEqual(text.focusToken, focus + 1)

        // Просмотр закрыт (его окна нет на экране) — команда снова ищет файлы.
        text.close()
        text.window = { nil }
        XCTAssertFalse(ViewerFindModel.openInViewer())
    }

    // MARK: - Текст просмотра

    private func textView(_ text: String) -> (window: NSWindow, view: NSTextView) {
        let scroll = NumberedTextView.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let view = scroll.documentView as! NumberedTextView
        view.show(text)
        scroll.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func background(_ view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index,
                                               effectiveRange: nil) as? NSColor
    }

    func test_текст_всёПодсвечено_текущееЯрче_шагПоКругу() {
        let lines = (1...200).map { $0 % 50 == 0 ? "строка \($0): здесь привод" : "строка \($0)" }
        let (window, view) = textView(lines.joined(separator: "\n"))
        defer { window.close() }
        let engine = TextViewFindEngine(textView: view)
        var answer = ViewerFindResult()
        engine.search(query("привод")) { answer = $0 }
        XCTAssertEqual(answer, ViewerFindResult(count: 4, position: 1))

        let text = view.string as NSString
        let all = ViewerTextSearch.ranges(of: query("привод"), in: text)
        XCTAssertEqual(background(view, at: all[0].location), TextViewFindEngine.currentColor)
        XCTAssertEqual(background(view, at: all[1].location), TextViewFindEngine.matchColor)
        XCTAssertNil(background(view, at: 0), "остальной текст без подложки")

        engine.step(1) { answer = $0 }
        XCTAssertEqual(answer.position, 2)
        XCTAssertEqual(background(view, at: all[0].location), TextViewFindEngine.matchColor, "прежнее — как все")
        XCTAssertEqual(background(view, at: all[1].location), TextViewFindEngine.currentColor)
        XCTAssertTrue(NSLocationInRange(all[1].location, visibleCharacters(view)), "к текущему прокручено")

        engine.step(-1) { answer = $0 }
        engine.step(-1) { answer = $0 }
        XCTAssertEqual(answer.position, 4, "назад от первого — последнее")
        engine.step(1) { answer = $0 }
        XCTAssertEqual(answer.position, 1, "вперёд от последнего — первое")

        engine.clear()
        XCTAssertNil(background(view, at: all[0].location), "подсветка снята")
    }

    private func visibleCharacters(_ view: NSTextView) -> NSRange {
        guard let layout = view.layoutManager, let container = view.textContainer else { return NSRange() }
        let origin = view.textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRect: view.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y),
                                       in: container)
        return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// Поиск идёт от того, что на экране: прокрутили вниз — текущим становится ближайшее ниже.
    func test_текст_поискОтВидимогоМеста() {
        let lines = (1...400).map { $0 % 100 == 0 ? "строка \($0): привод" : "строка \($0)" }
        let (window, view) = textView(lines.joined(separator: "\n"))
        defer { window.close() }
        let text = view.string as NSString
        let all = ViewerTextSearch.ranges(of: query("привод"), in: text)
        view.scrollRangeToVisible(NSRange(location: all[1].location + 200, length: 1))
        view.enclosingScrollView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(visibleCharacters(view).location, all[1].location, "второе совпадение уже выше экрана")

        let engine = TextViewFindEngine(textView: view)
        var answer = ViewerFindResult()
        engine.search(query("привод")) { answer = $0 }
        XCTAssertEqual(answer, ViewerFindResult(count: 4, position: 3))
    }

    /// Большой файл показан порциями. Шаг за последнее совпадение показанного дописывает
    /// следующую порцию и находит в ней — так поиск идёт по всему файлу, а не по началу.
    func test_большойФайл_поискИдётДальшеПоказанного() {
        let text = (1...3000).map { $0 == 10 || $0 == 2900 ? "строка \($0): привод" : "строка \($0)" }
            .joined(separator: "\n")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
        let view = scroll.documentView as! NSTextView
        let feeder = ChunkedTextFeeder()
        feeder.textView = view
        feeder.totalLimit = 12_000
        let source = text as NSString
        feeder.show(LongLineClip.chunk(of: source, from: 0, totalLimit: 12_000), of: source)
        XCTAssertLessThan(feeder.shownEnd, source.length, "показана только часть")

        let engine = TextViewFindEngine(textView: view, feeder: feeder)
        var answer = ViewerFindResult()
        engine.search(query("привод")) { answer = $0 }
        XCTAssertEqual(answer, ViewerFindResult(count: 1, position: 1, more: true))
        XCTAssertEqual(ViewerTextSearch.ranges(of: query("дальше"), in: view.string as NSString).count, 1,
                       "ссылка «Показать дальше» в тексте есть…")
        engine.search(query("Показать дальше")) { answer = $0 }
        XCTAssertEqual(answer.count, 0, "…но в ней не ищем: это не текст файла")

        engine.search(query("привод")) { answer = $0 }
        // Шагаем, пока не найдётся второе: каждая порция дописывается в фоне.
        var steps = 0
        while answer.count < 2, steps < 12 {
            var stepped = false
            engine.step(1) { answer = $0; stepped = true }
            wait { stepped }
            steps += 1
        }
        XCTAssertEqual(answer.count, 2, "второе совпадение лежало за показанной частью")
        XCTAssertEqual(answer.position, 2)
        XCTAssertGreaterThan(steps, 1, "до него несколько порций")
        // Файл кончился — дальше по кругу.
        var done = false
        while answer.more, steps < 40 {
            done = false
            engine.step(1) { answer = $0; done = true }
            wait { done }
            steps += 1
        }
        XCTAssertFalse(answer.more, "файл показан целиком")
        let before = answer.position
        engine.step(1) { answer = $0 }
        XCTAssertEqual(answer.position, before % 2 + 1, "дальше — по кругу")
        XCTAssertEqual(answer.count, 2)
    }
}
