import CoreGraphics
import Foundation

/// Reading a DXF drawing — AutoCAD's exchange format, and the one every CAD program can write.
///
/// The format is a flat list of PAIRS: a group code on one line, its value on the next. Codes
/// have fixed meanings (10 is an X, 20 a Y, 8 a layer name, 0 the start of a new thing), so a
/// reader is a state machine over pairs rather than a grammar. That is why this is hand-written
/// and not a dependency: the subset a drawing needs to be LOOKED at is small, and the rest of
/// the format — blocks, dimensions, hatches — can be added later without changing the shape.
///
/// Only ASCII DXF is read. The binary flavour exists, is rare, and is recognised by its opening
/// sentinel so the viewer can say what it is instead of drawing nothing.
struct DXFDocument {

    enum Entity {
        case line(from: CGPoint, to: CGPoint, layer: String)
        case circle(centre: CGPoint, radius: CGFloat, layer: String)
        /// Angles in DEGREES, counter-clockwise from the X axis, as the format states them.
        case arc(centre: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, layer: String)
        case polyline(points: [CGPoint], closed: Bool, layer: String)
        case point(at: CGPoint, layer: String)
        case text(String, at: CGPoint, height: CGFloat, rotation: CGFloat, layer: String)
    }

    var entities: [Entity] = []
    /// Layer name → colour index as the file gives it (ACI). Absent means "by block/default".
    var layerColours: [String: Int] = [:]
    /// True when the file is the binary flavour, which this does not read.
    var isBinary = false

    // MARK: - Reading

    static let binarySentinel = "AutoCAD Binary DXF"

    static func read(data: Data) -> DXFDocument {
        var document = DXFDocument()
        if let head = String(data: data.prefix(binarySentinel.utf8.count), encoding: .ascii),
           head == binarySentinel {
            document.isBinary = true
            return document
        }
        // DXF is ASCII by definition, but files carry local text in whatever the machine used;
        // Latin-1 never fails, which matters more here than being right about one label.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        return read(text: text)
    }

    /// The whole reader. Pure text in, drawing out — so every rule below is testable without a
    /// file on disk.
    static func read(text: String) -> DXFDocument {
        var document = DXFDocument()
        let pairs = Self.pairs(in: text)

        var index = 0
        var section = ""
        var current: [Int: [String]] = [:]
        var currentKind = ""

        func flush() {
            defer { current = [:]; currentKind = "" }
            guard !currentKind.isEmpty else { return }
            if section == "TABLES", currentKind == "LAYER" {
                if let name = current[2]?.first, let colour = current[62]?.first.flatMap(Int.init) {
                    document.layerColours[name] = abs(colour)
                }
                return
            }
            guard section == "ENTITIES" else { return }
            if let entity = Self.entity(kind: currentKind, values: current) {
                document.entities.append(entity)
            }
        }

        while index < pairs.count {
            let (code, value) = pairs[index]
            index += 1
            if code == 0 {
                flush()
                switch value {
                case "SECTION":
                    // The section's name is the next 2-pair.
                    if index < pairs.count, pairs[index].code == 2 {
                        section = pairs[index].value
                        index += 1
                    }
                case "ENDSEC":
                    section = ""
                case "EOF":
                    break
                default:
                    currentKind = value
                }
                continue
            }
            guard !currentKind.isEmpty else { continue }
            current[code, default: []].append(value)
        }
        flush()
        return document
    }

