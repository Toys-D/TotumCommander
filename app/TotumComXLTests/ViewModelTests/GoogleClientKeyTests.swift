import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Свой ключ Google: к какой службе он идёт и что считается ключом.
///
/// Хранение (связка ключей, настройки) здесь не трогается: проверки не пишут в данные
/// человека.
final class GoogleClientKeyTests: XCTestCase {

    private let key = GoogleClientKey(id: "123-abc.apps.googleusercontent.com", secret: "GOCSPX-x")

    private func service(_ type: String) -> RcloneCloudService {
        RcloneCloudService(type: type, title: type, icon: "cloud", logo: "", tint: "#000000")
    }

    func test_ключИдётТолькоКGoogle() {
        let drive = GoogleClientKey.pair(for: service("drive"), stored: key)
        XCTAssertEqual(drive.id, key.id)
        XCTAssertEqual(drive.secret, key.secret)

        let photos = GoogleClientKey.pair(for: service("google photos"), stored: key)
        XCTAssertEqual(photos.id, key.id)

        for other in ["dropbox", "onedrive", "yandex", "box", "pcloud"] {
            let pair = GoogleClientKey.pair(for: service(other), stored: key)
            XCTAssertEqual(pair.id, "", other)
            XCTAssertEqual(pair.secret, "", other)
        }
    }

    func test_безКлючаИлиСПоловинойИдётОбщий() {
        XCTAssertEqual(GoogleClientKey.pair(for: service("drive"), stored: nil).id, "")
        let half = GoogleClientKey(id: key.id, secret: "")
        let pair = GoogleClientKey.pair(for: service("drive"), stored: half)
        XCTAssertEqual(pair.id, "")
        XCTAssertEqual(pair.secret, "")
    }

    func test_ПлиткаGoogleDriveПринимаетКлюч() {
        let drive = RcloneCloudService.popular.first { $0.title == "Google Drive" }
        XCTAssertNotNil(drive)
        XCTAssertEqual(GoogleClientKey.pair(for: drive!, stored: key).id, key.id)
    }

    func test_узнаётИдентификаторКлиента() {
        XCTAssertTrue(GoogleClientKey.looksLikeClientID(key.id))
        XCTAssertTrue(GoogleClientKey.looksLikeClientID("  \(key.id)\n"))
        XCTAssertFalse(GoogleClientKey.looksLikeClientID("GOCSPX-abcdef"))
        XCTAssertFalse(GoogleClientKey.looksLikeClientID(".apps.googleusercontent.com"))
        XCTAssertFalse(GoogleClientKey.looksLikeClientID("a b.apps.googleusercontent.com"))
    }
}

/// Как выглядят поля ключа в Настройках ▸ Сеть — в обеих темах и в обоих состояниях.
@MainActor
final class GoogleClientKeyLookTests: XCTestCase {

    func test_поляРисуются() throws {
        let folder = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] ?? NSTemporaryDirectory()
        let stored = GoogleClientKey(id: "123456-abcdef.apps.googleusercontent.com", secret: "x")
        for (name, scheme) in [("светлая", ColorScheme.light), ("тёмная", ColorScheme.dark)] {
            for (state, saved) in [("пусто", nil), ("задан", stored)] as [(String, GoogleClientKey?)] {
                let view = GoogleClientKeySettingsView(saved: saved)
                    .padding(16)
                    .frame(width: 480)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage, "\(name), \(state)")
                let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                    .representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: folder)
                    .appendingPathComponent("ключ-google-\(state)-\(name).png"))
            }
        }
    }
}
