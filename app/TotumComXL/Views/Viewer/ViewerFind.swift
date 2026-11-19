import AppKit
import FCXLDjVuUI
import PDFKit
import SwiftUI

/// Что искать в просмотре.
struct ViewerFindQuery: Equatable, Sendable {
    var text = ""
    var matchCase = false
    var wholeWord = false

    var isEmpty: Bool { text.isEmpty }
}

/// Что нашлось: сколько всего и которое совпадение сейчас показано (с единицы; 0 — никакое).
struct ViewerFindResult: Equatable {
    var count = 0
    var position = 0
    /// Показано не всё, что есть в файле: текст подаётся порциями, книга — главами. Шаг за
    /// последнее совпадение ищет дальше, а не возвращает к первому.
    var more = false
    /// Искать здесь нечем — например, у скана нет текста. Причина словами.
    var note: String?
}

/// Поиск вхождений в тексте — один на все движки просмотра, чтобы «слово целиком» и регистр
/// значили одно и то же в тексте, PDF, книге и DjVu.
enum ViewerTextSearch {
    /// Больше этого не ищем и не подсвечиваем: тысячи рамок на странице уже ничего не говорят,
    /// а раскладка под ними тормозит.
    static let matchLimit = 5_000

    /// Все вхождения запроса в `text` до позиции `end`, по порядку, без наложений.
    static func ranges(of query: ViewerFindQuery, in text: NSString, upTo end: Int? = nil,
                       limit: Int = matchLimit) -> [NSRange] {
        let length = min(end ?? text.length, text.length)
        guard !query.isEmpty, length > 0 else { return [] }
        let options: NSString.CompareOptions = query.matchCase ? [] : [.caseInsensitive]
        var found: [NSRange] = []
        var from = 0
        while from < length, found.count < limit {
            let hit = text.range(of: query.text, options: options,
                                 range: NSRange(location: from, length: length - from))
            guard hit.location != NSNotFound, hit.length > 0 else { break }
            if !query.wholeWord || isWholeWord(hit, in: text) { found.append(hit) }
            from = NSMaxRange(hit)
        }
        return found
    }

    /// Стоит ли совпадение отдельным словом: по краям нет ни буквы, ни цифры, ни подчёркивания.
    static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < text.length else { return false }
            let unit = text.character(at: index)
            if unit == 0x5F { return true }                       // «_»
            guard let scalar = Unicode.Scalar(unit) else { return true }   // половина пары — внутри знака
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return !isWordCharacter(at: range.location - 1) && !isWordCharacter(at: NSMaxRange(range))
    }

    /// Номер совпадения, с которого начать показ: первое, что не выше видимого места, — как в
    /// браузере, поиск идёт от того, что на экране, а не с начала файла.
    static func firstIndex(in ranges: [NSRange], atOrAfter location: Int) -> Int {
        ranges.firstIndex { NSMaxRange($0) > location } ?? 0
    }

    // MARK: Байты (режим HEX)

    /// Запрос, записанный байтами: «FF D8 FF», «ffd8ff», «0xFF 0xD8». nil — это не байты.
    static func hexBytes(_ text: String) -> [UInt8]? {
        let cleaned = text.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .filter { !$0.isWhitespace && $0 != "," }
        guard cleaned.count >= 2, cleaned.count % 2 == 0,
              cleaned.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Что искать в байтах файла: сами байты, если запрос записан ими, и текст запроса во всех
    /// кодировках, в которых он обычно лежит в файлах. И то и другое сразу: «face» — это и
    /// слово, и два байта FA CE, а что имел в виду человек, по запросу не узнать.
    /// `foldsCase` — латиницу этого образца можно сравнивать без учёта регистра (байты — нет).
    static func bytePatterns(for query: ViewerFindQuery) -> [(bytes: [UInt8], foldsCase: Bool)] {
        var patterns: [(bytes: [UInt8], foldsCase: Bool)] = []
        if let bytes = hexBytes(query.text) { patterns.append((bytes, false)) }
        for encoding in [String.Encoding.utf8, .windowsCP1251, .utf16LittleEndian, .utf16BigEndian] {
            guard let data = query.text.data(using: encoding, allowLossyConversion: false),
                  !data.isEmpty else { continue }
            let bytes = [UInt8](data)
            if !patterns.contains(where: { $0.bytes == bytes && $0.foldsCase }) {
                patterns.append((bytes, !query.matchCase))
            }
        }
        return patterns
    }

    /// Вхождения в байтах, по порядку, без наложений. Текст без учёта регистра ищется только
    /// для латиницы: у байта нет кодировки, и «та же буква» известна лишь для ASCII.
    static func byteMatches(of query: ViewerFindQuery, in data: Data, limit: Int = matchLimit) -> [Range<Int>] {
        func fold(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte }
        let patterns = bytePatterns(for: query).map { pattern in
            (bytes: pattern.foldsCase ? pattern.bytes.map(fold) : pattern.bytes, foldsCase: pattern.foldsCase)
        }
        guard !patterns.isEmpty, !data.isEmpty else { return [] }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var found: [Range<Int>] = []
            var index = 0
            while index < bytes.count, found.count < limit {
                var matched = 0
                for pattern in patterns where index + pattern.bytes.count <= bytes.count {
                    var same = true
                    for offset in 0..<pattern.bytes.count {
                        let byte = pattern.foldsCase ? fold(bytes[index + offset]) : bytes[index + offset]
                        if byte != pattern.bytes[offset] {
                            same = false
                            break
                        }
                    }
                    if same { matched = max(matched, pattern.bytes.count) }
                }
                if matched > 0 {
                    found.append(index..<(index + matched))
                    index += matched
                } else {
                    index += 1
                }
            }
            return found
        }
    }
}

