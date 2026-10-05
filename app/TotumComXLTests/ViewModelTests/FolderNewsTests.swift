import AppKit
import XCTest
@testable import TotumComXLApp

/// Знак «новое внутри» у папки: в ней, на любой глубине, появились файлы за срок правила
/// «любое имя». Что нового — говорит Spotlight; здесь проверяется всё, что вокруг ответа.
@MainActor
final class FolderNewsTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Акцент в тестах — бирюзовый: так знак легко узнать.
    private let teal = NSColor(red: 0, green: 0xC7 / 255.0, blue: 0xBE / 255.0, alpha: 1)
    private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    // MARK: - Ответ Spotlight → подпапки

    func test_новоеНаЛюбойГлубине_считаетсяПодпапкеВерхнегоУровня() {
        let found: [(path: String, added: Date)] = [
            ("/Users/me/Work/Проект/src/main.swift", ago(3)),
            ("/Users/me/Work/Проект/README.md", ago(1)),
            ("/Users/me/Work/Фото/2026/лето/1.jpg", ago(5)),
        ]
        let news = FolderNews.newsByChild(of: "/Users/me/Work", found: found)
        XCTAssertEqual(news["/Users/me/Work/Проект"], FolderNews.Inside(count: 2, newest: ago(1)),
                       "у каждой подпапки — сколько нового и самое свежее")
        XCTAssertEqual(news["/Users/me/Work/Фото"], FolderNews.Inside(count: 1, newest: ago(5)))
        XCTAssertEqual(news.count, 2)
    }

    func test_файлПрямоВПапке_неНовоеВнутри() {
        let found: [(path: String, added: Date)] = [("/Users/me/Work/заметка.txt", ago(1))]
        XCTAssertTrue(FolderNews.newsByChild(of: "/Users/me/Work", found: found).isEmpty,
                      "его и так видно: имя красится само")
    }

    func test_скрытоеИЧужоеНеСчитается() {
        let found: [(path: String, added: Date)] = [
            ("/Users/me/Work/Проект/.DS_Store", ago(1)),
            ("/Users/me/Work/Проект/.git/objects/ab", ago(1)),
            ("/Users/me/Work/.cache/x/y", ago(1)),
            ("/Users/me/Workshop/a/b", ago(1)),         // похоже начинается, но не та папка
            ("/Users/other/a/b", ago(1)),
        ]
        XCTAssertTrue(FolderNews.newsByChild(of: "/Users/me/Work", found: found).isEmpty)
        XCTAssertEqual(FolderNews.newsByChild(of: "/Users/me/Work/", found: [("/Users/me/Work/a/b", ago(1))]),
                       ["/Users/me/Work/a": FolderNews.Inside(count: 1, newest: ago(1))],
                       "косая черта в конце пути не мешает")
    }

    /// Spotlight отдаёт настоящие пути, а панель могла прийти по ссылке: /tmp — это /private/tmp.
    func test_путьЧерезСсылку_подпапкиПоПутиПанели() throws {
        let folder = "/tmp/fcxl-news-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let real = FolderNews.realPath(folder)
        XCTAssertTrue(real.hasPrefix("/private/tmp/"), real)
        let news = FolderNews.newsByChild(of: folder, found: [(real + "/a/b.txt", ago(1))])
        XCTAssertEqual(news, [folder + "/a": FolderNews.Inside(count: 1, newest: ago(1))],
                       "подпапка — по пути панели, не по настоящему")
    }

    func test_новыеНаходкиСкладываются() {
        let before = ["/w/a": FolderNews.Inside(count: 3, newest: ago(5)),
                      "/w/b": FolderNews.Inside(count: 1, newest: ago(1))]
        let after = FolderNews.adding(before, ["/w/a": FolderNews.Inside(count: 2, newest: ago(2)),
                                               "/w/c": FolderNews.Inside(count: 1, newest: ago(3))])
        XCTAssertEqual(after["/w/a"], FolderNews.Inside(count: 5, newest: ago(2)), "счёт сложился, дата — свежайшая")
        XCTAssertEqual(after["/w/b"], before["/w/b"])
        XCTAssertEqual(after["/w/c"], FolderNews.Inside(count: 1, newest: ago(3)))
    }

    // MARK: - Правило и знак

    private func rule(mask: String = "", minutes: Double? = 24 * 60, fades: Bool = true,
                      enabled: Bool = true) -> FileColorRule {
        FileColorRule(mask: mask, colorHex: "#00C7BE", darkColorHex: "#63E6E2",
                      isEnabled: enabled, freshMinutes: minutes, fades: fades)
    }

    func test_новизнаПоПервомуВключённомуПравилуЛюбоеИмяСоСроком() {
        let masked = rule(mask: "*.pdf")
        let disabled = rule(enabled: false)
        let noPeriod = rule(minutes: nil)
        let wanted = rule(minutes: 60)
        XCTAssertEqual(FolderNews.rule(in: [masked, disabled, noPeriod, wanted])?.id, wanted.id)
        XCTAssertNil(FolderNews.rule(in: [masked, disabled, noPeriod]), "нет такого правила — нет и знака")
    }

    private func folder(newest: Date?, count: Int = 3, name: String = "Проект",
                        directory: Bool = true) -> FileItem {
        var item = FileItem(path: "/Users/me/Work/" + name, name: name, fileExtension: "", size: 0,
                            isDirectory: directory, isHidden: false, isSymlink: false,
                            permissions: "755", dateModified: ago(100))
        item.newestInside = newest
        item.newInsideCount = newest == nil ? 0 : count
        return item
    }

    func test_знакТолькоУПапкиСНовымВСрок() {
        let r = rule()
        func sign(_ item: FileItem, rule: FileColorRule? = nil, enabled: Bool = true) -> FolderNews.Mark? {
            FolderNews.mark(for: item, rule: rule ?? r, enabled: enabled, color: teal, now: now)
        }
        XCTAssertNotNil(sign(folder(newest: ago(1))))
        XCTAssertNil(sign(folder(newest: nil)))
        XCTAssertNil(sign(folder(newest: ago(1), count: 0)), "нечего считать — нечего показывать")
        XCTAssertNil(sign(folder(newest: ago(25))), "срок вышел")
        XCTAssertNil(sign(folder(newest: ago(1)), enabled: false), "выключено")
        XCTAssertNil(FolderNews.mark(for: folder(newest: ago(1)), rule: nil, enabled: true, color: teal, now: now),
                     "нет правила")
        XCTAssertNil(sign(folder(newest: ago(1), name: "..")))
        XCTAssertNil(sign(folder(newest: ago(1), name: "a.txt", directory: false)))
        XCTAssertNil(sign(folder(newest: ago(1), name: "Почта.app")), "программа — не папка: знака нет")
    }

    func test_знакГаснетКакПравилоИКрасится_акцентом() throws {
        let fading = try XCTUnwrap(FolderNews.mark(for: folder(newest: ago(12)), rule: rule(), enabled: true,
                                                   color: teal, now: now))
        XCTAssertEqual(fading.strength, 0.5, accuracy: 0.001, "гаснущее правило: полсрока — полсилы")
        XCTAssertLessThan(fading.opacity, 1)
        XCTAssertGreaterThan(fading.opacity, 0.4, "к концу срока тише, но читается")
        XCTAssertEqual(FolderNews.mark(for: folder(newest: ago(12)), rule: rule(fades: false), enabled: true,
                                       color: teal, now: now)?.strength, 1, "негаснущее — в полную силу до конца срока")
        let purple = try XCTUnwrap(FolderNews.mark(for: folder(newest: ago(1)), rule: rule(), enabled: true,
                                                   color: .systemPurple, now: now))
        XCTAssertEqual(purple.color, .systemPurple, "цвет — тот, что дали (акцентный), а не цвет правила")
    }

    // MARK: - О каких папках спрашивать

    func test_оКакихПапкахСпрашиватьSpotlight() {
        XCTAssertTrue(FolderNews.canWatch("/Users/me/Downloads"))
        XCTAssertFalse(FolderNews.canWatch("/"), "ответом был бы весь диск")
        XCTAssertFalse(FolderNews.canWatch(NSTemporaryDirectory()), "системную временную он не индексирует")
        XCTAssertFalse(FolderNews.canWatch(NSTemporaryDirectory() + "x/y"))
        XCTAssertFalse(FolderNews.canWatch("/var/folders/ab/cd/T/x"))
        XCTAssertFalse(FolderNews.canWatch("/Users/me/.config/x"), "скрытое не индексируется")
        XCTAssertFalse(FolderNews.canWatch("STACK"), "не путь")
    }

    // MARK: - Счётчик

    func test_счётчикПишетСколькоНового() {
        XCTAssertEqual(FolderNewsChip.text(count: 12), "+12")
        XCTAssertEqual(FolderNewsChip.text(count: 1), "+1")
        XCTAssertEqual(FolderNewsChip.text(count: 25_000), "+999", "длиннее плашке быть незачем")
    }

    func test_безНовогоШиринаНулевая_именемНичегоНеОтнято() throws {
        let font = NSFont.systemFont(ofSize: 12)
        XCTAssertEqual(FolderNewsChip.width(count: 0, font: font), 0)
        let mark = FolderNews.Mark(color: teal, strength: 1)
        XCTAssertNil(FolderNewsChip.image(count: 0, mark: mark, font: font))
        let chip = try XCTUnwrap(FolderNewsChip.image(count: 12, mark: mark, font: font))
        XCTAssertEqual(chip.size.width, FolderNewsChip.width(count: 12, font: font), accuracy: 0.5,
                       "ширина колонки — ровно по плашке")
        XCTAssertGreaterThan(FolderNewsChip.width(count: 123, font: font),
                             FolderNewsChip.width(count: 1, font: font), "больше цифр — шире")
        XCTAssertNotNil(FolderNewsChip.plaqueImage(count: 12, mark: mark, font: font))
    }

    // MARK: - В панели

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fcxl-news-\(UUID().uuidString)")
        for sub in ["Проект/src", "Фото"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("заметка.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func panel() -> PanelViewModel {
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: root.path,
                                pathDefaultsKey: "news.\(UUID().uuidString)",
                                viewModeDefaultsKey: "newsm.\(UUID().uuidString)", showHiddenFiles: true)
        let deadline = Date().addingTimeInterval(5)
        while vm.allItems.count < 3, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return vm
    }

    private func news(_ vm: PanelViewModel, _ name: String) -> FolderNews.Inside? {
        guard let item = vm.allItems.first(where: { $0.name == name }), let newest = item.newestInside else { return nil }
        return FolderNews.Inside(count: item.newInsideCount, newest: newest)
    }

    func test_ответSpotlightРасходитсяПоПапкамИПереживаетПеречитку() throws {
        let vm = panel()
        XCTAssertNil(vm.folderNewsQuery, "модель без экрана Spotlight не спрашивает")
        let project = root.appendingPathComponent("Проект").path
        let inside = FolderNews.Inside(count: 4, newest: ago(2))
        vm.applyFolderNews([project: inside], in: vm.currentPath)
        XCTAssertEqual(news(vm, "Проект"), inside)
        XCTAssertNil(news(vm, "Фото"))
        XCTAssertNil(news(vm, "заметка.txt"))

        vm.reloadKeepingCursor()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(news(vm, "Проект"), inside, "перечитка той же папки знак не гасит")

        vm.applyFolderNews([:], in: vm.currentPath)
        XCTAssertNil(news(vm, "Проект"), "нового больше нет — знак гаснет")
        XCTAssertEqual(vm.allItems.first { $0.name == "Проект" }?.newInsideCount, 0)
    }

    func test_ответОДругойПапкеОтбрасывается() {
        let vm = panel()
        vm.applyFolderNews([root.appendingPathComponent("Проект").path: FolderNews.Inside(count: 1, newest: ago(1))],
                           in: "/Users/me/Elsewhere")
        XCTAssertNil(news(vm, "Проект"))
    }

    func test_размерПапкиНеСтираетЗнак() {
        let item = folder(newest: ago(1), count: 7)
        XCTAssertEqual(item.withSize(1024).newestInside, ago(1))
        XCTAssertEqual(item.withSize(1024).newInsideCount, 7)
        XCTAssertEqual(item.withSize(1024).size, 1024)
    }
}
