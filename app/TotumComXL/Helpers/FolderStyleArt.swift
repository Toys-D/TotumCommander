import AppKit

/// Своя картинка папки в нужном размере и цвете.
///
/// SVG перекрашивается подстановкой: вместо цветов-ролей (FolderStyleRole) в текст рисунка
/// встают цвета папок, а рисует его сама macOS — чётко на любом размере. PNG перекрашивается по
/// светлоте: основной тон рисунка (тело папки) становится цветом папок, что светлее — светлее,
/// до белого, что темнее — темнее; прозрачность остаётся своей.
enum FolderStyleArt {

    /// Насколько задняя стенка темнее цвета папки — как у встроенных стилей (24–27 %).
    static let darkening: CGFloat = 0.25

    static func image(for entry: FolderStyleLibrary.Entry, size: CGFloat, tint: NSColor,
                      scale: CGFloat) -> NSImage? {
        let pixels = max(1, Int((size * scale).rounded()))
        let bitmap: NSBitmapImageRep?
        switch entry.format {
        case .svg:
            guard let text = svgText(entry) else { return nil }
            return image(svg: text, size: size, tint: tint, scale: scale)
        case .png:
            guard let png = pngImage(entry) else { return nil }
            bitmap = draw(png, pixels: pixels)
            if entry.recolor, let bitmap {
                paint(bitmap, tint: tint, base: baseLightness(entry, png))
            }
        }
        guard let bitmap else { return nil }
        bitmap.size = NSSize(width: size, height: size)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(bitmap)
        return image
    }

    // MARK: - SVG

    /// Рисунок SVG с цветами папок вместо ролей — для своих стилей и встроенного «Totum».
    static func image(svg text: String, size: CGFloat, tint: NSColor, scale: CGFloat) -> NSImage? {
        let pixels = max(1, Int((size * scale).rounded()))
        guard let svg = NSImage(data: Data(recolored(svg: text, tint: tint).utf8)),
              let bitmap = draw(svg, pixels: pixels) else { return nil }
        bitmap.size = NSSize(width: size, height: size)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(bitmap)
        return image
    }

    /// Текст рисунка с цветами папок вместо ролей. «#F0F» — тот же «#FF00FF».
    static func recolored(svg text: String, tint: NSColor) -> String {
        let folder = hex(tint)
        // Затемнение — в sRGB, долей каждого канала. NSColor.blended(…of: .black) смешивает в
        // другом пространстве, и тёмный красный выходил с примесью зелёного.
        let rgb = tint.usingColorSpace(.sRGB) ?? tint
        let dark = hex(NSColor(srgbRed: rgb.redComponent * (1 - darkening),
                               green: rgb.greenComponent * (1 - darkening),
                               blue: rgb.blueComponent * (1 - darkening), alpha: 1))
        var result = text
        for case let (expression?, color) in [(folderRole, folder), (darkRole, dark)] {
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: color)
        }
        return result
    }

    /// Цвета-роли в тексте SVG. Выражения одни на все вызовы: собирать их при каждой перекраске
    /// незачем. Шаблоны постоянные — не собраться могут только из-за опечатки в коде.
    private static let folderRole = try? NSRegularExpression(pattern: "#(?:FF00FF|F0F)(?![0-9A-Fa-f])",
                                                             options: .caseInsensitive)
    private static let darkRole = try? NSRegularExpression(pattern: "#B000B0(?![0-9A-Fa-f])",
                                                           options: .caseInsensitive)

    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }

    // MARK: - PNG

    /// Перекрасить по светлоте. `base` — светлота основного тона: он становится ровно цветом
    /// папок. Без этого жёлтая папка и синяя после перекраски вышли бы разной яркости.
    static func paint(_ bitmap: NSBitmapImageRep, tint: NSColor, base: CGFloat) {
        guard let data = bitmap.bitmapData, bitmap.samplesPerPixel == 4 else { return }
        let rgb = tint.usingColorSpace(.sRGB) ?? tint
        let color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        let shadow = color.map { $0 * 0.3 }
        let anchor = min(max(base, 0.2), 0.8)
        let count = bitmap.pixelsWide * bitmap.pixelsHigh
        for index in 0..<count {
            let pixel = data + index * 4
            let alpha = CGFloat(pixel[3]) / 255
            guard alpha > 0 else { continue }
            // Байты умножены на прозрачность — для светлоты нужен сам цвет.
            let r = CGFloat(pixel[0]) / 255 / alpha
            let g = CGFloat(pixel[1]) / 255 / alpha
            let b = CGFloat(pixel[2]) / 255 / alpha
            let lightness = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let painted: [CGFloat]
            if lightness <= anchor {
                let t = lightness / anchor
                painted = zip(shadow, color).map { $0 + ($1 - $0) * t }
            } else {
                let t = (lightness - anchor) / (1 - anchor)
                painted = color.map { $0 + (1 - $0) * t }
            }
            for channel in 0..<3 {
                pixel[channel] = UInt8((min(max(painted[channel], 0), 1) * alpha * 255).rounded())
            }
        }
    }

    /// Светлота основного тона — медиана по непрозрачным точкам: тело папки занимает больше
    /// всего места, лист и тени — меньше.
    static func lightness(ofMostOf image: NSImage) -> CGFloat {
        guard let pixels = FolderStyleValidator.rgba(of: image, side: 128) else { return 0.5 }
        var values: [CGFloat] = []
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let alpha = CGFloat(pixels[index + 3]) / 255
            let r = CGFloat(pixels[index]) / 255 / alpha
            let g = CGFloat(pixels[index + 1]) / 255 / alpha
            let b = CGFloat(pixels[index + 2]) / 255 / alpha
            values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        guard !values.isEmpty else { return 0.5 }
        values.sort()
        return values[values.count / 2]
    }

    // MARK: - Общее

    private static func draw(_ image: NSImage, pixels: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: pixels * 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        return bitmap
    }

    // Файлы библиотеки не меняются: id новый у каждой добавленной картинки. Поэтому прочитанное
    // держится по id, пока стиль в библиотеке.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var texts: [String: String] = [:]
    nonisolated(unsafe) private static var images: [String: NSImage] = [:]
    nonisolated(unsafe) private static var bases: [String: CGFloat] = [:]

    private static func svgText(_ entry: FolderStyleLibrary.Entry) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let text = texts[entry.id] { return text }
        let text = try? String(contentsOf: FolderStyleLibrary.fileURL(of: entry), encoding: .utf8)
        texts[entry.id] = text
        return text
    }

    private static func pngImage(_ entry: FolderStyleLibrary.Entry) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let image = images[entry.id] { return image }
        let image = NSImage(contentsOf: FolderStyleLibrary.fileURL(of: entry))
        images[entry.id] = image
        return image
    }

    private static func baseLightness(_ entry: FolderStyleLibrary.Entry, _ image: NSImage) -> CGFloat {
        lock.lock()
        if let base = bases[entry.id] {
            lock.unlock()
            return base
        }
        lock.unlock()
        let base = lightness(ofMostOf: image)
        lock.lock()
        bases[entry.id] = base
        lock.unlock()
        return base
    }

    /// Убранные из библиотеки — забыть.
    static func forget(keeping ids: Set<String>) {
        lock.lock()
        texts = texts.filter { ids.contains($0.key) }
        images = images.filter { ids.contains($0.key) }
        bases = bases.filter { ids.contains($0.key) }
        lock.unlock()
    }
}
