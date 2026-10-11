import AppKit
import QuartzCore

/// Когда файл стал «новым» и где новое не отмечается вовсе — одно правило для цвета недавних и
/// для счётчика «+N».
///
/// Новый — появился в папке за срок (дата добавления: старый снимок, только что скопированный
/// сюда, здесь новый) или перезаписан за срок. Пересохранённый другой программой файл хранит и
/// дату создания, и дату добавления прежними — меняется только дата изменения. Перезапись не в
/// счёт у папок: их дата меняется от любой правки внутри.
///
/// Не отмечается новое — ни счётчиком, ни цветом — в системных папках, в ~/Library (настройки,
/// кэши и данные программ), в папках кэша и в скрытых: программы переписывают там свои файлы
/// постоянно. Горело бы всё, а подсчёт в домашней папке перебирал их десятки тысяч — первый
/// ответ приходил через полминуты, и до того счётчиков не было вовсе.
enum FileNewness {
    /// Корни системного диска: лежит там не человеческое, а системы и программ.
    static let systemRoots = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin",
                              "/opt", "/cores", "/dev", "/etc", "/var", "/tmp"]
    /// Папки кэша — где бы ни лежали.
    static let cacheFolderNames: Set<String> = ["Caches", "Cache", "caches", "cache"]
    /// Исключённые целиком: системные корни и ~/Library.
    static let excludedRoots = systemRoots + [NSHomeDirectory() + "/Library"]

    /// Подмена для проверок: временная папка лежит в /private, а проверять надо обычную.
    nonisolated(unsafe) static var excludedOverride: ((String) -> Bool)?

    /// Не отмечать здесь новое (см. выше).
    static func isExcluded(_ path: String) -> Bool {
        excludedOverride?(path) ?? isExcludedByDefault(path)
    }

    static func isExcludedByDefault(_ path: String) -> Bool {
        if excludedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return path.split(separator: "/").contains { $0.hasPrefix(".") || cacheFolderNames.contains(String($0)) }
    }

    /// Самая поздняя из дат: появления в папке и — у файла, не у папки, — перезаписи. Нет даты
    /// появления (том её не хранит) — остаётся дата изменения, как и было.
    static func date(added: Date?, modified: Date?, isFolder: Bool) -> Date? {
        guard let modified, modified > .distantPast else { return added }
        guard let added else { return modified }
        return isFolder ? added : max(added, modified)
    }
}

