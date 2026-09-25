import AppKit

/// Finder's colour labels, in the order Finder itself lists them.
///
/// A tag is stored as a plain name; the colour comes from that name matching one of the seven
/// standard ones. Finder localises what it DISPLAYS but keeps the English names on disk, so the
/// stored value has to stay English or the tag stops being one of the coloured seven.
enum FinderTag: String, CaseIterable, Identifiable {
    case red = "Red", orange = "Orange", yellow = "Yellow", green = "Green"
    case blue = "Blue", purple = "Purple", gray = "Gray"

    var id: String { rawValue }

    var color: NSColor {
        switch self {
        case .red:    return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green:  return .systemGreen
        case .blue:   return .systemBlue
        case .purple: return .systemPurple
        case .gray:   return .systemGray
        }
    }

    /// Localised name for the UI only — never written to disk.
    var localizedName: String { L("tag.\(rawValue.lowercased())") }
}

/// The coloured dots that follow a name in every panel mode.
///
/// They are drawn as an image attachment rather than a "●" glyph. A text run cannot be sized or
/// spaced independently of the line it sits on: the glyph came out tiny and pressed against the
/// name, and enlarging the run past the field's own font got it clipped by the line height instead
/// of growing the line. An attachment carries its own bounds, so the dot is exactly the diameter
/// asked for, keeps a chosen distance from the name, and cannot be cut in half.
enum FinderTagDots {
    /// Clear space between the name and the first dot.
    private static let leadingGap: CGFloat = 7
    /// Space between two dots of a multiply-tagged file.
    private static let dotGap: CGFloat = 3

    /// Thickness of the white ring around a dot. It is what keeps the colour readable when the row
    /// sits under the cursor bar or the selection tint, whose own colour would otherwise touch it.
    private static let ringWidth: CGFloat = 1.5

    /// Outer diameter, ring included. Big enough to read the colour at a glance, small enough to
    /// stay inside the line box — the attachment is clipped if it reaches past the font's ascender.
    /// The ring is drawn on the edge, so the diameter carries it without shrinking the colour.
    static func diameter(for font: NSFont) -> CGFloat {
        min(max(10, (font.pointSize * 0.8).rounded()), font.ascender)
    }

    /// Total width the dots occupy, gap included. Callers that reserve space need this.
    static func width(_ tags: [FinderTag], font: NSFont) -> CGFloat {
        guard !tags.isEmpty else { return 0 }
        let d = diameter(for: font)
        return leadingGap + CGFloat(tags.count) * d + CGFloat(tags.count - 1) * dotGap
    }

    /// The dots as a plain image, for the modes that place them in a view of their own.
    static func image(_ tags: [FinderTag], font: NSFont) -> NSImage? {
        guard !tags.isEmpty else { return nil }
        let d = diameter(for: font)
        let total = width(tags, font: font)

        // The drawing-handler form re-runs on an appearance change, so the system colours resolve
        // to their light or dark variant on their own — a bitmap baked once would keep whichever
        // theme was active when it was made.
        let image = NSImage(size: NSSize(width: total, height: d), flipped: false) { _ in
            // A stroke straddles its path, half in and half out. Insetting by half the ring keeps
            // the outer edge exactly on `d`, so the ring cannot be clipped by the image bounds.
            let inset = ringWidth / 2
            for (index, tag) in tags.enumerated() {
                let x = leadingGap + CGFloat(index) * (d + dotGap)
                let circle = NSBezierPath(ovalIn: NSRect(x: x + inset, y: inset,
                                                        width: d - ringWidth, height: d - ringWidth))
                tag.color.setFill()
                circle.fill()
                NSColor.white.setStroke()
                circle.lineWidth = ringWidth
                circle.stroke()
            }
            return true
        }

        return image
    }

    /// The dots as text, for the modes that append them to a label.
    static func attributed(_ tags: [FinderTag], font: NSFont) -> NSAttributedString? {
        guard let image = image(tags, font: font) else { return nil }
        let d = diameter(for: font)
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centred on the cap height, so the dots sit level with the letters rather than on the
        // baseline (where they would hang below the text).
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - d) / 2,
                                   width: image.size.width, height: d)
        return NSAttributedString(attachment: attachment)
    }
}

/// Reading and writing Finder tags.
///
/// Reading goes through URLResourceValues. Writing has to go through NSURL: the Swift setter for
/// `tagNames` is macOS 26+, while the Objective-C `setResourceValue:forKey:` has no such gate and
/// writes the very same `com.apple.metadata:_kMDItemUserTags` attribute Finder uses — verified on
/// this deployment target.
enum FinderTagService {

    static func tags(at path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// The coloured tags of a file, in Finder's order, ignoring any free-text tags it also carries.
    static func colorTags(at path: String) -> [FinderTag] {
        let names = Set(tags(at: path))
        return FinderTag.allCases.filter { names.contains($0.rawValue) }
    }

    @discardableResult
    static func setTags(_ names: [String], at path: String) -> Bool {
        let url = NSURL(fileURLWithPath: path)
        do {
            // An empty array clears the attribute, which is how a tag is removed.
            try url.setResourceValue(names as NSArray, forKey: .tagNamesKey)
            return true
        } catch {
            return false
        }
    }

    /// Add or remove one colour, leaving any other tags on the file untouched.
    @discardableResult
    static func toggle(_ tag: FinderTag, at path: String) -> Bool {
        var names = tags(at: path)
        if let index = names.firstIndex(of: tag.rawValue) {
            names.remove(at: index)
        } else {
            names.append(tag.rawValue)
        }
        return setTags(names, at: path)
    }

    /// Does this file carry the tag already? Used to tick the menu item.
    static func hasTag(_ tag: FinderTag, at path: String) -> Bool {
        tags(at: path).contains(tag.rawValue)
    }

    @discardableResult
    static func clear(at path: String) -> Bool {
        setTags([], at: path)
    }

    /// Show the file in Finder, selected — the one Finder interaction people miss most.
    static func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
