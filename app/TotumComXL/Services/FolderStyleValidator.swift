import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Цвета-роли своего SVG. Вместо них программа подставляет цвет папок — так своя картинка
/// перекрашивается, как встроенные стили. Других цветов в рисунке быть не может.
enum FolderStyleRole {
    /// Цвет папки.
    static let folder = "#FF00FF"
    /// Цвет папки темнее — задняя стенка, клапан.
    static let folderDark = "#B000B0"
    /// Остаётся белым — лист в папке.
    static let paper = "#FFFFFF"
    /// Остаётся чёрным — тени, обычно с прозрачностью.
    static let shadow = "#000000"

    static let all: Set<String> = [folder, folderDark, paper, shadow]
}

/// Что не так с картинкой. У каждого правила свой текст: человек должен понять, что исправить.
enum FolderStyleProblem: Equatable {
    case format
    case fileTooBig(limitKB: Int)
    case notSVG
    case noViewBox
    case notSquare
    case text
    case styleBlock
    case hiddenLayers
    case references
    case forbidden([String])
    case colors([String])
    case noFolderColor
    case tooComplex
    case unrenderable
    case pngUnreadable
    case pngNotSquare(width: Int, height: Int)
    case pngTooSmall(side: Int)
    case pngTooLarge(side: Int)
    case pngNoAlpha
    case pngOpaqueBackground
    case empty

    var message: String {
        switch self {
        case .format: return L("folderStyles.problem.format")
        case .fileTooBig(let limit): return L("folderStyles.problem.fileTooBig", limit)
        case .notSVG: return L("folderStyles.problem.notSVG")
        case .noViewBox: return L("folderStyles.problem.noViewBox")
        case .notSquare: return L("folderStyles.problem.notSquare")
        case .text: return L("folderStyles.problem.text")
        case .styleBlock: return L("folderStyles.problem.styleBlock")
        case .hiddenLayers: return L("folderStyles.problem.hiddenLayers")
        case .references: return L("folderStyles.problem.references")
        case .forbidden(let names): return L("folderStyles.problem.forbidden", names.joined(separator: ", "))
        case .colors(let colors): return L("folderStyles.problem.colors", colors.joined(separator: ", "))
        case .noFolderColor: return L("folderStyles.problem.noFolderColor")
        case .tooComplex: return L("folderStyles.problem.tooComplex", FolderStyleValidator.maxElements)
        case .unrenderable: return L("folderStyles.problem.unrenderable")
        case .pngUnreadable: return L("folderStyles.problem.pngUnreadable")
        case .pngNotSquare(let width, let height): return L("folderStyles.problem.pngNotSquare", width, height)
        case .pngTooSmall(let side): return L("folderStyles.problem.pngTooSmall", FolderStyleValidator.minSide, side)
        case .pngTooLarge(let side): return L("folderStyles.problem.pngTooLarge", FolderStyleValidator.maxSide, side)
        case .pngNoAlpha: return L("folderStyles.problem.pngNoAlpha")
        case .pngOpaqueBackground: return L("folderStyles.problem.pngOpaqueBackground")
        case .empty: return L("folderStyles.problem.empty")
        }
    }
}

/// Строгие правила для своих картинок папок. Картинка, не прошедшая их, в программу не попадает.
///
/// SVG рисует сама macOS, и рисует не всё так, как ждёшь: скрытые слои (`display:none`) она
/// показывает, неквадратный холст растягивает. Поэтому правила строже, чем «лишь бы открылось»:
/// только залитые фигуры, только цвета-роли, без текста, ссылок, скриптов и стилей.
enum FolderStyleValidator {
    static let svgLimit = 200 * 1024
    static let pngLimit = 2 * 1024 * 1024
    static let minSide = 512
    static let maxSide = 2048
    static let maxElements = 2000

    static func problems(at url: URL) -> [FolderStyleProblem] {
        let kind = url.pathExtension.lowercased()
        guard kind == "svg" || kind == "png" else { return [.format] }
        // Размер — до чтения: огромный файл незачем грузить в память ради отказа.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let limit = kind == "svg" ? svgLimit : pngLimit
        guard size <= limit else { return [.fileTooBig(limitKB: limit / 1024)] }
        guard let data = try? Data(contentsOf: url) else { return kind == "svg" ? [.notSVG] : [.pngUnreadable] }
        return kind == "svg" ? problems(svg: data) : problems(png: data)
    }

