import XCTest
@testable import TotumComXLApp

/// Разбор `smbutil view`: какие папки показывать и когда пустой ответ — отказ во входе,
/// а когда просто тишина. От этого зависит, появится ли наше окно входа.
final class SmbutilListingTests: XCTestCase {

    func test_папкиDiskБезСкрытых() {
        let output = """
        Share                                           Type    Comments
        -------------------------------
        Public                                          Disk
        ADMIN$                                          Disk    Remote Admin
        print$                                          Disk    Printer Drivers
        HP LaserJet                                     Printer
        Фото                                            Disk

        3 shares listed
        """
        XCTAssertEqual(NetworkBrowserService.parseSmbutilShares(output), ["Public", "Фото"])
    }

    func test_отказВоВходеОтличаемОтТишины() {
        XCTAssertEqual(NetworkBrowserService.smbutilFailure(
            status: 1, stderr: "smbutil: server rejected the connection: Authentication error"),
                       .authentication)
        XCTAssertEqual(NetworkBrowserService.smbutilFailure(status: 1, stderr: "Permission denied"),
                       .authentication)
        XCTAssertEqual(NetworkBrowserService.smbutilFailure(status: 1, stderr: "Connection refused"),
                       .other)
        XCTAssertEqual(NetworkBrowserService.smbutilFailure(status: 68, stderr: "Host is down"), .other)
        XCTAssertNil(NetworkBrowserService.smbutilFailure(status: 0, stderr: ""))
    }
}

/// «Отмена» во входе на сервер — это «передумал», а не «папок нет»: панель возвращается
/// к списку компьютеров. Раньше она оставалась в пустой папке, и сеть выглядела пропавшей.
final class NetworkSharesResultTests: XCTestCase {

    func test_отменаОтличаетсяОтПустогоСписка() {
        let cancelled = NetworkBrowserService.SharesResult(shares: [], cancelled: true)
        let empty = NetworkBrowserService.SharesResult(shares: [], cancelled: false)
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertFalse(empty.cancelled)
        XCTAssertTrue(cancelled.shares.isEmpty)
    }

    func test_неизвестныйКомпьютерНеСчитаетсяОтменой() async {
        let result = await NetworkBrowserService.shared.listShares(computerName: "нет-такого-\(UUID().uuidString)")
        XCTAssertTrue(result.shares.isEmpty)
        XCTAssertFalse(result.cancelled, "нечего отменять — панель остаётся на месте")
    }
}