/// Новое внутри папки: в ней, на любой глубине, появились или перезаписаны файлы за срок
/// новизны (FileNewness).
///
/// Новизна та же, что красит новые файлы: первое включённое правило «любое имя» со сроком в
/// «Цвета файлов» — его срок и угасание. Узнаётся не обходом — обход всех подпапок нагружал бы
/// диск так же, как подсчёт размеров папок, — а у системы: из журнала изменений диска (FSEvents,
/// FolderNewsArrivals) — сразу, в том числе перенесённое; у Spotlight — давнее. Spotlight о
/// переносе узнаёт с большим опозданием. В сети и скрытых папках знака нет. Знак — счётчик
/// «+12» после имени (FolderNewsChip): сколько нового, гаснет к концу срока. Цвет — акцентный:
/// им программа отмечает своё.
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
            // Системные папки, ~/Library, кэши — новое там не отмечается (FileNewness).
            if FileNewness.isExcluded(path) { return false }
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
    /// получает всю колонку, как раньше. С 5 плашка липла к буквам.
    static let leading: CGFloat = 8

    /// Плашка для строки списка: цифры цветом имени рядом, на подложке того же цвета, — читаются
    /// как продолжение имени. Под курсором имя в цвете курсора — и цифры в нём же.
    static func image(count: Int, mark: FolderNews.Mark, font base: NSFont,
                      nameColor: NSColor) -> NSImage? {
        guard count > 0 else { return nil }
        let font = listFont(for: base)
        let ink = nameColor.withAlphaComponent(mark.opacity)
        let plate = nameColor.withAlphaComponent(0.16 * mark.opacity)
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

    /// Плашка растёт вместе с именем под курсором (CursorLift): тот же масштаб, что у букв на
    /// этом кадре, опора — начало имени, поэтому она и едет за последней буквой. Длинное имя
    /// обрезано, и плашка прижата к краю колонки — тогда опора её собственный левый край: буквы
    /// упираются в неё на любом кадре. Единица — рост окончен, плашка стоит как есть.
    @MainActor
    static func follow(_ chip: NSView, label: NSView, textEnd: CGFloat, scale: CGFloat) {
        guard let layer = chip.layer else { return }
        guard abs(scale - 1) > 0.001, chip.frame.width > 0 else {
            if !CATransform3DIsIdentity(layer.transform) { layer.transform = CATransform3DIdentity }
            return
        }
        let pinned = chip.frame.minX < label.frame.minX + textEnd - 0.5
        // Слой плашки, как у всех видов AppKit, держится за угол: опора задаётся сдвигом.
        let px = pinned ? 0 : label.frame.minX - chip.frame.minX
        let py = layer.bounds.height / 2
        var transform = CATransform3DMakeTranslation(px, py, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        layer.transform = CATransform3DTranslate(transform, -px, -py, 0)
    }

    static func width(count: Int, font base: NSFont) -> CGFloat {
        guard count > 0 else { return 0 }
        return capsuleSize(text(count: count), font: listFont(for: base)).width + leading
    }

    /// Цифры плашки в строке — тонкие, на пункт меньше имени: плотные спорили с именем рядом.
    static func listFont(for base: NSFont) -> NSFont {
        NSFont.systemFont(ofSize: max(9, base.pointSize - 1), weight: .light)
    }

    /// Плашка на картинке миниатюры: сплошной акцент и белые цифры — читается поверх любой
    /// картинки, как плашка git там же.
    static func plaqueImage(count: Int, mark: FolderNews.Mark, font base: NSFont) -> NSImage? {
        guard count > 0 else { return nil }
        return capsule(text(count: count), font: plaqueFont(for: base), ink: .white,
                       plate: mark.color.withAlphaComponent(0.5 + 0.5 * mark.opacity), leading: 0)
    }

    /// Цифры на плашке миниатюры — обычные, не жирные. Тоньше, как в строке, нельзя: белые
    /// тонкие на светлом акценте (зелёный тёмной темы) пропадают.
    static func plaqueFont(for base: NSFont) -> NSFont {
        NSFont.systemFont(ofSize: base.pointSize, weight: .regular)
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

/// Живой запрос к Spotlight и слежка по журналу диска (FolderNewsStream) — на одной фоновой
/// очереди.
///
/// Разбор — не на главном потоке: в домашней папке за сутки появляются десятки тысяч файлов
/// (почти все в ~/Library/Application Support, программы пишут туда постоянно), и перебирать их
/// на главном значило бы дёргать интерфейс. Счёт — по объединению: что знает Spotlight и что
/// пришло по журналу, один путь считается один раз. Раз в десять минут запрос к Spotlight
/// собирается заново: файлы, вышедшие за срок, выпадают из счёта; слежка при этом не трогается.
/// На главный поток уходит готовый словарь.
final class FolderNewsQuery {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var arrivalsObserver: NSObjectProtocol?
    private var stream: FolderNewsStream?
    private var renewal: Timer?
    private let work = DispatchQueue(label: "FolderNews", qos: .utility)
    private lazy var queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FolderNews"
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = work
        return queue
    }()
    /// Ответы старого запроса, доехавшие после перехода, узнаются по этому счётчику.
    private var generation = 0
    private(set) var folder: String?
    private(set) var period: TimeInterval?
    /// Счёт последнего собранного запроса и отложенный пересчёт — только на очереди `work`.
    private var tally: FolderNewsTally?
    private var recountPending = false
    static let renewInterval: TimeInterval = 600
    /// Пачки событий складываются: пересчёт не чаще раза в четверть секунды.
    static let recountDelay: TimeInterval = 0.25
    /// Папка и новое по её подпапкам. На главном потоке.
    var onUpdate: ((String, [String: FolderNews.Inside]) -> Void)?

    /// Следить за папкой. С главного потока, после каждого чтения папки панелью; та же папка с
    /// тем же сроком — всё остаётся как есть.
    func follow(_ folder: String, period: TimeInterval) {
        guard folder != self.folder || period != self.period else { return }
        stop()
        generation &+= 1
        self.folder = folder
        self.period = period
        stream = FolderNewsStream(folder: folder, period: period, queue: work)
        let bases = FolderNewsArrivals.bases(of: folder)
        let generation = generation
        let work = work
        // Без очереди-получателя и с переходом вручную: с очередью отправитель ждал бы, пока
        // блок выполнится, а шлёт и сама слежка с этой же очереди — встали бы оба.
        arrivalsObserver = NotificationCenter.default.addObserver(
            forName: FolderNewsArrivals.changed, object: nil, queue: nil) { [weak self] note in
            work.async { self?.arrivalsChanged(note, bases: bases, generation: generation) }
        }
        ask(folder, period: period)
    }

    private func ask(_ folder: String, period: TimeInterval) {
        stopQuery()
        let generation = generation
        let query = NSMetadataQuery()
        // Появилось или перезаписано за срок; что из перезаписанного не в счёт — решает FileNewness.
        let since = Date(timeIntervalSinceNow: -period) as NSDate
        query.predicate = NSPredicate(format: "%K >= %@ OR %K >= %@", "kMDItemDateAdded", since,
                                      "kMDItemFSContentChangeDate", since)
        let scopes = Self.scopes(for: folder)
        query.searchScopes = scopes
        query.notificationBatchingInterval = 1
        // Свойства — сразу с ответом. Без этого каждое спрашивалось у Spotlight отдельным запросом:
        // разбор полутора тысяч находок шёл полторы секунды, и всё это время счётчиков не было.
        query.valueListAttributes = FolderNewsTally.attributes
        query.operationQueue = queue
        let tally = FolderNewsTally(folder: folder, since: Date(timeIntervalSinceNow: -period),
                                    generation: generation)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                               queue: queue) { [weak self] _ in
                tally.gathered(from: query)
                self?.adopt(tally)
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query,
                               queue: queue) { [weak self] note in
                tally.updated(by: note, in: query)
                self?.scheduleRecount()
            },
        ]
        self.query = query
        // Подпапок нет — искать негде (пустой список Spotlight понял бы как «везде»); новое в
        // появившихся потом подпапках принесёт журнал.
        if scopes.isEmpty || !query.start() {
            // Spotlight здесь не отвечает — считается то, что пришло по журналу.
            stopQuery()
            work.async { [weak self] in self?.adopt(tally) }
        }
        renewal?.invalidate()
        renewal = Timer.scheduledTimer(withTimeInterval: Self.renewInterval, repeats: false) { [weak self] _ in
            guard let self, let folder = self.folder, let period = self.period else { return }
            self.ask(folder, period: period)
        }
    }

    /// Где спрашивать Spotlight: подпапки — новое внутри папки и есть новое в её подпапках, —
    /// кроме скрытых и исключённых (FileNewness). В домашней папке так Spotlight не перебирает
    /// десятки тысяч файлов ~/Library. Подпапок слишком много — спрашивается сама папка, а
    /// исключённое отсеивается в ответе.
    static func scopes(for folder: String, limit: Int = 300) -> [URL] {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [url] }
        let folders = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && !FileNewness.isExcluded($0.path)
        }
        return folders.count > limit ? [url] : folders
    }

    /// Собранный запрос становится текущим. До того в силе прежний — переход к новому сроку
    /// не гасит счётчики на время сбора. На очереди `work`.
    private func adopt(_ tally: FolderNewsTally) {
        if let current = self.tally, current.generation == tally.generation, current.since > tally.since { return }
        self.tally = tally
        deliver(tally.recount(), folder: tally.folder, generation: tally.generation)
    }

    /// Журнал принёс пачку. Ушедшее с места Spotlight может ещё числить — забыть сразу.
    /// На очереди `work`.
    private func arrivalsChanged(_ note: Notification, bases: [String], generation: Int) {
        guard let tally, tally.generation == generation else { return }
        let inside = { (path: String) in bases.contains { path.hasPrefix($0) } }
        let gone = (note.userInfo?["gone"] as? [String] ?? []).filter(inside)
        let paths = note.userInfo?["paths"] as? [String] ?? []
        if tally.forget(gone) || paths.contains(where: inside) { scheduleRecount() }
    }

    /// На очереди `work`.
    private func scheduleRecount() {
        guard !recountPending else { return }
        recountPending = true
        work.asyncAfter(deadline: .now() + Self.recountDelay) { [weak self] in
            guard let self else { return }
            self.recountPending = false
            guard let tally = self.tally else { return }
            self.deliver(tally.recount(), folder: tally.folder, generation: tally.generation)
        }
    }

    private func stopQuery() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        // Запрос живёт на своей очереди — там же и останавливается.
        if let query { queue.addOperation { query.stop() } }
        query = nil
    }

    func stop() {
        generation &+= 1
        renewal?.invalidate()
        renewal = nil
        stopQuery()
        stream?.stop()
        stream = nil
        if let arrivalsObserver { NotificationCenter.default.removeObserver(arrivalsObserver) }
        arrivalsObserver = nil
        work.async { [weak self] in self?.tally = nil }
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
        if let arrivalsObserver { NotificationCenter.default.removeObserver(arrivalsObserver) }
        if let query { queue.addOperation { query.stop() } }
        stream?.stop()
    }
}

