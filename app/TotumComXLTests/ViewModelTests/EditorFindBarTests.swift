import AppKit
import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Полоса поиска и замены редактора F4: подписанные кнопки вместо значков Monaco. Ищет сам
/// Monaco (страница, fcxlFind) — здесь проверяется, что полоса говорит ему и что показывает.
@MainActor
final class EditorFindBarTests: XCTestCase {

    private func model() -> (EditorFindModel, () -> [String]) {
        let model = EditorFindModel()
        var scripts: [String] = []
        model.run = { scripts.append($0) }
        return (model, { scripts })
    }

    func test_открытие_выделенноеСтановитсяИскомым_иПолосаВидна() {
        let (model, scripts) = model()
        model.opened(replace: false, seed: "Совет")
        XCTAssertTrue(model.isVisible)
        XCTAssertFalse(model.showsReplace)
        XCTAssertEqual(model.query, "Совет")
        XCTAssertEqual(scripts().last?.hasPrefix("fcxlFind.set("), true, "искомое ушло на страницу")
        XCTAssertEqual(scripts().last?.hasSuffix(", false)"), true, "выделенное остаётся текущим совпадением")
    }

    func test_открытиеЗамены_показываетПолеЗамены() {
        let (model, _) = model()
        model.opened(replace: true, seed: "")
        XCTAssertTrue(model.showsReplace)
    }

    func test_повторноеОткрытие_сноваОтдаётКлавиатуруПолю() {
        let (model, _) = model()
        model.opened(replace: false, seed: "")
        let first = model.focusToken
        model.opened(replace: false, seed: "")
        XCTAssertNotEqual(model.focusToken, first, "⌘F при открытой полосе возвращает курсор в поле")
    }

    func test_покаПолосаЗакрыта_страницеНичегоНеШлётся() {
        let (model, scripts) = model()
        model.query = "что-то"
        model.matchCase = true
        XCTAssertTrue(scripts().isEmpty)
    }

    func test_запрос_доходитДоСтраницыКакЕсть() throws {
        let (model, scripts) = model()
        model.opened(replace: false, seed: "")
        let tricky = "a\"b'c\\d\nконец`${x}"
        model.query = tricky
        model.isRegex = true
        let script = try XCTUnwrap(scripts().last)
        XCTAssertTrue(script.hasPrefix("fcxlFind.set(") && script.hasSuffix(", true)"), "набор ведёт курсор к найденному")
        let json = String(script.dropFirst("fcxlFind.set(".count).dropLast(", true)".count))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["query"] as? String, tricky)
        XCTAssertEqual(payload["isRegex"] as? Bool, true)
    }

    func test_переходИЗамена_толькоКогдаЧтоТоНашлось() {
        let (model, scripts) = model()
        model.opened(replace: true, seed: "x")
        let before = scripts().count
        model.next(); model.previous(); model.replaceOne(); model.replaceAll()
        XCTAssertEqual(scripts().count, before, "ничего не найдено — кнопки молчат")
        model.pageState(revealed: true, count: 3, position: 1)
        model.next(); model.previous(); model.replaceOne(); model.replaceAll()
        XCTAssertEqual(Array(scripts().suffix(4)),
                       ["fcxlFind.next()", "fcxlFind.previous()", "fcxlFind.replace()", "fcxlFind.replaceAll()"])
    }

    func test_поискЗакрылиВТексте_полосаУходит() {
        let (model, _) = model()
        model.opened(replace: false, seed: "x")
        model.pageState(revealed: false, count: 0, position: 0)
        XCTAssertFalse(model.isVisible)
    }

    func test_закрытие_гаситПоискИВозвращаетКлавиатуруТексту() {
        let (model, scripts) = model()
        var returned = false
        model.onClose = { returned = true }
        model.opened(replace: false, seed: "x")
        model.close()
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(scripts().last, "fcxlFind.close()")
        XCTAssertTrue(returned)
    }

    func test_escЗакрываетПоискСвоегоОкна_аНеЧужого() {
        let mine = NSWindow(), other = NSWindow()
        let (model, _) = model()
        model.window = { mine }
        model.opened(replace: false, seed: "x")
        XCTAssertFalse(EditorFindModel.closeVisible(in: other), "в другом окне закрывать нечего")
        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(EditorFindModel.closeVisible(in: mine))
        XCTAssertFalse(model.isVisible)
        XCTAssertFalse(EditorFindModel.closeVisible(in: mine), "второй Esc уже закрывает редактор")
    }

    func test_счётчик() {
        XCTAssertEqual(EditorFindModel.counterText(count: 0, position: 0, query: ""), "", "пока не ищем — пусто")
        XCTAssertEqual(EditorFindModel.counterText(count: 0, position: 0, query: "x"), L("editor.find.none"))
        XCTAssertEqual(EditorFindModel.counterText(count: 8, position: 0, query: "x"), L("editor.find.total", 8))
        XCTAssertEqual(EditorFindModel.counterText(count: 8, position: 3, query: "x"), L("editor.find.counter", 3, 8))
    }

    /// Полосы редактора картинкой в обеих темах — в папку FCXL_LOOK_DIR, чтобы посмотреть глазами.
    func test_полосыРедактораСохраняютсяКартинкойДляПросмотра() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        let find = EditorFindModel()
        find.opened(replace: true, seed: "Совет")
        find.pageState(revealed: true, count: 8, position: 3)
        find.matchCase = true
        let options = EditorViewOptions()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let bars = VStack(spacing: 0) {
                EditorToolbar(options: options, onFind: {}, onReplace: {})
                Divider()
                EditorFindBar(model: find)
            }
            .frame(width: 1100)
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: bars)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("editor-bars-\(name).png"))
        }
    }

    func test_подписиПолосыРедактора_естьНаОбоихЯзыках() {
        let keys = ["editor.find.label", "editor.find.replaceLabel", "editor.find.previous", "editor.find.next",
                    "editor.find.showReplace", "editor.find.replace", "editor.find.replaceAll",
                    "editor.find.matchCase", "editor.find.wholeWord", "editor.find.regex",
                    "editor.toolbar.find", "editor.toolbar.replace", "editor.toolbar.size",
                    "editor.language.plainText"]
            + EditorViewOptions.whitespaceModes.map { "editor.whitespace.\($0)" }
            + EditorViewOptions.lineHighlightModes.map { "editor.lineHighlight.\($0)" }
        for language in ["ru", "en"] {
            let url = AppResources.bundle.bundleURL.appendingPathComponent("\(language).lproj/Localizable.strings")
            let table = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
            for key in keys {
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(language): нет «\(key)»")
            }
        }
    }
}
