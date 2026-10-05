import AppKit

/// Custom NSView that renders a single line of text with optional horizontal
/// marquee scrolling when the text doesn't fit in the visible width.
///
/// Why not subclass NSTextField:
/// - NSTextField/NSTextFieldCell render text via Core Text in their own
///   pipeline. Tricks like layer.transform or bounds.origin tend to be
///   silently undone on every redraw, so the marquee never actually moves.
///
/// We render the text ourselves in `draw(_:)` at an offset, which is the
/// approach used by the popular MPScrollingTextField and similar projects.
///
/// Used for the file-name cell: when a file is under the cursor and its
/// name is truncated, after a short delay the text starts scrolling so the
/// user can read the full name.
final class MarqueeTextField: NSView {

    // MARK: - Public surface (mirrors NSTextField API we use elsewhere)

    var stringValue: String = "" {
        didSet {
            if stringValue != oldValue {
                attributed = nil
                stopMarquee()
                stopGrowth()
                needsDisplay = true
                invalidateIntrinsicContentSize()
            }
        }
    }

    var attributedStringValue: NSAttributedString {
        get { attributed ?? NSAttributedString(string: stringValue, attributes: defaultAttributes) }
        set {
            // Plain text FIRST. `stringValue`'s didSet clears `attributed` whenever the text
            // changes, and a property observer fires even when the assignment comes from in here —
            // so storing the attributed value first threw it away again on the very next line, and
            // the field fell back to drawing the bare string in its own single textColor. Every
            // per-run attribute went with it: the tag dots, the symlink marker, the name colours.
            // It only ever looked right when a later repaint happened to assign the same text.
            stringValue = newValue.string
            attributed = newValue
            stopMarquee()
            stopGrowth()
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    var font: NSFont = .systemFont(ofSize: 12) {
        didSet { needsDisplay = true; invalidateIntrinsicContentSize() }
    }

    var textColor: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    /// Kept for API compatibility with NSTextField call sites that read it.
    var lineBreakMode: NSLineBreakMode = .byTruncatingTail

    // MARK: - Marquee state

    private var attributed: NSAttributedString?
    private var marqueeTimer: Timer?
    private var scrollOffset: CGFloat = 0
    private var direction: CGFloat = -1
    private var isMarqueeRunning = false
    private var marqueeStartedForText: String = ""
    private let pixelsPerSecond: CGFloat = 30
    private let edgePauseFrames = 30
    private var pauseFramesLeft = 0

    // MARK: - Growth state

    /// Плавный рост под курсором: текст уже в новом шрифте, а рисуется пока в промежуточном
    /// кегле — от прежнего размера к настоящему, с обрезкой по ширине на каждом кадре.
    private var growth: TextGrowth?
    private var growthStartedAt: TimeInterval = 0
    private var growthTimer: Timer?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    deinit {
        // A repeating timer is retained by the run loop, and it holds the view only weakly — so a
        // view torn down mid-marquee (a view-mode switch) would leave a 60 Hz timer firing into
        // nothing for the rest of the app's life, one more per occurrence.
        marqueeTimer?.invalidate()
        growthTimer?.invalidate()
    }

    // MARK: - NSTextField labelWithString shim
    /// Shim so call sites can do `MarqueeTextField(labelWithString: "")`
    /// without changing.
    convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        self.stringValue = string
    }

    // MARK: - Drawing

    override var intrinsicContentSize: NSSize {
        let size = currentAttributedString().size()
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let attr = isMarqueeRunning ? currentAttributedString() : displayedAttributedString()
        let textSize = attr.size()
        let yCenter = (bounds.height - textSize.height) / 2

        if isMarqueeRunning {
            // Draw the full string offset by scrollOffset (negative shifts left).
            let drawRect = NSRect(x: scrollOffset,
                                  y: yCenter,
                                  width: ceil(textSize.width),
                                  height: ceil(textSize.height))
            attr.draw(in: drawRect)
        } else if textSize.width > bounds.width {
            // Static, but doesn't fit — render with manual tail-truncation
            // (a single ellipsis at the end). We re-implement what NSCell
            // would do because we're a plain NSView now.
            let drawRect = NSRect(x: 0, y: yCenter,
                                  width: bounds.width, height: ceil(textSize.height))
            let truncated = Self.truncatedToFit(attr, width: bounds.width)
            truncated.draw(in: drawRect)
        } else {
            // Fits — draw normally aligned to the leading edge.
            let drawRect = NSRect(x: 0, y: yCenter,
                                  width: ceil(textSize.width),
                                  height: ceil(textSize.height))
            attr.draw(in: drawRect)
        }
    }

    // MARK: - Marquee control

    /// Start marquee after `delay` seconds if the current text doesn't fit.
    /// Idempotent for the same text.
    func startMarqueeIfOverflowing(delay: TimeInterval) {
        if marqueeStartedForText == stringValue && (isMarqueeRunning || marqueeTimer != nil) {
            return
        }
        stopMarquee()
        guard textOverflowsBounds() else { return }
        marqueeStartedForText = stringValue
        marqueeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.beginScrolling()
        }
    }

