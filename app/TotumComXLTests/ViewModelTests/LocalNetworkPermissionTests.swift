import Network
import XCTest

@testable import TotumComXLApp

/// Запрет macOS на локальную сеть: программа должна отличать «сети нет» от «система не
/// пускает» — иначе человек видит пустой список и думает, что виновата программа.
final class LocalNetworkPermissionTests: XCTestCase {

    func test_отказСистемыОтличаемОтОбычнойНеудачи() {
        // Права: система прямо отвечает «нельзя».
        XCTAssertEqual(LocalNetworkPermission.reading(.posix(.EPERM)), .denied)
        // Хост не отвечает, сети нет, отказ в соединении — это не запрет.
        // «Отказано в соединении» — ответ роутера: пакет дошёл, фильтр не мешает.
        XCTAssertEqual(LocalNetworkPermission.reading(.posix(.ECONNREFUSED)), .granted)
        XCTAssertEqual(LocalNetworkPermission.reading(.posix(.EHOSTUNREACH)), .unknown)
        XCTAssertEqual(LocalNetworkPermission.reading(.posix(.ETIMEDOUT)), .unknown)
    }

    func test_адресНастроекВедётВНужныйРаздел() {
        let url = LocalNetworkPermission.settingsURL.absoluteString
        XCTAssertTrue(url.hasPrefix("x-apple.systempreferences:"), url)
        XCTAssertTrue(url.contains("Privacy_LocalNetwork"), url)
    }

    /// Молчащий адрес — это «не знаю», а не «запрещено»: иначе программа обвиняла бы систему
    /// каждый раз, когда сети просто нет.
    func test_молчаниеНеСчитаетсяЗапретом() async {
        // 203.0.113.0/24 — адреса «для примеров», к ним никто не отвечает.
        let state = await LocalNetworkPermission.check(host: "203.0.113.1", port: 445, timeout: 0.4)
        XCTAssertNotEqual(state, .denied, "молчание — не отказ")
    }

    func test_переводыЕсть() {
        for key in ["network.denied.title", "network.denied.message", "network.denied.open"] {
            XCTAssertNotEqual(L(key), key, "нет перевода \(key)")
        }
    }

    /// Пустой обзор: явный отказ — отказ; молчание после полного обхода — повод сказать
    /// (macOS молча не пускает, если её вопрос так и не появился); ответивший роутер — сеть
    /// и правда пуста.
    func test_советПослеПустогоОбхода() {
        XCTAssertEqual(LocalNetworkPermission.adviceAfterEmptyScan(.denied), .denied)
        XCTAssertEqual(LocalNetworkPermission.adviceAfterEmptyScan(.unknown), .unsure)
        XCTAssertNil(LocalNetworkPermission.adviceAfterEmptyScan(.granted))
    }

    func test_переводыТихогоЗапретаЕсть() {
        for key in ["network.unsure.title", "network.unsure.message"] {
            XCTAssertNotEqual(L(key), key, key)
        }
    }

    /// Запрет виден и при непустом списке: имена из кэша Bonjour остаются, а прямые
    /// соединения программы гасятся — половины сети не видно, и молчать об этом нельзя.
    func test_оЗапретеГоворимДажеКогдаКтоТоВСпискеЕсть() {
        XCTAssertTrue(LocalNetworkPermission.shouldWarn(.denied, afterScan: true, listIsEmpty: false))
        XCTAssertTrue(LocalNetworkPermission.shouldWarn(.denied, afterScan: false, listIsEmpty: false))
    }

    func test_молчаниеОбсуждаемТолькоПослеПолногоОбходаИПриПустомСписке() {
        XCTAssertTrue(LocalNetworkPermission.shouldWarn(.unsure, afterScan: true, listIsEmpty: true))
        XCTAssertFalse(LocalNetworkPermission.shouldWarn(.unsure, afterScan: true, listIsEmpty: false))
        XCTAssertFalse(LocalNetworkPermission.shouldWarn(.unsure, afterScan: false, listIsEmpty: true))
    }

    func test_вСообщенииОЗапретеСказаноПроПерезапуск() {
        for word in ["закройте", "заново"] {
            XCTAssertTrue(L("network.denied.message").lowercased().contains(word), word)
        }
    }
}
