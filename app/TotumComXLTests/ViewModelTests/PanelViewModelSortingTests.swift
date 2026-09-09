import Foundation
import XCTest

@testable import TotumComXLApp

@MainActor
final class PanelViewModelSortingTests: XCTestCase {
    func test_sortByExtension_shouldKeepDirectoriesFirstInAllViewModes() throws {
        let fixture = try SortingFixture()
        defer { fixture.cleanup() }

        let panelViewModel = fixture.makeViewModel()
        panelViewModel.toggleSort(by: .fileExtension)

        assertDirectoriesGoFirst(in: panelViewModel.items)
        XCTAssertEqual(
            fileNames(in: panelViewModel.items),
            ["a.jpg", "b.png", "c.txt"]
        )

        panelViewModel.viewMode = .brief
        assertDirectoriesGoFirst(in: panelViewModel.items)
        XCTAssertEqual(fileNames(in: panelViewModel.items), ["a.jpg", "b.png", "c.txt"])

        panelViewModel.viewMode = .thumbnails
        assertDirectoriesGoFirst(in: panelViewModel.items)
        XCTAssertEqual(fileNames(in: panelViewModel.items), ["a.jpg", "b.png", "c.txt"])
    }

    func test_whenToggleNameSort_shouldReverseOrderInsideDirectoryAndFileGroups() throws {
        let fixture = try SortingFixture()
        defer { fixture.cleanup() }

        let panelViewModel = fixture.makeViewModel()
        panelViewModel.toggleSort(by: .name)

        assertDirectoriesGoFirst(in: panelViewModel.items)
        XCTAssertEqual(
            directoryNames(in: panelViewModel.items),
            ["docs", "apps"]
        )
        XCTAssertEqual(
            fileNames(in: panelViewModel.items),
            ["c.txt", "b.png", "a.jpg"]
        )
    }

    func test_sortBySize_shouldKeepDirectoriesFirstAndSortFilesBySize() throws {
        let fixture = try SortingFixture()
        defer { fixture.cleanup() }

        let panelViewModel = fixture.makeViewModel()
        panelViewModel.toggleSort(by: .size)

        assertDirectoriesGoFirst(in: panelViewModel.items)
        XCTAssertEqual(
            fileNames(in: panelViewModel.items),
            ["a.jpg", "b.png", "c.txt"]
        )
        XCTAssertEqual(
            fileSizes(in: panelViewModel.items),
            [1, 2, 3]
        )
    }

    func test_sortByDate_shouldSortDirectoriesByDateInsideDirectoryGroup() throws {
        let fixture = try SortingFixture()
        defer { fixture.cleanup() }

        let panelViewModel = fixture.makeViewModel()
        panelViewModel.toggleSort(by: .dateModified)

        assertDirectoriesGoFirst(in: panelViewModel.items)
        XCTAssertEqual(
            directoryNames(in: panelViewModel.items),
            ["apps", "docs"]
        )

        panelViewModel.toggleSort(by: .dateModified)
        XCTAssertEqual(
            directoryNames(in: panelViewModel.items),
            ["docs", "apps"]
        )
    }

    func test_sortByExtension_shouldBeIndependentFromCursorType() throws {
        let fixture = try SortingFixture()
        defer { fixture.cleanup() }

        let dirCursorViewModel = fixture.makeViewModel()
        let fileCursorViewModel = fixture.makeViewModel()

        guard let directoryIndex = dirCursorViewModel.items.firstIndex(where: { $0.name != ".." && $0.isDirectory }),
              let fileIndex = fileCursorViewModel.items.firstIndex(where: { !$0.isDirectory })
        else {
            XCTFail("Не удалось подготовить курсор на папке/файле")
            return
        }

        dirCursorViewModel.setCursor(index: directoryIndex)
        fileCursorViewModel.setCursor(index: fileIndex)

        dirCursorViewModel.toggleSort(by: .fileExtension)
        fileCursorViewModel.toggleSort(by: .fileExtension)

        XCTAssertEqual(
            dirCursorViewModel.items.map(\.path),
            fileCursorViewModel.items.map(\.path)
        )
    }

    private func assertDirectoriesGoFirst(in items: [FileItem]) {
        let visibleItems = items.filter { $0.name != ".." }
        guard let firstFileIndex = visibleItems.firstIndex(where: { !$0.isDirectory }) else {
            return
        }
        let leadingItems = visibleItems[..<firstFileIndex]
        let trailingItems = visibleItems[firstFileIndex...]
        XCTAssertTrue(leadingItems.allSatisfy(\.isDirectory))
        XCTAssertTrue(trailingItems.allSatisfy { !$0.isDirectory })
    }

    private func directoryNames(in items: [FileItem]) -> [String] {
        items
            .filter { $0.name != ".." && $0.isDirectory }
            .map(\.name)
    }

    private func fileNames(in items: [FileItem]) -> [String] {
        items
            .filter { $0.name != ".." && !$0.isDirectory }
            .map(\.name)
    }

    private func fileSizes(in items: [FileItem]) -> [UInt64] {
        items
            .filter { $0.name != ".." && !$0.isDirectory }
            .map(\.size)
    }
}

@MainActor
private final class SortingFixture {
    let rootURL: URL

    init() throws {
        let fileManager = FileManager.default
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("fcxl-sort-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        try fileManager.createDirectory(at: rootURL.appendingPathComponent("apps"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootURL.appendingPathComponent("docs"), withIntermediateDirectories: true)

        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: rootURL.appendingPathComponent("apps").path
        )
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_750_000_000)],
            ofItemAtPath: rootURL.appendingPathComponent("docs").path
        )

        try Data(repeating: 65, count: 3).write(to: rootURL.appendingPathComponent("c.txt"))
        try Data(repeating: 66, count: 2).write(to: rootURL.appendingPathComponent("b.png"))
        try Data(repeating: 67, count: 1).write(to: rootURL.appendingPathComponent("a.jpg"))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeViewModel() -> PanelViewModel {
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: rootURL.path,
            pathDefaultsKey: "panel.path.sort.tests.\(UUID().uuidString)",
            viewModeDefaultsKey: "panel.mode.sort.tests.\(UUID().uuidString)",
            showHiddenFiles: true
        )
        // loadDirectory is async — populate items synchronously so tests run
        // without waiting for the background Task to finish.
        let children = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
        vm.allItems = children.compactMap { name in
            FileItem.fromPath(rootURL.appendingPathComponent(name).path)
        }
        return vm
    }
}