/// Счёт нового по подпапкам для одного запроса: что знает Spotlight и что пришло по журналу.
/// Живёт на очереди запроса.
final class FolderNewsTally {
    let folder: String
    let since: Date
    let generation: Int
    /// Что нашёл Spotlight и что лежит на месте: путь → когда появился.
    private(set) var spotlight: [String: Date] = [:]
    /// Путь панели и настоящий — разные, если панель пришла по ссылке (/var → /private/var).
    private let bases: [String]
    private var delivered: [String: FolderNews.Inside]?

    init(folder: String, since: Date, generation: Int = 0) {
        self.folder = folder
        self.since = since
        self.generation = generation
        bases = FolderNewsArrivals.bases(of: folder)
    }

    /// Первый сбор — целиком.
    func gathered(from query: NSMetadataQuery) {
        query.disableUpdates()
        // Свойства берутся из того, что пришло с ответом (valueListAttributes), а не новыми
        // запросами к каждой находке. Путь в этот список не попадает — его знает сама находка,
        // и спросить её быстро.
        let found = Self.files(count: query.resultCount) { index, attribute in
            attribute == NSMetadataItemPathKey
                ? (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: attribute)
                : query.value(ofAttribute: attribute, forResultAt: index)
        }
        query.enableUpdates()
        spotlight = [:]
        take(found)
    }

