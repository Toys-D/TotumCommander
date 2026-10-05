import AppKit

/// Новое внутри папки: в ней, на любой глубине, появились файлы за срок новизны.
///
/// Новизна та же, что красит новые файлы: первое включённое правило «любое имя» со сроком в
/// «Цвета файлов» — его срок и угасание. Узнаётся у Spotlight, а не обходом: обход всех
/// подпапок нагружал бы диск так же, как подсчёт размеров папок, а Spotlight уже всё
/// проиндексировал. Где он не индексирует — сеть, скрытые папки, диски без индекса, — знака
/// просто нет. Знак — счётчик «+12» после имени (FolderNewsChip): сколько нового, гаснет к
/// концу срока. Цвет — акцентный: им программа отмечает своё.
enum FolderNews {

    /// Отмечать ли папки с новым внутри. Включение и правка правил шлют
    /// `.fcxlFileColorsChanged` — по нему панели перезапускают запрос и перерисовываются.
    static let defaultsKey = "folderNewsMark"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// Правило, по которому судится новизна: первое включённое «любое имя» со сроком.
    static func rule(in rules: [FileColorRule] = FileColorRulesStore.shared.rules) -> FileColorRule? {
        rules.first { $0.isEnabled && $0.isFreshness && FileColorRule.patterns(in: $0.mask).isEmpty }
    }

    /// О какой папке стоит спрашивать. Не о корне диска — ответом был бы весь диск; не о
    /// скрытых и не о системных временных: Spotlight их не индексирует, ответ всегда пуст.
    static func canWatch(_ folder: String) -> Bool {
        guard folder.hasPrefix("/"), folder != "/" else { return false }
        let resolved = realPath(folder)
        let temporary = realPath(NSTemporaryDirectory())
        for path in [folder, resolved] {
            if path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")
                || path == temporary || path.hasPrefix(temporary + "/") {
                return false
            }
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        }
        return true
    }

    /// Новое внутри одной подпапки: сколько файлов и когда появился самый свежий.
    struct Inside: Equatable {
        var count: Int
        var newest: Date
    }

    /// Новое по подпапкам — по файлам, которые нашёл Spotlight.
    ///
    /// Файл прямо в папке — не «новое внутри»: его и так видно, имя красится само. Скрытое
    /// (`.DS_Store`, `.git/…`) новостью не считается. Spotlight отдаёт настоящие пути, а панель
    /// могла прийти по ссылке, — годится и то и другое.
    static func newsByChild(of folder: String, found: [(path: String, added: Date)]) -> [String: Inside] {
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        let resolved = realPath(folder)
        let resolvedBase = resolved.hasSuffix("/") ? resolved : resolved + "/"
        var news: [String: Inside] = [:]
        for (path, added) in found {
            let rest: Substring
            if path.hasPrefix(base) {
                rest = path.dropFirst(base.count)
            } else if path.hasPrefix(resolvedBase) {
                rest = path.dropFirst(resolvedBase.count)
            } else {
                continue
            }
            let parts = rest.split(separator: "/")
            guard parts.count >= 2, !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
            let child = base + parts[0]
            if var known = news[child] {
                known.count += 1
                known.newest = max(known.newest, added)
                news[child] = known
            } else {
                news[child] = Inside(count: 1, newest: added)
            }
        }
        return news
    }

    /// Прежний счёт плюс новые находки: счёт складывается, свежайшее — из двух.
    static func adding(_ news: [String: Inside], _ delta: [String: Inside]) -> [String: Inside] {
        var merged = news
        for (child, more) in delta {
            if var known = merged[child] {
                known.count += more.count
                known.newest = max(known.newest, more.newest)
                merged[child] = known
            } else {
                merged[child] = more
            }
        }
        return merged
    }

    /// Настоящий путь, как его видит Spotlight: /tmp → /private/tmp. Не resolvingSymlinksInPath —
    /// тот нарочно срезает /private и делает ровно обратное. Нет такого пути — как есть.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Знак

    /// Знак папки с новым внутри: акцентный цвет темы, в которой рисуют, и сила (1 — свежее,
    /// к концу срока бледнеет, если правило гаснущее).
    struct Mark: Equatable {
        let color: NSColor
        let strength: Double

        /// Насколько знак виден: свежее — в полную силу, к концу срока — тише, но читается.
        var opacity: CGFloat { CGFloat(0.45 + 0.55 * min(1, max(0, strength))) }
    }

