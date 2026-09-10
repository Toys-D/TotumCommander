import AppKit

/// The hand-drawn cursor mask: a grayscale-as-alpha image the user paints in the mask editor.
///
/// The PNG keeps WHITE pixels with their painted alpha — white is the cursor's body, transparent
/// is not-cursor. FeatheredCursor stretches it over the bar and tints it with the cursor colour,
/// so the mask defines only the SHAPE; colour and blur stay live settings on top of it.
extension Notification.Name {
    /// Posted on EVERY change that affects the drawn cursor — a preview push, a save, the
    /// enable toggle. The panels repaint on it. This exists because UserDefaults KVO cannot
    /// observe dotted keys (the project's own AppDelegate documents it), and every mask key is
    /// dotted — the defaults observer never fired once for them.
    static let fcxlCursorMaskChanged = Notification.Name("fcxlCursorMaskChanged")
}

enum CursorMaskStore {

    private static func notifyPanels() {
        NotificationCenter.default.post(name: .fcxlCursorMaskChanged, object: nil)
    }

    /// The one way to flip the custom cursor on or off — it tells the panels, which a raw
    /// defaults write never does (dotted keys are invisible to defaults KVO).
    @MainActor
    static func setEnabled(_ on: Bool) {
        // Per theme, like the other cursor switches: a drawn cursor can suit the light theme
        // and not the dark one. The effective key is the mirror of the current theme's.
        defaults.set(on, forKey: PanelAppearanceSettings.isDarkAppearance ? enabledDarkKey : enabledLightKey)
        defaults.set(on, forKey: enabledKey)
        notifyPanels()
    }

    /// Painting is on. Kept apart from the mask file so switching the shape off does not throw
    /// the drawing away. Effective key — the current theme's, kept in step by the theme sync.
    static let enabledKey = "fcxl.customCursorMaskEnabled"
    static let enabledLightKey = "fcxl.customCursorMaskEnabledLight"
    static let enabledDarkKey = "fcxl.customCursorMaskEnabledDark"
    /// Bumped on every save — part of the bake's cache key, and the signal every panel observes
    /// to repaint after the editor closes.
    static let revisionKey = "fcxl.customCursorMaskRevision"

    /// The mask bitmap's logical size. Wide like the row bar it will stretch onto, so what the
    /// user draws is roughly what the row shows.
    static let maskSize = NSSize(width: 360, height: 60)

