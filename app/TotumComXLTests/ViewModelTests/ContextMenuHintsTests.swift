import AppKit
import XCTest
@testable import TotumComXLApp

/// Подсказки в правом меню: зелёным — то, ради чего этот файл или это место.
final class ContextMenuHintsTests: XCTestCase {

    func test_обычныйФайл_безПодсказок() {
        XCTAssertTrue(ContextMenuHints.tinted(.init(isFile: true)).isEmpty)
    }

    func test_архив_распаковать() {
        XCTAssertEqual(ContextMenuHints.tinted(.init(isArchive: true, isFile: true)), ["context.unpack"])
    }

    /// На полке — снять и очистить: там за этим и пришли.
    func test_полка_снятьИОчистить() {
        XCTAssertEqual(ContextMenuHints.tinted(.init(onShelf: true, isFile: true)),
                       ["stack.remove", "stack.clear"])
    }

    func test_корзина_восстановить() {
        XCTAssertEqual(ContextMenuHints.tinted(.init(inTrash: true, isFile: true)), ["trash.restore"])
    }

    /// Файлу нечем открыться — «Открыть с помощью»; у папки такого вопроса нет.
    func test_безПрограммы_открытьСПомощью() {
        XCTAssertEqual(ContextMenuHints.tinted(.init(isFile: true, hasOpener: false)), ["context.openWith"])
        XCTAssertTrue(ContextMenuHints.tinted(.init(isFile: false, hasOpener: false)).isEmpty)
    }

    func test_ссылкаИХранилище() {
        XCTAssertEqual(ContextMenuHints.tinted(.init(isFile: true, isSymlink: true)), ["context.followSymlink"])
        XCTAssertEqual(ContextMenuHints.tinted(.init(isVault: true)), ["vault.unlock.menu"])
        XCTAssertEqual(ContextMenuHints.tinted(.init(isVault: true, vaultUnlocked: true)), ["vault.lock.menu"])
    }

    /// В буфере файлы — вставить; выбрано несколько — групповое переименование.
    func test_буферИВыборНескольких() {
        XCTAssertEqual(ContextMenuHints.tinted(.init(clipboardHasFiles: true, selectionCount: 0)), ["context.paste"])
        XCTAssertEqual(ContextMenuHints.tinted(.init(isFile: true, selectionCount: 3)), ["context.multiRename"])
    }

    /// PDF и картинки: зелёная дверь в инструменты, а внутри — только то, что дал выбор.
    func test_инструментыДляPDFиКартинок() {
        XCTAssertEqual(ContextMenuHints.tinted(.init(isFile: true, isPDF: true, pdfCount: 1)), ["context.fileTools"])
        XCTAssertEqual(ContextMenuHints.tinted(.init(isFile: true, selectionCount: 2, isPDF: true, pdfCount: 2)),
                       ["context.multiRename", "context.fileTools", "context.pdfMerge"],
                       "несколько PDF — слить")
        XCTAssertEqual(ContextMenuHints.tinted(.init(isFile: true, isImage: true, imageCount: 1)), ["context.fileTools"])
        XCTAssertEqual(ContextMenuHints.tinted(.init(isFile: true, selectionCount: 3, isImage: true, imageCount: 3)),
                       ["context.multiRename", "context.fileTools", "context.pdfMake"],
                       "несколько картинок — собрать PDF")
    }

    /// Несколько обстоятельств разом — все подсказки, ни одна не теряется.
    func test_подсказкиСкладываются() {
        let all = ContextMenuHints.tinted(.init(isArchive: true, onShelf: true, isFile: true,
                                                clipboardHasFiles: true, selectionCount: 2))
        XCTAssertEqual(all, ["context.unpack", "stack.remove", "stack.clear", "context.paste", "context.multiRename"])
    }

    /// Раскраска: нужные пункты зеленеют, и в подменю тоже; остальные как были.
    @MainActor
    func test_раскраскаПоИменам() throws {
        let menu = NSMenu()
        menu.addStyledItem(title: "Открыть", symbolName: "arrow.right.circle", id: "context.open") {}
        menu.addStyledItem(title: "Снять с полки", symbolName: "tray", id: "stack.remove") {}
        let more = NSMenu()
        more.addStyledItem(title: "Распаковать", symbolName: "archivebox", id: "context.unpack") {}
        let moreItem = NSMenuItem(title: "Ещё", action: nil, keyEquivalent: "")
        moreItem.submenu = more
        menu.addItem(moreItem)

        ContextMenuHints.apply(["stack.remove", "context.unpack"], to: menu)

        func colour(_ item: NSMenuItem) -> NSColor? {
            item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        XCTAssertNil(colour(menu.items[0]), "«Открыть» не тронут")
        XCTAssertEqual(colour(menu.items[1]), ContextMenuHints.color)
        XCTAssertEqual(colour(try XCTUnwrap(more.items.first)), ContextMenuHints.color, "и под «Ещё»")
        XCTAssertEqual(menu.items[1].title, "Снять с полки", "текст цел")
    }

    /// Ответ системы про программу: у текстового файла она есть, у выдуманного расширения — нет.
    func test_естьЛиПрограмма() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fcxl-hints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("заметка.txt")
        try Data("текст".utf8).write(to: text)
        let odd = dir.appendingPathComponent("данные.fcxlнеизвестно")
        try Data([1, 2, 3]).write(to: odd)
        XCTAssertTrue(ContextMenuHints.hasOpener(forFileAt: text.path))
        XCTAssertFalse(ContextMenuHints.hasOpener(forFileAt: odd.path))
    }
}