/// То, что умеет искать в показанном: текст, PDF, страница, книга, DjVu, байты. Движок сам
/// подсвечивает найденное и сам прокручивает к текущему.
@MainActor
protocol ViewerFindEngine: AnyObject {
    /// Найти всё и встать на первое совпадение у видимого места.
    func search(_ query: ViewerFindQuery, completion: @escaping (ViewerFindResult) -> Void)
    /// К следующему (+1) или предыдущему (−1).
    func step(_ direction: Int, completion: @escaping (ViewerFindResult) -> Void)
    /// Убрать подсветку.
    func clear()
}

/// Поиск в просмотре (F3): что искать, сколько нашлось и которое сейчас. Ищет не сама модель,
/// а движок показанного содержимого; модель знает только, как его спросить.
@MainActor
final class ViewerFindModel: ObservableObject {
    @Published private(set) var isVisible = false
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var matchCase = false { didSet { if matchCase != oldValue { scheduleSearch() } } }
    @Published var wholeWord = false { didSet { if wholeWord != oldValue { scheduleSearch() } } }
    @Published private(set) var result = ViewerFindResult()
    @Published private(set) var isSearching = false
    /// Растёт при каждом открытии: поле создаётся заново и снова получает клавиатуру — и
    /// когда поиск вызвали при уже открытой полосе.
    @Published private(set) var focusToken = 0

    /// Движок того, что сейчас на экране; nil — искать не в чем (картинка, видео) или ещё
    /// не загрузилось.
    var resolveEngine: (() -> ViewerFindEngine?)?
    /// Есть ли в показанном что искать вообще: у картинки — нет, и никогда не будет; у текста,
    /// который ещё читается с диска, движка пока нет, но искать будет в чём — его ждём.
    var canSearch: (() -> Bool)?
    /// Полоса закрыта — вернуть клавиатуру панели.
    var onClose: (() -> Void)?
    /// Окно, где стоит просмотр: главное, когда он встроен в панель, или своё плавающее.
    var window: (() -> NSWindow?)?
    /// Пауза перед поиском, пока человек печатает. Для проверок — ноль.
    var typingDelay: TimeInterval = 0.18

    private var engine: ViewerFindEngine?
    private var pending: DispatchWorkItem?
    /// Каждый новый запрос — новое поколение: опоздавший ответ прежнего не показывается.
    private var generation = 0 { didSet { stepInFlight = false; queuedSteps = [] } }
    /// Страница и книга отвечают на шаг не сразу. Второе нажатие «Далее» до ответа ждёт своей
    /// очереди: шаг считается от того места, куда привёл предыдущий, а не от прежнего.
    private var stepInFlight = false
    private var queuedSteps: [Int] = []

    /// Модели открытых просмотров — чтобы проверка могла взять модель настоящего просмотрщика.
    static let live = NSHashTable<ViewerFindModel>.weakObjects()

    init() {
        Self.live.add(self)
    }

    var findQuery: ViewerFindQuery {
        ViewerFindQuery(text: query, matchCase: matchCase, wholeWord: wholeWord)
    }

    var canStep: Bool { !query.isEmpty && (result.count > 0 || result.more) }

    var counterText: String {
        Self.counterText(result: result, query: query, isSearching: isSearching)
    }

    /// «3 из 8», «Найдено: 8», «Не найдено», причина, по которой искать нечем, — и пусто,
    /// пока не ищем. Плюс после числа: показано не всё, дальше в файле может быть ещё.
    static func counterText(result: ViewerFindResult, query: String, isSearching: Bool) -> String {
        guard !query.isEmpty else { return "" }
        if let note = result.note { return note }
        if isSearching, result.count == 0 { return L("viewer.find.searching") }
        guard result.count > 0 else {
            return result.more ? L("viewer.find.noneHere") : L("editor.find.none")
        }
        let total = result.more ? "\(result.count)+" : "\(result.count)"
        guard result.position > 0 else { return String(format: L("viewer.find.total"), total) }
        return String(format: L("viewer.find.counter"), result.position, total)
    }

