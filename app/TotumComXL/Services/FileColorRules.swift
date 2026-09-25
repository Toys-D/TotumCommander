import AppKit
import Combine

/// Цвет имени файла по правилу — как в Total Commander и Directory Opus: маска, цвет,
/// порядок. Первое подошедшее правило и красит, поэтому частное человек ставит выше общего.
///
/// Правило про СВЕЖЕСТЬ — то же самое плюс срок: «моложе суток». В остальных программах
/// такой цвет держится ровно до истечения срока и пропадает разом; здесь он может гаснуть
/// постепенно, и тогда «полчаса назад» и «вчера вечером» отличаются на глаз, а не по
/// столбцу с датой.
struct FileColorRule: Codable, Equatable, Identifiable {

    var id: UUID
    /// Маска имени: `*.dmg`, можно несколько через `;`. Пусто — правило ловит всё,
    /// что имеет смысл только вместе со сроком свежести.
    var mask: String
    /// Цвет для СВЕТЛОЙ темы.
    var colorHex: String
    /// Цвет для ТЁМНОЙ темы. Пусто — берётся светлый: то, что читается на белом, на чёрном
    /// обычно теряется, и наоборот, поэтому цвет запоминается для каждой темы отдельно.
    var darkColorHex: String
    var isEnabled: Bool
    /// Сколько МИНУТ файл считается свежим. nil — правило про тип, возраст ему безразличен.
    ///
    /// В минутах, потому что сроки бывают короткие: «подсветить то, что появилось за
    /// последние двадцать минут» — обычная просьба при разборе загрузок, а в часах её
    /// не выразить.
    var freshMinutes: Double?
    /// Гаснуть постепенно, а не пропадать разом в конце срока.
    var fades: Bool

    init(id: UUID = UUID(), mask: String, colorHex: String, darkColorHex: String = "",
         isEnabled: Bool = true, freshMinutes: Double? = nil, fades: Bool = false) {
        self.id = id
        self.mask = mask
        self.colorHex = colorHex
        self.darkColorHex = darkColorHex
        self.isEnabled = isEnabled
        self.freshMinutes = freshMinutes
        self.fades = fades
    }

    /// Цвет для темы, в которой сейчас рисуют. Тёмного нет — светлый годится и там.
    func color(dark: Bool) -> NSColor? {
        if dark, !darkColorHex.isEmpty {
            return PanelAppearanceSettings.optionalNSColor(from: darkColorHex)
        }
        return PanelAppearanceSettings.optionalNSColor(from: colorHex)
    }

    /// Правило про свежесть — у него есть срок.
    var isFreshness: Bool { freshMinutes != nil }

    enum CodingKeys: String, CodingKey {
        case id, mask, colorHex, darkColorHex, isEnabled, freshMinutes, freshHours, fades
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        mask = try box.decode(String.self, forKey: .mask)
        colorHex = try box.decode(String.self, forKey: .colorHex)
        // Правила, записанные до разделения тем, читаются как были: один цвет на обе.
        darkColorHex = try box.decodeIfPresent(String.self, forKey: .darkColorHex) ?? ""
        isEnabled = try box.decode(Bool.self, forKey: .isEnabled)
        fades = try box.decode(Bool.self, forKey: .fades)
        // Сроки раньше хранились в часах — правила, записанные тогда, читаются как были.
        if let minutes = try box.decodeIfPresent(Double.self, forKey: .freshMinutes) {
            freshMinutes = minutes
        } else if let hours = try box.decodeIfPresent(Double.self, forKey: .freshHours) {
            freshMinutes = hours * 60
        } else {
            freshMinutes = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(mask, forKey: .mask)
        try box.encode(colorHex, forKey: .colorHex)
        try box.encode(darkColorHex, forKey: .darkColorHex)
        try box.encode(isEnabled, forKey: .isEnabled)
        try box.encode(fades, forKey: .fades)
        try box.encodeIfPresent(freshMinutes, forKey: .freshMinutes)
    }

    // MARK: - Совпадение

    static func patterns(in mask: String) -> [String] {
        mask.split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Подходит ли имя под маску. Пустая маска подходит любому имени — это правило
    /// «про всё», годное только вместе со сроком.
    func matches(fileName: String) -> Bool {
        let list = Self.patterns(in: mask)
        guard !list.isEmpty else { return true }
        let name = fileName.lowercased()
        // Через fnmatch, как маски понимает оболочка: кто написал `*.[ch]`, получит ровно
        // то, что ожидал.
        return list.contains { fnmatch($0, name, 0) == 0 }
    }

    /// Насколько правило красит этот файл: 0 — не красит вовсе, 1 — в полную силу.
    /// Между ними — гаснущая свежесть.
    func strength(age: TimeInterval) -> Double {
        guard let freshMinutes else { return 1 }
        let limit = freshMinutes * 60
        guard limit > 0, age >= 0, age < limit else { return 0 }
        guard fades else { return 1 }
        // Ровное угасание от полной силы к обычному цвету. Без «полки» в начале: она
        // делала первые часы неотличимыми друг от друга, а весь смысл — видеть разницу
        // между «только что» и «утром».
        return max(0, 1 - age / limit)
    }
}

/// Список правил раскраски.
final class FileColorRulesStore: ObservableObject {

