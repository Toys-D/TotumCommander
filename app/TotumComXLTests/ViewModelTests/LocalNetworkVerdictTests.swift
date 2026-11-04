import XCTest

@testable import TotumComXLApp

/// «Нас не пускают в локальную сеть» — как это узнаётся. Прежняя проверка стучалась шлюзу в
/// порт общих папок Windows, которого у роутера нет: замер на живой сети — 445 молчит, 80
/// отвечает мгновенно. Молчание же значило «непонятно», и разговор не начинался именно там,
/// ради чего проверка писалась.
final class LocalNetworkVerdictTests: XCTestCase {

    func test_шлюзОтветилЗначитПускают() {
        XCTAssertEqual(LocalNetworkPermission.verdict(anyPortAnswered: true, gatewayAlive: true),
                       .granted)
    }

    func test_шлюзЖивНоМолчитНамЗначитНеПускают() {
        // Таблицу ARP наполняет вся система, нашего разрешения на это не нужно: раз шлюз в
        // ней есть, он жив — и молчание в ответ именно нам и есть запрет.
        XCTAssertEqual(LocalNetworkPermission.verdict(anyPortAnswered: false, gatewayAlive: true),
                       .denied)
    }

    func test_шлюзаНетВовсеЗначитНетСети() {
        XCTAssertEqual(LocalNetworkPermission.verdict(anyPortAnswered: false, gatewayAlive: false),
                       .unknown)
    }

    func test_ответПересиливаетОтсутствиеВТаблице() {
        // Ответил — значит пускают, что бы ни было в таблице.
        XCTAssertEqual(LocalNetworkPermission.verdict(anyPortAnswered: true, gatewayAlive: false),
                       .granted)
    }

    func test_безШлюзаНичегоНеУтверждаем() {
        XCTAssertEqual(LocalNetworkPermission.state(gateway: nil), .unknown)
        XCTAssertEqual(LocalNetworkPermission.state(gateway: ""), .unknown)
    }

    func test_запретВедётКРазговору() {
        let advice = LocalNetworkPermission.adviceAfterEmptyScan(.denied)
        XCTAssertEqual(advice, .denied)
        XCTAssertTrue(LocalNetworkPermission.shouldWarn(.denied, afterScan: false, listIsEmpty: false))
    }
}
