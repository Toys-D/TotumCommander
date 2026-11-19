import AppKit
import Combine
@preconcurrency import FCXLBridgeObjC
import FCXLDjVuUI
import PDFKit
import WebKit

// MARK: - PDF

/// Поиск в PDF. Ищет PDFKit — в фоне, по страницам, так что большой документ не держит окно;
/// найденное подсвечено на страницах, текущее — ярче и выделено (⌘C его копирует).
@MainActor
final class PDFFindEngine: NSObject, ViewerFindEngine {
    private weak var pdfView: PDFView?
    private var query = ViewerFindQuery()
    private var selections: [PDFSelection] = []
    private var current = -1
    private var collecting: [PDFSelection] = []
    private var completion: ((ViewerFindResult) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private weak var searching: PDFDocument?

    static let matchColor = NSColor.systemYellow.withAlphaComponent(0.55)
    static let currentColor = NSColor.systemOrange.withAlphaComponent(0.9)

    init(pdfView: PDFView) {
        self.pdfView = pdfView
    }

    func search(_ query: ViewerFindQuery, completion: @escaping (ViewerFindResult) -> Void) {
        stop()
        removeHighlights()
        self.query = query
        guard let document = pdfView?.document, !query.isEmpty else {
            completion(ViewerFindResult())
            return
        }
        guard Self.hasText(document) else {
            completion(ViewerFindResult(note: L("viewer.find.noTextLayer")))
            return
        }
        self.completion = completion
        collecting = []
        searching = document
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) {
                [weak self] note in
                let found = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
                MainActor.assumeIsolated { self?.collect(found) }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            },
        ]
        document.beginFindString(query.text, withOptions: query.matchCase ? [] : [.caseInsensitive])
    }

    func step(_ direction: Int, completion: @escaping (ViewerFindResult) -> Void) {
        guard !selections.isEmpty else { completion(answer()); return }
        show(((current + direction) % selections.count + selections.count) % selections.count)
        completion(answer())
    }

    func clear() {
        stop()
        removeHighlights()
    }

    /// Есть ли в документе текст вообще. У скана его нет — и «не найдено» там значило бы
    /// неправду: искать не в чем. Смотрим первые страницы, не весь документ.
    static func hasText(_ document: PDFDocument, pagesToCheck: Int = 12) -> Bool {
        for index in 0..<min(document.pageCount, pagesToCheck) {
            if let text = document.page(at: index)?.string,
               text.contains(where: { !$0.isWhitespace }) {
                return true
            }
        }
        return document.pageCount > pagesToCheck
    }

    /// Стоит ли найденное отдельным словом — по тексту его страницы.
    static func isWholeWord(_ selection: PDFSelection) -> Bool {
        guard let page = selection.pages.first, let text = page.string as NSString?,
              selection.numberOfTextRanges(on: page) > 0 else { return true }
        let range = selection.range(at: 0, on: page)
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return true }
        return ViewerTextSearch.isWholeWord(range, in: text)
    }

    private func collect(_ selection: PDFSelection?) {
        guard let selection, collecting.count < ViewerTextSearch.matchLimit else { return }
        if query.wholeWord, !Self.isWholeWord(selection) { return }
        collecting.append(selection)
    }

    private func finish() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        searching = nil
        selections = collecting
        collecting = []
        current = -1
        for selection in selections { selection.color = Self.matchColor }
        pdfView?.highlightedSelections = selections.isEmpty ? nil : selections
        if !selections.isEmpty { show(firstIndexFromCurrentPage()) }
        let done = completion
        completion = nil
        done?(answer())
    }

    private func answer() -> ViewerFindResult {
        ViewerFindResult(count: selections.count, position: current + 1)
    }

    /// Первое совпадение на странице, что на экране, или после неё.
    private func firstIndexFromCurrentPage() -> Int {
        guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        let onScreen = document.index(for: page)
        return selections.firstIndex { selection in
            guard let page = selection.pages.first else { return false }
            return document.index(for: page) >= onScreen
        } ?? 0
    }

    private func show(_ index: Int) {
        guard let pdfView, selections.indices.contains(index) else { return }
        if selections.indices.contains(current) { selections[current].color = Self.matchColor }
        current = index
        let selection = selections[index]
        selection.color = Self.currentColor
        // Цвет меняется у того же объекта — вид перерисует подсветку только после присваивания.
        pdfView.highlightedSelections = selections
        pdfView.setCurrentSelection(selection, animate: false)
        pdfView.go(to: selection)
    }

    private func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        searching?.cancelFindString()
        searching = nil
        collecting = []
        completion = nil
    }

    private func removeHighlights() {
        selections = []
        current = -1
        pdfView?.highlightedSelections = nil
        pdfView?.clearSelection()
    }
}