    static let shared = FileColorRulesStore()

    /// Больше этого список перестаёт быть списком.
    static let maxRules = 100

    private let defaults: UserDefaults
    private let defaultsKey: String

    @Published private(set) var rules: [FileColorRule] = []

    /// Счётчик перекрасок. Меняется при правке правил и на каждом шаге угасания.
    ///
    /// Нужен кратким видам: там цвет запоминается в ячейке, а ячейка перенастраивается
    /// только когда меняется её содержимое. Гаснущий цвет содержимого не меняет — он
    /// зависит от времени, — и без этого счётчика имя оставалось того цвета, каким его
    /// нарисовали при первом показе, до самого щелчка по панели.
    private(set) var generation: Int = 0

    /// Пора перекрашивать: время идёт, цвет гаснущего правила изменился.
    func markRepaint() { generation &+= 1 }

    init(defaults: UserDefaults = .standard, key: String = "fcxl.fileColorRules") {
        self.defaults = defaults
        self.defaultsKey = key
        if defaults.data(forKey: key) == nil {
            // Первый запуск: набор ставится сам. Пустой список означал бы, что цвета,
            // которые в программе были всегда, вдруг пропали — а человек ничего не делал.
            rules = Self.starterRules
            save()
        } else {
            rules = Self.read(from: defaults, key: key)
        }
    }

    // MARK: - Хранение

    private static func read(from defaults: UserDefaults, key: String) -> [FileColorRule] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([FileColorRule].self, from: data)
        else { return [] }
        return Array(list.prefix(maxRules))
    }

    private func save() {
        generation &+= 1
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: .fcxlFileColorsChanged, object: nil)
    }

    func replaceAll(_ list: [FileColorRule]) {
        rules = Array(list.prefix(Self.maxRules))
        save()
    }

    func add(_ rule: FileColorRule) {
        guard rules.count < Self.maxRules else { return }
        rules.append(rule)
        save()
    }

