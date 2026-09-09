import AppKit

final class FileListRowView: NSTableRowView {
    var isCursor = false {
        didSet { needsDisplay = true }
    }
    var isItemSelected = false {
        didSet { needsDisplay = true }
    }
    /// Custom cursor-bar color; nil = system selection color.
    var cursorBackgroundColor: NSColor? {
        didSet { needsDisplay = true }
    }
    /// Is the panel the one being typed into right now?
    ///
    /// The cursor USED to vanish entirely the moment the panel lost focus — click into the
    /// viewer to select a line of the document and you could no longer see which file you were
    /// looking at. The cursor answers "which file is this", and that question does not stop
    /// mattering when the keyboard goes elsewhere; it just stops being the thing you are
    /// steering. So it stays, dimmed.
    var isPanelActive = true {
        didSet { needsDisplay = true }
    }

    override var isEmphasized: Bool {
        get { false }
        set { }
    }
    override var isSelected: Bool {
        get { false }
        set { }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        // Cursor bar FIRST, then the selection tint OVER it. The opaque cursor bar used to be
        // painted last and completely hid the selection tint — so a marked file that was also
        // the cursor row (exactly what Cmd-click and Space produce: they mark the file AND move
        // the cursor onto it) showed no mark at all. Drawing the tint on top keeps the mark
        // visible as an accent wash on the cursor bar.
        //
        // Beauty mode draws a feathered cursor in the table background (behind the rows),
        // so skip the flat cursor fill here; otherwise paint the solid cursor bar as before.
        // Курсор рисуется только в той панели, которой управляют.
        //
        // Был короткий период, когда он оставался и в неактивной — приглушённым. Это было
        // лечение симптома: курсор пропадал при работе в просмотрщике, потому что щелчок по
        // кнопкам его шапки объявлял активной ПУСТУЮ панель под ним. Настоящую причину
        // починили, и приглушённый след в соседней панели остался просто мусором на экране.
        if isCursor, isPanelActive,
           !UserDefaults.standard.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey) {
            (cursorBackgroundColor ?? .selectedContentBackgroundColor).setFill()
            bounds.fill()
        }

        if isItemSelected {
            // A touch stronger when it has to read over the opaque cursor bar; the plain 0.25
            // tint over the panel background is unchanged for non-cursor marked rows.
            let alpha: CGFloat = isCursor ? 0.42 : 0.25
            PanelAppearanceSettings.selectedNameNSColor.withAlphaComponent(alpha).setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Selection rendering handled in drawBackground
    }
}