// MARK: - Страницы: HTML, документы Word, книги

/// Поиск на странице веб-вида: HTML страницей, документ Word (он показан как веб-архив), глава
/// книги. Ищет и подсвечивает код на самой странице — в своём, отдельном от страницы мире.
///
/// Книга показывается по одной главе. Шаг за последнее совпадение главы открывает следующую
/// главу, где запрос есть (`chapters`), и продолжает в ней — так поиск идёт по всей книге.
@MainActor
final class WebFindEngine: ViewerFindEngine {
    /// Главы книги — чтобы искать дальше открытой.
    struct Chapters {
        /// Сколько глав и которая открыта.
        var count: () -> Int
        var current: () -> Int
        /// Текст главы без разметки. Звать вне главного потока.
        var text: @Sendable (Int) -> String
        /// Две главы лежат в одном файле — на экране это одна и та же страница, и искать в
        /// «другой» из них значит найти то же самое.
        var isSamePage: @Sendable (Int, Int) -> Bool
        /// Открыть главу; `done` — когда она на экране.
        var open: (Int, @escaping () -> Void) -> Void
    }

    private weak var webView: WKWebView?
    private let chapters: Chapters?
    private var query = ViewerFindQuery()
    private var count = 0
    private var position = 0
    /// Каждый поиск главы — новое поколение: опоздавший ответ прежнего не открывает главу.
    private var generation = 0

    init(webView: WKWebView, chapters: Chapters? = nil) {
        self.webView = webView
        self.chapters = chapters
    }

    private var hasOtherChapters: Bool { (chapters?.count() ?? 1) > 1 }

    func search(_ query: ViewerFindQuery, completion: @escaping (ViewerFindResult) -> Void) {
        generation &+= 1
        self.query = query
        run(Self.searchCall(query, from: "screen")) { [weak self] reply in
            guard let self else { return }
            self.adopt(reply)
            completion(self.answer())
        }
    }

    func step(_ direction: Int, completion: @escaping (ViewerFindResult) -> Void) {
        // Последнее совпадение главы (или в главе их нет) — дальше в соседних главах.
        let leavesChapter = count == 0 || (direction > 0 ? position >= count : position <= 1)
        if leavesChapter, hasOtherChapters {
            stepToAnotherChapter(direction, completion: completion)
            return
        }
        run("fcxlViewFind.step(\(direction))") { [weak self] reply in
            guard let self else { return }
            self.adopt(reply)
            completion(self.answer())
        }
    }

    func clear() {
        generation &+= 1
        count = 0
        position = 0
        webView?.evaluateJavaScript("window.fcxlViewFind && fcxlViewFind.clear()", in: nil,
                                    in: .defaultClient, completionHandler: nil)
    }

    private func answer() -> ViewerFindResult {
        ViewerFindResult(count: count, position: position, more: hasOtherChapters)
    }

    private func adopt(_ reply: Any?) {
        let values = reply as? [String: Any]
        count = (values?["count"] as? NSNumber)?.intValue ?? 0
        position = (values?["position"] as? NSNumber)?.intValue ?? 0
    }

    /// Ближайшая в сторону шага глава, где запрос есть; книга замкнута в кольцо, и круг кончается
    /// на открытой главе — тогда шаг просто переходит через её край.
    private func stepToAnotherChapter(_ direction: Int, completion: @escaping (ViewerFindResult) -> Void) {
        guard let chapters else { return }
        generation &+= 1
        let started = generation
        let total = chapters.count()
        let from = chapters.current()
        let query = self.query
        let text = chapters.text
        let isSamePage = chapters.isSamePage
        DispatchQueue.global(qos: .userInitiated).async {
            var target: Int?
            for offset in 1..<max(total, 1) {
                let index = ((from + direction * offset) % total + total) % total
                if isSamePage(index, from) { continue }
                if !ViewerTextSearch.ranges(of: query, in: text(index) as NSString, limit: 1).isEmpty {
                    target = index
                    break
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == started else { return }
                    guard let target else {
                        // В других главах нет — ходим по кругу в этой.
                        self.run("fcxlViewFind.step(\(direction))") { reply in
                            self.adopt(reply)
                            completion(self.answer())
                        }
                        return
                    }
                    chapters.open(target) {
                        guard self.generation == started else { return }
                        self.run(Self.searchCall(query, from: direction > 0 ? "start" : "end")) { reply in
                            self.adopt(reply)
                            completion(self.answer())
                        }
                    }
                }
            }
        }
    }

