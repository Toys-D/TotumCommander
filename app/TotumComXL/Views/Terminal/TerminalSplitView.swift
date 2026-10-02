import AppKit

/// Терминал вкладки или нижней полосы: одна или несколько частей, как в iTerm.
///
/// Каждая часть — обычный `SwiftTermContainerView` со своей оболочкой, поэтому бросок файла,
/// фокус щелчком и возвращение фокуса работают в каждой. Раскладку считает `TerminalLayout`,
/// здесь только расставляются готовые прямоугольники и тянутся разделители.
///
/// Клавиши — когда клавиатура в одной из частей: ⌘D рядом, ⌘⇧D друг под другом, ⌘W закрыть
/// часть, ⌘⌥стрелки к соседу, ⌘T новая вкладка терминала (если владелец её умеет).
@MainActor
final class TerminalSplitView: NSView {
    static let dividerThickness: CGFloat = 1
    static let minimumPaneSize: CGFloat = 60

    private(set) var arrangement: TerminalLayout
    private(set) var activePane: UUID
    private var panes: [UUID: SwiftTermContainerView] = [:]
    private var dividerViews: [TerminalPaneDivider] = []
    private let activeFrame = TerminalActiveFrame()
    /// Полоска над каждой частью с кнопками «рядом», «под низ», «закрыть» — чтобы не держать в
    /// голове клавиши. Своё место, а не поверх терминала: кнопки поверх закрывали текст.
    private var headers: [UUID: TerminalPaneHeader] = [:]
    static let headerHeight: CGFloat = 22
    private var keyMonitor: Any?
    private let startDirectory: String
    private var isStarted = false

    /// Закрыта последняя часть: вкладка закрывается, нижняя полоса убирается.
    var onEmpty: (() -> Void)?
    /// ⌘T — новая вкладка терминала в этой папке. Нет владельца, умеющего вкладки, — клавиша
    /// уходит дальше.
    var onNewTerminal: ((String) -> Void)?

    override var isFlipped: Bool { true }

