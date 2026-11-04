import AppKit
import PDFKit

/// Готовые страницы тяжёлого PDF, оставленные картинками.
///
/// PDFKit ничего не запоминает: каждый взгляд на страницу — это заново собранная векторная
/// графика. Для обычного документа это 30 мс и никого не трогает, а для чертежа с десятками
/// групп прозрачности — 600 мс на КАЖДЫЙ показ. Промотал вперёд, вернулся назад — и ждёшь
/// ту же страницу второй раз, будто видишь её впервые.
///
/// Здесь страница рисуется один раз, кладётся картинкой в кэш и дальше показывается мгновенно.
/// Текст при этом остаётся текстом: выделение, копирование и поиск живут отдельно от рисования,
/// поэтому подмена картинкой их не касается — как и полосы страниц сбоку.
final class PDFRasterCache {

    struct Entry {
        let image: CGImage
        /// Масштаб, в котором картинка нарисована: экранный (retina) умноженный на зум.
        let scale: CGFloat
        var bytes: Int { image.height * image.bytesPerRow }
    }

    /// Сколько памяти отдаётся под страницы. Просьба была прямая: «чтобы кэша хватало, чтобы
    /// предыдущие страницы оставались прорисованными». Страница A4 на retina — около 15 МБ,
    /// так что 384 МБ держат два десятка страниц: назад мотается мгновенно.
    static var defaultByteLimit: Int {
        min(384 << 20, Int(ProcessInfo.processInfo.physicalMemory / 16))
    }

    /// Выше этого масштаба кэш не работает вовсе. Экран даёт 2–3 (retina плюс зум), а всё
    /// заметно большее — это печать или экспорт, и туда обязана уйти настоящая векторная
    /// страница, а не растянутая картинка.
    static let maxCachedScale: CGFloat = 3.5

    /// Больше этого картинку не делаем: 40 млн пикселей — уже 160 МБ на одну страницу.
    private static let maxPixels = 40_000_000

    private let byteLimit: Int
    private var store: [Int: Entry] = [:]
    /// Порядок обращений, свежие в конце. Вытесняется давно не показанное, а не далёкое:
    /// человек мотает туда-обратно, и «далеко» — плохая мера нужности.
    private var recency: [Int] = []
    private var bytes = 0
    private let lock = NSLock()

    /// Рисование сериализовано: PDFKit рисует страницу в своём потоке, мы готовим соседей в
    /// своём, и одновременный доступ к одному документу CoreGraphics не обещает пережить.
    private let renderLock = NSLock()
    private let queue = DispatchQueue(label: "com.fcxl.pdf.pagecache", qos: .userInitiated)
    private var pending: Set<Int> = []

    /// Экран, которому надо сказать «перерисуйся», когда фоновая страница готова.
    weak var view: PDFView?

    init(byteLimit: Int = PDFRasterCache.defaultByteLimit) {
        self.byteLimit = byteLimit
    }

    // MARK: - Хранилище

    func entry(for index: Int) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = store[index] else { return nil }
        touch(index)
        return entry
    }

    func put(_ entry: Entry, for index: Int) {
        lock.lock(); defer { lock.unlock() }
        if let old = store[index] {
            // Качество не понижается: крупная картинка годится и для мелкого показа, а
            // обратно — нет, и страница «мылилась» бы после каждого сужения окна.
            guard entry.scale + 0.01 >= old.scale else { touch(index); return }
            bytes -= old.bytes
        }
        store[index] = entry
        bytes += entry.bytes
        touch(index)
        evictIfNeeded()
    }

    /// Только для проверок и отчётов.
    var pageCount: Int {
        lock.lock(); defer { lock.unlock() }
        return store.count
    }

    var usedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    /// Отпустить всё разом — просмотрщик закрыли. Память возвращается системе здесь и
    /// сейчас, не дожидаясь, пока последний державший документ отпустит его.
    func purge() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
        recency.removeAll()
        bytes = 0
    }

    private func touch(_ index: Int) {
        recency.removeAll { $0 == index }
        recency.append(index)
    }

    private func evictIfNeeded() {
        // Две страницы остаются всегда: без текущей и следующей кэш теряет смысл, даже если
        // лимит выставлен неприлично маленьким.
        while bytes > byteLimit, store.count > 2, let oldest = recency.first {
            recency.removeFirst()
            if let gone = store.removeValue(forKey: oldest) { bytes -= gone.bytes }
        }
    }

    // MARK: - Рисование

    /// Нарисовать страницу в картинку — под общим замком, по одной за раз.
    func render(_ page: PDFPage, box: PDFDisplayBox, scale: CGFloat) -> CGImage? {
        let rect = page.bounds(for: box)
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0, width * height <= Self.maxPixels else { return nil }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: Self.rgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }

        // Бумага под страницей: PDF рисует по прозрачному, и без белого фона тёмная тема
        // проступала бы сквозь текст.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)

        renderLock.lock()
        if let cached = page as? PDFCachedPage {
            cached.drawWithoutCache(box: box, to: context)
        } else {
            page.draw(with: box, to: context)
        }
        renderLock.unlock()

        return context.makeImage()
    }

    private static let rgb = CGColorSpaceCreateDeviceRGB()

    /// Приготовить соседние страницы, пока человек смотрит на эту. Прокрутка вперёд тогда
    /// тоже не упирается в ожидание.
    func prefetch(around index: Int, in document: PDFDocument,
                  box: PDFDisplayBox, scale: CGFloat) {
        guard scale <= Self.maxCachedScale else { return }
        for neighbour in [index + 1, index - 1] where document.pageIndices.contains(neighbour) {
            schedule(neighbour, in: document, box: box, scale: scale, repaint: false)
        }
    }

    /// Перерисовать страницу заново в новом масштабе (окно растянули, зум сменили) и попросить
    /// экран обновиться. До готовности на месте страницы остаётся прежняя картинка — размытая,
    /// зато сразу: пустоты человек не видит.
    func refresh(_ index: Int, in document: PDFDocument, box: PDFDisplayBox, scale: CGFloat) {
        guard scale <= Self.maxCachedScale else { return }
        schedule(index, in: document, box: box, scale: scale, repaint: true)
    }

    private func schedule(_ index: Int, in document: PDFDocument,
                          box: PDFDisplayBox, scale: CGFloat, repaint: Bool) {
        lock.lock()
        if let existing = store[index], existing.scale + 0.01 >= scale {
            lock.unlock(); return          // уже есть не хуже требуемого
        }
        guard !pending.contains(index) else { lock.unlock(); return }
        pending.insert(index)
        lock.unlock()

        // Документ здесь ТОЛЬКО слабой ссылкой: просмотрщик закрывают в любой момент, и
        // фоновая страница не имеет права задержать освобождение памяти ни на секунду.
        queue.async { [weak self, weak document] in
            guard let self else { return }
            defer {
                self.lock.lock(); self.pending.remove(index); self.lock.unlock()
            }
            guard let document, let page = document.page(at: index) else { return }
            guard let image = self.render(page, box: box, scale: scale) else { return }
            self.put(Entry(image: image, scale: scale), for: index)
            guard repaint else { return }
            DispatchQueue.main.async { self.view?.needsDisplay = true }
        }
    }
}

