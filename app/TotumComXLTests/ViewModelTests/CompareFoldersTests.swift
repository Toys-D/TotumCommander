import XCTest
@testable import TotumComXLApp

/// Папки в сравнении: стрелка по файлам внутри, щелчок на всё содержимое, пустые папки
/// создаются на другой стороне.
final class CompareFoldersTests: XCTestCase {

    private func file(_ path: String, left: UInt64? = 1, right: UInt64? = nil,
                      status: CompareStatus) -> CompareEntry {
        CompareEntry(relativePath: path, status: status, isDirectory: false,
                     leftSize: left, rightSize: right, leftDate: nil, rightDate: nil)
    }

    private func folder(_ path: String, status: CompareStatus) -> CompareEntry {
        CompareEntry(relativePath: path, status: status, isDirectory: true,
                     leftSize: nil, rightSize: nil, leftDate: nil, rightDate: nil)
    }

    private var entries: [CompareEntry] {
        [folder("1", status: .leftOnly),
         folder("1/source", status: .leftOnly),
         file("1/source/a.png", status: .leftOnly),
         file("1/source/b.png", status: .leftOnly),
         folder("2", status: .same),
         file("2/x.txt", left: 1, right: 1, status: .same),
         file("2/y.txt", left: nil, right: 1, status: .rightOnly),
         folder("пустая", status: .rightOnly),
         file("10.txt", status: .leftOnly)]
    }

    func test_файлыВнутриПапкиНаЛюбойГлубине() {
        let inside = CompareFolders.files(in: "1", of: entries).map(\.relativePath)
        XCTAssertEqual(inside, ["1/source/a.png", "1/source/b.png"])
        XCTAssertTrue(CompareFolders.files(in: "пустая", of: entries).isEmpty)
        XCTAssertFalse(CompareFolders.isInside("10.txt", folder: "1"), "«1» — не приставка «10»")
    }

    /// Папка только слева едет вправо сама, только справа — влево, общая — никуда.
    func test_собственноеНаправлениеПапки() {
        XCTAssertEqual(folder("1", status: .leftOnly).defaultDirection, .toRight)
        XCTAssertEqual(folder("п", status: .rightOnly).defaultDirection, .toLeft)
        XCTAssertEqual(folder("2", status: .same).defaultDirection, .none)
    }

    func test_папкиНадПутём() {
        XCTAssertEqual(CompareFolders.ancestors(of: "1/source/a.png"), ["1", "1/source"])
        XCTAssertEqual(CompareFolders.ancestors(of: "10.txt"), [])
    }

    /// Сводка одним проходом: файлы считаются в каждой папке над ними, стороны и направление.
    func test_сводкаПоПапкам() {
        let stats = CompareFolders.stats(files: entries) { $0.defaultDirection }
        XCTAssertEqual(stats["1"], .init(files: 2, hasLeft: true, hasRight: false, direction: .toRight, mixed: false))
        XCTAssertEqual(stats["1/source"]?.files, 2)
        XCTAssertEqual(stats["2"], .init(files: 2, hasLeft: true, hasRight: true, direction: nil, mixed: true),
                       "x — никуда, y — влево: вразнобой")
        XCTAssertNil(stats["пустая"], "без файлов — без сводки")
    }

    /// Стрелка папки — по сводке: все в одну сторону — она; вразнобой — нет стрелки; без
    /// файлов — собственная.
    func test_стрелкаПапкиПоФайлам() {
        let stats = CompareFolders.stats(files: entries) { $0.defaultDirection }
        XCTAssertEqual(CompareFolders.direction(own: .none, stat: stats["1"]), .toRight)
        XCTAssertNil(CompareFolders.direction(own: .none, stat: stats["2"]), "вразнобой")
        XCTAssertEqual(CompareFolders.direction(own: .toLeft, stat: stats["пустая"]), .toLeft, "пустая — своя")
    }

    /// Круг щелчка: только туда, откуда есть что везти, и «не трогать».
    func test_кругЩелчкаПоПапке() {
        let stats = CompareFolders.stats(files: entries) { $0.defaultDirection }
        XCTAssertEqual(CompareFolders.cycle(for: folder("1", status: .leftOnly), stat: stats["1"]), [.toRight, .none],
                       "справа файлов нет — влево нечего везти")
        XCTAssertEqual(CompareFolders.cycle(for: folder("2", status: .same), stat: stats["2"]), [.toRight, .toLeft, .none])
        XCTAssertEqual(CompareFolders.cycle(for: folder("пустая", status: .rightOnly), stat: nil), [.toLeft, .none],
                       "пустая справа — только влево")
        XCTAssertEqual(CompareFolders.next(after: .toRight, in: [.toRight, .toLeft, .none]), .toLeft)
        XCTAssertEqual(CompareFolders.next(after: .none, in: [.toRight, .none]), .toRight, "по кругу")
        XCTAssertEqual(CompareFolders.next(after: nil, in: [.toRight, .none]), .toRight, "смешанное — с начала")
    }