    /// Обновление: добавленное и изменённое — поверх; если что-то удалили — сбор заново.
    func updated(by note: Notification, in query: NSMetadataQuery) {
        let info = note.userInfo ?? [:]
        if let removed = info[NSMetadataQueryUpdateRemovedItemsKey] as? [Any], !removed.isEmpty {
            gathered(from: query)
            return
        }
        let fresh = ((info[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? [])
            + ((info[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]) ?? [])
        take(Self.files(count: fresh.count) { fresh[$0].value(forAttribute: $1) })
    }

    /// Находки Spotlight — только то, что лежит на месте: о переносе он узнаёт с опозданием и
    /// долго числит файл там, откуда его унесли.
    func take(_ found: [(String, Date)]) {
        var info = stat()
        for (path, added) in found where lstat(path, &info) == 0 {
            spotlight[path] = max(spotlight[path] ?? added, added)
        }
    }

    /// Журнал сказал, что этих файлов на месте нет. Было что забыть — true.
    func forget(_ paths: [String]) -> Bool {
        var forgot = false
        for path in paths where spotlight.removeValue(forKey: path) != nil { forgot = true }
        return forgot
    }

    /// Счёт по объединению: Spotlight и журнал, один путь — один раз. nil — с прошлого раза
    /// ничего не поменялось, перерисовывать нечего.
    func recount() -> [String: FolderNews.Inside]? {
        var union: [String: Date] = [:]
        let found = spotlight.map { (path: $0.key, added: $0.value) }
            + FolderNewsArrivals.shared.entries(under: folder, since: since)
        for (path, added) in found where added >= since {
            let key = realSpelling(path)
            union[key] = max(union[key] ?? added, added)
        }
        let news = FolderNews.newsByChild(of: folder, found: union.map { ($0.key, $0.value) })
        guard news != delivered else { return nil }
        delivered = news
        return news
    }

    /// Один файл — одно написание: Spotlight и журнал дают настоящий путь, тесты и ссылки —
    /// как получится.
    private func realSpelling(_ path: String) -> String {
        guard bases.count == 2, path.hasPrefix(bases[0]) else { return path }
        return bases[1] + path.dropFirst(bases[0].count)
    }

    /// Что спрашивается у Spotlight о каждой находке — одним ответом (valueListAttributes).
    static let attributes = [NSMetadataItemPathKey, NSMetadataItemContentTypeKey, "kMDItemContentTypeTree",
                             "kMDItemDateAdded", "kMDItemFSContentChangeDate"]

    /// Файлы — не папки: новая пустая папка внутри ещё не «новые файлы». Пакет (.pages,
    /// программа) — как папка: новость — его появление, а не правка внутри. `value` — свойство
    /// находки по номеру.
    static func files(count: Int, value: (Int, String) -> Any?) -> [(String, Date)] {
        (0..<count).compactMap { index in
            guard let path = value(index, NSMetadataItemPathKey) as? String,
                  !FileNewness.isExcluded(path),
                  (value(index, NSMetadataItemContentTypeKey) as? String) != "public.folder"
            else { return nil }
            let types = value(index, "kMDItemContentTypeTree") as? [String] ?? []
            guard let date = FileNewness.date(
                added: value(index, "kMDItemDateAdded") as? Date,
                modified: value(index, "kMDItemFSContentChangeDate") as? Date,
                isFolder: types.contains("com.apple.package"))
            else { return nil }
            return (path, date)
        }
    }
}