private extension PDFDocument {
    var pageIndices: Range<Int> { 0..<pageCount }
}

/// Страница, которая рисует себя из кэша.
///
/// Подставляется документом `PDFCachingDocument` — иначе PDFKit создаёт обычные `PDFPage`,
/// и перехватить рисование негде.
final class PDFCachedPage: PDFPage {

    private var cache: PDFRasterCache? { (document as? PDFCachingDocument)?.cache }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let scale = context.drawingScale
        guard let cache, let document,
              scale > 0, scale <= PDFRasterCache.maxCachedScale else {
            super.draw(with: box, to: context)
            return
        }
        let index = document.index(for: self)
        guard index != NSNotFound else {
            super.draw(with: box, to: context)
            return
        }

        let rect = bounds(for: box)

        if let entry = cache.entry(for: index) {
            let sharpEnough = entry.scale + 0.01 >= scale
            context.saveGState()
            context.interpolationQuality = sharpEnough ? .high : .low
            context.draw(entry.image, in: rect)
            context.restoreGState()
            // Размытую картинку заменит точная — фоном, без пустого места на экране.
            if !sharpEnough {
                cache.refresh(index, in: document, box: box, scale: scale)
            }
            cache.prefetch(around: index, in: document, box: box, scale: scale)
            return
        }

        guard let image = cache.render(self, box: box, scale: scale) else {
            super.draw(with: box, to: context)
            return
        }
        cache.put(PDFRasterCache.Entry(image: image, scale: scale), for: index)
        context.draw(image, in: rect)
        cache.prefetch(around: index, in: document, box: box, scale: scale)
    }

    /// Настоящая отрисовка, в обход кэша — то, чем кэш и наполняется.
    func drawWithoutCache(box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
    }
}

/// Документ, чьи страницы умеют запоминаться картинками.
///
/// Кэш живёт внутри документа: закрыли просмотрщик — память вернулась вся и сразу, забыть
/// её негде. Документ сам себе делегат: PDFKit держит делегата неучитываемой ссылкой, и
/// отдельный объект пришлось бы удерживать снаружи — ровно та мелочь, на которой кэш однажды
/// молча перестал бы работать.
final class PDFCachingDocument: PDFDocument, PDFDocumentDelegate {
    let cache: PDFRasterCache

    init?(url: URL, cache: PDFRasterCache = PDFRasterCache()) {
        self.cache = cache
        super.init(url: url)
        delegate = self
    }

    func classForPage() -> AnyClass { PDFCachedPage.self }
}

private extension CGContext {
    /// Во сколько раз контекст крупнее координат страницы. Через определитель, а не через `a`:
    /// у повёрнутой страницы масштаб сидит в других членах матрицы.
    var drawingScale: CGFloat {
        let m = ctm
        return abs(m.a * m.d - m.b * m.c).squareRoot()
    }
}

/// Насколько тяжело этот документ рисовать — измеряется, а не угадывается.
enum PDFWeight {

    /// Выше этого страница рисуется столько, что чтение превращается в ожидание. 0,12 с —
    /// порог, на котором возврат к прочитанной странице заметно мигает; обычные документы
    /// укладываются в 0,03 с.
    static let slowPageSeconds = 0.12

    /// Замерить одну страницу. Вызывается не на главном потоке, при открытии PDF.
    static func secondsPerPage(_ document: PDFDocument) -> Double {
        guard let page = document.page(at: min(1, document.pageCount - 1)) else { return 0 }
        let size = page.bounds(for: .mediaBox).size
        guard size.width > 1 else { return 0 }
        let started = Date()
        _ = page.thumbnail(of: size, for: .mediaBox)
        return Date().timeIntervalSince(started)
    }

    static func isSlow(_ document: PDFDocument) -> Bool {
        secondsPerPage(document) > slowPageSeconds
    }
}

/// Показанный PDF, чтобы закладки в шапке могли до него дотянуться. Тот же приём, что у DjVu:
/// ссылка из @State теряется, когда SwiftUI пересобирает представление, а закладка, которая
/// молчит в ответ на нажатие, хуже отсутствующей.
@MainActor
final class PDFPageBridge {
    static let shared = PDFPageBridge()
    weak var current: PDFView?
}
