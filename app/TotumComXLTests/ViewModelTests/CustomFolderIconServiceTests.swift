import XCTest
import AppKit
@testable import TotumComXLApp

/// Icons a user assigns to a folder in Finder. The tests write a real one with the system API, so
/// what they exercise is the same `Icon\r` file Finder creates — not a stand-in for it.
@MainActor
final class CustomFolderIconServiceTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tagicons-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: CustomFolderIconService.enabledKey)
        CustomFolderIconService.clearCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: CustomFolderIconService.enabledKey)
        CustomFolderIconService.clearCache()
        super.tearDown()
    }

    private func makeFolder(_ name: String, customIcon: Bool, picture: NSImage? = nil) -> FileItem {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if customIcon {
            let art = picture ?? NSImage(size: NSSize(width: 128, height: 128), flipped: false) { _ in
                NSColor.systemTeal.setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 128, height: 128)).fill()
                return true
            }
            XCTAssertTrue(NSWorkspace.shared.setIcon(art, forFile: url.path),
                          "could not assign a custom icon — the rest of this test proves nothing")
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
            as? Date) ?? Date()
        return FileItem(path: url.path, name: name, fileExtension: "", size: 0,
                        isDirectory: true, isHidden: false, isSymlink: false,
                        permissions: "drwxr-xr-x", dateModified: modified ?? Date())
    }

    func test_folderWithAnAssignedPictureReturnsIt() {
        let folder = makeFolder("Designed", customIcon: true)
        let icon = CustomFolderIconService.icon(for: folder, size: 32)
        XCTAssertNotNil(icon, "the picture assigned in Finder never reached the panel")
        XCTAssertEqual(icon?.size, NSSize(width: 32, height: 32))
    }

    /// The panel's own folder style and tint must survive on every ordinary folder.
    func test_plainFolderKeepsThePanelStyle() {
        let folder = makeFolder("Plain", customIcon: false)
        XCTAssertNil(CustomFolderIconService.icon(for: folder, size: 32))
    }

    func test_settingOffMeansNoLookupAtAll() {
        let folder = makeFolder("Designed", customIcon: true)
        UserDefaults.standard.set(false, forKey: CustomFolderIconService.enabledKey)
        CustomFolderIconService.clearCache()
        XCTAssertNil(CustomFolderIconService.icon(for: folder, size: 32))
    }

    func test_parentEntryAndFilesAreLeftAlone() {
        let folder = makeFolder("Designed", customIcon: true)
        let parent = FileItem(path: folder.path, name: "..", fileExtension: "", size: 0,
                              isDirectory: true, isHidden: false, isSymlink: false,
                              permissions: "drwxr-xr-x", dateModified: Date())
        XCTAssertNil(CustomFolderIconService.icon(for: parent, size: 32))

        let file = FileItem(path: folder.path, name: "note.txt", fileExtension: "txt", size: 1,
                            isDirectory: false, isHidden: false, isSymlink: false,
                            permissions: "-rw-r--r--", dateModified: Date())
        XCTAssertNil(CustomFolderIconService.icon(for: file, size: 32))
    }

    /// Installers hand folders an icon that is a picture of an ordinary folder. Honouring those
    /// makes a few folders drop the configured style while their neighbours keep it, which reads as
    /// the panel being broken. The system's own folder icon is exactly that kind of artwork, so it
    /// is the sharpest possible case to assign.
    func test_pictureOfAPlainFolderIsNotTreatedAsAPicture() {
        let folderArt = NSWorkspace.shared.icon(for: .folder)
        let folder = makeFolder("InstallerStyle", customIcon: true, picture: folderArt)
        XCTAssertNil(CustomFolderIconService.icon(for: folder, size: 32),
                     "folder-shaped artwork overrode the folder style chosen in Settings")
    }

    /// …while a real picture still wins, or the setting would do nothing at all.
    func test_aRealPictureStillOverridesTheStyle() {
        let folder = makeFolder("Designed", customIcon: true)
        XCTAssertNotNil(CustomFolderIconService.icon(for: folder, size: 32))
    }

    /// Each mode asks for a different size from the same cached picture, so handing out the cached
    /// instance itself would let one mode resize another mode's icon.
    func test_differentSizesDoNotFightOverTheCachedImage() {
        let folder = makeFolder("Designed", customIcon: true)
        let small = CustomFolderIconService.icon(for: folder, size: 16)
        let large = CustomFolderIconService.icon(for: folder, size: 64)
        XCTAssertEqual(small?.size, NSSize(width: 16, height: 16),
                       "asking for a bigger icon resized the one already handed out")
        XCTAssertEqual(large?.size, NSSize(width: 64, height: 64))
    }

    /// Assigning an icon rewrites the folder, which moves its mtime — the cache key includes that,
    /// so a folder that gains an icon while the app is open must stop reporting "none".
    func test_cacheDoesNotOutliveTheFolderGainingAnIcon() {
        var folder = makeFolder("Later", customIcon: false)
        XCTAssertNil(CustomFolderIconService.icon(for: folder, size: 32))

        let picture = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { _ in
            NSColor.systemPink.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
            return true
        }
        XCTAssertTrue(NSWorkspace.shared.setIcon(picture, forFile: folder.path))

        let modified = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate]
            as? Date) ?? Date()
        folder = FileItem(path: folder.path, name: folder.name, fileExtension: "", size: 0,
                          isDirectory: true, isHidden: false, isSymlink: false,
                          permissions: "drwxr-xr-x", dateModified: modified ?? Date())
        XCTAssertNotNil(CustomFolderIconService.icon(for: folder, size: 32),
                        "the panel kept showing the plain folder after an icon was assigned")
    }
}
