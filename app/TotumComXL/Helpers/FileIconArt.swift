import AppKit
import UniformTypeIdentifiers

// MARK: - Стиль значков файлов

/// Чем рисовать значки файлов: значками macOS или своими — листом цвета вида файла с
/// расширением внизу. Значкам macOS можно включить контур: новые значки — почти белые листы,
/// и на светлой панели их не видно. Контур тонкий, акцентным цветом, и только у тех, что
/// сливаются с фоном: где значок и так виден (цветной, на тёмном фоне), его не трогают.
enum FileIconStyle: String, CaseIterable, Identifiable {
    case macos
    case totum

    var id: String { rawValue }
    var title: String { L("fileIconStyle.\(rawValue)") }

    /// Рабочий ключ — его читают панели; выбор помнится на каждую тему, как у картинки папок.
    static let storageKey = "fileIconStyle"
    static let lightKey = "fileIconStyleLight"
    static let darkKey = "fileIconStyleDark"

    static let fallback: FileIconStyle = .macos

    static func current(in defaults: UserDefaults = .standard) -> FileIconStyle {
        defaults.string(forKey: storageKey).flatMap(FileIconStyle.init(rawValue:)) ?? fallback
    }

    /// Выбрать для темы на экране; другая тема помнит своё.
    static func choose(_ style: FileIconStyle, dark: Bool, in defaults: UserDefaults = .standard) {
        themed.choose(style.rawValue, dark: dark, in: defaults)
    }

    /// Тема сменилась — её выбор на экран, и стиль, и контур. Зовётся из
    /// `PanelAppearanceSettings.syncThemedColorsToEffective()` вместе с цветами.
    static func mirror(dark: Bool, in defaults: UserDefaults = .standard) {
        themed.mirror(dark: dark, in: defaults)
        themedContour.mirror(dark: dark, in: defaults)
    }

    private static let themed = ThemedChoice(working: storageKey, light: lightKey, dark: darkKey,
                                             fallback: fallback.rawValue)

    // MARK: Контур

    /// Контур у значков macOS, что сливаются с панелью, — тоже на каждую тему.
    static let contourKey = "fileIconContour"
    static let contourLightKey = "fileIconContourLight"
    static let contourDarkKey = "fileIconContourDark"

    /// Пока не трогали — включён: там, где значки видны, это те же значки macOS.
    static let defaultContour = true

    static func contour(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: contourKey) as? Bool ?? defaultContour
    }

    static func chooseContour(_ on: Bool, dark: Bool, in defaults: UserDefaults = .standard) {
        themedContour.choose(on, dark: dark, in: defaults)
    }

    private static let themedContour = ThemedChoice(working: contourKey, light: contourLightKey,
                                                    dark: contourDarkKey, fallback: defaultContour)

    /// Контур был третьим стилем, «macOS с контуром». Тот, кто его выбирал, получает macOS с
    /// включённым контуром, а выбравший macOS — без него: что было на экране, то и остаётся.
    static func migrateContourStyleIfNeeded(_ defaults: UserDefaults = .standard) {
        let pairs = [(storageKey, contourKey), (lightKey, contourLightKey), (darkKey, contourDarkKey)]
        for (styleKey, contourFlagKey) in pairs {
            guard let raw = defaults.string(forKey: styleKey), defaults.object(forKey: contourFlagKey) == nil
            else { continue }
            if raw == "contour" {
                defaults.set(FileIconStyle.macos.rawValue, forKey: styleKey)
                defaults.set(true, forKey: contourFlagKey)
            } else if raw == FileIconStyle.macos.rawValue {
                defaults.set(false, forKey: contourFlagKey)
            }
        }
    }
}

// MARK: - Облик: стиль и фон под значком

/// Всё, от чего зависит картинка значка файла: стиль, контур и фон, на котором значок стоит.
///
/// Фон хранится ступенями яркости, а не цветом. Цвет панели, пока его тянут в настройках,
/// меняется на каждом шаге мыши, а картинка — только когда яркость переходит на другую
/// ступень; список перерисовывается тогда же, а не за каждым движением.
struct FileIconLook: Hashable {
    let style: FileIconStyle
    /// Контур у значков macOS, что сливаются с фоном.
    let contour: Bool
    /// Ступени яркости фона (0…20): панель и полоса строк, если она есть. Нужны только
    /// контуру — он решает по ним, сливается ли значок.
    let backgroundSteps: [Int]
    /// Фон тёмный: свои значки берут тёмный лист, контур без своего цвета — светлую линию.
    let darkBackground: Bool
    /// Цвет контура, sRGB 0…255 с прозрачностью; nil — нейтральная линия под фон. Числами, а не
    /// NSColor: облик сравнивается и собирает ключ запаса, а значки рисуются и в фоне.
    let contourRGBA: [Int]?