    func stopMarquee() {
        marqueeTimer?.invalidate()
        marqueeTimer = nil
        scrollOffset = 0
        direction = -1
        pauseFramesLeft = 0
        isMarqueeRunning = false
        marqueeStartedForText = ""
        needsDisplay = true
    }

    private func beginScrolling() {
        stopGrowth()
        isMarqueeRunning = true
        scrollOffset = 0
        direction = -1
        pauseFramesLeft = edgePauseFrames
        marqueeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickFrame()
        }
        needsDisplay = true
    }

    private func tickFrame() {
        guard isMarqueeRunning else { return }
        let maxDist = maxScrollDistance
        if maxDist <= 0 {
            stopMarquee()
            return
        }
        if pauseFramesLeft > 0 {
            pauseFramesLeft -= 1
            return
        }
        let stepPerFrame = pixelsPerSecond / 60.0
        scrollOffset += direction * stepPerFrame
        if scrollOffset <= -maxDist {
            scrollOffset = -maxDist
            direction = 1
            pauseFramesLeft = edgePauseFrames
        } else if scrollOffset >= 0 {
            scrollOffset = 0
            direction = -1
            pauseFramesLeft = edgePauseFrames
        }
        needsDisplay = true
    }

    // MARK: - Growth control

    /// Текст уже в новом шрифте; показать, как он к нему дорастает: первый кадр — в `ratio`
    /// раз от настоящего кегля, последний — настоящий. Каждый кадр рисуется своим кеглем и
    /// заново обрезается по ширине, поэтому длинное имя всю дорогу кончается многоточием у
    /// края колонки, а не вылезает в соседнюю. Единица — переход не нужен.
    func animateGrowth(fromRatio ratio: CGFloat, duration: TimeInterval) {
        stopGrowth()
        guard ratio > 0, abs(ratio - 1) > 0.001, duration > 0 else { return }
        growth = TextGrowth(startRatio: ratio, duration: duration)
        growthStartedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickGrowth()
        }
        // В общем режиме цикла: стрелка с автоповтором и прокрутка держат цикл в режиме
        // слежения, и таймер по умолчанию там молчит — рост замирал бы на первом кадре.
        RunLoop.main.add(timer, forMode: .common)
        growthTimer = timer
        needsDisplay = true
    }

    func stopGrowth() {
        growthTimer?.invalidate()
        growthTimer = nil
        if growth != nil {
            growth = nil
            needsDisplay = true
        }
    }

    /// Масштаб, в котором текст рисуется сейчас; единица — рост окончен или не шёл.
    var currentGrowthScale: CGFloat {
        growth?.scale(at: CACurrentMediaTime() - growthStartedAt) ?? 1
    }

    private func tickGrowth() {
        guard let growth else { return }
        if growth.isFinished(at: CACurrentMediaTime() - growthStartedAt) {
            stopGrowth()
        }
        needsDisplay = true
    }

    /// Что рисовать в этот кадр: настоящий текст или он же в промежуточном кегле роста.
    private func displayedAttributedString() -> NSAttributedString {
        Self.scaled(currentAttributedString(), by: currentGrowthScale)
    }

    /// Тот же текст со всеми шрифтами (и вложениями, и разрядкой) в `scale` раз крупнее.
    static func scaled(_ text: NSAttributedString, by scale: CGFloat) -> NSAttributedString {
        guard scale > 0, abs(scale - 1) > 0.001 else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: all) { value, range, _ in
            guard let font = value as? NSFont else { return }
            result.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * scale),
                                range: range)
        }
        result.enumerateAttribute(.kern, in: all) { value, range, _ in
            guard let kern = value as? NSNumber else { return }
            result.addAttribute(.kern, value: NSNumber(value: kern.doubleValue * Double(scale)), range: range)
        }
        result.enumerateAttribute(.attachment, in: all) { value, range, _ in
            // Копия, а не правка на месте: вложение общее с хранимой строкой.
            guard let attachment = value as? NSTextAttachment else { return }
            let copy = NSTextAttachment()
            copy.image = attachment.image
            let b = attachment.bounds
            copy.bounds = CGRect(x: b.origin.x * scale, y: b.origin.y * scale,
                                 width: b.width * scale, height: b.height * scale)
            result.addAttribute(.attachment, value: copy, range: range)
        }
        return result
    }

    // MARK: - Helpers

    private func currentAttributedString() -> NSAttributedString {
        if let attributed { return attributed }
        return NSAttributedString(string: stringValue, attributes: defaultAttributes)
    }

    private var defaultAttributes: [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let kern = PanelAppearanceSettings.resolvedListLetterSpacing
        if kern != 0 { attrs[.kern] = kern }
        return attrs
    }

    private func textOverflowsBounds() -> Bool {
        guard !stringValue.isEmpty else { return false }
        return currentAttributedString().size().width > bounds.width - 2
    }

    private var maxScrollDistance: CGFloat {
        let measured = currentAttributedString().size().width
        return max(0, ceil(measured) - bounds.width + 4)
    }

    /// Manual tail-truncation for the static (non-scrolling) state.
    ///
    /// The ellipsis takes the text's own font, colour and spacing — the first run's, which is the
    /// name itself — so it matches the text at whatever size the growth is drawing it in.
    static func truncatedToFit(_ source: NSAttributedString, width: CGFloat) -> NSAttributedString {
        guard source.size().width > width, source.length > 0 else { return source }
        var ellipsisAttributes = source.attributes(at: 0, effectiveRange: nil)
        ellipsisAttributes[.attachment] = nil
        let ellipsis = NSAttributedString(string: "…", attributes: ellipsisAttributes)
        let ellipsisWidth = ellipsis.size().width
        let target = width - ellipsisWidth
        let mut = NSMutableAttributedString(attributedString: source)
        while mut.size().width > target, mut.length > 0 {
            // By composed character sequence, not by UTF-16 unit: an emoji is two units, and
            // cutting between them leaves an unpaired surrogate that renders as "�".
            let last = (mut.string as NSString).rangeOfComposedCharacterSequence(at: mut.length - 1)
            mut.deleteCharacters(in: last)
        }
        let result = NSMutableAttributedString(attributedString: mut)
        result.append(ellipsis)
        return result
    }

    override func layout() {
        super.layout()
        if isMarqueeRunning && !textOverflowsBounds() {
            stopMarquee()
        }
    }
}

