import XCTest
@testable import TotumComXLApp

/// Облачные диски из `~/Library/CloudStorage` в полосе томов: Google Drive for desktop,
/// OneDrive, Dropbox. Проверяется на временной папке, а не на настоящей CloudStorage.
final class CloudStorageVolumesTests: XCTestCase {

    func test_имяКнопкиПоИмениПапки() {
        XCTAssertEqual(CloudStorageVolumes.label(forFolder: "GoogleDrive-pixmap@gmail.com"), "Google Drive")
        XCTAssertEqual(CloudStorageVolumes.label(forFolder: "OneDrive-Personal"), "OneDrive")
        XCTAssertEqual(CloudStorageVolumes.label(forFolder: "Dropbox"), "Dropbox")
        XCTAssertEqual(CloudStorageVolumes.label(forFolder: "Proton Drive-user"), "Proton Drive", "незнакомый — до дефиса")
        XCTAssertNil(CloudStorageVolumes.label(forFolder: "iCloud\u{00A0}Drive-iCloudDrive (09.02.2025 12:08)"),
                     "iCloud уже есть своей кнопкой; у Apple в имени неразрывный пробел")
        XCTAssertNil(CloudStorageVolumes.label(forFolder: "iCloud Drive-iCloudDrive"))
    }

    func test_папкиПоставщиковСтановятсяДисками() throws {
        let root = NSTemporaryDirectory() + "fcxl-cloudstorage-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        for name in ["GoogleDrive-me@gmail.com", "iCloud\u{00A0}Drive-iCloudDrive (x)", ".hidden", "Dropbox"] {
            try FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: root + "/OneDrive-Personal", contents: Data())   // файл, не папка
        let volumes = CloudStorageVolumes.volumes(in: root)
        XCTAssertEqual(volumes.map(\.label), ["Dropbox", "Google Drive"])
        XCTAssertEqual(volumes.first?.path, root + "/Dropbox")
    }

    func test_безПапкиCloudStorage_Пусто() {
        XCTAssertEqual(CloudStorageVolumes.volumes(in: "/нет/такой/папки"), [])
    }

    func test_корнемСчитаетсяТолькоПапкаПоставщика() {
        let root = "/Users/x/Library/CloudStorage"
        XCTAssertTrue(CloudStorageVolumes.isRoot(root + "/GoogleDrive-me", root: root))
        XCTAssertFalse(CloudStorageVolumes.isRoot(root + "/GoogleDrive-me/Docs", root: root), "внутри — обычная папка")
        XCTAssertFalse(CloudStorageVolumes.isRoot(root, root: root), "сама CloudStorage — не диск")
        XCTAssertFalse(CloudStorageVolumes.isRoot("/Users/x/Documents", root: root))
    }
}