    /// Вызов поиска на странице. Запрос — JSON, а не склейка строк: кавычки и обратная косая
    /// доходят как есть.
    static func searchCall(_ query: ViewerFindQuery, from: String) -> String {
        let payload: [String: Any] = ["text": query.text, "matchCase": query.matchCase,
                                      "wholeWord": query.wholeWord, "from": from,
                                      "limit": ViewerTextSearch.matchLimit]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return "fcxlViewFind.search(\(String(decoding: data, as: UTF8.self)))"
    }

    private func run(_ call: String, completion: @escaping (Any?) -> Void) {
        guard let webView else { completion(nil); return }
        webView.evaluateJavaScript(Self.script + "\n" + call, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value): completion(value)
            case .failure: completion(nil)
            }
        }
    }

    /// Текст главы без разметки — тем же взглядом, что у страницы: без скриптов и стилей, с
    /// раскрытыми сущностями.
    nonisolated static func plainText(ofHTML html: String) -> String {
        var text = html
        for block in ["script", "style", "head"] {
            text = text.replacingOccurrences(of: "<\(block)\\b[^>]*>[\\s\\S]*?</\(block)>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": "\u{00A0}", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&apos;": "'", "&#39;": "'", "&laquo;": "«", "&raquo;": "»", "&mdash;": "—",
                        "&ndash;": "–", "&hellip;": "…"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text
    }

    /// Поиск на странице. Текст собирается из всех текстовых узлов подряд, поэтому слово,
    /// разрезанное разметкой («<b>сло</b>во»), находится целиком; каждое совпадение обёрнуто в
    /// метки, по одной на узел. Определяется один раз на страницу.
    static let script = """
    (function () {
      if (window.fcxlViewFind) { return; }
      var groups = [], current = -1;
      function style() {
        if (document.getElementById('fcxl-view-find-style')) { return; }
        var s = document.createElement('style');
        s.id = 'fcxl-view-find-style';
        s.textContent = 'mark.fcxl-view-find{background:rgba(255,214,10,.55)!important;color:inherit!important;' +
          'border-radius:2px;padding:0;margin:0}' +
          'mark.fcxl-view-find.fcxl-view-find-current{background:rgba(255,149,0,.95)!important;color:#000!important}';
        (document.head || document.documentElement).appendChild(s);
      }
      function clear() {
        for (var g = 0; g < groups.length; g++) {
          for (var m = 0; m < groups[g].length; m++) {
            var mark = groups[g][m], parent = mark.parentNode;
            if (!parent) { continue; }
            while (mark.firstChild) { parent.insertBefore(mark.firstChild, mark); }
            parent.removeChild(mark);
            parent.normalize();
          }
        }
        groups = []; current = -1;
      }
      function isWord(ch) { return !!ch && /[\\p{L}\\p{N}_]/u.test(ch); }
      function wrap(node, from, to) {
        var middle = from > 0 ? node.splitText(from) : node;
        if (to - from < middle.nodeValue.length) { middle.splitText(to - from); }
        var mark = document.createElement('mark');
        mark.className = 'fcxl-view-find';
        middle.parentNode.insertBefore(mark, middle);
        mark.appendChild(middle);
        return mark;
      }
      function visibleTop() {
        return window.scrollY || document.documentElement.scrollTop || 0;
      }
      function show(index) {
        if (current >= 0 && groups[current]) {
          groups[current].forEach(function (m) { m.classList.remove('fcxl-view-find-current'); });
        }
        current = index;
        if (current < 0 || !groups[current]) { return; }
        groups[current].forEach(function (m) { m.classList.add('fcxl-view-find-current'); });
        groups[current][0].scrollIntoView({ block: 'center', inline: 'nearest' });
      }
      function state() { return { count: groups.length, position: current + 1 }; }
      function search(q) {
        clear();
        if (!q || !q.text || !document.body) { return state(); }
        style();
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: function (n) {
            var parent = n.parentNode, p = parent && parent.nodeName;
            if (p === 'SCRIPT' || p === 'STYLE' || p === 'NOSCRIPT') { return NodeFilter.FILTER_REJECT; }
            // Оглавление страницы (полоса листов таблицы) — не её текст.
            if (parent && parent.closest && parent.closest('[data-fcxl-nofind]')) { return NodeFilter.FILTER_REJECT; }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        var nodes = [], starts = [], text = '', n;
        while ((n = walker.nextNode())) { nodes.push(n); starts.push(text.length); text += n.nodeValue; }
        var hay = text, needle = q.text;
        if (!q.matchCase) {
          var lower = text.toLowerCase();
          // Редкая буква меняет длину при смене регистра — тогда ищем как есть, чтобы
          // позиции не разошлись с текстом.
          if (lower.length === text.length && needle.toLowerCase().length === needle.length) {
            hay = lower; needle = needle.toLowerCase();
          }
        }
        var found = [], from = 0, at, limit = q.limit || 5000;
        while ((at = hay.indexOf(needle, from)) >= 0 && found.length < limit) {
          if (!q.wholeWord || (!isWord(text[at - 1]) && !isWord(text[at + needle.length]))) { found.push(at); }
          from = at + needle.length;
        }
        // С конца: разрезая узел, начало текста и его узлы остаются как были.
        var k = nodes.length - 1;
        for (var i = found.length - 1; i >= 0; i--) {
          var start = found[i], end = start + needle.length, marks = [];
          while (k > 0 && starts[k] >= end) { k--; }
          for (var j = k; j >= 0 && starts[j] + nodes[j].nodeValue.length > start; j--) {
            var a = Math.max(start - starts[j], 0);
            var b = Math.min(end - starts[j], nodes[j].nodeValue.length);
            if (b > a) { marks.unshift(wrap(nodes[j], a, b)); }
          }
          groups[i] = marks;
        }
        groups = groups.filter(function (g) { return g && g.length; });
        if (groups.length) {
          var first = 0;
          if (q.from === 'end') {
            first = groups.length - 1;
          } else if (q.from !== 'start') {
            var top = visibleTop();
            for (var g = 0; g < groups.length; g++) {
              if (groups[g][0].getBoundingClientRect().bottom + top >= top) { first = g; break; }
            }
          }
          show(first);
        }
        return state();
      }
      function step(direction) {
        if (!groups.length) { return state(); }
        show(((current + direction) % groups.length + groups.length) % groups.length);
        return state();
      }
      window.fcxlViewFind = { search: search, step: step, clear: clear };
    })();
    """
}

// MARK: - DjVu

/// Текст страницы DjVu: слова текстового слоя подряд через пробел — и где на странице лежит
/// каждое. По позиции в тексте находятся рамки слов, которые надо подсветить.
struct DjVuPageText: Sendable {
    let text: String
    /// Место слова в `text` и его рамка на странице (точки, начало вверху слева).
    let words: [(range: NSRange, box: CGRect)]

    static let empty = DjVuPageText(words: [])

    /// Из ответа читателя (`FCXLDjVuReader.words(at:)`).
    init(words raw: [[String: Any]]) {
        var text = ""
        var words: [(NSRange, CGRect)] = []
        var length = 0
        for word in raw {
            guard let value = word["text"] as? String, !value.isEmpty else { continue }
            if length > 0 {
                text += " "
                length += 1
            }
            func number(_ key: String) -> CGFloat { CGFloat((word[key] as? NSNumber)?.doubleValue ?? 0) }
            let size = (value as NSString).length
            words.append((NSRange(location: length, length: size),
                          CGRect(x: number("x"), y: number("y"), width: number("w"), height: number("h"))))
            text += value
            length += size
        }
        self.text = text
        self.words = words
    }

    /// Рамки слов, которых касается найденное: запрос из двух слов подсвечивает оба.
    func boxes(for range: NSRange) -> [CGRect] {
        words.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.box)
    }
}

