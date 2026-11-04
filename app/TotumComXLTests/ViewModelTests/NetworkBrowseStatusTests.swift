import XCTest

@testable import TotumComXLApp

/// Панель обзора сети должна говорить, что происходит: раньше «ищем» и «никого нет»
/// выглядели одинаково — пустотой.
final class NetworkBrowseStatusTests: XCTestCase {

    func testWhileWalkingTheNetworkItSaysSo() {
        XCTAssertEqual(NetworkBrowseStatus.of(scanning: true, hostCount: 0), .searching)
    }

    func testWhenTheWalkIsOverAndNobodyAnsweredItSaysThat() {
        XCTAssertEqual(NetworkBrowseStatus.of(scanning: false, hostCount: 0), .nobody)
    }

    func testTheListSpeaksForItself() {
        XCTAssertEqual(NetworkBrowseStatus.of(scanning: false, hostCount: 3), .hosts)
    }

    func testAFoundComputerHidesTheBannerEvenWhileTheWalkGoesOn() {
        // Обход продолжается, но список уже не пуст — держать поверх него «ищем» незачем.
        XCTAssertEqual(NetworkBrowseStatus.of(scanning: true, hostCount: 1), .hosts)
    }
}
