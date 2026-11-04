import AppKit
import Foundation
import os

extension Notification.Name {
    /// Posted when a check changes whether a newer release is known.
    static let fcxlUpdateAvailabilityChanged = Notification.Name("com.fcxl.updateAvailabilityChanged")
}

/// A look at GitHub for a newer release at every launch and every three days while the program
/// stays open — and a word about it, nothing more.
///
/// No Sparkle, no keys, no server: GitHub's releases API is open, one anonymous request
/// brings the list of releases, and the ones newer than the running version show in the
/// Updates section of Settings — with their notes and a count beside the section — and as a
/// dot on the toolbar's Settings button.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable, Codable {
        /// "1.1" — the tag without its "v".
        let version: String
        /// The release page, where the DMG is.
        let url: URL
        /// Что нового — текст выпуска с GitHub, обе половины: английская и русская.
        var notes: String = ""
        var published: Date?
    }

    static let enabledKey = "fcxl.updates.check"
    /// Вопрос «проверять ли» задан. Первый выход в сеть — только с разрешения.
    static let askedKey = "fcxl.updates.asked"
    static let lastCheckKey = "fcxl.updates.lastCheck"
    static let latestVersionKey = "fcxl.updates.latestVersion"
    static let latestURLKey = "fcxl.updates.latestURL"
    /// Выпуски новее установленной версии на момент проверки, с заметками: что показать в
    /// разделе и сколько их. Записи прошлых версий программы этого ключа не знают.
    static let newerKey = "fcxl.updates.newer"
    /// A hook for LOOKING at the notice without publishing a release: the version the program
    /// pretends to run. `defaults write com.fcxl.filecommander fcxl.updates.pretendVersion 0.9`
    static let pretendVersionKey = "fcxl.updates.pretendVersion"
    static let interval: TimeInterval = 3 * 24 * 60 * 60
    static let latestURL = URL(string: "https://api.github.com/repos/\(AppIdentity.repositorySlug)/releases/latest")!
    /// Тридцать последних выпусков — больше пропустить не выйдет: число у раздела честное.
    static let listURL = URL(string: "https://api.github.com/repos/\(AppIdentity.repositorySlug)/releases?per_page=30")!

    /// Самый новый выпуск, если он новее установленного, — его ставит «Обновить».
    @Published private(set) var available: Release?
    /// Все выпуски новее установленного, новые сверху. Их число стоит у раздела «Обновления».
    @Published private(set) var newer: [Release] = []
    @Published private(set) var lastChecked: Date?

    private let defaults: UserDefaults
    private let fetch: () async throws -> Data
    /// Как спросить разрешение. Подменяется в тестах; в программе — своё окно.
    var askPermission: @MainActor () async -> Bool = UpdateChecker.askInDialog
    private var timer: Timer?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander",
                                category: "Updates")

    init(defaults: UserDefaults = .standard,
         fetch: @escaping () async throws -> Data = UpdateChecker.fetchListFromGitHub) {
        self.defaults = defaults
        self.fetch = fetch
        lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date
        // What the last check found, so Settings can say it before today's check has run.
        recomputeAvailability()
    }

    /// Спрашивать ли, прежде чем впервые пойти в сеть: пока не спрашивали и человек сам не
    /// решил в «Основных». Кто уже поставил галочку или снял её, вопроса не увидит.
    static func needsQuestion(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: askedKey) && defaults.object(forKey: enabledKey) == nil
    }

    /// Окно вопроса — в стиле программы, с тем же пояснением, что в настройках.
    @MainActor
    static func askInDialog() async -> Bool {
        await fcxlPresentModalAsync {
            let choice = FCXLMessageDialog.run(FCXLMessageConfig(
                title: L("updates.ask.title"),
                message: L("settings.updates.hint"),
                icon: "arrow.down.circle",
                iconColor: PanelAppearanceSettings.accentColor,
                buttons: [
                    FCXLMessageButton(title: L("updates.ask.no")),
                    FCXLMessageButton(title: L("updates.ask.yes"), kind: .primary)
                ]))
            return choice.buttonIndex == 1
        }
    }

    /// On by default; the General settings can switch it off.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The version the program runs — or pretends to, for a look at the notice.
    static func currentVersion(_ defaults: UserDefaults = .standard) -> String {
        if let pretend = defaults.string(forKey: pretendVersionKey), !pretend.isEmpty { return pretend }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    // MARK: - Versions

    /// "v1.0.1" → [1, 0, 1]. Anything that is not a number counts as 0.
    static func components(of version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        return text.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Whether `candidate` is a later version than `current`: "1.1" is newer than "1.0.9",
    /// "1.0" is not newer than "1.0.0" — missing parts are zeros.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        var a = components(of: candidate), b = components(of: current)
        let width = max(a.count, b.count)
        a += Array(repeating: 0, count: width - a.count)
        b += Array(repeating: 0, count: width - b.count)
        for (x, y) in zip(a, b) where x != y { return x > y }
        return false
    }

    // MARK: - GitHub's answer

    /// The release in GitHub's `releases/latest` answer: its tag and page.
    static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return release(from: json)
    }

    /// Выпуски из ответа `releases`, новые по номеру сверху. Черновик и предвыпуск — не
    /// новость для того, кто ставит программу. Одиночный ответ — список из одного.
    static func releases(from data: Data) -> [Release] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items = (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
        return items
            .filter { ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true }
            .compactMap(release(from:))
            .sorted { isNewer($0.version, than: $1.version) }
    }

    private static func release(from json: [String: Any]) -> Release? {
        guard let tag = json["tag_name"] as? String, !tag.isEmpty,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        var version = tag
        if version.lowercased().hasPrefix("v") { version.removeFirst() }
        let published = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: version, url: page, notes: json["body"] as? String ?? "", published: published)
    }

    /// Последний выпуск с его файлами — то, что скачивает «Обновить».
    static func fetchFromGitHub() async throws -> Data {
        try await fetch(latestURL)
    }

    /// Список выпусков — то, что сверяет проверка.
    static func fetchListFromGitHub() async throws -> Data {
        try await fetch(listURL)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TotumCommander", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Policy

    /// A check is due every three days; never checked — due now.
    static func isDue(now: Date, last: Date?, interval: TimeInterval = interval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Start the rhythm: a check at once — a new version is seen the day it comes out, not up
    /// to three days later — then a check when due, re-asked every hour so a Mac that never
    /// sleeps still checks on time, and one that was asleep checks on waking.
    func start() {
        Task { await checkIfDue(atLaunch: true) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkIfDue() }
        }
    }

    /// Проверить, если пора. При запуске пора всегда; пока программа открыта — раз в три дня.
    func checkIfDue(atLaunch: Bool = false) async {
        // При первом запуске программа не лезет к GitHub молча — один раз спрашивает. Ответ
        // ложится в ту же настройку из «Основных», и дальше всё как обычно. Так ни один
        // файрвол не спросит о соединении, которого человек не разрешал.
        if Self.needsQuestion(defaults) {
            let allowed = await askPermission()
            defaults.set(true, forKey: Self.askedKey)
            defaults.set(allowed, forKey: Self.enabledKey)
        }
        guard Self.isEnabled(defaults), atLaunch || Self.isDue(now: Date(), last: lastChecked) else { return }
        _ = await checkNow()
    }

    /// Ask GitHub now. Answers the newer release, if there is one; a failed request changes
    /// nothing and is only logged — a missing network is not news.
    @discardableResult
    func checkNow() async -> Release? {
        do {
            let data = try await fetch()
            let releases = Self.releases(from: data)
            guard let latest = releases.first else {
                logger.error("update.check: unreadable answer")
                return available
            }
            defaults.set(latest.version, forKey: Self.latestVersionKey)
            defaults.set(latest.url.absoluteString, forKey: Self.latestURLKey)
            // Хранится только новое: у установленной версии заметки уже не нужны, а тридцать
            // текстов выпусков в настройках — лишний вес.
            let current = Self.currentVersion(defaults)
            let unseen = releases.filter { Self.isNewer($0.version, than: current) }
            defaults.set(try? JSONEncoder().encode(unseen), forKey: Self.newerKey)
            let now = Date()
            defaults.set(now, forKey: Self.lastCheckKey)
            lastChecked = now
            recomputeAvailability()
            logger.notice("update.check current=\(current, privacy: .public) latest=\(latest.version, privacy: .public) newer=\(self.newer.count, privacy: .public)")
        } catch {
            logger.error("update.check failed: \(error.localizedDescription, privacy: .public)")
        }
        return available
    }

    /// From what is stored: the releases that beat the running version, newest first. After an
    /// update the same record gives fewer of them — the installed one and older drop out.
    private func recomputeAvailability() {
        let before = newer
        let current = Self.currentVersion(defaults)
        if let data = defaults.data(forKey: Self.newerKey),
           let stored = try? JSONDecoder().decode([Release].self, from: data) {
            newer = stored.filter { Self.isNewer($0.version, than: current) }
        } else if let version = defaults.string(forKey: Self.latestVersionKey),
                  let url = defaults.string(forKey: Self.latestURLKey).flatMap(URL.init(string:)),
                  Self.isNewer(version, than: current) {
            // Записано прошлой версией программы: известен только последний выпуск.
            newer = [Release(version: version, url: url)]
        } else {
            newer = []
        }
        available = newer.first
        if newer != before {
            NotificationCenter.default.post(name: .fcxlUpdateAvailabilityChanged, object: nil)
        }
    }
}
