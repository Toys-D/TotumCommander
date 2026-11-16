import AppKit

/// Totum Commander вместо Finder.
///
/// Когда программа просит «Показать в Finder» (`activateFileViewerSelectingURLs`,
/// `selectFile(_:inFileViewerRootedAtPath:)`), AppKit смотрит настройку `NSFileViewer`; стоит
/// там наш идентификатор (`defaults write -g NSFileViewer -string com.fcxl.filecommander`) —
/// запрос уходит нам. Приходит он обычным «открыть документ» (odoc) с самим путём, проверено
/// опытом на macOS 27: для файла — путь файла, не его папки. Поэтому папка открывается в
/// активной панели, а файл показывается в своей папке с курсором на нём и ничем не
/// запускается. Так же ведёт себя `open -a "Totum Commander" <папка>`.
enum FileViewerRequest {
    struct Target: Equatable {
        /// Папка, которую показать.
        let folder: String
        /// На чём поставить курсор; nil — на первой строке, как при обычном входе в папку.
        let cursor: String?
    }

    /// Папка — она сама; файл, программа (папка-пакет) и прочее — папка, где лежит, и курсор
    /// на нём. Чего нет на диске или что не файл — nil.
    static func target(for url: URL) -> Target? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue, !NSWorkspace.shared.isFilePackage(atPath: path) {
            return Target(folder: path, cursor: nil)
        }
        return Target(folder: (path as NSString).deletingLastPathComponent, cursor: path)
    }

    /// Из нескольких путей — первый, что есть на диске: панель показывает одну папку.
    static func target(for urls: [URL]) -> Target? {
        urls.lazy.compactMap { target(for: $0) }.first
    }

    /// Показать в панели — тем же путём, что «перейти к файлу» у поиска: папка открывается,
    /// курсор встаёт на файл.
    @MainActor
    static func show(_ target: Target, in panel: PanelViewModel) {
        panel.loadDirectory(at: target.folder, preferredCursorPath: target.cursor)
    }
}
