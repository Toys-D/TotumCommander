import DiskArbitration
import XCTest
@testable import TotumComXLApp

/// Подключение и отключение папок Windows — по следам работы с настоящим сервером.
///
/// Всё взято из ленты подключений (MountTrace) за один день: щелчок по уже подключённой папке
/// четыре раза подряд не делал ничего; извлечение спрашивало «отключить силой?», хотя том
/// просто ещё не отпустили или он уже был отключён; каждое открытие списка папок компьютера
/// писало в журнал ошибку слежки.
final class NetworkMountFixesTests: XCTestCase {

    // MARK: - Уже подключённая папка

    private let mounted = [
        MountTable.Entry(source: "/dev/disk3s1s1", path: "/", type: "apfs"),
        MountTable.Entry(source: "//GUEST:@192.168.1.20/D", path: "/Volumes/192.168.1.20", type: "smbfs"),
        MountTable.Entry(source: "//GUEST:@192.168.1.20/E", path: "/Volumes/192.168.1.20-1", type: "smbfs"),
        MountTable.Entry(source: "//anna@192.168.1.20/%D0%9E%D1%82%D1%87%D1%91%D1%82%D1%8B%202025", path: "/Volumes/Отчёты 2025", type: "smbfs"),
        MountTable.Entry(source: "//GUEST:@nas.local/D", path: "/Volumes/D", type: "smbfs"),
    ]

    func test_источникСетевогоТома_разбирается() {
        let d = MountTable.networkSource("//GUEST:@192.168.1.20/D")
        XCTAssertEqual(d?.host, "192.168.1.20")
        XCTAssertEqual(d?.share, "D")
        let unf = MountTable.networkSource("//anna@192.168.1.20/%D0%9E%D1%82%D1%87%D1%91%D1%82%D1%8B%202025")
        XCTAssertEqual(unf?.share, "Отчёты 2025", "имя папки в таблице записано процентами")
        XCTAssertEqual(MountTable.networkSource("//OFFICE-PC/Обмен")?.host, "OFFICE-PC")
        XCTAssertNil(MountTable.networkSource("/dev/disk3s1s1"))
        XCTAssertNil(MountTable.networkSource("//192.168.1.20"), "без папки — не том")
    }

    /// Система на повторное подключение отвечает «уже есть» и точки не называет. Том при этом
    /// может называться не по папке: «D» с сервера встаёт как /Volumes/192.168.1.20.
    func test_ужеПодключённаяПапка_находитсяПоСерверуИИмени() {
        let find = { (host: String, share: String) in
            MountTable.existingMount(host: host, share: share, among: self.mounted)
        }
        XCTAssertEqual(find("192.168.1.20", "D"), "/Volumes/192.168.1.20")
        XCTAssertEqual(find("192.168.1.20", "E"), "/Volumes/192.168.1.20-1")
        XCTAssertEqual(find("192.168.1.20", "e"), "/Volumes/192.168.1.20-1", "Windows регистр не различает")
        XCTAssertEqual(find("192.168.1.20", "Отчёты 2025"), "/Volumes/Отчёты 2025")
        XCTAssertEqual(find("NAS.local", "D"), "/Volumes/D", "имя сервера — тоже без учёта регистра")
        XCTAssertNil(find("192.168.1.20", "install"), "такой папки среди подключённых нет")
    }

    /// Подключали по адресу, а спрашивают по имени компьютера (или наоборот): система считает
    /// это тем же томом. Папка с таким именем одна — значит, это она.
    func test_ужеПодключённая_подДругимИменемСервера() {
        let find = { (host: String, share: String) in
            MountTable.existingMount(host: host, share: share, among: self.mounted)
        }
        XCTAssertEqual(find("OFFICE-PC", "E"), "/Volumes/192.168.1.20-1")
        XCTAssertNil(find("OFFICE-PC", "D"), "папок «D» две, с разных серверов — гадать нельзя")
    }

    // MARK: - Ответы диспетчера дисков

    func test_занятыйТом_узнаётсяВОбоихВидах() {
        XCTAssertEqual(VolumeUnmount.outcome(status: DAReturn(kDAReturnBusy), text: ""), .busy)
        // Сетевой том отвечает кодом системы EBUSY (0xC010), а не диспетчера: из-за этого
        // повторные попытки не делались, и сразу шёл вопрос «отключить силой?».
        XCTAssertEqual(VolumeUnmount.outcome(status: 0xC010, text: ""), .busy)
    }

    func test_томУжеОтключён_этоУспех() {
        XCTAssertEqual(VolumeUnmount.outcome(status: DAReturn(kDAReturnNotMounted), text: ""), .done)
    }