/// The Name column's cell: a truncating name, and the Finder tag dots beside it.
///
/// The dots are their own view rather than the tail of the name string. Tail truncation removes
/// whatever sits at the end first, so a tagged file with a long name used to render without its
/// dot — indistinguishable from an untagged one, in the one mode where names are longest.
final class NameCellView: NSTableCellView {
    let label = MarqueeTextField(labelWithString: "")
    private let dotsView = NSImageView()
    private var dotsWidth: NSLayoutConstraint!
    /// Git's mark, in a gutter BEFORE the name. A column of letters is read at a glance; the
    /// same letters trailing names of different lengths would have to be hunted for.
    private let gitView = NSImageView()
    private var gitWidth: NSLayoutConstraint!
    /// The branch of a repository folder. It rides at the row's trailing end, outside the
    /// truncating label, so a long folder name ends in "…" without eating the branch.
    private let branchView = NSImageView()
    private var branchWidth: NSLayoutConstraint!
    /// Замок хранилища — в той же колонке пометок, что и ветка, того же роста. Раньше он был
    /// приклеен к концу имени символом в строке: свой размер, своё место, и у длинных имён
    /// уезжал вместе с многоточием.
    private let lockView = NSImageView()
    private var lockWidth: NSLayoutConstraint!
    /// Счётчик нового внутри папки — «+12» вплотную за именем (FolderNewsChip). Место под
    /// него в конце колонки отложено всегда, когда он есть: длинное имя обрезается до него, и
    /// он встаёт у края; короткое — он стоит сразу за последней буквой.
    private let newsView = NSImageView()
    private var newsWidth: NSLayoutConstraint!
    private var newsLeading: NSLayoutConstraint!
    private var labelTrailing: NSLayoutConstraint!
    /// The hidden-file eye. A fixed view at the cell's edge, NOT part of the name text: a
    /// long name truncates BEFORE it, so the eye survives every "…" — appended to the
    /// string it was the first thing the ellipsis ate.
    private let eyeView = NSImageView()
    private var eyeWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        dotsView.translatesAutoresizingMaskIntoConstraints = false
        dotsView.imageScaling = .scaleNone
        // Never squeeze the name out of existence, and never stretch to fill.
        dotsView.setContentHuggingPriority(.required, for: .horizontal)
        dotsView.setContentCompressionResistancePriority(.required, for: .horizontal)
        eyeView.translatesAutoresizingMaskIntoConstraints = false
        eyeView.imageScaling = .scaleNone
        eyeView.setContentHuggingPriority(.required, for: .horizontal)
        eyeView.setContentCompressionResistancePriority(.required, for: .horizontal)
        gitView.translatesAutoresizingMaskIntoConstraints = false
        gitView.imageScaling = .scaleNone
        // The gutter is exactly one letter plus the gap, so a left-aligned letter starts the
        // column and the gap it leaves is what separates the marks from the names.
        gitView.imageAlignment = .alignLeft
        branchView.translatesAutoresizingMaskIntoConstraints = false
        branchView.imageScaling = .scaleNone
        branchView.imageAlignment = .alignRight
        branchView.setContentHuggingPriority(.required, for: .horizontal)
        branchView.setContentCompressionResistancePriority(.required, for: .horizontal)
        gitView.setContentHuggingPriority(.required, for: .horizontal)
        gitView.setContentCompressionResistancePriority(.required, for: .horizontal)
        lockView.translatesAutoresizingMaskIntoConstraints = false
        lockView.imageScaling = .scaleNone
        lockView.imageAlignment = .alignRight
        lockView.setContentHuggingPriority(.required, for: .horizontal)
        lockView.setContentCompressionResistancePriority(.required, for: .horizontal)
        newsView.translatesAutoresizingMaskIntoConstraints = false
        newsView.imageScaling = .scaleNone
        newsView.imageAlignment = .alignLeft
        newsView.setContentHuggingPriority(.required, for: .horizontal)
        newsView.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        addSubview(newsView)
        addSubview(dotsView)
        addSubview(eyeView)
        addSubview(gitView)
        addSubview(lockView)
        addSubview(branchView)

