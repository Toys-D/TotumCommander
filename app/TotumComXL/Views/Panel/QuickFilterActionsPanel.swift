import AppKit

/// What a narrowed list can be turned into — mark it, unmark it, show the rest, delete it —
/// on its own plate beside the filter bubble.
///
/// Beside it rather than inside it on purpose: the bubble is a read-out of what is being typed,
/// and buttons under the text made the two look like one control. Apart, the bubble says what
/// is happening and the plate offers what to do about it.
///
/// Each row lights the way a shop-window lamp does — a couple of flickers and then steady —
/// because a control that simply materialises beside the text goes unnoticed, and the flicker
/// is what makes the eye look. In the dark theme the lit rows carry a glow of the app's accent;
/// in the light one they take a plain shadow, where a glow only turns to mud.
final class QuickFilterActionsPanel: NSView {

    private let selectButton = NSButton()
    private let deselectButton = NSButton()
    private let invertButton = NSButton()
    private let deleteButton = NSButton()
    /// Which buttons were alight last time, so only the ones that just came on flicker.
    private var wasEnabled: [ObjectIdentifier: Bool] = [:]

    var onSelect: (() -> Void)?
    var onDeselect: (() -> Void)?
    var onInvert: (() -> Void)?
    var onDelete: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        configure(selectButton, symbol: "plus.square.dashed",
                  title: L("quickFilter.select"), action: #selector(select))
        configure(deselectButton, symbol: "minus.square.dashed",
                  title: L("quickFilter.deselect"), action: #selector(deselect))
        configure(invertButton, symbol: "arrow.triangle.2.circlepath",
                  title: L("quickFilter.invert"), action: #selector(invert))
        configure(deleteButton, symbol: "trash", title: L("quickFilter.delete"),
                  action: #selector(deleteSelection))

        let column = NSStackView(views: [selectButton, deselectButton, invertButton, deleteButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        applyAppearanceColours()
        watchAppearanceChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Only the buttons answer the mouse; a click beside them belongs to the file list beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColours()
    }

    private func configure(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func select() { onSelect?() }
    @objc private func deselect() { onDeselect?() }
    @objc private func invert() { onInvert?() }
    @objc private func deleteSelection() { onDelete?() }

    /// The beauty switch can be flipped while the plate is up — the settings window sits right
    /// there — and the halo has to follow it without waiting for the filter to be reopened.
    private var appearanceObserver: Any?

    deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
    }

    private func watchAppearanceChanges() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .fcxlAppearanceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearanceColours() }
        }
    }

    /// Light the rows that have work to do, dim the rest.
    func update(canSelect: Bool, canDeselect: Bool, canInvert: Bool, canDelete: Bool,
                inverted: Bool) {
        set(selectButton, enabled: canSelect, tip: L("quickFilter.selectHint"), lamp: 0)
        set(deselectButton, enabled: canDeselect,
            tip: canDeselect ? nil : L("quickFilter.nothingSelected"), lamp: 1)
        set(invertButton, enabled: canInvert, tip: L("quickFilter.invertHint"), lamp: 2)
        set(deleteButton, enabled: canDelete,
            tip: canDelete ? L("quickFilter.deleteHint") : L("quickFilter.nothingSelected"),
            lamp: 3)
        invertButton.state = inverted ? .on : .off
    }

    private func set(_ button: NSButton, enabled: Bool, tip: String?, lamp: Int) {
        let key = ObjectIdentifier(button)
        let previously = wasEnabled[key]
        button.isEnabled = enabled
        button.toolTip = tip
        button.alphaValue = enabled ? 1 : 0.45
        glow(button, on: enabled)
        // Only a row that JUST came on flickers — one that has been alight all along would
        // blink at every keystroke.
        if enabled, previously != true { flicker(button, pattern: lamp) }
        wasEnabled[key] = enabled
    }

    /// The lamp coming on: uneven flickers, then steady. Shared with everything else in the
    /// app that lights up this way.
    private func flicker(_ view: NSView, pattern index: Int) {
        guard let layer = view.layer else { return }
        LampFlicker.light(layer, pattern: index)
    }

    /// A real halo under a lit row — but only with the beauty switch on, the same switch that
    /// decides whether the panel's cursor glows. Without it the app draws flat, and a glowing
    /// button here would be the one lit thing on a matte screen.
    ///
    /// Tuned per theme rather than turned off: on a dark panel the halo can be wide and bright,
    /// on a light one the same halo reads as dirt, so it stays tight.
    private func glow(_ button: NSButton, on: Bool) {
        guard let layer = button.layer else { return }
        layer.masksToBounds = false
        layer.shadowOffset = .zero

        let beauty = UserDefaults.standard.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard beauty, on else {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowRadius = 2
            layer.shadowOpacity = on ? 0.25 : 0
            return
        }
        layer.shadowColor = PanelAppearanceSettings.accentNSColor.cgColor
        layer.shadowRadius = dark ? 9 : 5
        layer.shadowOpacity = dark ? 0.95 : 0.55
    }

    /// The plate arriving: the frame fades in quietly while the lamps on it do the flickering,
    /// each in its own time. A plate that blinked as a whole made the three read as one lamp.
    func lightUp() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        layer.add(fade, forKey: "appear")
    }

    private func applyAppearanceColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
            layer?.borderColor = PanelAppearanceSettings.accentNSColor
                .withAlphaComponent(0.85).cgColor
            for button in [selectButton, deselectButton, invertButton, deleteButton] {
                glow(button, on: button.isEnabled)
            }
        }
    }
}

extension NSLayoutConstraint {
    /// Reads better than a separate line setting the priority — used where a constraint should
    /// give way rather than break the layout.
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