    func test_прочийОтказ_сТекстомИлиКодом() {
        XCTAssertEqual(VolumeUnmount.outcome(status: DAReturn(kDAReturnNotPermitted), text: "нельзя"), .failed("нельзя"))
        XCTAssertEqual(VolumeUnmount.outcome(status: 0x1234, text: ""), .failed("0x00001234"))
    }

    func test_точкаПодключения_поТаблицеТомов() {
        XCTAssertTrue(MountTable.isMountPoint("/"))
        XCTAssertFalse(MountTable.isMountPoint(NSTemporaryDirectory()))
        XCTAssertFalse(MountTable.isMountPoint("/Volumes/нет-такого-\(UUID().uuidString)"))
    }

    /// Не точку подключения отключать нельзя: диспетчер мог бы принять её за том, где она лежит.
    func test_отключениеНеТома_ничегоНеДелает() {
        XCTAssertEqual(VolumeUnmount.unmount(path: NSTemporaryDirectory()), .done)
    }

    // MARK: - Закрытие вкладки сетевого тома

    func test_закрытиеВкладки_томОтключается_еслиНаНёмБольшеНикого() {
        let root = "/Volumes/Обмен"
        XCTAssertTrue(NetworkTabClose.unmountsVolume(root, remainingPaths: ["/Users/кто", "/Volumes/Обмен2/x", "/NETWORK/OFFICE-PC"]))
        XCTAssertFalse(NetworkTabClose.unmountsVolume(root, remainingPaths: ["/Users/кто", "/Volumes/Обмен/отчёты"]),
                       "в соседней вкладке открыта папка этого тома")
        XCTAssertFalse(NetworkTabClose.unmountsVolume(root, remainingPaths: ["/Volumes/Обмен"]))
        XCTAssertFalse(NetworkTabClose.unmountsVolume(root + "/", remainingPaths: ["/Volumes/Обмен/a"]))
    }

    // MARK: - Корзины на сетевой папке нет

    func test_безКорзины_толькоСетевойТомБезНеё() {
        XCTAssertTrue(TrashAvailability.isWithoutTrash(isLocal: false, trashLookupFails: true))
        XCTAssertFalse(TrashAvailability.isWithoutTrash(isLocal: true, trashLookupFails: true),
                       "местный диск — прежней дорогой: ошибка здесь стёрла бы то, что можно вернуть")
        XCTAssertFalse(TrashAvailability.isWithoutTrash(isLocal: false, trashLookupFails: false))
        XCTAssertFalse(TrashAvailability.isWithoutTrash(isLocal: nil, trashLookupFails: true))
    }

    func test_уМестнойПапки_корзинаЕсть() {
        XCTAssertFalse(TrashAvailability.isWithoutTrash(path: NSTemporaryDirectory()))
        XCTAssertFalse(TrashAvailability.isWithoutTrash(path: NSHomeDirectory()))
    }

    func test_удаляемоеДелитсяПоТомам_томСпрашиваетсяРазНаПапку() {
        func item(_ path: String) -> FileItem {
            FileItem(path: path, name: (path as NSString).lastPathComponent, fileExtension: "", size: 1,
                     isDirectory: false, isHidden: false, isSymlink: false, permissions: "",
                     dateModified: Date(), owner: "")
        }
        var asked: [String] = []
        let split = TrashAvailability.split(
            [item("/Volumes/Обмен/а.txt"), item("/Users/кто/б.txt"), item("/Volumes/Обмен/в.txt")],
            withoutTrash: { path in asked.append(path); return path.hasPrefix("/Volumes/Обмен/") })
        XCTAssertEqual(split.toErase.map(\.name), ["а.txt", "в.txt"])
        XCTAssertEqual(split.toTrash.map(\.name), ["б.txt"])
        XCTAssertEqual(asked.count, 2, "две папки — два вопроса о томе, а не три")
    }

    // MARK: - Слежка

    func test_уСпискаКомпьютеровИПапок_слежкиНет() {
        XCTAssertEqual(FolderWatchMode.mode(insideArchive: false, slowVolume: false, networkVolume: false,
                                            virtualLocation: true), .none)
        XCTAssertEqual(FolderWatchMode.mode(insideArchive: false, slowVolume: false, networkVolume: false,
                                            virtualLocation: false), .journal)
        XCTAssertEqual(FolderWatchMode.mode(insideArchive: false, slowVolume: true, networkVolume: true,
                                            virtualLocation: false), .network)
    }
}
