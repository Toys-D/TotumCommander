import AppKit

/// Каким цветом писать имя файла.
///
/// Раньше расклад был зашит в код — список расширений и семь цветов, — и работал только в
/// кратком виде и в миниатюрах: в подробном списке имена оставались одноцветными. Теперь
/// цвета задаёт человек (см. `FileColorRules`), а это — единственная дверь к ним, общая для
/// всех трёх видов панели.
enum FileTypeColorPalette {

    static func color(for item: FileItem,
                      folderColor: NSColor,
                      fileColor: NSColor) -> NSColor {
        let base: NSColor = (item.isDirectory || item.name == "..") ? folderColor : fileColor
        guard item.name != ".." else { return base }
        return FileColorRulesStore.shared.color(for: item, base: base) ?? base
    }

    /// Для тех мест, где от файла остались только имя и признак папки — например, ячейка
    /// краткого вида во время переименования.
    static func color(name: String,
                      isDirectory: Bool,
                      created: Date?,
                      folderColor: NSColor,
                      fileColor: NSColor) -> NSColor {
        let base: NSColor = isDirectory ? folderColor : fileColor
        guard name != ".." else { return base }
        let stamp = created ?? Date.distantPast
        let item = FileItem(path: "/" + name, name: name,
                            fileExtension: (name as NSString).pathExtension,
                            size: 0, isDirectory: isDirectory, isHidden: false,
                            isSymlink: false, isAlias: false, symlinkTarget: nil,
                            hardlinkCount: 1, permissions: "", dateModified: stamp,
                            dateCreated: stamp, dateAdded: stamp, owner: "", entryCount: 0)
        return FileColorRulesStore.shared.color(for: item, base: base) ?? base
    }
}
