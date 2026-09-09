import SwiftUI
import XCTest
@testable import TotumComXLApp

private final class StubRemoteFileSystem: RemoteFileSystemProtocol {
    var isConnected = false
    let protocolDisplayName = "STUB"
    func connect() async throws { isConnected = true }
    func disconnect() { isConnected = false }
    func listDirectory(at path: String) async throws -> [FileItem] { [] }
    func createDirectory(at path: String, name: String) async throws {}
    func deleteItem(at path: String, isDirectory: Bool) async throws {}
    func rename(at path: String, to newName: String) async throws {}
    func moveItem(from sourcePath: String, to destinationPath: String) async throws {}
    func download(remotePath: String, to localPath: String,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {}
    func upload(localPath: String, to remotePath: String,
                progress: @escaping (Int64, Int64) -> Bool) async throws {}
}

/// Подключение видно из обеих панелей — как примонтированный том. Раньше чип сессии
/// был только у панели-хозяйки, и второй панели приходилось подключаться заново вслепую.
@MainActor
final class RemoteSessionRegistryTests: XCTestCase {

    private func session(_ label: String, connection: RemoteConnection? = nil) -> RemoteSession {
        RemoteSession(connection: connection ?? RemoteConnection(label: label, proto: .sftp, host: "h"),
                      fileSystem: StubRemoteFileSystem())
    }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                              pathDefaultsKey: "panel.path.registry.\(id)",
                              viewModeDefaultsKey: "panel.mode.registry.\(id)",
                              showHiddenFiles: false)
    }

    func test_панельЗаписываетСессиюВОбщийСписокИСнимаетПриВыходе() {
        let vm = panel()
        let a = session("A")
        defer { vm.remoteSession = nil }

        vm.remoteSession = a
        XCTAssertTrue(RemoteSessionRegistry.shared.sessions.contains { $0 === a })

        let b = session("B")
        vm.remoteSession = b
        XCTAssertFalse(RemoteSessionRegistry.shared.sessions.contains { $0 === a },
                       "прежняя сессия панели ушла из списка")
        XCTAssertTrue(RemoteSessionRegistry.shared.sessions.contains { $0 === b })

        vm.remoteSession = nil
        XCTAssertFalse(RemoteSessionRegistry.shared.sessions.contains { $0 === b })
    }

    func test_чипы_свояПерваяЧужиеСледомБезВторогоЧипаТогоЖеСервера() {
        let shared = RemoteConnection(label: "Drive", proto: .rclone, host: "")
        let own = session("own", connection: shared)
        let twin = session("twin", connection: shared)   // тот же сервер в другой панели
        let other = session("other")

        let chips = RemoteSessionRegistry.chips(own: own, all: [other, own, twin])
        XCTAssertEqual(chips.map { $0.session === own ? "own" : ($0.session === other ? "other" : "twin") },
                       ["own", "other"])
        XCTAssertEqual(chips.map(\.foreign), [false, true])

        let none = RemoteSessionRegistry.chips(own: nil, all: [other, twin])
        XCTAssertEqual(none.map(\.foreign), [true, true])
    }

    /// Чип чужой сессии рисуется в полосе панели, у которой своей сессии нет.
    func test_полосаРисуетЧужоеПодключение() throws {
        let owner = panel()
        let watcher = panel()
        let drive = session("Google Drive", connection: RemoteConnection(label: "Google Drive", proto: .rclone, host: ""))
        defer { owner.remoteSession = nil }

        func orangeInk(_ bitmap: NSBitmapImageRep) -> Int {
            guard let data = bitmap.bitmapData else { return 0 }
            let samples = bitmap.samplesPerPixel
            let alphaFirst = bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                let row = data + y * bitmap.bytesPerRow
                for x in 0..<bitmap.pixelsWide {
                    let px = row + x * samples + alphaFirst
                    if px[0] > 200, px[1] > 90, px[1] < 200, px[2] < 120 { count += 1 }
                }
            }
            return count
        }
        func render(_ name: String) throws -> NSBitmapImageRep {
            let view = PanelVolumeBar(viewModel: watcher)
                .frame(width: 700)
                .background(Color(white: 0.93))
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
            if let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"],
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
            }
            return bitmap
        }

        let before = orangeInk(try render("полоса-без-чужого"))
        owner.remoteSession = drive
        let after = orangeInk(try render("полоса-с-чужим"))
        XCTAssertGreaterThan(after, before + 100,
                             "оранжевый чип чужой сессии появился: \(after) против \(before)")
    }
}
