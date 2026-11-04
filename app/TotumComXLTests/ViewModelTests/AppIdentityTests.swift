import XCTest

@testable import TotumComXLApp

/// Сведения о программе — одно место на всех: раздел «О программе» показывал старое имя
/// аккаунта GitHub, потому что оно было набито в нём руками.
final class AppIdentityTests: XCTestCase {

    func test_адресаВедутВОдинРепозиторийНаGitHub() {
        XCTAssertEqual(AppIdentity.repositoryURL.host, "github.com")
        XCTAssertEqual(AppIdentity.repositoryURL.path, "/" + AppIdentity.repositorySlug)
        XCTAssertTrue(AppIdentity.releasesURL.absoluteString.hasPrefix(AppIdentity.repositoryURL.absoluteString))
        XCTAssertTrue(AppIdentity.licenseURL.absoluteString.hasSuffix("/LICENSE"))
        XCTAssertFalse(AppIdentity.repositorySlug.lowercased().contains("toys1981"), "старое имя аккаунта")
    }

    func test_разработчикИКомпанияНазваны() {
        XCTAssertFalse(AppIdentity.developer.isEmpty)
        XCTAssertFalse(AppIdentity.company.isEmpty)
        XCTAssertEqual(AppIdentity.license, "GNU GPL v3", "лицензия проекта — файл LICENSE")
        for key in ["about.developer", "about.company", "about.license", "about.releases", "about.releases.open"] {
            XCTAssertNotEqual(L(key), key, "нет перевода \(key)")
        }
    }

    /// Кнопка поддержки ведёт на PayPal, к нужному адресу, и не молчит ни на одном языке.
    func test_поддержкаВедётНаPayPalКНужномуАдресу() {
        XCTAssertEqual(AppIdentity.supportURL.host, "www.paypal.com")
        let query = AppIdentity.supportURL.query ?? ""
        XCTAssertTrue(query.contains("business=pixmap1981%40gmail.com"), "получатель — почта аккаунта")
        XCTAssertTrue(query.contains("item_name=Totum+Commander"))
        for key in ["about.support.title", "about.support.body", "about.support.button",
                    "about.support.thanks", "about.support.note"] {
            XCTAssertNotEqual(L(key), key, "нет перевода \(key)")
        }
        // README и FUNDING.yml — та же ссылка, чтобы люди с GitHub приходили туда же.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["README.md", ".github/FUNDING.yml"] {
            let text = (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
            XCTAssertTrue(text.contains(AppIdentity.supportURL.absoluteString), "\(file) без ссылки поддержки")
        }
    }
}

/// Заголовок окна: автору — номер сборки, людям — версия.
final class WindowTitleTests: XCTestCase {
    func test_отладочнаяСборкаАвтораПоказываетНомерСборки() {
        XCTAssertTrue(AppIdentity.showsBuildInTitle(debugBuild: true, freshCopy: false))
        XCTAssertEqual(AppIdentity.windowTitle(product: "Totum Commander", version: "1.0", build: 2243, showsBuild: true),
                       "Totum Commander — Build 2243")
    }

    func test_релизИКопияНовогоПользователяПоказываютВерсию() {
        XCTAssertFalse(AppIdentity.showsBuildInTitle(debugBuild: false, freshCopy: false), "релиз")
        XCTAssertFalse(AppIdentity.showsBuildInTitle(debugBuild: true, freshCopy: true), "копия --fresh")
        XCTAssertFalse(AppIdentity.showsBuildInTitle(debugBuild: false, freshCopy: true))
        XCTAssertEqual(AppIdentity.windowTitle(product: "Totum Commander", version: "1.0", build: 2243, showsBuild: false),
                       "Totum Commander 1.0")
    }

    func test_копияУзнаётсяПоИдентификатору() {
        XCTAssertTrue(AppIdentity.isFreshCopy(bundleIdentifier: "com.fcxl.filecommander.fresh"))
        XCTAssertFalse(AppIdentity.isFreshCopy(bundleIdentifier: "com.fcxl.filecommander"))
        XCTAssertFalse(AppIdentity.isFreshCopy(bundleIdentifier: nil))
    }

    /// Куда писать: адрес один на всю программу, и письмо открывается с готовой темой.
    func test_адресДляСвязиИПисьмоСТемой() {
        XCTAssertEqual(AppIdentity.email, "pixmap1981@gmail.com")
        XCTAssertEqual(AppIdentity.supportEmail, AppIdentity.email,
                       "PayPal и письма — один и тот же адрес")
        let url = AppIdentity.contactURL
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:pixmap1981@gmail.com"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("subject=Totum%20Commander"), url.absoluteString)
    }

    func test_надписьСвязьПереведена() {
        XCTAssertNotEqual(L("about.contact"), "about.contact")
    }
}