    /// Открыть полосу (или вернуть клавиатуру в уже открытую).
    func open() {
        // Плавающее окно просмотра клавиатуру само не берёт (она остаётся у панели) — а в
        // поле поиска печатают, значит, окну пора стать ключевым.
        if let window = window?(), !window.isKeyWindow { window.makeKey() }
        isVisible = true
        focusToken &+= 1
        if !query.isEmpty { searchNow() }
    }

    /// Команда «Поиск» (⌘F или то, на что её переназначили): открыт просмотр с текстом —
    /// ищем в нём, а не по файлам. true — просмотр нашёлся и поиск в нём открыт. Сочетание
    /// сопоставляет сама строка меню, поэтому раскладка клавиатуры здесь ни при чём.
    static func openInViewer() -> Bool {
        let candidates = live.allObjects.filter {
            $0.canSearch?() == true && $0.window?()?.isVisible == true
        }
        guard let model = candidates.first(where: { $0.window?()?.isKeyWindow == true })
                ?? candidates.first else { return false }
        model.open()
        return true
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        cancelPending()
        generation &+= 1
        engine?.clear()
        engine = nil
        isSearching = false
        result = ViewerFindResult()
        onClose?()
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ direction: Int) {
        guard isVisible, !query.isEmpty else { return }
        // Запрос ещё не доехал до движка (человек нажал Enter сразу после буквы) — сначала он.
        if pending != nil || engine == nil {
            searchNow()
            return
        }
        guard !stepInFlight else {
            queuedSteps.append(direction)
            return
        }
        runStep(direction)
    }

    private func runStep(_ direction: Int) {
        guard canStep, let engine else {
            queuedSteps = []
            return
        }
        stepInFlight = true
        let started = generation
        engine.step(direction) { [weak self] result in
            guard let self, self.generation == started else { return }
            self.stepInFlight = false
            self.result = result
            if !self.queuedSteps.isEmpty { self.runStep(self.queuedSteps.removeFirst()) }
        }
    }

    /// На экране другое содержимое (другой файл, режим, глава загрузилась): прежний движок
    /// снимает подсветку, и, если полоса открыта, тот же запрос ищется в новом.
    func contentChanged() {
        cancelPending()
        generation &+= 1
        engine?.clear()
        engine = nil
        isSearching = false
        result = ViewerFindResult()
        guard isVisible, !query.isEmpty else { return }
        waitForContent()
    }

    /// Сколько раз спросить о содержимом, которое ещё грузится, и с какой паузой: шесть секунд.
    private static let contentAttempts = 30
    private static let contentPause: TimeInterval = 0.2

    /// Содержимое грузится не сразу — движка ещё нет. Ждём его и ищем, как только появится;
    /// не дождались — говорим, что искать не в чем.
    private func waitForContent(attemptsLeft: Int = contentAttempts) {
        guard canSearch?() ?? true else {
            isSearching = false
            result = ViewerFindResult(note: L("viewer.find.nothingToSearch"))
            return
        }
        isSearching = true
        let started = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == started, self.isVisible else { return }
            self.pending = nil
            if self.resolveEngine?() != nil {
                self.searchNow()
            } else if attemptsLeft > 0 {
                self.waitForContent(attemptsLeft: attemptsLeft - 1)
            } else {
                self.isSearching = false
                self.result = ViewerFindResult(note: L("viewer.find.nothingToSearch"))
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.contentPause, execute: work)
    }

    private func scheduleSearch() {
        guard isVisible else { return }
        cancelPending()
        guard typingDelay > 0 else { searchNow(); return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.searchNow()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + typingDelay, execute: work)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func searchNow() {
        cancelPending()
        generation &+= 1
        let started = generation
        if engine == nil { engine = resolveEngine?() }
        guard let engine else {
            result = ViewerFindResult()
            isSearching = false
            if !query.isEmpty { waitForContent() }
            return
        }
        guard !query.isEmpty else {
            engine.clear()
            isSearching = false
            result = ViewerFindResult()
            return
        }
        isSearching = true
        engine.search(findQuery) { [weak self] result in
            guard let self, self.generation == started else { return }
            self.isSearching = false
            self.result = result
        }
    }
}

// MARK: - Текст (NSTextView)

/// Поиск в тексте, который показывает NSTextView: простой текст с номерами строк, большой
/// файл порциями, оформленный Markdown.
@MainActor
final class TextViewFindEngine: ViewerFindEngine {
    private weak var textView: NSTextView?
    /// Большой файл показывается порциями (ChunkedTextFeeder): шаг за последнее совпадение
    /// дописывает следующую порцию и ищет в ней.
    private weak var feeder: ChunkedTextFeeder?
    private var query = ViewerFindQuery()
    private var ranges: [NSRange] = []
    private var current = -1
    private var highlighted: NSRange?