    /// Code/value pairs. A DXF line holds ONE thing: an integer code, then its value on the
    /// following line. Whitespace around either is padding the format allows.
    nonisolated static func pairs(in text: String) -> [(code: Int, value: String)] {
        var out: [(Int, String)] = []
        var pendingCode: Int?
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let code = pendingCode {
                out.append((code, trimmed))
                pendingCode = nil
            } else if let code = Int(trimmed) {
                pendingCode = code
            }
            // A line that is neither a code nor a value (a stray blank) is simply skipped.
        }
        return out
    }

    /// One entity from the values gathered under it. Unknown kinds answer nil and are skipped —
    /// a drawing with a hatch in it should still show its lines.
    nonisolated static func entity(kind: String, values: [Int: [String]]) -> Entity? {
        func number(_ code: Int, _ position: Int = 0) -> CGFloat? {
            guard let list = values[code], list.count > position,
                  let value = Double(list[position]) else { return nil }
            return CGFloat(value)
        }
        let layer = values[8]?.first ?? "0"

        switch kind {
        case "LINE":
            guard let x1 = number(10), let y1 = number(20),
                  let x2 = number(11), let y2 = number(21) else { return nil }
            return .line(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2), layer: layer)

        case "CIRCLE":
            guard let x = number(10), let y = number(20), let r = number(40), r > 0 else { return nil }
            return .circle(centre: CGPoint(x: x, y: y), radius: r, layer: layer)

        case "ARC":
            guard let x = number(10), let y = number(20), let r = number(40), r > 0,
                  let start = number(50), let end = number(51) else { return nil }
            return .arc(centre: CGPoint(x: x, y: y), radius: r,
                        start: start, end: end, layer: layer)

        case "POINT":
            guard let x = number(10), let y = number(20) else { return nil }
            return .point(at: CGPoint(x: x, y: y), layer: layer)

        case "LWPOLYLINE":
            // Every vertex repeats codes 10 and 20, in order.
            let xs = values[10]?.compactMap(Double.init) ?? []
            let ys = values[20]?.compactMap(Double.init) ?? []
            let points = zip(xs, ys).map { CGPoint(x: $0, y: $1) }
            guard points.count >= 2 else { return nil }
            let closed = (values[70]?.first.flatMap(Int.init) ?? 0) & 1 == 1
            return .polyline(points: points, closed: closed, layer: layer)

        case "TEXT", "MTEXT":
            guard let x = number(10), let y = number(20) else { return nil }
            let content = (values[1] ?? []).joined()
            guard !content.isEmpty else { return nil }
            return .text(Self.plainText(content), at: CGPoint(x: x, y: y),
                         height: number(40) ?? 2.5, rotation: number(50) ?? 0, layer: layer)

        default:
            return nil
        }
    }

    /// MTEXT carries formatting in braces and backslashes — "\\pxqc;{\\fArial|b1;Hi}" is one
    /// word with a lot of decoration. The decoration is dropped rather than shown.
    nonisolated static func plainText(_ raw: String) -> String {
        var out = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\\" {
                let next = raw.index(after: index)
                guard next < raw.endIndex else { break }
                let code = raw[next]
                if code == "P" || code == "p" {          // paragraph break
                    out.append(" ")
                    index = raw.index(after: next)
                    // A \p… run ends at the first ";"
                    if code == "p" {
                        while index < raw.endIndex, raw[index] != ";" { index = raw.index(after: index) }
                        if index < raw.endIndex { index = raw.index(after: index) }
                    }
                    continue
                }
                if code == "\\" || code == "{" || code == "}" {   // an escaped literal
                    out.append(code)
                    index = raw.index(after: next)
                    continue
                }
                // Any other control run ends at ";" or at the next space.
                index = raw.index(after: next)
                while index < raw.endIndex, raw[index] != ";", raw[index] != " " {
                    index = raw.index(after: index)
                }
                if index < raw.endIndex { index = raw.index(after: index) }
                continue
            }
            if character == "{" || character == "}" {
                index = raw.index(after: index)
                continue
            }
            out.append(character)
            index = raw.index(after: index)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - What the drawing occupies

    /// The rectangle every entity fits inside, in the drawing's own units. Empty when there is
    /// nothing to show — the viewer says so rather than dividing by zero while fitting.
    var bounds: CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        func include(_ point: CGPoint) {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        for entity in entities {
            switch entity {
            case .line(let a, let b, _): include(a); include(b)
            case .circle(let c, let r, _), .arc(let c, let r, _, _, _):
                include(CGPoint(x: c.x - r, y: c.y - r)); include(CGPoint(x: c.x + r, y: c.y + r))
            case .polyline(let points, _, _): points.forEach(include)
            case .point(let p, _): include(p)
            case .text(_, let p, let h, _, _):
                include(p); include(CGPoint(x: p.x, y: p.y + h))
            }
        }
        guard minX <= maxX, minY <= maxY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var isEmpty: Bool { entities.isEmpty }

    /// Layers in the order a person reads them, for the viewer's caption.
    var layerNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entity in entities {
            let layer: String
            switch entity {
            case .line(_, _, let l), .circle(_, _, let l), .arc(_, _, _, _, let l),
                 .polyline(_, _, let l), .point(_, let l), .text(_, _, _, _, let l):
                layer = l
            }
            if seen.insert(layer).inserted { out.append(layer) }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