    // MARK: - SVG

    static func problems(svg data: Data) -> [FolderStyleProblem] {
        guard data.count <= svgLimit else { return [.fileTooBig(limitKB: svgLimit / 1024)] }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return [.notSVG] }
        // Свои сущности в DTD — путь к внешним файлам и к «бомбам» из вложенных подстановок.
        if text.contains("<!ENTITY") { return [.references] }

        let scan = SVGScan()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = scan
        guard parser.parse(), scan.root == "svg" else { return [.notSVG] }

        var found: [FolderStyleProblem] = []
        if let box = scan.viewBox {
            let numbers = box.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if numbers.count != 4 || numbers[2] <= 0 || numbers[3] <= 0
                || abs(numbers[2] - numbers[3]) > 0.005 * max(numbers[2], numbers[3]) {
                found.append(.notSquare)
            }
        } else {
            found.append(.noViewBox)
        }
        if scan.text { found.append(.text) }
        if scan.styleBlock { found.append(.styleBlock) }
        if scan.hidden { found.append(.hiddenLayers) }
        if scan.references { found.append(.references) }
        if !scan.forbidden.isEmpty { found.append(.forbidden(scan.forbidden.sorted())) }
        let strangers = scan.colors.subtracting(FolderStyleRole.all)
        if !strangers.isEmpty { found.append(.colors(strangers.sorted())) }
        if !scan.colors.contains(FolderStyleRole.folder) { found.append(.noFolderColor) }
        if scan.elements > maxElements { found.append(.tooComplex) }
        if found.isEmpty, !draws(svg: data) { found.append(.unrenderable) }
        return found
    }

    /// Цвет так, как его сравнивают с ролями: «#f0f» и «#ff00ff» — это «#FF00FF».
    static func normalized(_ color: String) -> String {
        let value = color.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("#") else { return value }
        let hex = value.dropFirst().uppercased()
        if hex.count == 3 { return "#" + hex.map { "\($0)\($0)" }.joined() }
        return "#" + hex
    }

    /// macOS действительно его рисует: хоть одна непрозрачная точка.
    private static func draws(svg data: Data) -> Bool {
        guard let image = NSImage(data: data), let pixels = rgba(of: image, side: 64) else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 128 }
    }

    // MARK: - PNG

    static func problems(png data: Data) -> [FolderStyleProblem] {
        guard data.count <= pngLimit else { return [.fileTooBig(limitKB: pngLimit / 1024)] }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [.pngUnreadable] }

        var found: [FolderStyleProblem] = []
        if image.width != image.height {
            found.append(.pngNotSquare(width: image.width, height: image.height))
        } else if image.width < minSide {
            found.append(.pngTooSmall(side: image.width))
        } else if image.width > maxSide {
            found.append(.pngTooLarge(side: image.width))
        }
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else {
            return found + [.pngNoAlpha]
        }
        let side = 64
        guard let pixels = rgba(of: NSImage(cgImage: image, size: .zero), side: side) else {
            return found + [.pngUnreadable]
        }
        // Фон — по углам: у картинки папки на прозрачном фоне они пустые.
        let corners = [(0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1)]
        if corners.contains(where: { pixels[($0.1 * side + $0.0) * 4 + 3] > 25 }) {
            found.append(.pngOpaqueBackground)
        }
        if !stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] > 128 }) {
            found.append(.empty)
        }
        return found
    }

    /// Картинка в квадрате side×side, RGBA по байту на канал (с умножением на прозрачность).
    static func rgba(of image: NSImage, side: Int) -> [UInt8]? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        guard let data = bitmap.bitmapData else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: side * side * 4))
    }
}