    static let steps: CGFloat = 20

    init(style: FileIconStyle, backgrounds: [NSColor], contour: Bool = false, contourColor: NSColor? = nil) {
        self.style = style
        // Контур — только у значков macOS. Облик, от фона и цвета не зависящий, при их смене
        // не меняется и ничего не перерисовывает: своим значкам важно лишь «светлый фон или
        // тёмный», значкам macOS без контура — ничего.
        let outlined = style == .macos && contour
        self.contour = outlined
        let luminances = backgrounds.map(ContrastAppearance.luminance(of:))
        backgroundSteps = outlined ? luminances.map { Int(($0 * Self.steps).rounded()) } : []
        darkBackground = (outlined || style == .totum) && (luminances.first ?? 1) < ContrastAppearance.darkBelow
        contourRGBA = outlined ? contourColor?.usingColorSpace(.sRGB).map {
            [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent].map { Int(($0 * 255).rounded()) }
        } : nil
    }

    /// Облик по настройкам: выбранный стиль, контур той темы, что на экране, — акцентным
    /// цветом программы.
    @MainActor
    static func current(backgrounds: [NSColor], style: FileIconStyle = .current(),
                        contour: Bool = FileIconStyle.contour()) -> FileIconLook {
        FileIconLook(style: style, backgrounds: backgrounds, contour: contour,
                     contourColor: PanelAppearanceSettings.accentNSColor)
    }

    /// Значки на панели: её фон и полоса строк той темы, что на экране.
    @MainActor
    static func panel(background: NSColor, stripe: NSColor?, style: FileIconStyle = .current(),
                      contour: Bool = FileIconStyle.contour()) -> FileIconLook {
        current(backgrounds: [background] + [stripe].compactMap { $0 }, style: style, contour: contour)
    }

    var contourColor: NSColor? {
        contourRGBA.map { c in
            NSColor(srgbRed: CGFloat(c[0]) / 255, green: CGFloat(c[1]) / 255, blue: CGFloat(c[2]) / 255,
                    alpha: CGFloat(c[3]) / 255)
        }
    }

    var cacheToken: String {
        "\(style.rawValue)\(contour ? "+c" : "")-\(darkBackground ? "d" : "l")-"
            + backgroundSteps.map(String.init).joined(separator: ".")
            + "-" + (contourRGBA?.map(String.init).joined(separator: ".") ?? "")
    }
}

// MARK: - Значки по расширению

/// Значок файла по расширению — один на вид файла, размер и облик, запомненный.
///
/// Им пользуются все виды панели и поиск: стиль из настроек один на всех. Звать можно с
/// любой очереди — значок macOS спрашивается у LaunchServices, а это не быстро, и подробный
/// список делает это в фоне.
enum FileIcons {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [String: NSImage] = [:]
    nonisolated(unsafe) private static var systemIcons: [String: NSImage] = [:]
    /// Яркость края системного значка — одна на расширение, от фона не зависит.
    nonisolated(unsafe) private static var edges: [String: CGFloat] = [:]
    private static let plain = NSWorkspace.shared.icon(for: .data)

    static func normalized(_ fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        return ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
    }

    static func key(forExtension fileExtension: String, size: CGFloat, look: FileIconLook) -> String {
        "\(normalized(fileExtension))|\(Int((size * 2).rounded()))|\(look.cacheToken)"
    }

    /// Готовый значок — без похода в LaunchServices; nil, пока его никто не спрашивал.
    static func cached(forExtension fileExtension: String, size: CGFloat, look: FileIconLook) -> NSImage? {
        let key = key(forExtension: fileExtension, size: size, look: look)
        lock.lock(); defer { lock.unlock() }
        return images[key]
    }