    static let matchColor = NSColor.systemYellow.withAlphaComponent(0.45)
    static let currentColor = NSColor.systemOrange.withAlphaComponent(0.85)

    init(textView: NSTextView, feeder: ChunkedTextFeeder? = nil) {
        self.textView = textView
        self.feeder = feeder
    }

    private var hasMore: Bool {
        guard let feeder, let source = feeder.source else { return false }
        return feeder.shownEnd < source.length
    }

    /// Докуда искать: ссылка «Показать дальше» в конце — не текст файла.
    private var searchEnd: Int? { feeder?.moreRange?.location }

    func search(_ query: ViewerFindQuery, completion: @escaping (ViewerFindResult) -> Void) {
        self.query = query
        find(startingAt: visibleStart())
        completion(answer())
    }

    func step(_ direction: Int, completion: @escaping (ViewerFindResult) -> Void) {
        guard !ranges.isEmpty || hasMore else { completion(answer()); return }
        let target = current + direction
        if target >= ranges.count, hasMore, let feeder {
            // Дальше в файле ещё есть текст: дописываем порцию и ищем в ней.
            let oldEnd = searchEnd ?? 0
            feeder.showMore { [weak self] in
                guard let self else { return }
                self.find(startingAt: oldEnd)
                // В новой порции ничего — остаёмся на последнем найденном; следующий шаг
                // допишет ещё одну, пока файл не кончится.
                if self.ranges.indices.contains(self.current),
                   self.ranges[self.current].location < oldEnd, let last = self.ranges.indices.last {
                    self.show(last)
                }
                completion(self.answer())
            }
            return
        }
        guard !ranges.isEmpty else { completion(answer()); return }
        show((target % ranges.count + ranges.count) % ranges.count)
        completion(answer())
    }

    func clear() {
        removeHighlights()
        ranges = []
        current = -1
    }

    private func answer() -> ViewerFindResult {
        ViewerFindResult(count: ranges.count, position: current + 1, more: hasMore)
    }

    private func find(startingAt location: Int) {
        removeHighlights()
        ranges = []
        current = -1
        guard let textView, let storage = textView.textStorage, let layout = textView.layoutManager else { return }
        ranges = ViewerTextSearch.ranges(of: query, in: storage.string as NSString, upTo: searchEnd)
        for range in ranges {
            layout.addTemporaryAttribute(.backgroundColor, value: Self.matchColor, forCharacterRange: range)
        }
        highlighted = ranges.isEmpty ? nil : NSRange(location: 0, length: storage.length)
        if !ranges.isEmpty { show(ViewerTextSearch.firstIndex(in: ranges, atOrAfter: location)) }
    }

    /// Первый знак, видимый на экране: поиск начинается от него.
    private func visibleStart() -> Int {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer
        else { return 0 }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
    }

    private func show(_ index: Int) {
        guard let textView, let layout = textView.layoutManager, ranges.indices.contains(index) else { return }
        if ranges.indices.contains(current) {
            layout.addTemporaryAttribute(.backgroundColor, value: Self.matchColor,
                                         forCharacterRange: ranges[current])
        }
        current = index
        let range = ranges[index]
        layout.addTemporaryAttribute(.backgroundColor, value: Self.currentColor, forCharacterRange: range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    private func removeHighlights() {
        guard let textView, let layout = textView.layoutManager, let storage = textView.textStorage,
              highlighted != nil else { return }
        layout.removeTemporaryAttribute(.backgroundColor,
                                        forCharacterRange: NSRange(location: 0, length: storage.length))
        highlighted = nil
    }
}

// MARK: - Что на экране

/// Текстовые виды просмотра, которые сейчас на экране, — их находит поиск. Обычный объект, а
/// не состояние SwiftUI: виды кладут сюда себя при создании, и перерисовывать тут нечего.
@MainActor
final class ViewerFindTargets {
    /// Простой текст: с номерами строк или большой файл порциями.
    weak var text: NSTextView?
    /// Подача порций большого файла — если на экране он.
    weak var feeder: ChunkedTextFeeder?
    /// Оформленный Markdown.
    weak var markdown: NSTextView?
    /// Показанный PDF.
    weak var pdf: PDFView?
    /// Показанные страницы DjVu.
    weak var djvu: DjVuPagesView?
    /// Главу книги открыл сам поиск — её смена не сбрасывает найденное.
    var chapterOpenedByFind: Int?
}

extension ViewerFindModel {
    /// Сочетание команды «Поиск» сейчас — для подсказки на кнопке «Найти».
    static var searchShortcut: KeyCombo {
        KeyBindings.current(for: "cmd:menuSearch:") ?? KeyCombo(key: "f", modifiers: .command)
    }
}
