import XCTest
@testable import TotumComXLApp

/// Где облаку место: подключённое — в полосе, убранное — в меню и возвращается оттуда,
/// неподключённое — в меню с тем, что случится по щелчку.
final class CloudPlacesTests: XCTestCase {

    private var savedHidden: [String]?

    override func setUp() {
        super.setUp()
        savedHidden = UserDefaults.standard.stringArray(forKey: CloudPlaces.hiddenKey)
        UserDefaults.standard.removeObject(forKey: CloudPlaces.hiddenKey)
    }

    override func tearDown() {
        if let savedHidden { UserDefaults.standard.set(savedHidden, forKey: CloudPlaces.hiddenKey) }
        else { UserDefaults.standard.removeObject(forKey: CloudPlaces.hiddenKey) }
        super.tearDown()
    }

    func test_подключённоеВПолосе_УбранноеВМеню() {
        XCTAssertEqual(CloudPlaces.placement(of: .googleDrive, connectedAt: "/x", installed: true, hidden: false),
                       .bar(path: "/x"))
        XCTAssertEqual(CloudPlaces.placement(of: .googleDrive, connectedAt: "/x", installed: true, hidden: true),
                       .menuHidden(path: "/x"))
    }

    func test_неподключённое_ЧтоСлучитсяПоЩелчку() {
        XCTAssertEqual(CloudPlaces.placement(of: .googleDrive, connectedAt: nil, installed: true, hidden: false),
                       .menuSignIn, "программа есть — войти")
        XCTAssertEqual(CloudPlaces.placement(of: .dropbox, connectedAt: nil, installed: false, hidden: false),
                       .menuInstall, "программы нет — установить")
        XCTAssertEqual(CloudPlaces.placement(of: .icloud, connectedAt: nil, installed: true, hidden: false),
                       .menuSystemSettings, "iCloud выключен — в настройки")
    }

    func test_папкиCloudStorageУзнаются() {
        XCTAssertEqual(CloudProvider.match(folder: "GoogleDrive-me@gmail.com"), .googleDrive)
        XCTAssertEqual(CloudProvider.match(folder: "OneDrive-Personal"), .oneDrive)
        XCTAssertEqual(CloudProvider.match(folder: "Dropbox"), .dropbox)
        XCTAssertEqual(CloudProvider.match(folder: "iCloud\u{00A0}Drive-iCloudDrive (x)"), .icloud)
        XCTAssertEqual(CloudProvider.match(folder: "Box-Box"), .box)
        XCTAssertNil(CloudProvider.match(folder: "Proton Drive-x"))
    }

    /// pCloud и Яндекс кладут диск не в CloudStorage — ищутся по запасным путям.
    func test_дискВнеCloudStorage_НаходитсяПоЗапасномуПути() {
        let path = CloudProvider.yandexDisk.connectedPath(cloudStorage: [], home: "/Users/x",
                                                          exists: { $0 == "/Users/x/Yandex.Disk.localized" })
        XCTAssertEqual(path, "/Users/x/Yandex.Disk.localized")
        XCTAssertNil(CloudProvider.pCloud.connectedPath(cloudStorage: [], home: "/Users/x", exists: { _ in false }))
        XCTAssertEqual(CloudProvider.pCloud.connectedPath(cloudStorage: [], home: "/Users/x",
                                                          exists: { $0 == "/Volumes/pCloud Drive" }),
                       "/Volumes/pCloud Drive", "том pCloudFS считается подключением")
        let folder = CloudStorageVolumes.Volume(label: "pCloud", path: "/cs/pCloud-x", provider: .pCloud)
        XCTAssertEqual(CloudProvider.pCloud.connectedPath(cloudStorage: [folder], exists: { _ in false }),
                       "/cs/pCloud-x", "папка в CloudStorage важнее запасных путей")
    }

    func test_извлечениеПрячетИЗапоминается_ЩелчокВозвращает() {
        CloudPlaces.hide(.googleDrive)
        XCTAssertEqual(CloudPlaces.hidden, [.googleDrive])
        let volumes = [CloudStorageVolumes.Volume(label: "Google Drive", path: "/gd", provider: .googleDrive)]
        let placed = CloudPlaces.placements(icloudAvailable: true, cloudStorage: volumes,
                                            hidden: CloudPlaces.hidden, installed: { _ in true })
        XCTAssertEqual(placed.first { $0.provider == .googleDrive }?.placement, .menuHidden(path: "/gd"))
        XCTAssertEqual(placed.first { $0.provider == .icloud }?.placement,
                       .bar(path: CloudStatusService.cloudDriveRoot))
        XCTAssertEqual(placed.filter { !$0.placement.isInBar }.map(\.provider),
                       [.googleDrive, .oneDrive, .dropbox, .box, .pCloud, .yandexDisk])

        CloudPlaces.show(.googleDrive)
        XCTAssertTrue(CloudPlaces.hidden.isEmpty)
    }
}
