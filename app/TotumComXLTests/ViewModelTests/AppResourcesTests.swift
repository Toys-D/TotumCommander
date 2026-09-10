import XCTest

@testable import TotumComXLApp

/// Поиск набора ресурсов. Из-за него программа не запускалась на чужом Mac: сгенерированный
/// SwiftPM `Bundle.module` знает только два пути — рядом с `.app` и сборочную папку той
/// машины, где собирали, — а ресурсы лежат в `Contents/Resources`. На машине автора спасала
/// сборочная папка, на чужой не спасало ничто: `fatalError` до первого окна.
final class AppResourcesTests: XCTestCase {

    private let app = URL(fileURLWithPath: "/Applications/Totum Commander.app")
    private var resources: URL { app.appendingPathComponent("Contents/Resources") }
    private var leaf: String { AppResources.bundleName + ".bundle" }

    func test_первымСмотримТудаГдеРесурсыЛежатВСобраннойПрограмме() {
        let urls = AppResources.candidates(mainBundleURL: app, resourceURL: resources)
        XCTAssertEqual(urls.first, resources.appendingPathComponent(leaf))
    }

    func test_рядомСПрограммойТожеПроверяется() {
        // Туда смотрит сам SwiftPM, и туда же попадает набор при запуске из-под сборки.
        let urls = AppResources.candidates(mainBundleURL: app, resourceURL: resources)
        XCTAssertTrue(urls.contains(app.appendingPathComponent(leaf)))
    }

    func test_безПапкиРесурсовПоискНеПустеет() {
        // У голого исполняемого файла `resourceURL` нет вовсе — искать всё равно есть где.
        let bare = URL(fileURLWithPath: "/tmp/build/debug")
        let urls = AppResources.candidates(mainBundleURL: bare, resourceURL: nil)
        XCTAssertFalse(urls.isEmpty)
        XCTAssertEqual(urls.first, bare.appendingPathComponent(leaf))
    }

    func test_наборРядомСКодомИщетсяДляТестов() {
        // В тестах наш код лежит в тестовом наборе, а набор ресурсов — рядом с ним.
        let code = URL(fileURLWithPath: "/tmp/build/debug/TotumComXLPackageTests.xctest")
        let urls = AppResources.candidates(mainBundleURL: URL(fileURLWithPath: "/tmp/other"),
                                           resourceURL: nil, codeBundleURL: code)
        XCTAssertTrue(urls.contains(URL(fileURLWithPath: "/tmp/build/debug").appendingPathComponent(leaf)))
    }

    func test_путиНеПовторяются() {
        let urls = AppResources.candidates(mainBundleURL: app, resourceURL: resources,
                                           codeBundleURL: app)
        XCTAssertEqual(Set(urls.map(\.path)).count, urls.count, "один и тот же путь не проверяется дважды")
    }

    func test_несуществующиеПутиДаютНичего() {
        let nothing = AppResources.firstBundle(among: [
            URL(fileURLWithPath: "/tmp/нет-такого-набора-1.bundle"),
            URL(fileURLWithPath: "/tmp/нет-такого-набора-2.bundle")
        ])
        XCTAssertNil(nothing)
    }

    func test_настоящийНаборНаходится() throws {
        // Тот, что рядом с тестовым набором: если бы не находился, все строки перевода в
        // тестах превратились бы в ключи.
        XCTAssertTrue(AppResources.found, "набор ресурсов нашёлся, а не подменён самим .app")
        XCTAssertNotNil(AppResources.bundle.path(forResource: "ru", ofType: "lproj"))
    }

    func test_проверкаДляСкриптаВыкладкиПроходит() {
        // Тот же ответ, по которому release.sh решает, можно ли делать DMG.
        XCTAssertTrue(AppResources.selfCheck())
    }
}
