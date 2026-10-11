import Foundation
import XCTest
@testable import TotumComXLApp

/// Редактор F4 — Monaco из бандла программы. Его файлы когда-то положили вручную и не все: без
/// шрифта значков кнопки поиска были пустыми квадратами, а вместо перевода лежала страница
/// «404 Not Found». Редактор при этом работал — молча и без кнопок. Эти проверки ловят
/// недостающее до выпуска.
final class MonacoBundleTests: XCTestCase {

    private var root: URL { AppResources.bundle.bundleURL }

    func test_всёНаЧтоСсылаетсяОформлениеРедактора_лежитВБандле() throws {
        let css = root.appendingPathComponent("monaco/vs/editor/editor.main.css")
        let text = try String(contentsOf: css, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"url\(([^)]+)\)"#)
        let references = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            .filter { !$0.hasPrefix("data:") }
        XCTAssertFalse(references.isEmpty, "оформление ссылается хотя бы на шрифт значков")
        for reference in Set(references) {
            let file = css.deletingLastPathComponent().appendingPathComponent(reference).standardizedFileURL
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "в бандле нет \(reference)")
        }
    }

    func test_вПапкеРедактораСкрипты_аНеСтраницыОшибок() throws {
        let folder = root.appendingPathComponent("monaco")
        let scripts = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "js" }
        XCTAssertFalse(scripts.isEmpty)
        for script in scripts {
            let handle = try FileHandle(forReadingFrom: script)
            defer { try? handle.close() }
            let head = String(decoding: try handle.read(upToCount: 256) ?? Data(), as: UTF8.self).lowercased()
            XCTAssertFalse(head.contains("<html"), "\(script.lastPathComponent) — страница ошибки, а не скрипт")
        }
    }

    func test_русскийПереводРедактора_модульДляЗагрузчика() throws {
        let file = root.appendingPathComponent("monaco/vs/nls.messages.ru.js")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = String(decoding: try handle.read(upToCount: 64) ?? Data(), as: UTF8.self)
        XCTAssertTrue(head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("define("),
                      "перевод загружается как модуль: \(head)")
    }

    func test_языкПодписейРедактора_изНастройкиПрограммы() {
        XCTAssertEqual(MonacoEditorController.monacoLanguage(for: "ru"), "ru")
        XCTAssertEqual(MonacoEditorController.monacoLanguage(for: "en"), "en")
        XCTAssertEqual(MonacoEditorController.monacoLanguage(for: "de"), "en", "перевода нет — встроенный английский")
    }

    func test_окошкоПоискаMonaco_спрятано_аПолосаПрограммыУправляетПоиском() throws {
        let page = try String(contentsOf: root.appendingPathComponent("monaco-editor.html"), encoding: .utf8)
        XCTAssertTrue(page.contains(".find-widget { display: none !important; }"), "значки Monaco не показываются")
        for method in ["open:", "set:", "next:", "previous:", "replace:", "replaceAll:", "close:"] {
            XCTAssertTrue(page.contains(method), "у fcxlFind есть \(method)")
        }
        XCTAssertTrue(page.contains("KeyCode.KeyF, function () { fcxlFind.open(false); }"), "⌘F открывает полосу")
        XCTAssertTrue(page.contains("KeyCode.KeyR, function () { fcxlFind.open(true); }"), "⌘R открывает замену")
        XCTAssertTrue(page.contains("type: 'findState'"), "счёт уходит полосе")
    }

    func test_страницаРедактора_передаётЯзыкЗагрузчику() throws {
        let page = try String(contentsOf: root.appendingPathComponent("monaco-editor.html"), encoding: .utf8)
        XCTAssertTrue(page.contains("window.fcxlLanguage"), "язык приходит от программы")
        XCTAssertTrue(page.contains("'vs/nls'"), "и уходит загрузчику Monaco")
    }
}