/// Проход по разметке SVG: что в ней есть из запрещённого и какие цвета.
private final class SVGScan: NSObject, XMLParserDelegate {
    private(set) var root: String?
    private(set) var viewBox: String?
    private(set) var elements = 0
    private(set) var forbidden: Set<String> = []
    private(set) var text = false
    private(set) var styleBlock = false
    private(set) var hidden = false
    private(set) var references = false
    /// Все цвета заливок и обводок, кроме «none». Фигура без заливки рисуется чёрным —
    /// это и так разрешённый цвет тени.
    private(set) var colors: Set<String> = []
    /// Внутри metadata — служебное описание (Illustrator кладёт туда RDF), оно не рисуется.
    private var metadataDepth = 0
    /// Текст блока стилей, пока его читают.
    private var stylesheet: String?

    private static let shapes: Set<String> = [
        "svg", "g", "defs", "path", "rect", "circle", "ellipse", "polygon", "polyline", "line",
        "title", "desc",
    ]
    private static let textElements: Set<String> = ["text", "tspan", "textPath"]
    private static let referencing: Set<String> = ["mask", "clip-path", "filter"]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if metadataDepth > 0 || name == "metadata" {
            metadataDepth += 1
            return
        }
        if root == nil {
            root = name
            viewBox = attributes["viewBox"]
        }
        elements += 1
        if Self.textElements.contains(name) {
            text = true
        } else if name == "style" {
            stylesheet = ""
        } else if !Self.shapes.contains(name) {
            forbidden.insert(name)
        }
        for (key, value) in attributes {
            let attribute = key.lowercased()
            if attribute.hasPrefix("on") || attribute == "href" || attribute.hasSuffix(":href")
                || Self.referencing.contains(attribute) || value.lowercased().contains("url(") {
                references = true
            }
            switch attribute {
            case "fill", "stroke": note(value)
            case "style": read(style: value)
            case "display": if value.trimmingCharacters(in: .whitespaces) == "none" { hidden = true }
            case "visibility": if value.trimmingCharacters(in: .whitespaces) == "hidden" { hidden = true }
            default: break
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if metadataDepth > 0 {
            metadataDepth -= 1
        } else if let css = stylesheet, (elementName.split(separator: ":").last.map(String.init) ?? elementName) == "style" {
            stylesheet = nil
            read(stylesheet: css)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stylesheet? += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stylesheet? += String(decoding: CDATABlock, as: UTF8.self)
    }

    /// Блок стилей — так Illustrator пишет цвета по умолчанию: `.st0 { fill: #f0f; }`. Простые
    /// классы читаются, как атрибут style: те же цвета, скрытое, ссылки. Всё сложнее — @import,
    /// селекторы не по классу — отказ: что из этого нарисует macOS, заранее не сказать.
    private func read(stylesheet raw: String) {
        let css = raw.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        guard !css.contains("@"), let rule = try? NSRegularExpression(pattern: #"([^{}]*)\{([^{}]*)\}"#) else {
            styleBlock = true
            return
        }
        let whole = NSRange(css.startIndex..., in: css)
        for match in rule.matches(in: css, range: whole) {
            guard let selectors = Range(match.range(at: 1), in: css),
                  let declarations = Range(match.range(at: 2), in: css) else { continue }
            let plainClasses = css[selectors].split(separator: ",").allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .range(of: #"^\.[A-Za-z_][\w-]*$"#, options: .regularExpression) != nil
            }
            if !plainClasses { styleBlock = true }
            read(style: String(css[declarations]))
        }
        let outside = rule.stringByReplacingMatches(in: css, range: whole, withTemplate: "")
        if !outside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { styleBlock = true }
    }

    private func read(style: String) {
        for declaration in style.split(separator: ";") {
            // Illustrator пишет стили в несколько строк — обрезаются и переводы строк.
            let parts = declaration.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else { continue }
            let property = parts[0].lowercased(), value = parts[1]
            if value.lowercased().contains("url(") { references = true }
            switch property {
            case "fill", "stroke": note(value)
            case "display": if value == "none" { hidden = true }
            case "visibility": if value == "hidden" { hidden = true }
            default: if Self.referencing.contains(property), value != "none" { references = true }
            }
        }
    }

    private func note(_ value: String) {
        let color = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard color.lowercased() != "none" else { return }
        colors.insert(FolderStyleValidator.normalized(color))
    }
}