    init(directory: String) {
        startDirectory = directory
        let first = UUID()
        arrangement = .pane(first)
        activePane = first
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        addSubview(activeFrame)
        panes[first] = makePane(id: first)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// Запустить оболочку первой части. Отдельно от создания: вид сначала встаёт на место.
    func start() {
        guard !isStarted, let first = panes[activePane] else { return }
        isStarted = true
        first.startTerminal(directory: startDirectory)
    }

    var paneCount: Int { panes.count }
    var paneIDs: [UUID] { arrangement.panes.filter { panes[$0] != nil } }

    /// Часть по номеру — для владельца и проверок.
    func pane(_ id: UUID) -> SwiftTermContainerView? { panes[id] }

    /// Полоска с кнопками над частью.
    func header(_ id: UUID) -> TerminalPaneHeader? { headers[id] }

    // MARK: - Parts

    private func makePane(id: UUID) -> SwiftTermContainerView {
        let pane = SwiftTermContainerView(frame: .zero)
        pane.onProcessExit = { [weak self] in self?.closePane(id) }
        pane.onActivated = { [weak self] in self?.markActive(id) }
        pane.makeContextMenu = { [weak self] in self?.contextMenu(for: id) }
        addSubview(pane, positioned: .below, relativeTo: activeFrame)
        let header = TerminalPaneHeader()
        header.controls.onSplitSideBySide = { [weak self] in self?.act(on: id) { $0.split(.sideBySide) } }
        header.controls.onSplitStacked = { [weak self] in self?.act(on: id) { $0.split(.stacked) } }
        header.controls.onClose = { [weak self] in self?.closePane(id) }
        header.onActivate = { [weak self] in self?.focus(id) }
        addSubview(header, positioned: .below, relativeTo: activeFrame)
        headers[id] = header
        return pane
    }

    /// Разделить активную часть; новая открывается в папке, где оболочка активной стоит сейчас.
    @discardableResult
    func split(_ axis: TerminalSplitAxis) -> UUID? {
        guard let current = panes[activePane] else { return nil }
        let directory = current.workingDirectory
        let id = UUID()
        let pane = makePane(id: id)
        panes[id] = pane
        arrangement = arrangement.splitting(activePane, axis: axis, newPane: id)
        relayout()
        pane.startTerminal(directory: directory)
        focus(id)
        return id
    }

    /// Закрыть часть и остановить её оболочку. Последняя — `onEmpty`.
    func closePane(_ id: UUID) {
        guard let pane = panes.removeValue(forKey: id) else { return }
        let hadKeyboard = pane.holdsKeyboard || id == activePane
        let order = arrangement.panes
        pane.terminateProcess()
        pane.removeFromSuperview()
        headers.removeValue(forKey: id)?.removeFromSuperview()
        guard let rest = arrangement.removing(id) else {
            onEmpty?()
            return
        }
        arrangement = rest
        if id == activePane {
            let index = order.firstIndex(of: id) ?? 0
            let remaining = rest.panes
            activePane = remaining[min(max(index - 1, 0), remaining.count - 1)]
        }
        relayout()
        if hadKeyboard { focusActivePane() }
    }

    /// Остановить все части — вкладку закрывают.
    func terminateAll() {
        for pane in panes.values {
            pane.terminateProcess()
        }
    }

    // MARK: - Focus

    func focusActivePane() {
        focus(activePane)
    }

    private func focus(_ id: UUID) {
        markActive(id)
        panes[id]?.takeKeyboard()
    }

    private func markActive(_ id: UUID) {
        guard panes[id] != nil else { return }
        activePane = id
        updateActiveFrame()
    }

    /// Часть, в которой сейчас клавиатура.
    private var focusedPane: UUID? {
        panes.first { $0.value.holdsKeyboard }?.key
    }

    /// Перейти к соседней части в направлении стрелки.
    @discardableResult
    func moveFocus(_ direction: TerminalDirection) -> Bool {
        let frames = arrangement.frames(in: bounds, divider: Self.dividerThickness).panes
        guard let next = TerminalLayout.neighbour(of: activePane, direction: direction, frames: frames)
        else { return false }
        focus(next)
        return true
    }

    // MARK: - Mouse

    /// Сделать часть активной и выполнить над разделением действие — для меню и кнопок.
    private func act(on id: UUID?, _ action: (TerminalSplitView) -> Void) {
        guard let id, panes[id] != nil else { return }
        focus(id)
        action(self)
    }

    /// Меню правого щелчка по части: то же, что клавиши, с клавишами справа.
    func contextMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pane = panes[id]
        menu.addItem(ShortcutMenuItem(title: L("terminal.copy"), symbolName: "doc.on.doc", shortcutHint: "⌘C",
                                      enabled: pane?.hasSelection ?? false) { pane?.copySelection() })
        menu.addItem(ShortcutMenuItem(title: L("terminal.paste"), symbolName: "doc.on.clipboard",
                                      shortcutHint: "⌘V") { pane?.pasteClipboard() })
        menu.addItem(.separator())
        menu.addItem(ShortcutMenuItem(title: L("terminal.splitSideBySide"), symbolName: "rectangle.split.2x1",
                                      shortcutHint: "⌘D") { [weak self] in self?.act(on: id) { $0.split(.sideBySide) } })
        menu.addItem(ShortcutMenuItem(title: L("terminal.splitStacked"), symbolName: "rectangle.split.1x2",
                                      shortcutHint: "⇧⌘D") { [weak self] in self?.act(on: id) { $0.split(.stacked) } })
        if onNewTerminal != nil {
            menu.addItem(ShortcutMenuItem(title: L("terminal.newTab"), symbolName: "terminal",
                                          shortcutHint: "⌘T") { [weak self] in
                guard let self, let pane = self.panes[id] else { return }
                self.onNewTerminal?(pane.workingDirectory)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ShortcutMenuItem(title: L("terminal.closePane"), symbolName: "xmark",
                                      shortcutHint: "⌘W") { [weak self] in self?.closePane(id) })
        return menu
    }

    // MARK: - Keys

    /// Клавиша, пока клавиатура в одной из частей. `true` — съедена.
    func perform(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        switch (keyCode, flags) {
        case (2, [.command]):            // ⌘D
            split(.sideBySide)
        case (2, [.command, .shift]):    // ⌘⇧D
            split(.stacked)
        case (13, [.command]):           // ⌘W
            closePane(activePane)
        case (17, [.command]):           // ⌘T
            guard let onNewTerminal, let pane = panes[activePane] else { return false }
            onNewTerminal(pane.workingDirectory)
        case (123, [.command, .option]): moveFocus(.left)
        case (124, [.command, .option]): moveFocus(.right)
        case (125, [.command, .option]): moveFocus(.down)
        case (126, [.command, .option]): moveFocus(.up)
        default:
            return false
        }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            return
        }
        guard keyMonitor == nil else { return }
        // По коду клавиши, не по букве: в русской раскладке ⌘D приходит как «в».
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !self.isHidden,
                  let focused = self.focusedPane else { return event }
            self.markActive(focused)
            return self.perform(keyCode: event.keyCode, modifiers: event.modifierFlags) ? nil : event
        }
    }

