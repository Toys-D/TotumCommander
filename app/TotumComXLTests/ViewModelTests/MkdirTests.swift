import XCTest
@testable import TotumComXLApp

/// F7 с дорогой вместо имени — «toys/alsde/dk» — создаёт всю цепочку, как в Total Commander.
final class MkdirTests: XCTestCase {

    private var folder = ""
    private let service = FileOperationsService(bridgeService: CoreBridgeService())

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "mkdir-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func test_имяДорогаСоздаётЦепочку() throws {
        try service.createDirectory(at: folder, name: "toys/alsde/dk")
        XCTAssertTrue(isFolder(folder + "/toys"))
        XCTAssertTrue(isFolder(folder + "/toys/alsde"))
        XCTAssertTrue(isFolder(folder + "/toys/alsde/dk"))
    }

    func test_существующиеЗвеньяНеТрогаются_аГотоваяДорогаОтказывает() throws {
        try FileManager.default.createDirectory(atPath: folder + "/toys", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/toys/файл.txt", contents: Data("x".utf8))
        try service.createDirectory(at: folder, name: "toys/alsde")
        XCTAssertTrue(isFolder(folder + "/toys/alsde"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/toys/файл.txt"), "старое звено цело")
        XCTAssertThrowsError(try service.createDirectory(at: folder, name: "toys/alsde"), "уже есть")
    }

    func test_звеньяИмени() {
        XCTAssertEqual(FileOperationsService.folderComponents(of: "toys/alsde/dk"), ["toys", "alsde", "dk"])
        XCTAssertEqual(FileOperationsService.folderComponents(of: "/toys//dk/"), ["toys", "dk"])
        XCTAssertEqual(FileOperationsService.folderComponents(of: "одна"), ["одна"])
    }
}
