import AppKit

/// How Git's answer is drawn in the panel: one letter per row, in a gutter before the name.
///
/// A gutter rather than a suffix, because the value of these marks is reading a whole folder at
/// once — a column of letters is scanned in a glance, while marks trailing names of different
/// lengths have to be hunted for one by one. The gutter is as wide as the widest thing in the
/// listing and disappears entirely outside a repository, so a folder that has nothing to do with
/// Git looks exactly as it always did.
enum GitBadgeChip {
    /// Clear space kept between the gutter and the name.
    static let trailingGap: CGFloat = 6

    /// The colour of each state. System colours in the dark theme; in the light theme the
    /// same hues, darkened — a system orange or teal on a light grey row is too faint to
    /// read, and a letter that cannot be read tells nothing.
    static func color(for mark: GitMark) -> NSColor {
        switch mark {
        case .modified:   return themed(.systemOrange)
        case .added:      return themed(.systemGreen)
        case .deleted:    return themed(.systemRed)
        case .renamed:    return themed(.systemBlue)
        case .untracked:  return themed(.systemTeal)
        case .conflicted: return themed(.systemRed)
        case .ignored:    return themed(.tertiaryLabelColor, light: .secondaryLabelColor)
        }
    }

    /// How much darker a mark is in the light theme.
    static let lightThemeDarkening: CGFloat = 0.35