    // MARK: - Layout

    private func relayout() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let geometry = arrangement.frames(in: bounds, divider: Self.dividerThickness)
        for (id, rect) in geometry.panes {
            let (header, body) = Self.headerAndBody(of: rect)
            headers[id]?.frame = header
            panes[id]?.frame = body
        }
        syncDividers(geometry.dividers)
        updateActiveFrame(geometry)
    }

    private func syncDividers(_ dividers: [TerminalDivider]) {
        while dividerViews.count > dividers.count {
            dividerViews.removeLast().removeFromSuperview()
        }
        while dividerViews.count < dividers.count {
            let view = TerminalPaneDivider()
            view.onDrag = { [weak self, weak view] point in
                guard let self, let spot = view?.spot else { return }
                self.moveDivider(spot, to: point)
            }
            addSubview(view, positioned: .below, relativeTo: activeFrame)
            dividerViews.append(view)
        }
        for (view, spot) in zip(dividerViews, dividers) {
            view.spot = spot
            // Тонкая линия, но хватать её можно с запасом по обе стороны.
            view.frame = spot.axis == .sideBySide
                ? spot.rect.insetBy(dx: -3, dy: 0)
                : spot.rect.insetBy(dx: 0, dy: -3)
            view.window?.invalidateCursorRects(for: view)
        }
    }

    private func moveDivider(_ spot: TerminalDivider, to point: NSPoint) {
        let position = (spot.axis == .sideBySide ? point.x : point.y) - Self.dividerThickness / 2
        arrangement = arrangement.movingDivider(at: spot.path, index: spot.index, to: position,
                                                in: bounds, divider: Self.dividerThickness,
                                                minimum: Self.minimumPaneSize)
        relayout()
    }

    /// Полоска сверху, терминал под ней.
    static func headerAndBody(of rect: CGRect) -> (header: CGRect, body: CGRect) {
        let height = min(headerHeight, rect.height)
        return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
    }

    /// Рамка цвета акцента вокруг активной части — когда частей больше одной.
    private func updateActiveFrame(_ geometry: TerminalLayoutGeometry? = nil) {
        let frames = geometry?.panes ?? arrangement.frames(in: bounds, divider: Self.dividerThickness).panes
        for (id, header) in headers {
            header.isActive = panes.count > 1 && id == activePane
        }
        guard panes.count > 1, let rect = frames[activePane] else {
            activeFrame.isHidden = true
            return
        }
        activeFrame.isHidden = false
        activeFrame.frame = rect
        activeFrame.color = PanelAppearanceSettings.accentNSColor
    }
}

// MARK: - Divider