    static func icon(forExtension fileExtension: String, size: CGFloat, look: FileIconLook) -> NSImage {
        let ext = normalized(fileExtension)
        let key = key(forExtension: ext, size: size, look: look)
        lock.lock()
        if let ready = images[key] { lock.unlock(); return ready }
        lock.unlock()

        let made: NSImage
        switch look.style {
        case .macos:
            let base = systemIcon(ext)
            if look.contour, FileIconArt.needsContour(edge: edgeLuminance(ext, of: base), look: look) {
                let color = look.contourColor, dark = look.darkBackground
                made = FileIconArt.contoured(base, size: size, color: color, darkBackground: dark)
                // Под курсором — заново крупнее, а не растяжкой (LiftRaster).
                RedrawRegistry.register(made) { points in
                    FileIconArt.contoured(base, size: points, color: color, darkBackground: dark)
                }
            } else {
                made = base
            }
        case .totum:
            let dark = look.darkBackground
            made = FileIconArt.totum(extension: ext, size: size, darkBackground: dark)
            RedrawRegistry.register(made) { points in
                FileIconArt.totum(extension: ext, size: points, darkBackground: dark)
            }
        }

        lock.lock()
        images[key] = made
        lock.unlock()
        return made
    }

    private static func systemIcon(_ ext: String) -> NSImage {
        guard !ext.isEmpty else { return plain }
        lock.lock()
        if let known = systemIcons[ext] { lock.unlock(); return known }
        lock.unlock()
        let icon = UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? plain
        lock.lock()
        systemIcons[ext] = icon
        lock.unlock()
        return icon
    }

    private static func edgeLuminance(_ ext: String, of icon: NSImage) -> CGFloat? {
        lock.lock()
        if let known = edges[ext] { lock.unlock(); return known }
        lock.unlock()
        guard let measured = FileIconArt.edgeLuminance(of: icon) else { return nil }
        lock.lock()
        edges[ext] = measured
        lock.unlock()
        return measured
    }
}

// MARK: - Вид файла — для своих значков

enum FileKind: CaseIterable {
    case image, video, audio, archive, diskImage, pdf, document, spreadsheet, presentation
    case book, code, text, font, other

    static func of(_ fileExtension: String) -> FileKind {
        let ext = FileIcons.normalized(fileExtension)
        guard !ext.isEmpty else { return .other }
        // Сначала — те, что система числит не тем: docx, xlsx и epub для неё zip-архивы,
        // а djvu и fb2 она не знает вовсе.
        switch ext {
        case "doc", "docx", "pages", "rtf", "rtfd", "odt", "wpd": return .document
        case "xls", "xlsx", "numbers", "ods", "csv", "tsv": return .spreadsheet
        case "ppt", "pptx", "key", "odp": return .presentation
        case "djvu", "djv", "epub", "fb2", "mobi", "azw", "azw3", "cbz", "cbr": return .book
        case "dmg", "iso", "img", "sparseimage", "sparsebundle", "toast": return .diskImage
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .presentation) { return .presentation }
        if type.conforms(to: .font) { return .font }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .html) || type.conforms(to: .xml) { return .code }
        if type.conforms(to: .text) { return .text }
        return .other
    }

    var color: NSColor {
        switch self {
        case .image: return NSColor(srgbRed: 0.18, green: 0.66, blue: 0.41, alpha: 1)
        case .video: return NSColor(srgbRed: 0.55, green: 0.36, blue: 0.84, alpha: 1)
        case .audio: return NSColor(srgbRed: 0.87, green: 0.27, blue: 0.47, alpha: 1)
        case .archive: return NSColor(srgbRed: 0.77, green: 0.53, blue: 0.16, alpha: 1)
        case .diskImage: return NSColor(srgbRed: 0.35, green: 0.47, blue: 0.59, alpha: 1)
        case .pdf: return NSColor(srgbRed: 0.86, green: 0.25, blue: 0.22, alpha: 1)
        case .document: return NSColor(srgbRed: 0.18, green: 0.48, blue: 0.87, alpha: 1)
        case .spreadsheet: return NSColor(srgbRed: 0.09, green: 0.57, blue: 0.48, alpha: 1)
        case .presentation: return NSColor(srgbRed: 0.89, green: 0.45, blue: 0.17, alpha: 1)
        case .book: return NSColor(srgbRed: 0.36, green: 0.37, blue: 0.83, alpha: 1)
        case .code: return NSColor(srgbRed: 0.16, green: 0.62, blue: 0.72, alpha: 1)
        case .text: return NSColor(srgbRed: 0.48, green: 0.51, blue: 0.55, alpha: 1)
        case .font: return NSColor(srgbRed: 0.69, green: 0.34, blue: 0.56, alpha: 1)
        case .other: return NSColor(srgbRed: 0.56, green: 0.58, blue: 0.61, alpha: 1)
        }
    }

    /// Знак вида посреди листа; у «прочего» листа его нет — только расширение.
    var symbol: String? {
        switch self {
        case .image: return "photo"
        case .video: return "play.fill"
        case .audio: return "music.note"
        case .archive: return "archivebox"
        case .diskImage: return "opticaldiscdrive"
        case .pdf: return "doc.richtext"
        case .document: return "text.alignleft"
        case .spreadsheet: return "tablecells"
        case .presentation: return "chart.bar"
        case .book: return "book.closed"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "text.alignleft"
        case .font: return "textformat"
        case .other: return nil
        }
    }
}