    /// Where the ARTWORK lives — the drawing before the fades. The cursor uses the composited
    /// mask; the editor reopens on this, so moving a fade slider filters the original drawing
    /// instead of multiplying an already-faded one.
    static var artworkURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("cursor-mask-artwork.png")
    }

    // MARK: - Где всё лежит

    /// Подменяемое место хранения — для проверок.
    ///
    /// Без него прогон тестов писал в НАСТОЯЩИЙ файл человека и стирал его флажок: после
    /// каждого `swift test` нарисованный курсор превращался в простую полосу, а «свой
    /// курсор» выключался. Проверка обязана работать со своей папкой и своими настройками,
    /// а не с чужим рисунком.
    struct Storage {
        let directory: URL
        let defaults: UserDefaults
    }

    nonisolated(unsafe) static var storageOverride: Storage? {
        didSet {
            // Хранилище сменилось — запомненное от прежнего больше не про эту маску.
            cachedImage = nil
            cachedRevision = -1
            previewMask = nil
            FeatheredCursor.dropCache()
        }
    }

    /// Идёт проверка? Тогда настоящие папка и настройки человека недоступны в принципе.
    /// Одной забытой подмены в новом тесте хватило, чтобы прогон переписал нарисованный
    /// курсор сплошной полосой — защита не должна зависеть от памяти пишущего.
    private static var underTest: Bool { NSClassFromString("XCTestCase") != nil }

    nonisolated(unsafe) private static let testDirectory: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-cursor-mask-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Чистая на каждый запуск: остатки прошлого прогона делали порядок проверок значимым.
    nonisolated(unsafe) private static let testDefaults: UserDefaults = {
        let name = "fcxl.cursor.mask.tests"
        guard let suite = UserDefaults(suiteName: name) else { return .standard }
        suite.removePersistentDomain(forName: name)
        return suite
    }()

    /// Настройки, в которых живут ключи маски: обычные — в программе, свои — в проверке.
    static var defaults: UserDefaults {
        if let overridden = storageOverride?.defaults { return overridden }
        return underTest ? testDefaults : .standard
    }

    private static var baseDirectory: URL {
        if let directory = storageOverride?.directory { return directory }
        if underTest { return testDirectory }
        return FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first!
            .appendingPathComponent("TotumCommander", isDirectory: true)
    }

    @discardableResult
    static func saveArtwork(_ rep: NSBitmapImageRep) -> Bool {
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: artworkURL, options: .atomic) } catch { return false }
        return true
    }

    static func loadArtworkImage() -> NSImage? { NSImage(contentsOf: artworkURL) }

    static var fileURL: URL {
        let base = baseDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("cursor-mask.png")
    }

    static var isEnabled: Bool {
        defaults.bool(forKey: enabledKey)
    }

    static var revision: Int {
        defaults.integer(forKey: revisionKey)
    }

    /// Save the painted mask and bump the revision, so every cached bake goes stale at once.
    @discardableResult
    static func save(_ rep: NSBitmapImageRep) -> Bool {
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: fileURL, options: .atomic)
        } catch {
            return false
        }
        cachedImage = nil
        cachedRevision = -1
        defaults.set(revision + 1, forKey: revisionKey)
        notifyPanels()
        return true
    }

    // MARK: - Vertical gradient mode

    /// The editor's "vertical" switch. Kept in defaults so the editor reopens as it was left.
    static let verticalGradientKey = "fcxl.cursorMaskVerticalGradient"
    /// Where the blur value waits while the vertical gradient owns the softness.
    private static let blurStashKey = "fcxl.cursorMaskBlurStash"

    static var isVerticalGradientOn: Bool {
        defaults.bool(forKey: verticalGradientKey)
    }

    /// Flip the vertical-gradient mode. A vertical fade and the Gaussian blur both soften the
    /// same edges — together they turn to mush, so switching the fade ON parks the blur at zero
    /// and switching it OFF gives the parked value back.
    static func setVerticalGradient(_ on: Bool) {
        let d = defaults
        guard on != isVerticalGradientOn else { return }
        d.set(on, forKey: verticalGradientKey)
        if on {
            let blur = d.object(forKey: PanelAppearanceSettings.cursorBlurKey) as? Double ?? 0
            if blur > 0 {
                d.set(blur, forKey: blurStashKey)
                d.set(0.0, forKey: PanelAppearanceSettings.cursorBlurKey)
            }
        } else if let stashed = d.object(forKey: blurStashKey) as? Double {
            d.set(stashed, forKey: PanelAppearanceSettings.cursorBlurKey)
            d.removeObject(forKey: blurStashKey)
        }
    }

    // MARK: - Live preview while the editor is open

    /// Bumped on every preview push — observed by the panels, part of the bake key.
    static let previewRevisionKey = "fcxl.customCursorMaskPreviewRevision"

    /// The mask as it is being drawn RIGHT NOW, before any save. While set, it overrides both
    /// the saved file and the on/off toggle: a preview is for seeing, whatever the settings say.
    private(set) static var previewMask: NSImage?

    static var previewRevision: Int {
        defaults.integer(forKey: previewRevisionKey)
    }

    /// Show the in-progress drawing on the panels. The defaults bump is what wakes them up.
    static func pushPreview(_ image: NSImage) {
        previewMask = image
        defaults.set(previewRevision + 1, forKey: previewRevisionKey)
        notifyPanels()
    }

    /// The editor closed — back to the saved state (whatever it is), and tell the panels.
    static func clearPreview() {
        guard previewMask != nil else { return }
        previewMask = nil
        defaults.set(previewRevision + 1, forKey: previewRevisionKey)
        notifyPanels()
    }

    private static var cachedImage: NSImage?
    private static var cachedRevision: Int = -1

    /// The saved mask, cached until the next save. nil when nothing was ever drawn.
    static func loadImage() -> NSImage? {
        if cachedRevision == revision, let cachedImage { return cachedImage }
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        cachedImage = image
        cachedRevision = revision
        return image
    }

    /// The mask the cursor should use right now: the live preview while the editor is open,
    /// else the saved drawing when the toggle is on.
    static func activeMask() -> NSImage? {
        if let previewMask { return previewMask }
        guard isEnabled else { return nil }
        return loadImage() ?? shippedImage()
    }

    /// The mask the program ships with — the author's own — for a Mac where nothing was drawn
    /// yet: the toggle comes on by default (DefaultStyle), and a toggle with no mask behind it
    /// would show a bare cursor.
    static func shippedImage() -> NSImage? {
        AppResources.bundle.url(forResource: "DefaultCursorMask", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }

    /// The artwork behind the shipped mask, so the editor opens on it rather than on nothing.
    static func shippedArtworkImage() -> NSImage? {
        AppResources.bundle.url(forResource: "DefaultCursorMaskArtwork", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }
}
