import AppKit
import XCTest
@testable import TotumComXLApp

/// Картинка папки из «Свойств» — как в Finder.
@MainActor
final class FolderPictureTests: XCTestCase {

    private var folder: String!
    private var savedEnabled: Any?
    private var savedGeneration: Any?

    override func setUp() {
        super.setUp()
        folder = NSTemporaryDirectory() + "fcxl-picture-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        savedEnabled = UserDefaults.standard.object(forKey: CustomFolderIconService.enabledKey)
        savedGeneration = UserDefaults.standard.object(forKey: CustomFolderIconService.generationKey)
        UserDefaults.standard.set(true, forKey: CustomFolderIconService.enabledKey)
        CustomFolderIconService.clearCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        UserDefaults.standard.set(savedEnabled, forKey: CustomFolderIconService.enabledKey)
        UserDefaults.standard.set(savedGeneration, forKey: CustomFolderIconService.generationKey)
        CustomFolderIconService.clearCache()
        super.tearDown()
    }

    private func picture(width: CGFloat = 200, height: CGFloat = 100, color: NSColor = .systemRed) -> NSImage {
        NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }

    private func shown() -> NSImage? {
        guard let item = FileItem.fromPath(folder) else { return nil }
        return CustomFolderIconService.icon(for: item, size: 32)
    }

    func test_картинкаЗаписываетсяКакВFinder_иПоказываетсяВПанели() throws {
        XCTAssertFalse(FolderPicture.hasPicture(folder))
        let before = CustomFolderIconService.cacheToken
        try FolderPicture.assign(picture(), to: folder)
        XCTAssertTrue(FolderPicture.hasPicture(folder), "скрытый Icon\\r в папке — как у Finder")
        XCTAssertTrue(FolderPicture.isAssignedHere(folder))
        XCTAssertNotNil(shown(), "панель показывает картинку")
        XCTAssertNotEqual(CustomFolderIconService.cacheToken, before, "виды списка перечитают значки")
    }

    /// Картинку обычной папки панель не показывает — такие ставят установщики. Но назначенную
    /// здесь, пусть и похожую на папку, — показывает: её выбрал человек.
    func test_похожаяНаПапку_своюПоказываем_чужуюНет() throws {
        let folderArtwork = NSWorkspace.shared.icon(for: .folder)
        XCTAssertTrue(NSWorkspace.shared.setIcon(folderArtwork, forFile: folder, options: []))
        CustomFolderIconService.clearCache()
        XCTAssertNil(shown(), "поставлена в обход «Свойств» — как установщиком: не показывается")

        try FolderPicture.assign(folderArtwork, to: folder)
        XCTAssertNotNil(shown(), "назначена здесь — показывается")
    }

    func test_показКартинокВключаетсяСам() throws {
        UserDefaults.standard.set(false, forKey: CustomFolderIconService.enabledKey)
        XCTAssertEqual(try FolderPicture.assign(picture(), to: folder), .init(turnedOn: true),
                       "иначе назначенное не появилось бы")
        XCTAssertTrue(CustomFolderIconService.isEnabled)
        XCTAssertEqual(try FolderPicture.assign(picture(color: .systemBlue), to: folder), .init(), "уже включён")
    }

    /// Метка не повесилась — об этом говорится, а не молчится: на диске без расширенных
    /// атрибутов картинка, похожая на папку, пропадала бы из панели без объяснений.
    func test_непринятаяМеткаНеМолчит() throws {
        XCTAssertTrue(FolderPicture.mark(folder))
        XCTAssertTrue(FolderPicture.isAssignedHere(folder))
        XCTAssertFalse(FolderPicture.mark(folder + "/нет такой папки"), "диск не принял — ложь")
        XCTAssertEqual(try FolderPicture.assign(picture(), to: folder), .init(), "на обычном диске метка принята")
    }

    func test_убрать() throws {
        try FolderPicture.assign(picture(), to: folder)
        try FolderPicture.remove(from: folder)
        XCTAssertFalse(FolderPicture.hasPicture(folder))
        XCTAssertFalse(FolderPicture.isAssignedHere(folder))
        XCTAssertNil(shown())
    }

    func test_вписываетсяВКвадратБезИскажения() throws {
        let square = try XCTUnwrap(FolderPicture.fitted(picture(width: 200, height: 100)))
        let rep = try XCTUnwrap(square.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, FolderPicture.side)
        XCTAssertEqual(rep.pixelsHigh, FolderPicture.side)
        XCTAssertEqual(rep.colorAt(x: 512, y: 60)?.alphaComponent ?? 1, 0, accuracy: 0.01, "сверху поле прозрачное")
        XCTAssertEqual(rep.colorAt(x: 512, y: 512)?.alphaComponent ?? 0, 1, accuracy: 0.01, "середина — картинка")
        XCTAssertEqual(rep.colorAt(x: 10, y: 512)?.alphaComponent ?? 0, 1, accuracy: 0.01, "по ширине — во всю")
    }

    func test_картинкаИзБуфера_самаИлиФайлом() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("fcxl-picture-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertNil(FolderPicture.image(from: board), "пусто — нечего вставить")

        board.clearContents()
        board.writeObjects([picture()])
        XCTAssertNotNil(FolderPicture.image(from: board), "скопированная картинка")

        let png = URL(fileURLWithPath: folder).appendingPathComponent("картинка.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(picture().tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        board.clearContents()
        board.writeObjects([png as NSURL])
        XCTAssertNotNil(FolderPicture.image(from: board), "файл с картинкой, скопированный в Finder")
    }
}