    static func mark(for item: FileItem, rule: FileColorRule?, enabled: Bool, color: NSColor,
                     now: Date = Date()) -> Mark? {
        guard enabled, item.isDirectory, !item.isAppBundle, item.name != "..",
              item.newInsideCount > 0, let newest = item.newestInside, let rule
        else { return nil }
        let strength = rule.strength(age: now.timeIntervalSince(newest))
        guard strength > 0 else { return nil }
        return Mark(color: color, strength: strength)
    }

    /// Знак для этой папки по текущим настройкам — для видов списка. Акцент берётся той темы,
    /// что включена: у светлой и тёмной он свой.
    static func mark(for item: FileItem) -> Mark? {
        guard item.newestInside != nil else { return nil }
        return mark(for: item, rule: rule(), enabled: isEnabled, color: PanelAppearanceSettings.accentNSColor)
    }
}

/// Счётчик нового внутри папки — плашка «+12» после имени, как у ветки git.
enum FolderNewsChip {

    /// Что написано: «+12»; больше 999 — «+999», длиннее плашке быть незачем.
    static func text(count: Int) -> String {
        "+\(min(max(count, 0), 999))"
    }

    /// Отступ слева от имени — входит в саму картинку: без нового ширина нулевая, и имя
    /// получает всю колонку, как раньше.
    static let leading: CGFloat = 5

    /// Плашка для строки списка: цифры акцентом на подложке того же цвета.
    static func image(count: Int, mark: FolderNews.Mark, font base: NSFont) -> NSImage? {
        guard count > 0 else { return nil }
        let font = NSFont.systemFont(ofSize: max(9, base.pointSize - 1), weight: .medium)
        let ink = mark.color.withAlphaComponent(mark.opacity)
        let plate = mark.color.withAlphaComponent(0.16 * mark.opacity)
        return capsule(text(count: count), font: font, ink: ink, plate: plate, leading: leading)
    }

    /// Где у поля кончается имя: отсюда, вплотную, встаёт счётчик. Поле имени — обычное
    /// NSTextField или своё бегущее (MarqueeTextField): у обоих ширина текста — их
    /// собственный размер.
    @MainActor
    static func textEnd(of label: NSView) -> CGFloat {
        let intrinsic = label.intrinsicContentSize.width
        return intrinsic == NSView.noIntrinsicMetric ? 0 : ceil(max(0, intrinsic))
    }

    static func width(count: Int, font base: NSFont) -> CGFloat {
        guard count > 0 else { return 0 }
        let font = NSFont.systemFont(ofSize: max(9, base.pointSize - 1), weight: .medium)
        return capsuleSize(text(count: count), font: font).width + leading
    }

    /// Плашка на картинке миниатюры: сплошной акцент и белые цифры — читается поверх любой
    /// картинки, как плашка git там же.
    static func plaqueImage(count: Int, mark: FolderNews.Mark, font base: NSFont) -> NSImage? {
        guard count > 0 else { return nil }
        let font = NSFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        return capsule(text(count: count), font: font, ink: .white,
                       plate: mark.color.withAlphaComponent(0.5 + 0.5 * mark.opacity), leading: 0)
    }

    private static func capsuleSize(_ text: String, font: NSFont) -> NSSize {
        let label = (text as NSString).size(withAttributes: [.font: font])
        let height = ceil(font.ascender - font.descender) + 3
        return NSSize(width: ceil(label.width) + height * 0.9, height: height)
    }

    private static func capsule(_ text: String, font: NSFont, ink: NSColor, plate: NSColor,
                                leading: CGFloat) -> NSImage {
        let body = capsuleSize(text, font: font)
        let size = NSSize(width: body.width + leading, height: body.height)
        let image = NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(x: leading, y: 0, width: body.width, height: body.height)
            plate.setFill()
            NSBezierPath(roundedRect: rect, xRadius: body.height / 2, yRadius: body.height / 2).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let label = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: rect.midX - label.width / 2,
                                                y: rect.midY - label.height / 2),
                                    withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Живой запрос к Spotlight: какие файлы внутри папки появились за срок новизны.
///
/// Разбор — на своей фоновой очереди: в домашней папке за сутки появляются десятки тысяч
/// файлов (почти все в ~/Library/Application Support, программы пишут туда постоянно), и
/// перебирать их на главном потоке значило бы дёргать интерфейс каждую секунду. Первый сбор
/// считается целиком, дальше — только добавленное и изменённое; удалённое — пересчётом.
/// На главный поток уходит готовый словарь по подпапкам. Раз в десять минут запрос
/// собирается заново: файлы, вышедшие за срок, выпадают из счёта.
final class FolderNewsQuery {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var renewal: Timer?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FolderNews"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    /// Ответы старого запроса, доехавшие после перехода, узнаются по этому счётчику.
    private var generation = 0
    private(set) var folder: String?
    private(set) var period: TimeInterval?
    static let renewInterval: TimeInterval = 600
    /// Папка и новое по её подпапкам. На главном потоке.
    var onUpdate: ((String, [String: FolderNews.Inside]) -> Void)?

