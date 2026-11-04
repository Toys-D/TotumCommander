import XCTest
@testable import TotumComXLApp

/// Установщик облака: подпись разработчика читается из выдачи pkgutil и codesign, чужая
/// или отсутствующая подпись — отказ; имя в «Загрузках» не затирает существующий файл.
final class CloudInstallerTests: XCTestCase {

    func test_имяРазработчикаИзPkgutil() {
        let out = """
        Package "OneDrive.pkg":
           Status: signed by a certificate trusted by macOS
           Certificate Chain:
            1. Developer ID Installer: Microsoft Corporation (UBF8T346G9)
               Expires: 2027-02-01
        """
        XCTAssertEqual(CloudInstallerDownload.developerName(in: out), "Microsoft Corporation")
        XCTAssertNoThrow(try CloudInstallerDownload.check(signerOf: out, expected: "Microsoft"))
    }

    func test_имяРазработчикаИзCodesign() {
        let out = """
        Executable=/Volumes/x/Dropbox Installer.app/Contents/MacOS/x
        Authority=Developer ID Application: Dropbox, Inc. (G7HH3F8CAK)
        Authority=Developer ID Certification Authority
        """
        XCTAssertEqual(CloudInstallerDownload.developerName(in: out), "Dropbox, Inc.")
        XCTAssertNoThrow(try CloudInstallerDownload.check(signerOf: out, expected: "dropbox"))
    }

    func test_чужаяИлиОтсутствующаяПодпись_Отказ() {
        let stranger = "1. Developer ID Installer: Someone Else (ABC)"
        XCTAssertThrowsError(try CloudInstallerDownload.check(signerOf: stranger, expected: "Google")) { error in
            XCTAssertEqual(error as? CloudInstallerDownload.Failure,
                           .wrongSigner(found: "Someone Else", expected: "Google"))
        }
        XCTAssertThrowsError(try CloudInstallerDownload.check(signerOf: "Status: no signature", expected: "Google")) { error in
            if case .unsigned = error as? CloudInstallerDownload.Failure {} else { XCTFail("ожидался unsigned") }
        }
    }

    func test_имяВЗагрузкахНеЗатираетСуществующее() {
        let folder = URL(fileURLWithPath: "/tmp/dl")
        let taken: Set<String> = ["/tmp/dl/OneDrive.pkg", "/tmp/dl/OneDrive (2).pkg"]
        let url = CloudInstallerDownload.freeDownloadsURL(named: "OneDrive.pkg", in: folder,
                                                          exists: { taken.contains($0.path) })
        XCTAssertEqual(url.path, "/tmp/dl/OneDrive (3).pkg")
        XCTAssertEqual(CloudInstallerDownload.freeDownloadsURL(named: "GoogleDrive.dmg", in: folder,
                                                               exists: { _ in false }).path,
                       "/tmp/dl/GoogleDrive.dmg")
    }

    func test_уКогоЕстьПрямойАдрес() {
        XCTAssertNotNil(CloudProvider.googleDrive.installerURL)
        XCTAssertNotNil(CloudProvider.oneDrive.installerURL)
        XCTAssertNotNil(CloudProvider.dropbox.installerURL)
        XCTAssertNotNil(CloudProvider.box.installerURL)
        XCTAssertNil(CloudProvider.pCloud.installerURL, "нет прямого адреса — страница загрузки")
        XCTAssertNil(CloudProvider.yandexDisk.installerURL)
        XCTAssertNotNil(CloudProvider.pCloud.downloadPage)
    }
}
