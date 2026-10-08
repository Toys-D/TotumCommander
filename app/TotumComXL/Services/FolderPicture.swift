import AppKit

/// Своя картинка папки — как «Свойства ▸ вставить изображение» в Finder. Запись та же
/// (NSWorkspace.setIcon кладёт скрытый файл `Icon\r` в саму папку), так что картинку видят Finder
/// и другие программы, а показывает в панелях CustomFolderIconService.
@MainActor
enum FolderPicture {

    /// Метка «картинку назначили здесь» — на самой папке, поэтому переезжает вместе с ней. По
    /// ней картинка показывается, даже если похожа на обычную папку: такие ставят установщики,
    /// и панель их нарочно не показывает (CustomFolderIconService), а свою — должна.
    nonisolated static let markerAttribute = "com.totumcommander.folder-picture"

    /// Сторона, в которую вписывается картинка. Finder сам нарезает из неё все размеры значка.
    static let side = 1024

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func hasPicture(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("Icon\r"))
    }

    static func isAssignedHere(_ path: String) -> Bool {
        getxattr(path, markerAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Текущая картинка папки, если она есть.
    static func picture(of path: String) -> NSImage? {
        hasPicture(path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }

    /// Назначить: вписать в квадрат без искажения и записать, как Finder. Возвращает true, если
    /// пришлось включить показ картинок на папках — иначе назначенное в панелях не появилось бы.
    @discardableResult
    static func assign(_ image: NSImage, to path: String) throws -> Bool {
        guard let square = fitted(image) else {
            throw Failure(errorDescription: L("properties.picture.unreadable"))
        }
        guard NSWorkspace.shared.setIcon(square, forFile: path, options: []) else {
            throw Failure(errorDescription: L("properties.picture.failed", path))
        }
        _ = "1".withCString { setxattr(path, markerAttribute, $0, 1, 0, XATTR_NOFOLLOW) }
        let turnedOn = !CustomFolderIconService.isEnabled
        if turnedOn { UserDefaults.standard.set(true, forKey: CustomFolderIconService.enabledKey) }
        CustomFolderIconService.pictureChanged()
        return turnedOn
    }

    static func remove(from path: String) throws {
        guard NSWorkspace.shared.setIcon(nil, forFile: path, options: []) else {
            throw Failure(errorDescription: L("properties.picture.failed", path))
        }
        removexattr(path, markerAttribute, XATTR_NOFOLLOW)
        CustomFolderIconService.pictureChanged()
    }

    /// Картинка из буфера: сама картинка или файл с ней, скопированный в Finder.
    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let image = urls.lazy.compactMap({ NSImage(contentsOf: $0) }).first(where: \.isValid) {
            return image
        }
        return (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first(where: \.isValid)
    }

    /// Вписать в квадрат side×side по центру, поля прозрачные: вытянутая картинка не сплющится.
    static func fitted(_ image: NSImage) -> NSImage? {
        let source = image.size
        guard image.isValid, source.width > 0, source.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: side * 4, bitsPerPixel: 32) else { return nil }
        let canvas = CGFloat(side)
        let scale = min(canvas / source.width, canvas / source.height)
        let drawn = NSSize(width: source.width * scale, height: source.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: (canvas - drawn.width) / 2, y: (canvas - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: canvas, height: canvas)
        let result = NSImage(size: bitmap.size)
        result.addRepresentation(bitmap)
        return result
    }
}
