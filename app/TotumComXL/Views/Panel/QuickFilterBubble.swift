import AppKit

/// The floating bubble that shows what is being typed into the panel's quick filter.
///
/// One AppKit view sitting over the panel's content slot — the same slot the file list, the
/// embedded terminal and the system monitor share — so it appears identically in the detailed,
/// brief and thumbnails modes without any of the three renderers knowing it exists.
///
/// It never becomes first responder. PanelViewController.handleKeyEvent owns every keystroke in the
/// panel; a bubble that took focus would fight it for the arrow keys and for Esc.
final class QuickFilterBubble: NSView {

    private let field = NSTextField(labelWithString: "")
    /// Remembered so a light/dark switch repaints the SAME state — re-deriving the colours with
    /// the default argument turned a red "no matches" border back to accent mid-theme-change.
    private var showsNoMatches = false
    private let countLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    /// The rules of the box, folded away until asked for. Inline rather than a popover: a
    /// popover takes the keyboard, and the panel — not the bubble — is what typing belongs to.
    private let helpButton = NSButton()
    private let helpText = NSTextField(wrappingLabelWithString: "")

    /// The star keeps the typed mask; the row under the text offers the kept ones back. A saved
    /// mask is pressed, not retyped — that is the whole point of saving it.
    private let presetButton = NSButton()
    private let presetsRow = NSStackView()
    private var currentText = ""
    /// The panel applies the chosen mask through the same road the typing takes.
    var onPresetChosen: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        // A drop shadow reads as "floating above the list" in both themes, where a border alone
        // disappears against a light panel.
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 14
            s.shadowOffset = NSSize(width: 0, height: -3)
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            return s
        }()

        icon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                             accessibilityDescription: nil)
        icon.image?.isTemplate = true
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        field.lineBreakMode = .byTruncatingHead
        field.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        helpButton.bezelStyle = .accessoryBarAction
        helpButton.isBordered = false
        helpButton.controlSize = .small
        helpButton.image = NSImage(systemSymbolName: "questionmark.circle",
                                   accessibilityDescription: L("quickFilter.help"))
        helpButton.imagePosition = .imageOnly
        helpButton.target = self
        helpButton.action = #selector(toggleHelp)
        helpButton.toolTip = L("quickFilter.help")
        helpButton.setContentHuggingPriority(.required, for: .horizontal)

        helpText.font = .systemFont(ofSize: 11)
        helpText.textColor = .secondaryLabelColor
        helpText.stringValue = L("quickFilter.helpText")
        helpText.isHidden = true
        helpText.preferredMaxLayoutWidth = 340

        presetButton.bezelStyle = .accessoryBarAction
        presetButton.isBordered = false
        presetButton.controlSize = .small
        presetButton.imagePosition = .imageOnly
        presetButton.target = self
        presetButton.action = #selector(togglePreset)
        presetButton.setContentHuggingPriority(.required, for: .horizontal)

        presetsRow.orientation = .horizontal
        presetsRow.spacing = 4
        presetsRow.alignment = .centerY

        // The title row: what is typed, with the star and the "?" at its far end.
        let titleRow = NSStackView(views: [icon, field, presetButton, helpButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY

        let column = NSStackView(views: [titleRow, countLabel, presetsRow, helpText])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        // A hidden view is dropped from the layout, so the bubble shrinks back when the help
        // folds away instead of keeping a hole where it was.
        column.setCustomSpacing(3, after: titleRow)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            // High, not required: on a panel narrower than 500pt this and the "no wider than
            // 60% of the panel" cap cannot both hold, and a required pair makes Auto Layout
            // break one at random with a console full of complaints.
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
                .withPriority(.defaultHigh),
        ])
        applyAppearanceColours()
        watchAppearanceChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The accent and the beauty switch can change while the filter is open — the settings
    /// window sits right there. The plate next door already follows; a bubble that did not
    /// left the pair in two different colours.
    private var appearanceObserver: Any?

    deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
    }

    private func watchAppearanceChanges() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .fcxlAppearanceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyAppearanceColours(noMatches: self.showsNoMatches)
            }
        }
    }

    /// Save the typed mask, or forget it if it is already kept.
    @objc private func togglePreset() {
        guard !currentText.isEmpty else { return }
        MaskPresets.toggle(currentText)
        refreshPresets()
    }

    /// One chip per saved mask. Pressed, it becomes the filter.
    @objc private func applyPreset(_ sender: NSButton) {
        onPresetChosen?(sender.title)
    }

    private func refreshPresets() {
        let saved = MaskPresets.contains(currentText) && !currentText.isEmpty
        presetButton.image = NSImage(systemSymbolName: saved ? "star.fill" : "star",
                                     accessibilityDescription: L("quickFilter.savePreset"))
        presetButton.toolTip = L(saved ? "quickFilter.removePreset" : "quickFilter.savePreset")
        presetButton.isEnabled = !currentText.isEmpty
        presetButton.alphaValue = currentText.isEmpty ? 0.4 : 1

        presetsRow.arrangedSubviews.forEach { view in
            presetsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // Up to a handful: the bubble is capped at six tenths of the panel, and a chip that
        // cannot fit is reached by saving less rather than by scrolling a bubble.
        for mask in MaskPresets.masks.prefix(6) {
            let chip = NSButton(title: mask, target: self, action: #selector(applyPreset(_:)))
            chip.bezelStyle = .accessoryBarAction
            chip.controlSize = .small
            chip.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            chip.toolTip = mask
            chip.lineBreakMode = .byTruncatingTail
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
            presetsRow.addArrangedSubview(chip)
        }
        presetsRow.isHidden = presetsRow.arrangedSubviews.isEmpty
    }

    @objc private func toggleHelp() {
        helpText.isHidden.toggle()
        helpButton.state = helpText.isHidden ? .off : .on
    }

    /// Clicks belong to the file list underneath — the bubble is a read-out. Only the "?"
    /// answers, so typing keeps working and a click beside it still reaches the list.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColours(noMatches: showsNoMatches)
    }

    /// `matches` is counted over what is on screen, `total` over the whole folder, so the
    /// read-out says how much is being hidden rather than just how much is left.
    func update(text: String, matches: Int, total: Int, inverted: Bool) {
        currentText = text
        refreshPresets()
        // "≠" says the list is showing everything the pattern does NOT match — otherwise the
        // bubble would read "*.png" over a list without a single png in it.
        field.stringValue = text.isEmpty ? L("quickFilter.prompt")
                                         : (inverted ? "≠ " + text : text)
        field.alphaValue = text.isEmpty ? 0.55 : 1
        countLabel.stringValue = matches == 0
            ? L("quickFilter.noMatches")
            : L("quickFilter.matches", matches, total)
        showsNoMatches = matches == 0 && !text.isEmpty
        applyAppearanceColours(noMatches: showsNoMatches)
    }

    private func applyAppearanceColours(noMatches: Bool = false) {
        // Resolved inside the view's own appearance, so the light and dark variants of the system
        // colours are the ones actually drawn.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
            let accent = PanelAppearanceSettings.accentNSColor
            // Nothing matched is worth saying in colour, not only in words.
            let edge = noMatches ? NSColor.systemRed : accent
            layer?.borderColor = edge.withAlphaComponent(0.85).cgColor
            icon.contentTintColor = edge
            field.textColor = .labelColor
            countLabel.textColor = noMatches ? .systemRed : .secondaryLabelColor
            helpText.textColor = .secondaryLabelColor
            helpButton.contentTintColor = .secondaryLabelColor
            presetButton.contentTintColor = MaskPresets.contains(currentText) && !currentText.isEmpty
                ? NSColor.systemYellow : .secondaryLabelColor
        }
    }
}
