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
        let attr = currentAttributedString()
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
            let truncated = truncateTail(attr, fitting: bounds.width)
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
    private func truncateTail(_ source: NSAttributedString, fitting width: CGFloat) -> NSAttributedString {
        guard source.size().width > width else { return source }
        let ellipsis = NSAttributedString(string: "…", attributes: defaultAttributes)
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
        addSubview(label)
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
        NSLayoutConstraint.activate([
            gitView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            gitView.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitWidth,

            label.leadingAnchor.constraint(equalTo: gitView.trailingAnchor),
            label.trailingAnchor.constraint(equalTo: lockView.leadingAnchor),

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
    }
}
