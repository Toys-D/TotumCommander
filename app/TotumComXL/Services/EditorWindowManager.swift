import AppKit
import Foundation

enum EditorDocumentSource {
    case fileSystem
    case archive(archivePath: String, entryPath: String, temporaryRoot: String)
}

@MainActor
final class EditorWindowManager {
    static let shared = EditorWindowManager()

    private var monacoControllers: [UUID: MonacoEditorWindow] = [:]

    private init() {}

    func openDocument(at path: String, source: EditorDocumentSource, operations: FileOperationsService) {
        // Use Monaco Editor (WKWebView + VS Code engine)
        if let existing = monacoControllers.values.first {
            existing.addTab(path: path, source: source)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let identifier = UUID()
        let controller = MonacoEditorWindow(
            identifier: identifier,
            path: path,
            source: source,
            operations: operations
        ) { [weak self] closedIdentifier in
            self?.monacoControllers[closedIdentifier] = nil
        }
        monacoControllers[identifier] = controller
        controller.showWindow(nil)
    }

    /// Paths of unsaved file-backed documents open in any standalone editor window that live on
    /// the given volume. Used to warn before ejecting so an edit isn't silently orphaned.
    func dirtyDocumentPaths(onVolume volumeRoot: String) -> [String] {
        monacoControllers.values.flatMap { $0.dirtyFileSystemPaths(onVolume: volumeRoot) }
    }
}
