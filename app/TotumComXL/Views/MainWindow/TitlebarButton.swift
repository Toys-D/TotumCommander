import AppKit

/// Кнопка строки заголовка: значок (и подпись), без рамки. Под мышью чуть приподнимается — плавно,
/// если включена «Плавная анимация», как растёт строка под курсором, — и светится: акцентным
/// цветом, если он заметен на заголовке, а если сливается с ним — цветом, контрастным заголовку.
/// Одна и та же на всех системах: в своём ряду заголовка на macOS 26 и новее и вью пункта
/// панели на Sequoia.
final class TitlebarButton: NSButton {
    /// Чем кнопка выделяется под мышью: значок, подпись и свечение вокруг — одного цвета.
    enum HoverLook: Equatable {
        /// Акцентного: он заметен на заголовке.
        case accent(NSColor)
        /// Контрастного заголовку: акцент с ним сливается.
        case glow(NSColor)
    }

    /// Акцент, сливающийся с заголовком (контраст ниже 3:1 — порог WCAG для элементов
    /// интерфейса), не выделяет ничего: в светлой теме у автора акцент #59676F на заголовке
    /// #5A666F. Тогда — свечение белым на тёмном заголовке и чёрным на светлом.
    static func hoverLook(accent: NSColor, background: NSColor) -> HoverLook {
        if contrastRatio(accent, background) >= 3 { return .accent(accent) }
        return .glow(ContrastAppearance.isDark(background) ? .white : .black)
    }

    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = ContrastAppearance.luminance(of: a), lb = ContrastAppearance.luminance(of: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Цвет заголовка под кнопкой — его даёт окно; по нему выбирается выделение под мышью.
    var titlebarBackground: NSColor? {
        didSet { if isHovered { applyTint(); needsDisplay = true } }
    }

    /// Выделение под мышью — по НЫНЕШНЕМУ акценту: его меняют в настройках, окну об этом не
    /// сообщая.
    var hoverLook: HoverLook {
        let accent = PanelAppearanceSettings.accentNSColor
        guard let background = titlebarBackground else { return .accent(accent) }
        return Self.hoverLook(accent: accent, background: background)
    }
    /// На сколько точек кнопка приподнимается под мышью.
    static let hoverLift: CGFloat = 2

    /// Цвет значка и подписи в покое; под мышью — акцентный.
    var restingTint: NSColor = .secondaryLabelColor {
        didSet { applyTint() }
    }

    /// Насколько кнопка сейчас приподнята; анимируется через animator().
    @objc dynamic var lift: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private(set) var isHovered = false
    private var hoverArea: NSTrackingArea?

    /// Поля вокруг значка и подписи: есть куда приподняться и где светиться, и в кнопку легче
    /// попасть мышью.
    static let padding = NSSize(width: 12, height: 10)

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        // От значка, а не только от ячейки: ячейка бывает ниже значка, и поля выходили мнимыми.
        let content = max(base.height, imagePosition == .noImage ? 0 : image?.size.height ?? 0)
        return NSSize(width: base.width + Self.padding.width,
                      height: max(content + Self.padding.height, 24))
    }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "lift" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    /// Мышь пришла или ушла: цвет — сразу, подъём — плавно, если анимация включена.
    func setHovered(_ hovered: Bool, animated: Bool? = nil) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyTint()
        let target = hovered ? Self.hoverLift : 0
        guard animated ?? CursorLift.isEnabled else {
            lift = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CursorLift.duration
            animator().lift = target
        }
    }

    /// Цвет, которым сейчас нарисованы значок и подпись.
    var currentTint: NSColor {
        guard isHovered else { return restingTint }
        switch hoverLook {
        case .accent(let color), .glow(let color): return color
        }
    }

    func applyTint() {
        let color = currentTint
        // Шаблонный значок красит contentTintColor; испечённый со своими цветами (поднос со
        // счётчиком, шестерёнка с точкой) остаётся в них и только приподнимается.
        contentTintColor = color
        // Подпись — только видимая: у кнопки «один значок» подпись есть (для чтения с экрана), а
        // установка attributedTitle у такой кнопки возвращала значок к «слева от подписи».
        if imagePosition != .imageOnly, !title.isEmpty {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: color,
                .font: font ?? NSFont.systemFont(ofSize: 12),
            ])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Свечение — всегда, цветом выделения: акцентным или контрастным заголовку.
        let glow: NSColor? = isHovered ? currentTint : nil
        guard lift != 0 || glow != nil else {
            super.draw(dirtyRect)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        if lift != 0 {
            let shift = NSAffineTransform()
            shift.translateX(by: 0, yBy: isFlipped ? -lift : lift)
            shift.concat()
        }
        if let glow { drawHalo(glow) }
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Ореол вокруг значка: значок цвета свечения с размытой тенью того же цвета — под обычным
    /// рисованием кнопки. Тень, поставленная на саму кнопку, не годится: ячейка рисует значок с
    /// обрезкой по его рамке, и свечение срезалось до узкой полоски между штрихами.
    private func drawHalo(_ glow: NSColor) {
        guard let image, imagePosition != .noImage, let cell else { return }
        let rect = cell.imageRect(forBounds: bounds)
        let tinted = NSImage(size: rect.size, flipped: false) { box in
            image.draw(in: box)
            glow.set()
            box.fill(using: .sourceIn)
            return true
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = glow.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = .zero
        shadow.set()
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.6,
                    respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Черта между группами кнопок в ряду заголовка: одна точка цветом tertiaryLabelColor — на
/// грифельном заголовке системный цвет разделителя почти не виден.
final class TitlebarSeparator: NSView {
    static let size = NSSize(width: 9, height: 18)

    override var intrinsicContentSize: NSSize { Self.size }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: floor(bounds.midX), y: bounds.minY + 1, width: 1, height: bounds.height - 2).fill()
    }
}
