import XCTest

@testable import TotumComXLApp

/// Состояние файлов iCloud: проверяется на настоящем iCloud Drive этой машины, когда он
/// включён, и на обычных файлах — всегда. Главное, что проверяется: программа не путает
/// облачные файлы с обычными и не обещает убрать с диска то, что ещё не долетело в облако.
@MainActor
final class CloudStatusTests: XCTestCase {
    private var root = ""

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "fcxl-cloud-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    func testAnOrdinaryFileIsNotCloudy() {
        let file = (root as NSString).appendingPathComponent("обычный.txt")
        FileManager.default.createFile(atPath: file, contents: Data("текст".utf8))

        XCTAssertFalse(CloudStatusService.isInCloudDrive(file), "файл на диске — не облачный")
        XCTAssertEqual(CloudStatusService.state(of: file), .local)
        XCTAssertFalse(CloudStatusService.isUploaded(file), "обычный файл никуда не выгружается")
    }

    func testCloudPathsAreRecognisedByPlace() {
        let cloud = CloudStatusService.cloudDriveRoot + "/Документы/отчёт.pdf"
        XCTAssertTrue(CloudStatusService.isInCloudDrive(cloud))
        // Контейнеры других программ тоже лежат в iCloud
        let appContainer = NSHomeDirectory()
            + "/Library/Mobile Documents/com~apple~Keynote/Documents/презентация.key"
        XCTAssertTrue(CloudStatusService.isInCloudDrive(appContainer))
        XCTAssertFalse(CloudStatusService.isInCloudDrive("/Users/кто-то/Документы/файл.txt"))
    }

    /// Заглушка нескачанного файла — служебная, а показывать надо настоящее имя.
    func testAPlaceholderShowsTheRealName() {
        let stub = CloudStatusService.cloudDriveRoot + "/.Документ.pdf.icloud"
        XCTAssertEqual(CloudStatusService.displayName(for: stub), "Документ.pdf")
        XCTAssertEqual(CloudStatusService.state(of: stub), .inCloudOnly,
                       "заглушка и означает «файл только в облаке»")

        let ordinary = CloudStatusService.cloudDriveRoot + "/Документ.pdf"
        XCTAssertEqual(CloudStatusService.displayName(for: ordinary), "Документ.pdf",
                       "обычное имя не трогаем")
    }

    /// Кнопка диска обязана исчезать, когда iCloud Drive выключен: наличие папки — не ответ,
    /// она остаётся лежать с местными копиями и после выключения.
    func testAvailabilityAsksTheSystemNotJustTheFolder() {
        let folderExists = FileManager.default.fileExists(
            atPath: CloudStatusService.cloudDriveRoot)
        let signedIn = FileManager.default.ubiquityIdentityToken != nil

        if !signedIn {
            XCTAssertFalse(CloudStatusService.isAvailable,
                           "не вошли в iCloud — кнопки быть не должно, даже если папка лежит")
        }
        if CloudStatusService.isAvailable {
            XCTAssertTrue(folderExists && signedIn,
                          "кнопка показывается только когда и вход есть, и папка облачная")
            let values = try? URL(fileURLWithPath: CloudStatusService.cloudDriveRoot)
                .resourceValues(forKeys: [.isUbiquitousItemKey])
            XCTAssertEqual(values?.isUbiquitousItem, true,
                           "папка должна быть настоящей облачной, а не остатком после выключения")
        }
    }

    /// iCloud Drive — самостоятельное место: наверх из него хода нет, иначе человек
    /// проваливается в служебную «Mobile Documents» со всеми контейнерами программ.
    func testICloudDriveIsAPlaceNotAFolderInLibrary() throws {
        try XCTSkipUnless(CloudStatusService.isAvailable, "iCloud Drive выключен на этой машине")
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: CloudStatusService.cloudDriveRoot,
            pathDefaultsKey: "test.icloud.\(UUID().uuidString)",
            viewModeDefaultsKey: "test.icloudmode.\(UUID().uuidString)",
            showHiddenFiles: false)
        vm.loadDirectory(at: CloudStatusService.cloudDriveRoot)

        let names: [String] = vm.items.map { $0.name }
        XCTAssertFalse(names.contains(".."),
                       "из корня iCloud Drive наверх хода нет — там служебная изнанка")

        // И клавиша подъёма тоже не выводит наружу.
        let before = vm.currentPath
        vm.goUp()
        XCTAssertEqual(vm.currentPath, before, "Backspace не открывает чёрный ход")
        XCTAssertFalse(vm.currentPath.hasSuffix("Mobile Documents"))
    }

    /// На живом iCloud Drive: все состояния читаются, ничего не падает, файлы не портятся.
    func testTheRealCloudDriveAnswers() throws {
        try XCTSkipUnless(CloudStatusService.isAvailable, "iCloud Drive выключен на этой машине")

        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: CloudStatusService.cloudDriveRoot)) ?? []
        var seen: Set<String> = []
        for name in names.prefix(20) {
            let path = (CloudStatusService.cloudDriveRoot as NSString)
                .appendingPathComponent(name)
            let state = CloudStatusService.state(of: path)
            seen.insert("\(state)")
            XCTAssertTrue(CloudStatusService.isInCloudDrive(path))
        }
        XCTAssertFalse(seen.isEmpty, "хоть одно состояние прочитано")
        // Настоящие файлы в облаке обязаны отвечать хоть что-то осмысленное, а не .local
        if !names.isEmpty {
            XCTAssertFalse(seen == ["local"],
                           "файлы внутри iCloud Drive не должны читаться как обычные")
        }
    }
}