// MARK: - Рисование

enum FileIconArt {

    /// Ниже этого отношения контраста край значка с фоном сливается: белый лист на белом —
    /// 1.1, на светло-сером полосы — 1.2; синий PDF на белом — больше четырёх.
    static let contourBelow: CGFloat = 1.6

    static func needsContour(edge: CGFloat?, look: FileIconLook) -> Bool {
        guard look.contour, let edge else { return false }
        return look.backgroundSteps.contains { step in
            let background = CGFloat(step) / FileIconLook.steps
            return (max(edge, background) + 0.05) / (min(edge, background) + 0.05) < contourBelow
        }
    }

    /// Средняя яркость края значка: видимые точки, у которых рядом прозрачные. По ней и
    /// решается, виден ли значок на фоне, — середина листа тут ни при чём.
    static func edgeLuminance(of icon: NSImage) -> CGFloat? {
        let side = 32
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            guard x >= 0, y >= 0, x < side, y < side else { return 0 }
            return pixels[(y * side + x) * 4 + 3]
        }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var sum: CGFloat = 0, count: CGFloat = 0
        for y in 0..<side {
            for x in 0..<side where alpha(x, y) > 153 {
                let border = [(-2, 0), (2, 0), (0, -2), (0, 2)].contains { alpha(x + $0.0, y + $0.1) < 51 }
                guard border else { continue }
                let i = (y * side + x) * 4
                let a = CGFloat(pixels[i + 3]) / 255
                let r = CGFloat(pixels[i]) / 255 / a, g = CGFloat(pixels[i + 1]) / 255 / a
                let b = CGFloat(pixels[i + 2]) / 255 / a
                sum += 0.2126 * linear(min(r, 1)) + 0.7152 * linear(min(g, 1)) + 0.0722 * linear(min(b, 1))
                count += 1
            }
        }
        return count > 0 ? sum / count : nil
    }

    // MARK: Растр на каждый масштаб экрана

    /// Масштабы экранов, под которые рисуется свой растр: обычный и Retina.
    static let screenScales: [CGFloat] = [1, 2]

    /// Картинка из растров на каждый масштаб экрана — каждый нарисован в своих точках, а не
    /// растянут из другого, как у значков macOS. Картинка с рисованием «по требованию»
    /// растягивалась экраном из одного растра и мылилась; здесь прямые края встают ровно на
    /// точки. `draw` рисует в точках растра: начало в левом нижнем углу, сторона — `side`.
    static func pixelExact(size: CGFloat, draw: (_ ctx: CGContext, _ side: Int, _ scale: CGFloat) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in screenScales {
            let side = max(1, Int((size * scale).rounded()))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            draw(ctx, side, scale)
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: size, height: size)
            image.addRepresentation(rep)
        }
        return image
    }

    // MARK: Обводка

    /// Значок macOS с контуром цвета `color` (в программе — акцентного); без цвета — на светлом
    /// фоне тёмным, на тёмном светлым. Контур — самая тонкая линия: одна точка экрана.
    ///
    /// Значок стоит в полный размер, как у macOS: уменьшенный под контур, он пересчитывался в
    /// чужое число точек и мылился. Контур — его же силуэт, раздвинутый на точку растра, а не
    /// копии со сдвигом и не тень: край у него такой же чёткий, как у самого значка.
    static func contoured(_ base: NSImage, size: CGFloat, color: NSColor? = nil, darkBackground: Bool) -> NSImage {
        let line = (color ?? (darkBackground ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0.25, alpha: 0.42)))
            .usingColorSpace(.sRGB) ?? NSColor(white: 0.25, alpha: 0.42)
        return pixelExact(size: size) { ctx, side, _ in
            let full = NSRect(x: 0, y: 0, width: side, height: side)
            base.draw(in: full)
            guard let data = ctx.data else { return }
            let count = side * side
            let pixels = data.bindMemory(to: UInt8.self, capacity: count * 4)
            let silhouette = (0..<count).map { pixels[$0 * 4 + 3] }
            // Радиус полторы точки: соседи по стороне — целиком, по диагонали — сглаженно.
            // Линия выходит в одну точку растра, углы — без зубцов.
            let grown = dilate(silhouette, side: side, radius: 1.5)
            let red = line.redComponent, green = line.greenComponent, blue = line.blueComponent
            for i in 0..<count {
                let cover = CGFloat(grown[i]) / 255 * line.alphaComponent
                pixels[i * 4] = UInt8((red * cover * 255).rounded())
                pixels[i * 4 + 1] = UInt8((green * cover * 255).rounded())
                pixels[i * 4 + 2] = UInt8((blue * cover * 255).rounded())
                pixels[i * 4 + 3] = UInt8((cover * 255).rounded())
            }
            base.draw(in: full)
        }
    }

    /// Силуэт, раздвинутый кругом радиуса `radius` точек. Край круга сглажен на одну точку,
    /// как у любой фигуры на экране, остальное — целыми точками.
    static func dilate(_ alpha: [UInt8], side: Int, radius: CGFloat) -> [UInt8] {
        let reach = Int((radius + 0.5).rounded(.up))
        var offsets: [(dx: Int, dy: Int, weight: Int)] = []
        for dy in -reach...reach {
            for dx in -reach...reach where dx != 0 || dy != 0 {
                let distance = CGFloat(dx * dx + dy * dy).squareRoot()
                let weight = min(1, max(0, radius + 0.5 - distance))
                if weight > 0 { offsets.append((dx, dy, Int((weight * 256).rounded()))) }
            }
        }
        var out = [UInt8](repeating: 0, count: alpha.count)
        alpha.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                for y in 0..<side {
                    for x in 0..<side {
                        var best = Int(source[y * side + x])
                        if best < 255 {
                            for offset in offsets {
                                let nx = x + offset.dx, ny = y + offset.dy
                                guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                                let value = Int(source[ny * side + nx]) * offset.weight >> 8
                                if value > best { best = value; if best >= 255 { break } }
                            }
                        }
                        target[y * side + x] = UInt8(min(255, best))
                    }
                }
            }
        }
        return out
    }

    // MARK: Свои значки

    /// Что написано на полосе: расширение заглавными, до пяти букв; длиннее — первые четыре.
    static func label(for fileExtension: String) -> String {
        let ext = FileIcons.normalized(fileExtension).uppercased()
        return ext.count <= 5 ? ext : String(ext.prefix(4))
    }

    /// Свой значок: лист с загнутым уголком в светлом (на тёмной панели — тёмном) тоне цвета
    /// вида, знак вида посередине, расширение на цветной полосе внизу. Всё — в долях размера,
    /// чтобы значок был одним и тем же в списке и в эскизах.
    static func totum(extension fileExtension: String, size: CGFloat, darkBackground: Bool) -> NSImage {
        let kind = FileKind.of(fileExtension)
        let label = label(for: fileExtension)
        return pixelExact(size: size) { _, side, _ in
            drawTotum(kind: kind, label: label, side: CGFloat(side), darkBackground: darkBackground)
        }
    }

    private static let darkPaper = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.11, alpha: 1)

    /// Рисует в точках растра. Всё прямое — края листа, полоса, обводка, уголок — стоит на
    /// целых точках: линия, попавшая между ними, расплывается на две соседние.
    private static func drawTotum(kind: FileKind, label: String, side: CGFloat, darkBackground dark: Bool) {
        let unit = side / 22
        let color = kind.color
        func mix(_ fraction: CGFloat, _ other: NSColor) -> NSColor { color.blended(withFraction: fraction, of: other) ?? color }

        let inset = (3 * unit).rounded(), lift = (0.5 * unit).rounded()
        let page = NSRect(x: inset, y: lift, width: side - 2 * inset, height: side - 2 * lift)
        let fold = (5.5 * unit).rounded()
        let corner = max(1, (1.5 * unit).rounded())
        let line = max(1, unit.rounded())
        let band = label.isEmpty ? 0 : (8.5 * unit).rounded()
        let path = pagePath(page, fold: fold, corner: corner)

        (dark ? mix(0.72, darkPaper) : mix(0.86, .white)).setFill()
        path.fill()

        if band > 0 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            color.setFill()
            NSRect(x: page.minX, y: page.minY, width: page.width, height: band).fill()
            NSGraphicsContext.restoreGraphicsState()
            drawLabel(label, in: NSRect(x: page.minX, y: page.minY, width: page.width, height: band), unit: unit)
        }

        let flap = NSBezierPath()
        flap.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
        flap.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
        flap.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
        flap.close()
        (dark ? mix(0.45, darkPaper) : mix(0.55, .white)).setFill()
        flap.fill()

        // Обводка — внутри листа: путь сдвинут внутрь на полтолщины, и линия ложится ровно
        // на крайние точки листа, а не наполовину за его край.
        let half = line / 2
        let edge = pagePath(page.insetBy(dx: half, dy: half), fold: fold - half * (2 - 2.squareRoot()),
                            corner: max(0, corner - half))
        (dark ? mix(0.15, .white) : color).setStroke()
        edge.lineWidth = line
        edge.stroke()

        // Знак вида — над полосой; в совсем мелком значке ему места нет.
        guard side >= 14, let name = kind.symbol else { return }
        let tint = dark ? mix(0.25, .white) : color
        let config = NSImage.SymbolConfiguration(pointSize: 7 * unit, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let free = NSRect(x: page.minX, y: page.minY + band, width: page.width,
                          height: page.height - band - fold * 0.4)
        let fit = min(1, free.width * 0.8 / symbol.size.width, free.height * 0.8 / symbol.size.height)
        let drawn = NSSize(width: (symbol.size.width * fit).rounded(), height: (symbol.size.height * fit).rounded())
        symbol.draw(in: NSRect(x: (free.midX - drawn.width / 2).rounded(), y: (free.midY - drawn.height / 2).rounded(),
                               width: drawn.width, height: drawn.height))
    }

    /// Расширение по середине полосы, шрифтом под её ширину: «PDF» крупнее, «SWIFT» мельче.
    private static func drawLabel(_ label: String, in band: NSRect, unit: CGFloat) {
        var fontSize = (label.count >= 4 ? 5.2 : 6.0) * unit
        var text: NSAttributedString
        repeat {
            text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: NSColor.white,
            ])
            if text.size().width <= band.width - 1.5 * unit { break }
            fontSize -= 0.25 * unit
        } while fontSize > 3 * unit
        let size = text.size()
        text.draw(at: NSPoint(x: (band.midX - size.width / 2).rounded(),
                              y: (band.midY - size.height / 2 + 0.3 * unit).rounded()))
    }

    private static func pagePath(_ r: NSRect, fold: CGFloat, corner c: CGFloat) -> NSBezierPath {
        let k = c * 0.4
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + c, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - c, y: r.minY))
        p.curve(to: NSPoint(x: r.maxX, y: r.minY + c),
                controlPoint1: NSPoint(x: r.maxX - k, y: r.minY), controlPoint2: NSPoint(x: r.maxX, y: r.minY + k))
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - fold))
        p.line(to: NSPoint(x: r.maxX - fold, y: r.maxY))
        p.line(to: NSPoint(x: r.minX + c, y: r.maxY))
        p.curve(to: NSPoint(x: r.minX, y: r.maxY - c),
                controlPoint1: NSPoint(x: r.minX + k, y: r.maxY), controlPoint2: NSPoint(x: r.minX, y: r.maxY - k))
        p.line(to: NSPoint(x: r.minX, y: r.minY + c))
        p.curve(to: NSPoint(x: r.minX + c, y: r.minY),
                controlPoint1: NSPoint(x: r.minX, y: r.minY + k), controlPoint2: NSPoint(x: r.minX + k, y: r.minY))
        p.close()
        return p
    }
}
