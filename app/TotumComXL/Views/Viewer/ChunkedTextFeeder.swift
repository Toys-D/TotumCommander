import AppKit

/// «Показать дальше» в просмотре текста: в виде — порция файла (LongLineClip.chunk), ссылка
/// внизу дописывает следующую. Весь файл в NSTextView раскладывался на главном потоке десятки
/// секунд; порция показывается сразу, а дописанное не трогает уже показанное.
@MainActor
final class ChunkedTextFeeder: NSObject, NSTextViewDelegate {
    static let moreLink = "fcxl-viewer:more"

    weak var textView: NSTextView?
    /// Знаков в порции — для тестов меньше.
    var totalLimit = LongLineClip.defaultTotal
    /// Весь текст файла и докуда он показан.
    private(set) var source: NSString?
    private(set) var shownEnd = 0
    /// Где в виде стоит ссылка «Показать дальше» — её место займёт следующая порция.
    private(set) var moreRange: NSRange?
    private var loadingMore = false
    /// Каждый новый файл — новое поколение: опоздавшая порция прежнего файла не дописывается.
    private var generation = 0

    /// Первая порция файла — на место прежнего текста.
    func show(_ chunk: (text: String, end: Int), of source: NSString) {
        generation += 1
        loadingMore = false
        self.source = source
        shownEnd = chunk.end
        moreRange = nil
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: chunk.text, attributes: textAttributes(tv)))
        appendMoreLink()
    }

    /// Текст не из файла (не прочиталось) — без продолжения.
    func showPlain(_ text: String) {
        generation += 1
        source = nil
        moreRange = nil
        textView?.string = text
    }

    nonisolated func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let target = (link as? URL)?.absoluteString ?? (link as? String)
        guard target == Self.moreLink else { return false }
        MainActor.assumeIsolated { showMore() }
        return true
    }

    /// Следующая порция — в фоне, на место ссылки. `done` — для тестов.
    func showMore(done: (() -> Void)? = nil) {
        guard let source, !loadingMore, shownEnd < source.length else { done?(); return }
        loadingMore = true
        let from = shownEnd
        let limit = totalLimit
        let started = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let part = LongLineClip.chunk(of: source, from: from, totalLimit: limit)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    defer { done?() }
                    guard self.generation == started else { return }
                    self.loadingMore = false
                    guard let tv = self.textView, let storage = tv.textStorage,
                          let range = self.moreRange else { return }
                    storage.replaceCharacters(in: range, with: NSAttributedString(
                        string: part.text, attributes: self.textAttributes(tv)))
                    self.moreRange = nil
                    self.shownEnd = part.end
                    self.appendMoreLink()
                }
            }
        }
    }

    private func appendMoreLink() {
        guard let tv = textView, let storage = tv.textStorage, let source, shownEnd < source.length else { return }
        let title = String(format: L("viewer.showMore"), (source.length - shownEnd).formatted(.number))
        let link = NSMutableAttributedString(string: "\n\n", attributes: textAttributes(tv))
        link.append(NSAttributedString(string: "⤓ " + title, attributes: [
            .link: Self.moreLink,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ]))
        link.append(NSAttributedString(string: "\n", attributes: textAttributes(tv)))
        moreRange = NSRange(location: storage.length, length: link.length)
        storage.append(link)
    }

    private func textAttributes(_ tv: NSTextView) -> [NSAttributedString.Key: Any] {
        [.font: tv.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
         .foregroundColor: NSColor.textColor]
    }
}