/// Поиск в DjVu — по текстовому слою страниц, если он в файле есть (у чистого скана его нет:
/// тогда искать не в чем, и полоса так и говорит). Текст страниц читается в фоне, один раз.
@MainActor
final class DjVuFindEngine: ViewerFindEngine {
    private let reader: FCXLDjVuReader
    private weak var pages: DjVuPagesView?
    private var texts: [Int: DjVuPageText] = [:]
    private var matches: [(page: Int, boxes: [CGRect])] = []
    private var current = -1
    private var generation = 0
    private let queue = DispatchQueue(label: "com.fcxl.djvu.find", qos: .userInitiated)

    init(reader: FCXLDjVuReader, pages: DjVuPagesView) {
        self.reader = reader
        self.pages = pages
    }

    func search(_ query: ViewerFindQuery, completion: @escaping (ViewerFindResult) -> Void) {
        generation &+= 1
        let started = generation
        let reader = self.reader
        let known = texts
        queue.async {
            var texts = known
            var found: [(page: Int, boxes: [CGRect])] = []
            var hasText = false
            for page in 0..<reader.pageCount {
                let pageText = texts[page] ?? DjVuPageText(words: reader.words(at: page))
                texts[page] = pageText
                if !pageText.text.isEmpty { hasText = true }
                let room = ViewerTextSearch.matchLimit - found.count
                guard room > 0 else { continue }
                for range in ViewerTextSearch.ranges(of: query, in: pageText.text as NSString, limit: room) {
                    found.append((page, pageText.boxes(for: range)))
                }
            }
            let result = (texts, found, hasText)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == started else { return }
                    self.texts = result.0
                    self.matches = result.1
                    self.current = -1
                    guard result.2 else {
                        self.pages?.showFound([:], current: nil)
                        completion(ViewerFindResult(note: L("viewer.find.noTextLayer")))
                        return
                    }
                    if self.matches.isEmpty {
                        self.pages?.showFound([:], current: nil)
                    } else {
                        let onScreen = self.pages?.currentPageIndex ?? 0
                        self.show(self.matches.firstIndex { $0.page >= onScreen } ?? 0)
                    }
                    completion(self.answer())
                }
            }
        }
    }

    func step(_ direction: Int, completion: @escaping (ViewerFindResult) -> Void) {
        guard !matches.isEmpty else { completion(answer()); return }
        show(((current + direction) % matches.count + matches.count) % matches.count)
        completion(answer())
    }

    func clear() {
        generation &+= 1
        matches = []
        current = -1
        pages?.showFound([:], current: nil)
    }

    private func answer() -> ViewerFindResult {
        ViewerFindResult(count: matches.count, position: current + 1)
    }

    private func show(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        current = index
        var byPage: [Int: [CGRect]] = [:]
        for match in matches { byPage[match.page, default: []].append(contentsOf: match.boxes) }
        let match = matches[index]
        pages?.showFound(byPage, current: (match.page, match.boxes))
        if let first = match.boxes.first { pages?.scrollTo(page: match.page, box: first) }
    }
}