    func update(_ rule: FileColorRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Есть ли правило, чей цвет зависит от времени — тогда список надо иногда
    /// перекрашивать сам по себе, без всяких событий файловой системы.
    var hasFreshnessRule: Bool {
        rules.contains { $0.isEnabled && $0.isFreshness }
    }

    /// Самый короткий срок среди гаснущих правил, в минутах.
    var shortestFadingMinutes: Double? {
        rules.filter { $0.isEnabled && $0.fades }
            .compactMap(\.freshMinutes)
            .min()
    }

    /// Как часто перекрашивать список, чтобы угасание было видно, но не жечь силы зря.
    ///
    /// Шаг привязан к самому короткому сроку: при пяти минутах десятиминутный таймер
    /// бесполезен — цвет успевал пропасть раньше первого тика. Двадцать шагов на весь срок
    /// дают плавность, ниже пятнадцати секунд опускаться незачем: глаз такой разницы в
    /// оттенке не ловит.
    var repaintInterval: TimeInterval? {
        guard hasFreshnessRule else { return nil }
        guard let shortest = shortestFadingMinutes else { return 600 }
        return min(600, max(15, shortest * 60 / 20))
    }

    // MARK: - Цвет

    /// Каким цветом писать имя этого файла, или nil — обычным.
    ///
    /// `base` нужен для гаснущей свежести: цвет правила смешивается с обычным по мере того,
    /// как файл стареет.
    func color(for item: FileItem, base: NSColor, dark: Bool = FileColorRulesStore.isDarkNow,
               now: Date = Date()) -> NSColor? {
        for rule in rules where rule.isEnabled {
            guard let color = rule.color(dark: dark),
                  rule.matches(fileName: item.name) else { continue }
            // Возраст — по тому, когда файл ПОЯВИЛСЯ В ЭТОЙ ПАПКЕ, а не когда его создали.
            // Скопированный сюда файл приносит с собой старые даты создания и изменения:
            // снимок с прошлогодней камеры, только что положенный в папку, — новый здесь,
            // и покрасить его надо как новый. Дату добавления ведёт сама macOS
            // (addedToDirectoryDate); если том её не хранит, остаются обычные даты.
            let appeared = item.dateAdded ?? item.dateCreated ?? item.dateModified
            let age = now.timeIntervalSince(appeared)
            let strength = rule.strength(age: age)
            guard strength > 0 else { continue }
            return strength >= 1 ? color : FileColorRulesStore.blend(color, into: base,
                                                                     amount: strength)
        }
        return nil
    }

    /// Тёмная ли сейчас тема. NSApp в тестах нет, поэтому спрашивается и текущая
    /// отрисовочная внешность.
    static var isDarkNow: Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Смешать цвет правила с обычным цветом имени.
    static func blend(_ color: NSColor, into base: NSColor, amount: Double) -> NSColor {
        let space = NSColorSpace.deviceRGB
        guard let a = color.usingColorSpace(space), let b = base.usingColorSpace(space) else {
            return color
        }
        let t = CGFloat(max(0, min(1, amount)))
        return NSColor(deviceRed: a.redComponent * t + b.redComponent * (1 - t),
                       green: a.greenComponent * t + b.greenComponent * (1 - t),
                       blue: a.blueComponent * t + b.blueComponent * (1 - t),
                       alpha: a.alphaComponent * t + b.alphaComponent * (1 - t))
    }

    // MARK: - Готовый набор

    /// Набор по умолчанию — ровно тот расклад, что раньше был зашит в код (и работал
    /// только в кратком виде), плюс правило про свежесть. У каждого правила свой цвет для
    /// светлой и для тёмной темы: коричневый архив, спокойный на белом, на чёрном фоне
    /// тонет, а яркий на чёрном режет глаз на белом. Так у того, кто ничего не
    /// настраивал, цвета остались прежними — и появились в подробном списке, где их не было.
    static var starterRules: [FileColorRule] {
        [
            FileColorRule(mask: "",
                          colorHex: "#00C7BE", darkColorHex: "#63E6E2", freshMinutes: 24 * 60, fades: true),
            FileColorRule(mask: "*.app;*.dmg;*.pkg;*.command;*.bin;*.run;*.exe",
                          colorHex: "#FF9500", darkColorHex: "#FF9F0A"),
            FileColorRule(mask: "*.zip;*.rar;*.7z;*.tar;*.gz;*.bz2;*.xz;*.tgz;*.tbz;*.txz",
                          colorHex: "#A2845E", darkColorHex: "#C0A080"),
            FileColorRule(mask: "*.png;*.jpg;*.jpeg;*.gif;*.webp;*.heic;*.bmp;*.tiff;*.svg;*.avif",
                          colorHex: "#007AFF", darkColorHex: "#0A84FF"),
            FileColorRule(mask: "*.mp3;*.aac;*.wav;*.flac;*.ogg;*.m4a",
                          colorHex: "#AF52DE", darkColorHex: "#BF5AF2"),
            FileColorRule(mask: "*.mp4;*.mov;*.mkv;*.avi;*.webm;*.m4v",
                          colorHex: "#FF2D55", darkColorHex: "#FF375F"),
            FileColorRule(mask: "*.pdf", colorHex: "#FF3B30", darkColorHex: "#FF453A"),
            // Книг в прежнем раскладе не было — их и читать было нечем.
            FileColorRule(mask: "*.djvu;*.djv;*.epub;*.fb2;*.fbz",
                          colorHex: "#5E5CE6", darkColorHex: "#7D7AFF"),
            FileColorRule(mask: "*.txt;*.rtf;*.log",
                          colorHex: "#34C759", darkColorHex: "#30D158"),
            FileColorRule(mask: "*.swift;*.m;*.mm;*.h;*.hpp;*.c;*.cc;*.cpp;*.cxx;*.go;*.rs;*.py;*.js;*.ts;*.tsx;*.jsx;*.java;*.kt;*.rb;*.php;*.cs;*.json;*.yaml;*.yml;*.toml;*.xml;*.html;*.css;*.scss;*.md;*.sh;*.zsh;*.bash",
                          colorHex: "#30B0C7", darkColorHex: "#5AC8DE"),
        ]
    }

}

/// В чём человек задаёт срок свежести.
enum FreshnessUnit: String, CaseIterable, Identifiable, Hashable {
    case minutes, hours, days

    var id: String { rawValue }

    var minutes: Double {
        switch self {
        case .minutes: return 1
        case .hours:   return 60
        case .days:    return 60 * 24
        }
    }

    var title: String {
        switch self {
        case .minutes: return L("colors.rules.unit.minutes")
        case .hours:   return L("colors.rules.unit.hours")
        case .days:    return L("colors.rules.unit.days")
        }
    }

    /// Самая крупная единица, в которой срок остаётся круглым числом: 1440 минут — это
    /// «1 день», а не «1440 минут».
    static func best(for minutes: Double) -> FreshnessUnit {
        if minutes >= 60 * 24, minutes.truncatingRemainder(dividingBy: 60 * 24) == 0 { return .days }
        if minutes >= 60, minutes.truncatingRemainder(dividingBy: 60) == 0 { return .hours }
        return .minutes
    }
}

extension Notification.Name {
    static let fcxlFileColorsChanged = Notification.Name("fcxl.fileColorsChanged")
}