    /// A colour that resolves per appearance: `dark` as is, `light` (or `dark` darkened)
    /// under the light theme.
    static func themed(_ dark: NSColor, light: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark { return dark }
            return light ?? dark.blended(withFraction: lightThemeDarkening, of: .black) ?? dark
        }
    }

    /// The letters are drawn in a monospaced face: every row's mark then has the same width and
    /// the column stays a column.
    static func font(for base: NSFont) -> NSFont {
        .monospacedSystemFont(ofSize: max(9, base.pointSize * 0.85), weight: .semibold)
    }

    private static func branchFont(for base: NSFont) -> NSFont {
        .systemFont(ofSize: max(9, base.pointSize * 0.8), weight: .medium)
    }

    /// Размер значка в колонке пометок — тот же, что у значка ветки: замок хранилища и ветка
    /// стоят рядом и должны быть одного роста.
    static func markSymbolPointSize(for base: NSFont) -> CGFloat {
        branchFont(for: base).pointSize
    }

    /// Замок хранилища для колонки пометок. Открытый горит красным — тихое предупреждение, что
    /// сейф стоит открытым; закрытый — цветом имени. Ширина — по собственным пропорциям
    /// значка: у открытого дужка отведена вбок, и втиснутый в квадрат он мельчал.
    static func vaultLockImage(unlocked: Bool, font base: NSFont, ink: NSColor) -> NSImage? {
        let size = markSymbolPointSize(for: base)
        let color: NSColor = unlocked ? .systemRed : ink
        guard let symbol = NSImage(systemSymbolName: unlocked ? "lock.open" : "lock",
                                   accessibilityDescription: "vault")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) else { return nil }
        let g = symbol.size
        let width = g.height > 0 ? ceil(size * g.width / g.height) : size
        let out = NSImage(size: NSSize(width: width, height: ceil(size)), flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        return out
    }

    /// The state letter, for the gutter. One character wide whatever the state, so the gutter
    /// costs the name almost nothing.
    static func markText(_ mark: GitMark, font base: NSFont,
                         tint: NSColor? = nil) -> NSAttributedString {
        NSAttributedString(string: mark.letter, attributes: [
            .font: font(for: base),
            .foregroundColor: tint ?? color(for: mark),
        ])
    }

    /// The ink a mark takes on the cursor row. The cursor bar is a colour of the person's own
    /// choosing, and a state colour can land close enough to it to disappear — white is what the
    /// rest of the row already uses over it.
    static let cursorInk = NSColor.white

    /// The branch of a repository folder, for the far end of the row.
    ///
    /// It rides at the trailing edge rather than in the gutter: a branch name is a dozen
    /// characters, and putting it in the gutter would push every name in the folder aside for
    /// the sake of one row. At the trailing edge the branches of several repositories line up
    /// as a column of their own instead.
    static func branchText(_ badge: GitBadge, font base: NSFont,
                           tint: NSColor? = nil) -> NSAttributedString? {
        if let branch = badge.branch {
            let result = NSMutableAttributedString()
            let ink = tint ?? PanelAppearanceSettings.accentNSColor
            let symbol = NSImage(systemSymbolName: "arrow.triangle.branch",
                                 accessibilityDescription: nil)
            if let symbol {
                let size = branchFont(for: base).pointSize
                let attachment = NSTextAttachment()
                // The symbol is given its colour outright. A template image inside an attachment
                // is drawn as it is, not in the text's colour, so it came out grey beside the
                // accent-coloured branch name.
                attachment.image = symbol.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [ink])))
                attachment.bounds = CGRect(x: 0, y: -size * 0.12, width: size * 1.1, height: size)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " "))
            }
            result.append(NSAttributedString(string: branch, attributes: [
                .font: branchFont(for: base),
                .foregroundColor: ink,
            ]))
            // A repository with uncommitted work carries a dot, the same way an editor's tab does.
            if badge.dirty {
                result.append(NSAttributedString(string: " •", attributes: [
                    .font: branchFont(for: base),
                    .foregroundColor: NSColor.systemOrange,
                ]))
            }
            return result
        }
        return nil
    }

    /// Everything one badge has to say, for the modes that show it in a single place.
    static func text(_ badge: GitBadge, font base: NSFont) -> NSAttributedString? {
        if badge.branch != nil { return branchText(badge, font: base) }
        return badge.mark.map { markText($0, font: base) }
    }

    /// Width one badge needs, gap excluded.
    static func width(_ badge: GitBadge, font base: NSFont) -> CGFloat {
        guard let text = text(badge, font: base) else { return 0 }
        return ceil(text.size().width)
    }

    /// The gutter: as wide as the widest LETTER in the listing, and no wider — the branch names
    /// live at the other end of the row.
    static func gutterWidth(_ badges: some Collection<GitBadge>, font base: NSFont) -> CGFloat {
        let widest = badges.reduce(CGFloat.zero) { widest, badge in
            guard let mark = badge.mark else { return widest }
            return max(widest, ceil(markText(mark, font: base).size().width))
        }
        return widest > 0 ? widest + trailingGap : 0
    }

    /// Width the branch chip needs, the gap before it included; zero when there is no branch.
    static func branchWidth(_ badge: GitBadge, font base: NSFont) -> CGFloat {
        guard let text = branchText(badge, font: base) else { return 0 }
        return ceil(text.size().width) + trailingGap
    }

    /// The branch chip as an image.
    static func branchImage(_ badge: GitBadge, font base: NSFont,
                            tint: NSColor? = nil) -> NSImage? {
        guard let text = branchText(badge, font: base, tint: tint) else { return nil }
        return draw(text)
    }

    /// The state letter as an image.
    static func markImage(_ mark: GitMark, font base: NSFont, tint: NSColor? = nil) -> NSImage? {
        draw(markText(mark, font: base, tint: tint))
    }

    /// One badge as an image, for the cells that keep it in a view of their own.
    static func image(_ badge: GitBadge, font base: NSFont, tint: NSColor? = nil) -> NSImage? {
        if badge.branch != nil { return branchImage(badge, font: base, tint: tint) }
        guard let mark = badge.mark else { return nil }
        return markImage(mark, font: base, tint: tint)
    }

    /// The badge as a plaque that sits ON the picture, for the thumbnail mode.
    ///
    /// A mark floating beside a big icon reads as belonging to nothing: there is empty space on
    /// every side of it. On the picture, over a plate dark enough to carry white text, it plainly
    /// belongs to the folder underneath — and the plate is what keeps it readable over an orange
    /// folder, a photograph or a white page alike.
    static func plaqueImage(_ badge: GitBadge, font base: NSFont, maxWidth: CGFloat) -> NSImage? {
        guard !badge.isEmpty else { return nil }
        let inset = CGSize(width: 5, height: 2)
        let ink = NSColor.white
        let body = NSMutableAttributedString()
        if let branch = badge.branch {
            let symbol = NSImage(systemSymbolName: "arrow.triangle.branch",
                                 accessibilityDescription: nil)
            let size = base.pointSize
            if let symbol {
                let attachment = NSTextAttachment()
                attachment.image = symbol.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: size * 0.9, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [ink])))
                attachment.bounds = CGRect(x: 0, y: -size * 0.12,
                                           width: size, height: size * 0.9)
                body.append(NSAttributedString(attachment: attachment))
                body.append(NSAttributedString(string: " "))
            }
            body.append(NSAttributedString(string: branch, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: ink,
            ]))
        } else if let mark = badge.mark {
            body.append(NSAttributedString(string: mark.letter, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .bold),
                .foregroundColor: mark == .ignored ? NSColor.white.withAlphaComponent(0.7)
                                                   : color(for: mark),
            ]))
        }
        guard body.length > 0 else { return nil }

        // The "uncommitted" dot is drawn separately, after the text is cut to fit: it is the
        // one thing on the plaque that must never be the part that gets trimmed away.
        let dot: CGFloat = badge.dirty ? base.pointSize * 0.75 : 0
        let room = max(20, maxWidth - inset.width * 2 - dot)

        // Trimmed by measuring, one character at a time, rather than by a truncating paragraph
        // style: an attributed string carrying an image attachment measures wider than it draws,
        // and the style then ate letters that would have fitted.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        body.addAttribute(.paragraphStyle, value: paragraph,
                          range: NSRange(location: 0, length: body.length))
        while body.size().width > room, body.length > 2 {
            body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
            if body.size().width <= room {
                body.replaceCharacters(in: NSRange(location: body.length - 1, length: 1),
                                       with: "…")
            }
        }
        let textSize = body.size()
        let width = ceil(textSize.width)
        let box = NSSize(width: width + dot + inset.width * 2,
                         height: ceil(textSize.height) + inset.height * 2)

        return NSImage(size: box, flipped: false) { rect in
            let plate = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                                     yRadius: rect.height / 2)
            NSColor.black.withAlphaComponent(0.62).setFill()
            plate.fill()
            body.draw(in: NSRect(x: inset.width, y: inset.height,
                                 width: width + 1, height: rect.height - inset.height * 2))
            if dot > 0 {
                let d = dot * 0.55
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - inset.width - dot + (dot - d) / 2,
                                            y: rect.midY - d / 2,
                                            width: d, height: d)).fill()
            }
            return true
        }
    }

    private static func draw(_ text: NSAttributedString) -> NSImage? {
        let size = text.size()
        let box = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard box.width > 0, box.height > 0 else { return nil }
        // The drawing-handler form re-runs when the theme changes, so the colours follow it.
        return NSImage(size: box, flipped: false) { rect in
            text.draw(in: rect)
            return true
        }
    }

    /// What the mark means, spelled out for the tooltip.
    static func help(_ badge: GitBadge) -> String? {
        if let branch = badge.branch {
            let state = badge.dirty ? L("git.dirty") : L("git.clean")
            return String(format: L("git.help.repository"), branch, state)
        }
        return badge.mark?.localizedName
    }
}