/// Полоска между частями: рисует линию посередине, тянется мышью.
private final class TerminalPaneDivider: NSView {
    var spot: TerminalDivider?
    var onDrag: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let spot else { return }
        NSColor.separatorColor.setFill()
        let line = spot.axis == .sideBySide
            ? NSRect(x: (bounds.width - TerminalSplitView.dividerThickness) / 2, y: 0,
                     width: TerminalSplitView.dividerThickness, height: bounds.height)
            : NSRect(x: 0, y: (bounds.height - TerminalSplitView.dividerThickness) / 2,
                     width: bounds.width, height: TerminalSplitView.dividerThickness)
        line.fill()
    }

    override func resetCursorRects() {
        guard let spot else { return }
        addCursorRect(bounds, cursor: spot.axis == .sideBySide ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview else { return }
        onDrag?(parent.convert(event.locationInWindow, from: nil))
    }
}

// MARK: - Active frame

/// Рамка активной части. Не ловит мышь: щелчок проходит в терминал под ней.
private final class TerminalActiveFrame: NSView {
    var color: NSColor = .controlAccentColor {
        didSet { layer?.borderColor = color.withAlphaComponent(0.8).cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1.5
        layer?.borderColor = color.withAlphaComponent(0.8).cgColor
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Pane controls

/// Три кнопки в углу части: разделить рядом, разделить под низ, закрыть. Подсказка у каждой —
/// с клавишей, чтобы со временем мышь стала не нужна.
final class TerminalPaneControls: NSView {
    var paneID: UUID?
    var onSplitSideBySide: (() -> Void)?
    var onSplitStacked: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var buttons: [TerminalPaneButton] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        let specs: [(String, String, String, Selector)] = [
            ("rectangle.split.2x1", "terminal.splitSideBySide", "⌘D", #selector(splitSideBySide)),
            ("rectangle.split.1x2", "terminal.splitStacked", "⇧⌘D", #selector(splitStacked)),
            ("xmark", "terminal.closePane", "⌘W", #selector(close)),
        ]
        for (symbol, title, keys, action) in specs {
            let button = TerminalPaneButton(symbol: symbol)
            button.target = self
            button.action = action
            button.toolTip = "\(L(title))  \(keys)"
            addSubview(button)
            buttons.append(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static let buttonSize: CGFloat = 22
    private static let inset: CGFloat = 0

    override var fittingSize: NSSize {
        NSSize(width: Self.inset * 2 + Self.buttonSize * CGFloat(buttons.count),
               height: Self.inset * 2 + Self.buttonSize)
    }

    override func layout() {
        super.layout()
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: Self.inset + Self.buttonSize * CGFloat(i), y: Self.inset,
                                  width: Self.buttonSize, height: Self.buttonSize)
        }
    }

    @objc private func splitSideBySide() { onSplitSideBySide?() }
    @objc private func splitStacked() { onSplitStacked?() }
    @objc private func close() { onClose?() }
}

/// Кнопка-значок: светлая на тёмной подложке, под мышью — цвет акцента, как плюс и звезда
/// на полосе вкладок.
final class TerminalPaneButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovering = false { didSet { updateTint() } }

    init(symbol: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func updateTint() {
        contentTintColor = hovering ? PanelAppearanceSettings.accentNSColor : NSColor(white: 1, alpha: 0.75)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

// MARK: - Pane header

/// Полоска над частью: кнопки справа, щелчок по ней делает часть активной. У активной части
/// (когда их несколько) полоска подкрашена цветом акцента.
final class TerminalPaneHeader: NSView {
    let controls = TerminalPaneControls()
    var onActivate: (() -> Void)?
    var isActive = false { didSet { if isActive != oldValue { updateColors() } } }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(controls)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Терминал всегда тёмный — полоска одна для светлой и тёмной темы.
    private func updateColors() {
        layer?.backgroundColor = isActive
            ? PanelAppearanceSettings.accentNSColor.withAlphaComponent(0.28).cgColor
            : NSColor(white: 0.13, alpha: 1).cgColor
    }

    override func layout() {
        super.layout()
        let size = controls.fittingSize
        controls.frame = NSRect(x: bounds.maxX - size.width - 4, y: (bounds.height - size.height) / 2,
                                width: size.width, height: size.height)
        controls.isHidden = bounds.width < size.width + 8
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }
}