    /// Следить за папкой. Та же папка с тем же сроком — ничего не делает. С главного потока.
    func follow(_ folder: String, period: TimeInterval) {
        guard folder != self.folder || period != self.period else { return }
        start(folder, period: period)
    }

    private func start(_ folder: String, period: TimeInterval) {
        stop()
        generation &+= 1
        let generation = self.generation
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K >= %@", "kMDItemDateAdded",
                                      Date(timeIntervalSinceNow: -period) as NSDate)
        query.searchScopes = [URL(fileURLWithPath: folder, isDirectory: true)]
        query.notificationBatchingInterval = 1
        query.operationQueue = queue
        let tally = FolderNewsTally(folder: folder)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                               queue: queue) { [weak self] _ in
                self?.deliver(tally.gathered(from: query), folder: folder, generation: generation)
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query,
                               queue: queue) { [weak self] note in
                self?.deliver(tally.updated(by: note, in: query), folder: folder, generation: generation)
            },
        ]
        self.query = query
        self.folder = folder
        self.period = period
        if !query.start() {
            stop()
            return
        }
        renewal = Timer.scheduledTimer(withTimeInterval: Self.renewInterval, repeats: false) { [weak self] _ in
            guard let self, let folder = self.folder, let period = self.period else { return }
            self.start(folder, period: period)
        }
    }

    func stop() {
        generation &+= 1
        renewal?.invalidate()
        renewal = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        // Запрос живёт на своей очереди — там же и останавливается.
        if let query { queue.addOperation { query.stop() } }
        query = nil
        folder = nil
        period = nil
    }

    private func deliver(_ news: [String: FolderNews.Inside]?, folder: String, generation: Int) {
        guard let news else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onUpdate?(folder, news)
        }
    }

    deinit {
        renewal?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        if let query { queue.addOperation { query.stop() } }
    }
}

/// Счёт нового по подпапкам для одного запроса. Живёт на очереди запроса.
final class FolderNewsTally {
    let folder: String
    private(set) var news: [String: FolderNews.Inside] = [:]

    init(folder: String) { self.folder = folder }

    /// Первый сбор — целиком.
    func gathered(from query: NSMetadataQuery) -> [String: FolderNews.Inside] {
        query.disableUpdates()
        let items = (0..<query.resultCount).compactMap { query.result(at: $0) as? NSMetadataItem }
        let list = Self.files(in: items)
        query.enableUpdates()
        news = FolderNews.newsByChild(of: folder, found: list)
        return news
    }

    /// Обновление: добавленное — в счёт; изменённое — только свежайшая дата; если что-то
    /// удалили — пересчёт. nil — для знака ничего не поменялось.
    func updated(by note: Notification, in query: NSMetadataQuery) -> [String: FolderNews.Inside]? {
        let info = note.userInfo ?? [:]
        if let removed = info[NSMetadataQueryUpdateRemovedItemsKey] as? [Any], !removed.isEmpty {
            let before = news
            let after = gathered(from: query)
            return after == before ? nil : after
        }
        let added = Self.files(in: (info[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? [])
        let changed = Self.files(in: (info[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]) ?? [])
        var next = FolderNews.adding(news, FolderNews.newsByChild(of: folder, found: added))
        for (child, more) in FolderNews.newsByChild(of: folder, found: changed) {
            if var known = next[child] {
                known.newest = max(known.newest, more.newest)
                next[child] = known
            }
        }
        guard next != news else { return nil }
        news = next
        return next
    }

    /// Файлы — не папки: новая пустая папка внутри ещё не «новые файлы».
    private static func files(in items: [NSMetadataItem]) -> [(path: String, added: Date)] {
        items.compactMap { item in
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let added = item.value(forAttribute: "kMDItemDateAdded") as? Date,
                  (item.value(forAttribute: NSMetadataItemContentTypeKey) as? String) != "public.folder"
            else { return nil }
            return (path, added)
        }
    }
}