        gitWidth = gitView.widthAnchor.constraint(equalToConstant: 0)
        lockWidth = lockView.widthAnchor.constraint(equalToConstant: 0)
        branchWidth = branchView.widthAnchor.constraint(equalToConstant: 0)
        dotsWidth = dotsView.widthAnchor.constraint(equalToConstant: 0)
        eyeWidth = eyeView.widthAnchor.constraint(equalToConstant: 0)
        newsWidth = newsView.widthAnchor.constraint(equalToConstant: 0)
        newsLeading = newsView.leadingAnchor.constraint(equalTo: label.leadingAnchor)
        newsLeading.priority = .defaultHigh
        labelTrailing = label.trailingAnchor.constraint(equalTo: lockView.leadingAnchor)
        NSLayoutConstraint.activate([
            gitView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            gitView.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitWidth,

            label.leadingAnchor.constraint(equalTo: gitView.trailingAnchor),
            labelTrailing,

            newsLeading,
            newsView.trailingAnchor.constraint(lessThanOrEqualTo: lockView.leadingAnchor),
            newsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            newsWidth,

            lockView.trailingAnchor.constraint(equalTo: branchView.leadingAnchor),
            lockView.centerYAnchor.constraint(equalTo: centerYAnchor),
            lockWidth,

            branchView.trailingAnchor.constraint(equalTo: eyeView.leadingAnchor),
            branchView.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchWidth,
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),

            eyeView.trailingAnchor.constraint(equalTo: dotsView.leadingAnchor),
            eyeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            eyeWidth,

            dotsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            dotsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotsWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Счётчик нового внутри папки — «+12» (FolderNewsChip). Нового нет — ширина нулевая, и имя
    /// получает всю колонку, как раньше.
    func setNews(_ item: FileItem, font: NSFont) {
        let mark = FolderNews.mark(for: item)
        let count = mark == nil ? 0 : item.newInsideCount
        newsView.image = mark.flatMap { FolderNewsChip.image(count: count, mark: $0, font: font) }
        newsView.toolTip = count > 0 ? String(format: L("folderNews.tooltip"), count) : nil
        let width = FolderNewsChip.width(count: count, font: font)
        if newsWidth.constant != width { newsWidth.constant = width }
        if labelTrailing.constant != -width { labelTrailing.constant = -width }
        let text = FolderNewsChip.textEnd(of: label)
        if newsLeading.constant != text { newsLeading.constant = text }
    }

    /// Width collapses to zero for an untagged file, which gives the name back the whole column.
    func setTags(_ tags: [FinderTag], font: NSFont) {
        dotsView.image = FinderTagDots.image(tags, font: font)
        let width = FinderTagDots.width(tags, font: font)
        if dotsWidth.constant != width { dotsWidth.constant = width }
    }

    /// The Git mark and the width of the gutter it sits in.
    ///
    /// The width is the LISTING's, not this row's: every mark in the folder starts at the same
    /// place, so the marks form a column and the names stay aligned beside them. A folder with
    /// nothing to say gives a width of zero and the name gets the whole cell back.
    func setGit(_ badge: GitBadge?, font: NSFont, gutter: CGFloat, isCursor: Bool = false) {
        let badge = badge ?? GitBadge()
        // Under the cursor the mark takes the cursor's own ink: a state colour can land close
        // enough to the cursor bar to vanish into it.
        let tint: NSColor? = isCursor ? GitBadgeChip.cursorInk : nil
        gitView.image = badge.mark.flatMap { GitBadgeChip.markImage($0, font: font, tint: tint) }
        gitView.toolTip = badge.mark?.localizedName
        if gitWidth.constant != gutter { gitWidth.constant = gutter }

        branchView.image = GitBadgeChip.branchImage(badge, font: font, tint: tint)
        branchView.toolTip = badge.branch == nil ? nil : GitBadgeChip.help(badge)
        let width = GitBadgeChip.branchWidth(badge, font: font)
        if branchWidth.constant != width { branchWidth.constant = width }
    }

    /// Замок хранилища в колонке пометок; nil — обычный файл, ширина схлопывается в ноль.
    func setVaultLock(_ image: NSImage?) {
        lockView.image = image
        let width = image.map { $0.size.width + 6 } ?? 0
        if lockWidth.constant != width { lockWidth.constant = width }
    }

    /// Show (or drop) the hidden-file eye. Width collapses to zero for ordinary files —
    /// the name keeps the whole column, same manner as the tag dots.
    func setHiddenEye(_ image: NSImage?) {
        eyeView.image = image
        let width = image.map { $0.size.width + 6 } ?? 0
        if eyeWidth.constant != width { eyeWidth.constant = width }
    }

    /// Put the cell's own drawing away while an inline rename editor sits on top of it.
    ///
    /// The editor is a borderless, background-less NSTextField laid over the cell, so
    /// everything underneath keeps showing through — the name, the tag dots and the eye all
    /// drew straight through the field and the user saw two overlapping texts. Hiding is done
    /// here rather than through `NSTableCellView.textField`, which this cell deliberately
    /// leaves unset: AppKit repaints a cell's `textField` on every background-style change,
    /// which would undo the cursor and tag colours this panel paints itself.
    func setEditing(_ editing: Bool) {
        label.isHidden = editing
        dotsView.isHidden = editing
        eyeView.isHidden = editing
        gitView.isHidden = editing
        lockView.isHidden = editing
        branchView.isHidden = editing
        newsView.isHidden = editing
    }
}
