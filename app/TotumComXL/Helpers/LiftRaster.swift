import AppKit

/// Картинки, которые программа рисует сама, и как нарисовать каждую в другом размере — заново,
/// а не растяжкой готового растра. Регистрирует тот, кто рисует (значки файлов, папки), звать
/// можно с любой очереди; перерисовку просит подъём значка под курсором, на главной.
enum RedrawRegistry {
    private final class Entry: @unchecked Sendable {
        let redraw: (CGFloat) -> NSImage
        init(_ redraw: @escaping (CGFloat) -> NSImage) { self.redraw = redraw }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static let table = NSMapTable<NSImage, Entry>.weakToStrongObjects()

    /// `redraw` получает сторону в точках и возвращает ту же картинку этого размера.
    static func register(_ image: NSImage, redraw: @escaping (CGFloat) -> NSImage) {
        lock.lock(); defer { lock.unlock() }
        table.setObject(Entry(redraw), forKey: image)
    }

    static func redraw(for image: NSImage) -> ((CGFloat) -> NSImage)? {
        lock.lock(); defer { lock.unlock() }
        return table.object(forKey: image)?.redraw
    }
}

/// Значок под курсором — крупным растром.
///
/// Подъём значка — растяжка слоя: картинка в нём нарисована под обычный размер, и растянутая
/// на треть она мылилась — у значков macOS так же, как у своих. Поднятому значку здесь
/// подкладывается растр под поднятый размер, опустившемуся возвращается обычный. Значки macOS
/// и программ перерисовываются из своих больших растров, свои значки и папки — заново в
/// поднятом размере (RedrawRegistry).
@MainActor
enum LiftRaster {
    private final class Sharp {
        let key: String
        let image: NSImage
        init(key: String, image: NSImage) { self.key = key; self.image = image }
    }

    /// Что лежало в значке до подъёма — вернуть, когда курсор уйдёт.
    private static let originals = NSMapTable<NSImageView, NSImage>.weakToStrongObjects()
    /// Крупный растр картинки — один, пока не сменятся увеличение или экран.
    private static let sharp = NSMapTable<NSImage, Sharp>.weakToStrongObjects()

    /// Подложить значку растр под его подъём `scale` (1 — обычный размер) или вернуть обычный.
    static func prepare(_ view: NSImageView, scale: CGFloat) {
        let shown = view.image
        if let original = originals.object(forKey: view) {
            if let shown, sharp.object(forKey: original)?.image === shown {
                if scale <= 1 {
                    view.image = original
                    originals.removeObject(forKey: view)
                }
                return
            }
            // Картинку с тех пор сменили (ячейку отдали другой строке) — обычная теперь она.
            originals.removeObject(forKey: view)
        }
        // Шаблон (стрелка «наверх») красится цветом значка — растр этот цвет потерял бы.
        guard scale > 1, let shown, !shown.isTemplate else { return }
        let backing = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let big = sharpImage(for: shown, zoom: max(scale, CursorIconZoom.effectiveScale),
                                   backing: backing) else { return }
        originals.setObject(shown, forKey: view)
        view.image = big
    }

    /// Та же картинка того же размера в точках, но с растром под увеличение `zoom` на экране
    /// с масштабом `backing`.
    static func sharpImage(for image: NSImage, zoom: CGFloat, backing: CGFloat) -> NSImage? {
        let key = "\(Int((zoom * 100).rounded()))-\(Int((backing * 100).rounded()))"
        if let known = sharp.object(forKey: image), known.key == key { return known.image }
        let points = image.size
        guard points.width > 0, points.height > 0 else { return nil }
        let wide = Int((points.width * backing * zoom).rounded(.up))
        let high = Int((points.height * backing * zoom).rounded(.up))

        var rep: NSBitmapImageRep?
        if let redraw = RedrawRegistry.redraw(for: image) {
            // Своя картинка — заново в поднятом размере; берётся растр, ближайший к нужному.
            // Копией: растр принадлежит той, большой картинке, и размер ему здесь меняется.
            rep = redraw(points.width * zoom).representations
                .compactMap { $0 as? NSBitmapImageRep }
                .min { abs($0.pixelsWide - wide) < abs($1.pixelsWide - wide) }?
                .copy() as? NSBitmapImageRep
        }
        if rep == nil, let drawn = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) {
            // Чужая картинка (значок macOS, программы) — из её же растров, самого подходящего.
            drawn.size = NSSize(width: wide, height: high)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: drawn)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: wide, height: high))
            NSGraphicsContext.restoreGraphicsState()
            rep = drawn
        }
        guard let rep else { return nil }
        rep.size = points
        let out = NSImage(size: points)
        out.addRepresentation(rep)
        sharp.setObject(Sharp(key: key, image: out), forKey: image)
        return out
    }
}