    /// «→» для папки: файлы с источником слева едут, файл только справа — не трогается.
    func test_направлениеФайламВнутри() {
        let two = CompareFolders.files(in: "2", of: entries)
        XCTAssertEqual(CompareFolders.fileDirections(for: .toRight, files: two),
                       ["2/x.txt": .toRight, "2/y.txt": .none])
        XCTAssertEqual(CompareFolders.fileDirections(for: .toLeft, files: two),
                       ["2/x.txt": .toLeft, "2/y.txt": .toLeft])
        XCTAssertEqual(CompareFolders.fileDirections(for: .none, files: two),
                       ["2/x.txt": .none, "2/y.txt": .none])
    }

    /// Создаются только пустые папки, и только там, где их нет; папка с файлами приедет с
    /// ними, а спрятанная маской не считается пустой.
    func test_пустыеПапкиСоздаются() {
        let folders = entries.filter(\.isDirectory)
        let nonEmpty = CompareFolders.nonEmptyFolders(entries: entries)
        XCTAssertEqual(nonEmpty, ["1", "1/source", "2"])
        let created = CompareFolders.creations(folders: folders, nonEmpty: nonEmpty) { $0.defaultDirection }
        XCTAssertEqual(created.left, ["пустая"])
        XCTAssertTrue(created.right.isEmpty, "«1» и «1/source» приедут со своими файлами")

        // Маска спрятала файлы из «1» — в списке она без файлов, но по всем записям не пуста.
        let filtered = entries.filter { !$0.relativePath.hasSuffix(".png") }
        let again = CompareFolders.creations(folders: filtered.filter(\.isDirectory), nonEmpty: nonEmpty) { $0.defaultDirection }
        XCTAssertTrue(again.right.isEmpty, "не пуста на самом деле — не создаём вхолостую")

        // Не трогать — не создаётся.
        let none = CompareFolders.creations(folders: folders, nonEmpty: nonEmpty) { _ in .none }
        XCTAssertTrue(none.left.isEmpty && none.right.isEmpty)
    }

    /// Двадцать пять тысяч записей, как у человека: сводка, пустые папки и план — за доли
    /// секунды, а не за секунды. Раньше каждая строка папки перебирала весь список.
    func test_большойСписокСчитаетсяБыстро() {
        var big: [CompareEntry] = []
        for folderIndex in 0..<1000 {
            big.append(folder("f\(folderIndex)", status: .leftOnly))
            big.append(folder("f\(folderIndex)/sub", status: .leftOnly))
            for fileIndex in 0..<23 {
                big.append(file("f\(folderIndex)/sub/file\(fileIndex).png", status: .leftOnly))
            }
        }
        XCTAssertEqual(big.count, 25_000)
        let start = Date()
        let stats = CompareFolders.stats(files: big) { $0.defaultDirection }
        let nonEmpty = CompareFolders.nonEmptyFolders(entries: big)
        let created = CompareFolders.creations(folders: big.filter(\.isDirectory), nonEmpty: nonEmpty) { $0.defaultDirection }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(stats.count, 2000)
        XCTAssertTrue(created.right.isEmpty)
        XCTAssertLessThan(elapsed, 0.5, "сводка по 25 000 записям: \(elapsed) с")
    }

    func test_планСчитаетСозданияПапок() {
        let plan = DirectorySyncPlan(toRight: ["a"], toLeft: [], moveRight: [], moveLeft: [],
                                     deleteLeft: [], deleteRight: [], leftRoot: "/l", rightRoot: "/r",
                                     createRight: [], createLeft: ["пустая"])
        XCTAssertEqual(plan.creations, 1)
        XCTAssertEqual(plan.total, 2)
    }

    // MARK: - Уровни, как в проводнике

    /// Сдвиг по глубине; имя одно, когда папка над ним видна, иначе полный путь.
    func test_уровниИПодписи() {
        XCTAssertEqual(CompareFolders.depth(of: "10.txt"), 0)
        XCTAssertEqual(CompareFolders.depth(of: "1/source/a.png"), 2)
        XCTAssertEqual(CompareFolders.parent(of: "1/source/a.png"), "1/source")
        XCTAssertNil(CompareFolders.parent(of: "10.txt"))

        let a = file("1/source/a.png", status: .leftOnly)
        XCTAssertEqual(CompareFolders.label(for: a, visibleFolders: ["1", "1/source"]), "a.png",
                       "папка видна — только имя")
        XCTAssertEqual(CompareFolders.label(for: a, visibleFolders: ["1"]), "1/source/a.png",
                       "родителя скрыл фильтр — полный путь")
        XCTAssertEqual(CompareFolders.label(for: file("10.txt", status: .leftOnly), visibleFolders: []), "10.txt")
    }
}