// MARK: - HEX

/// Поиск в режиме HEX — по байтам показанной части файла. Запрос, записанный байтами
/// («FF D8 FF»), ищется как байты; иначе — как текст в UTF-8, Windows-1251 и UTF-16.
/// Найденное красит сам список строк: он читает отсюда, какие байты строки подсветить.
@MainActor
final class HexFindEngine: ObservableObject, ViewerFindEngine {
    /// Байты, показанные в режиме HEX. Кладёт просмотр, когда читает файл.
    var data = Data()
    let bytesPerLine: Int

    @Published private(set) var matches: [Range<Int>] = []
    @Published private(set) var current = -1
    /// Строка, к которой прокрутить список; номер растёт, чтобы и та же строка сработала снова.
    @Published private(set) var scrollTarget: (line: Int, token: Int)?
    private var token = 0
    /// Строки, в которых есть найденное, — чтобы список не перебирал совпадения на каждую.
    private var linesWithMatches: [Int: [Int]] = [:]

    init(bytesPerLine: Int = 16) {
        self.bytesPerLine = bytesPerLine
    }

    func search(_ query: ViewerFindQuery, completion: @escaping (ViewerFindResult) -> Void) {
        let data = self.data
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ViewerTextSearch.byteMatches(of: query, in: data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.adopt(found)
                    if !found.isEmpty { self.show(0) }
                    completion(self.answer())
                }
            }
        }
    }

    func step(_ direction: Int, completion: @escaping (ViewerFindResult) -> Void) {
        guard !matches.isEmpty else { completion(answer()); return }
        show(((current + direction) % matches.count + matches.count) % matches.count)
        completion(answer())
    }

    func clear() {
        adopt([])
    }

    /// Какие байты строки подсветить (номера байтов в строке) и какие из них — текущее.
    func marks(forLine line: Int) -> (found: Set<Int>, current: Set<Int>)? {
        guard let indices = linesWithMatches[line] else { return nil }
        let lineRange = (line * bytesPerLine)..<((line + 1) * bytesPerLine)
        var found = Set<Int>()
        var now = Set<Int>()
        for index in indices {
            let overlap = matches[index].clamped(to: lineRange)
            for byte in overlap {
                found.insert(byte - lineRange.lowerBound)
                if index == current { now.insert(byte - lineRange.lowerBound) }
            }
        }
        return (found, now)
    }

    private func answer() -> ViewerFindResult {
        ViewerFindResult(count: matches.count, position: current + 1)
    }

    private func adopt(_ found: [Range<Int>]) {
        var lines: [Int: [Int]] = [:]
        for (index, match) in found.enumerated() where !match.isEmpty {
            for line in (match.lowerBound / bytesPerLine)...((match.upperBound - 1) / bytesPerLine) {
                lines[line, default: []].append(index)
            }
        }
        linesWithMatches = lines
        matches = found
        current = -1
    }

    private func show(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        current = index
        token &+= 1
        scrollTarget = (matches[index].lowerBound / bytesPerLine, token)
    }
}
