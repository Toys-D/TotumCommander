import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the app's light/dark appearance changes — panels re-read their
    /// per-theme background color in response.
    static let fcxlAppearanceChanged = Notification.Name("com.fcxl.appearanceChanged")
}

enum PanelAppearanceSettings {
    static let iconScaleKey = "iconScale"
    /// How far the list's icons may be scaled. Three times the base size — the setting exists
    /// for people who want to SEE the icons, and two was not enough for that.
    static let maximumIconScale: Double = 3.0
    static let minimumIconScale: Double = 0.75
    static let folderIconColorHexKey = "folderIconColorHex"
    static let folderNameColorHexKey = "folderNameColorHex"
    static let fileNameColorHexKey = "fileNameColorHex"
    /// Цвет имён выделенных файлов; пусто — цвет акцента, как было всегда.
    static let selectedNameColorHexKey = "selectedNameColorHex"
    static let cursorNameColorHexKey = "cursorNameColorHex"
    static let cursorBackgroundColorHexKey = "cursorBackgroundColorHex"
    /// Design page's "colour under cursor": the colour of a file or folder NAME while the cursor is
    /// on that row — Total Commander's foreground-colour-of-cursor. It does NOT tint the cursor bar
    /// itself; that stays the accent (or the Cursor section's colour when its custom mode is on).
    static let cursorUnderNameColorHexKey = "cursorUnderNameColorHex"
    /// Fill opacity of the active tab (0…1). The inactive one stays at its own fixed, lighter
    /// value, so raising this widens the gap between the two — which is the point of the setting.
    /// Text and glyph colour of the ACTIVE tab. Its own setting, per theme — the tab bar is not the
    /// file panel, and tying it to the panel cursor's colour made one choice govern two unrelated
    /// places. Unset = the ordinary label colour.
    static let tabActiveTitleColorHexKey = "tabActiveTitleColorHex"
    static let tabActiveTitleColorHexLightKey = "tabActiveTitleColorHexLight"
    static let tabActiveTitleColorHexDarkKey = "tabActiveTitleColorHexDark"

    static let tabActiveOpacityKey = "tabActiveOpacity"
    static let defaultTabActiveOpacity: Double = 0.40
    static let panelBackgroundColorHexKey = "panelBackgroundColorHex"
    // Non-dotted keys: the panel list observes appearance keys via KVO, and KVO
    // treats a "." as a key-path separator (dotted keys can't be observed).
    static let accentColorHexKey = "accentColorHex"
    static let cursorUsesCustomColorKey = "cursorUsesCustomColor"
    static let upIconScaleKey = "upIconScale"
    /// The side of a cell in the thumbnails mode, in points — its own setting, apart from the
    /// list's icon scale: a picture wants room the list's icons never do.
    static let thumbnailSizeKey = "thumbnailCellSize"
    static let defaultThumbnailSize: Double = 100
    static let minimumThumbnailSize: Double = 60
    static let maximumThumbnailSize: Double = 240
    static var resolvedThumbnailSize: CGFloat {
        let saved = UserDefaults.standard.object(forKey: thumbnailSizeKey) as? Double ?? defaultThumbnailSize
        return CGFloat(min(max(saved, minimumThumbnailSize), maximumThumbnailSize))
    }
    static let upIconWeightKey = "upIconWeight"
    static let upIconSymbolKey = "upIconSymbol"
    /// App theme: 0 = follow system, 1 = light, 2 = dark.
    static let appearanceModeKey = "appearanceMode"
    /// Master switch for GPU-heavy "beauty" effects (gated by MacCapabilities).
    /// Show Git state in the file list. On unless turned off: outside a repository it costs
    /// nothing and changes nothing, and inside one it is the whole point of the feature.
    static let gitStatusEnabledKey = "gitStatusEnabled"

    static let beautyModeEnabledKey = "beautyModeEnabled"
    /// Beauty effect: cursor edge-feather (Gaussian) radius, 0…30. Default 10.
    static let cursorBlurKey = "cursorBlur"
    static let defaultCursorBlur: Double = 10
    /// Beauty effect: cursor height as a fraction of the row (0.3…1.0). Default 0.8.
    static let cursorHeightKey = "cursorHeight"
    static let defaultCursorHeight: Double = 0.8

    static var resolvedCursorHeightFraction: CGFloat {
        let raw = UserDefaults.standard.object(forKey: cursorHeightKey) as? Double ?? defaultCursorHeight
        return CGFloat(max(0.3, min(1.0, raw)))
    }

    /// Beauty effect: cursor width as a fraction of the item (0.3…1.0). Default 1.0.
    static let cursorWidthKey = "cursorWidth"
    static let defaultCursorWidth: Double = 1.0

    static var resolvedCursorWidthFraction: CGFloat {
        let raw = UserDefaults.standard.object(forKey: cursorWidthKey) as? Double ?? defaultCursorWidth
        return CGFloat(max(0.01, min(1.0, raw)))
    }

    /// Beauty effect: cursor position offset within the cell, in points. Default 0.
    static let cursorOffsetXKey = "cursorOffsetX"
    static let cursorOffsetYKey = "cursorOffsetY"

    static var resolvedCursorOffsetX: CGFloat {
        CGFloat(max(-100, min(100, UserDefaults.standard.double(forKey: cursorOffsetXKey))))
    }
    static var resolvedCursorOffsetY: CGFloat {
        CGFloat(max(-30, min(30, UserDefaults.standard.double(forKey: cursorOffsetYKey))))
    }

    /// Beauty effect: scaling anchor point within the cell (0…1, 0.5 = centre). The anchor
    /// is where width/height scaling originates — anchorX 0 keeps the left edge fixed so
    /// the cursor grows/shrinks to the right, 1 keeps the right edge fixed, 0.5 is symmetric.
    static let cursorAnchorXKey = "cursorAnchorX"
    static let cursorAnchorYKey = "cursorAnchorY"
    static let defaultCursorAnchor: Double = 0.5

    static var resolvedCursorAnchorX: CGFloat {
        let raw = UserDefaults.standard.object(forKey: cursorAnchorXKey) as? Double ?? defaultCursorAnchor
        return CGFloat(max(0, min(1, raw)))
    }
    static var resolvedCursorAnchorY: CGFloat {
        let raw = UserDefaults.standard.object(forKey: cursorAnchorYKey) as? Double ?? defaultCursorAnchor
        return CGFloat(max(0, min(1, raw)))
    }

    /// Icon "lift": the file/folder icon on the cursor row grows by this factor (1…2,
    /// default 1.3). Gated by its own on/off switch. Works in every view mode.
    static let cursorIconZoomEnabledKey = "cursorIconZoomEnabled"
    static let cursorIconZoomAmountKey = "cursorIconZoomAmount"
    static let defaultCursorIconZoom: Double = 1.3

    /// How many rows on each side of the cursor the icon lift reaches. 0 = the cursor row only.
    static let cursorIconZoomSpreadKey = "cursorIconZoomSpread"
    static var resolvedCursorIconZoomSpread: Int {
        let raw = UserDefaults.standard.object(forKey: cursorIconZoomSpreadKey) as? Int ?? 0
        return max(0, min(5, raw))
    }

    static var resolvedCursorIconZoom: CGFloat {
        let raw = UserDefaults.standard.object(forKey: cursorIconZoomAmountKey) as? Double ?? defaultCursorIconZoom
        return CGFloat(max(1.0, min(2.0, raw)))
    }

    /// Left inset of the icon from the panel edge, in points (row-based modes only).
    /// Default 4 = the current look.
    static let iconEdgeInsetKey = "iconEdgeInset"
    static let defaultIconEdgeInset: Double = 4
    static var resolvedIconEdgeInset: CGFloat {
        let raw = UserDefaults.standard.object(forKey: iconEdgeInsetKey) as? Double ?? defaultIconEdgeInset
        return CGFloat(max(0, min(40, raw)))
    }

    // MARK: - File-list typography
    /// Font family ("" = system), point size, bold flag, and extra line spacing added to the
    /// row height. A separate switch enlarges the text on the cursor row.
    static let listFontFamilyKey = "listFontFamily"
    static let listFontSizeKey = "listFontSize"
    static let listFontBoldKey = "listFontBold"
    /// Extra spacing between letters (tracking / kern), in points. Can be negative to tighten.
    static let listLetterSpacingKey = "listLetterSpacing"
    static let cursorFontZoomEnabledKey = "cursorFontZoomEnabled"
    static let cursorFontZoomAmountKey = "cursorFontZoomAmount"
    static let defaultListFontSize: Double = 12
    static let defaultCursorFontZoom: Double = 1.3

    static var resolvedListFontSize: CGFloat {
        let raw = UserDefaults.standard.object(forKey: listFontSizeKey) as? Double ?? defaultListFontSize
        return CGFloat(max(8, min(28, raw)))
    }
    /// Letter spacing (kern) in points, -3…10, default 0.
    static var resolvedListLetterSpacing: CGFloat {
        let raw = UserDefaults.standard.object(forKey: listLetterSpacingKey) as? Double ?? 0
        return CGFloat(max(-3, min(10, raw)))
    }
    /// Font enlargement factor for the cursor row's text (1 = off).
    static var resolvedCursorFontZoom: CGFloat {
        guard UserDefaults.standard.bool(forKey: cursorFontZoomEnabledKey) else { return 1 }
        let raw = UserDefaults.standard.object(forKey: cursorFontZoomAmountKey) as? Double ?? defaultCursorFontZoom
        return CGFloat(max(1, min(2, raw)))
    }

    /// The list font at an explicit point size (family + bold taken from settings).
    static func listFont(size: CGFloat) -> NSFont {
        let family = UserDefaults.standard.string(forKey: listFontFamilyKey) ?? ""
        let bold = UserDefaults.standard.bool(forKey: listFontBoldKey)
        if !family.isEmpty {
            // availableFontFamilies gives FAMILY names — resolve to a concrete face via the
            // font manager (NSFont(name:) expects a font name, not a family, so it often fails).
            let traits: NSFontTraitMask = bold ? .boldFontMask : []
            if let f = NSFontManager.shared.font(withFamily: family, traits: traits,
                                                 weight: bold ? 9 : 5, size: size) {
                return f
            }
            if let named = NSFont(name: family, size: size) {
                return bold ? NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask) : named
            }
        }
        return .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
    /// The text's share of the cursor enlargement at `distance` rows from the cursor — the same
    /// Dock-style wave the icons ride (`CursorIconZoom.scale(atDistance:)`), and deliberately the
    /// SAME reach setting: how far the lift spreads is one idea, set once, in the folders page.
    static func cursorFontScale(atDistance distance: Int) -> CGFloat {
        let zoom = resolvedCursorFontZoom
        guard zoom != 1, distance >= 0 else { return 1 }
        let spread = resolvedCursorIconZoomSpread
        guard distance <= spread else { return 1 }
        let falloff = 1 - CGFloat(distance) / CGFloat(spread + 1)
        return 1 + (zoom - 1) * falloff
    }

    // Resolved-font cache (main-thread only, like FeatheredCursor's image cache). Resolving
    // a family via NSFontManager is the one non-trivial per-cell cost; cache one face per
    // enlargement step and only recompute when a font setting actually changes. The wave needs
    // a face per distance, so this is keyed by the scaled size rather than by a cursor flag.
    private static var fontCache: [Int: NSFont] = [:]
    private static var fontCacheSignature = ""

    /// The list font at the configured size, enlarged by the cursor wave at `distance` rows from
    /// the cursor (0 = the cursor row itself, Int.max = an inactive panel).
    /// Cached: the NSFontManager lookup runs only when the typography settings change.
    static func resolvedListFont(atDistance distance: Int) -> NSFont {
        let family = UserDefaults.standard.string(forKey: listFontFamilyKey) ?? ""
        let bold = UserDefaults.standard.bool(forKey: listFontBoldKey)
        let size = resolvedListFontSize
        let zoom = resolvedCursorFontZoom
        let signature = "\(family)-\(Int(size))-\(bold ? 1 : 0)-\(Int(zoom * 100))-\(resolvedCursorIconZoomSpread)"
        if signature != fontCacheSignature {
            fontCacheSignature = signature
            fontCache.removeAll()
        }
        // Rounded to whole tenths of a point: neighbouring distances that land on the same face
        // share one cache entry instead of resolving the family twice.
        let scaled = size * cursorFontScale(atDistance: distance)
        let key = Int((scaled * 10).rounded())
        if let cached = fontCache[key] { return cached }
        let font = listFont(size: CGFloat(key) / 10)
        fontCache[key] = font
        return font
    }

    /// The binary form: the cursor row's font, or the plain one.
    static func resolvedListFont(cursor: Bool = false) -> NSFont {
        resolvedListFont(atDistance: cursor ? 0 : Int.max)
    }

    /// Compact signature of the typography settings — appended to the collection cell
    /// reload tokens so a font change re-renders the brief / thumbnails cells.
    static var listFontToken: String {
        let family = UserDefaults.standard.string(forKey: listFontFamilyKey) ?? "sys"
        let bold = UserDefaults.standard.bool(forKey: listFontBoldKey) ? 1 : 0
        return "\(family)-s\(Int(resolvedListFontSize))-b\(bold)-let\(Int((resolvedListLetterSpacing * 10).rounded()))-fz\(Int(resolvedCursorFontZoom * 100))s\(resolvedCursorIconZoomSpread)"
    }

    /// Row height for the row-based modes: honours the user's row height, grows to fit the
    /// font, and adds the extra line spacing.
    static var resolvedListRowHeight: CGFloat {
        let userRow = UserDefaults.standard.object(forKey: "briefRowHeight") as? Double ?? 26
        let fontMin = Double(resolvedListFontSize) + 12
        return CGFloat(max(18, max(userRow, fontMin)))
    }

    // The cursor's OUTLINE — a crisp rim around the bar, the look the mask bubble has: soft
    // body, sharp edge. Drawn AFTER the feathering, so the blur softens the fill and leaves the
    // rim alone.
    static let cursorOutlineEnabledKey = "cursorOutlineEnabled"
    static let cursorOutlineWidthKey = "cursorOutlineWidth"
    static let cursorOutlineColorHexKey = "cursorOutlineColorHex"
    static let cursorOutlineColorHexLightKey = "cursorOutlineColorHexLight"
    static let cursorOutlineColorHexDarkKey = "cursorOutlineColorHexDark"
    static let cursorOutlineEnabledLightKey = "cursorOutlineEnabledLight"
    static let cursorOutlineEnabledDarkKey = "cursorOutlineEnabledDark"
    static let defaultCursorOutlineWidth: Double = 1.5

    /// Outline width in points, 0.5…6. Zero would be an invisible line that still costs a bake.
    static var resolvedCursorOutlineWidth: CGFloat {
        let raw = UserDefaults.standard.object(forKey: cursorOutlineWidthKey) as? Double
            ?? defaultCursorOutlineWidth
        return CGFloat(max(0.5, min(6, raw)))
    }

    static var isGitStatusEnabled: Bool {
        UserDefaults.standard.object(forKey: gitStatusEnabledKey) as? Bool ?? true
    }

    static var isCursorOutlineEnabled: Bool {
        UserDefaults.standard.bool(forKey: cursorOutlineEnabledKey)
    }

    /// The rim's colour: the user's own, or — unset — the cursor's own colour brightened, which
    /// is what makes the bubble's rim read as "the same colour, only sharper".
    static func resolvedCursorOutlineColor() -> NSColor {
        if let custom = optionalNSColor(from:
            UserDefaults.standard.string(forKey: cursorOutlineColorHexKey) ?? "") {
            return custom
        }
        return resolvedCursorBackground().blended(withFraction: 0.35, of: .white)
            ?? resolvedCursorBackground()
    }

    /// Beauty effect: cursor corner radius in points (0 = sharp), 0…20. Default 8.
    static let cursorCornerKey = "cursorCorner"
    static let defaultCursorCorner: Double = 8

    static var resolvedCursorCorner: CGFloat {
        let raw = UserDefaults.standard.object(forKey: cursorCornerKey) as? Double ?? defaultCursorCorner
        return CGFloat(max(0, min(20, raw)))
    }

    /// Effective cursor feather radius: the slider when beauty mode is on, else 0.
    static var resolvedCursorGlow: CGFloat {
        let d = UserDefaults.standard
        guard d.bool(forKey: beautyModeEnabledKey) else { return 0 }
        let raw = d.object(forKey: cursorBlurKey) as? Double ?? defaultCursorBlur
        return CGFloat(max(0, min(30, raw)))
    }
    /// Panel background is stored PER THEME so the user can e.g. pick a dark-blue for
    /// dark mode and a warm white for light mode. Resolved by effective appearance.
    static let panelBackgroundColorHexLightKey = "panelBackgroundColorHexLight"
    static let panelBackgroundColorHexDarkKey = "panelBackgroundColorHexDark"

    /// Whether the app is currently showing the dark appearance (system or forced).
    ///
    /// `NSApp` is implicitly unwrapped and is nil before the application object exists — reading
    /// it there is a crash, not a nil. Fall back to what is being drawn.
    @MainActor
    static var isDarkAppearance: Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The panel-background key for a given theme.
    static func panelBackgroundKey(dark: Bool) -> String {
        dark ? panelBackgroundColorHexDarkKey : panelBackgroundColorHexLightKey
    }

    // MARK: - Alternating rows (Total Commander style)

    /// The switch. Separate from the colour, so trying the stripes off and back on never costs
    /// the shade that was picked.
    static let alternateRowsEnabledKey = "alternateRowsEnabled"

    /// The stripe shade, per theme: one that reads on a dark panel is invisible on a light one.
    static let alternateRowColorHexLightKey = "alternateRowColorHexLight"
    static let alternateRowColorHexDarkKey = "alternateRowColorHexDark"

    static func alternateRowColorKey(dark: Bool) -> String {
        dark ? alternateRowColorHexDarkKey : alternateRowColorHexLightKey
    }

    /// The shade before the user has chosen one: barely off the panel background, because the
    /// point is a quiet guide for the eye, not a second colour scheme.
    static func defaultAlternateRowHex(dark: Bool) -> String {
        dark ? "#FFFFFF12" : "#00000010"
    }

    /// The stripe colour in force, or nil when the list stays plain. Off means nil whatever
    /// shade is remembered; on with nothing chosen falls back to the default, so switching it
    /// on always shows something.
    @MainActor
    static func resolvedAlternateRowColor() -> NSColor? {
        guard UserDefaults.standard.bool(forKey: alternateRowsEnabledKey) else { return nil }
        let dark = isDarkAppearance
        let hex = UserDefaults.standard.string(forKey: alternateRowColorKey(dark: dark)) ?? ""
        return optionalNSColor(from: hex) ?? optionalNSColor(from: defaultAlternateRowHex(dark: dark))
    }

    /// Interface tint (window chrome: toolbars, bars, tabs, divider, footer) — also
    /// stored per theme. Unset = the system window background (current look).
    static let interfaceColorHexLightKey = "interfaceColorHexLight"
    static let interfaceColorHexDarkKey = "interfaceColorHexDark"

    static func interfaceColorKey(dark: Bool) -> String {
        dark ? interfaceColorHexDarkKey : interfaceColorHexLightKey
    }

    /// AppKit interface tint for a theme (window background). Falls back to the system
    /// window background when the user hasn't picked one.
    static func interfaceNSColor(dark: Bool) -> NSColor {
        let hex = UserDefaults.standard.string(forKey: interfaceColorKey(dark: dark)) ?? ""
        return nsColor(from: hex, fallback: .windowBackgroundColor)
    }

    /// Titlebar-only colour (the window title row), stored per theme.
    /// Unset = follow the interface tint / system titlebar.
    static let titlebarColorHexLightKey = "titlebarColorHexLight"
    static let titlebarColorHexDarkKey = "titlebarColorHexDark"

    static func titlebarColorKey(dark: Bool) -> String {
        dark ? titlebarColorHexDarkKey : titlebarColorHexLightKey
    }

    /// The custom titlebar colour for a theme, or nil when the user hasn't picked one.
    static func titlebarNSColor(dark: Bool) -> NSColor? {
        optionalNSColor(from: UserDefaults.standard.string(forKey: titlebarColorKey(dark: dark)) ?? "")
    }

    /// Applies the saved theme to the whole app. Setting `NSApp.appearance` to nil
    /// follows the system; .aqua / .darkAqua force light / dark (all windows inherit it).
    /// Posts `.fcxlAppearanceChanged` so panels re-read their per-theme background.
    @MainActor
    static func applyAppearanceMode() {
        switch UserDefaults.standard.integer(forKey: appearanceModeKey) {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        // Swap each per-theme colour into its effective key for the new theme, THEN
        // notify so consumers re-read the already-updated values.
        syncThemedColorsToEffective()
        NotificationCenter.default.post(name: .fcxlAppearanceChanged, object: nil)
    }

    // MARK: - Per-theme colours (light/dark memory via an "effective mirror")
    //
    // These colours are consumed all over the app through @AppStorage(<effective key>).
    // Rather than teach every consumer to read a per-theme key, we keep the effective
    // key as the single source they read, and store a remembered value PER THEME. On
    // any appearance change `syncThemedColorsToEffective()` copies the remembered value
    // for the current theme into the effective key — so consumers update automatically
    // and each theme keeps its own colours.
    static let accentColorHexLightKey = "accentColorHexLight"
    static let accentColorHexDarkKey = "accentColorHexDark"
    static let folderIconColorHexLightKey = "folderIconColorHexLight"
    static let folderIconColorHexDarkKey = "folderIconColorHexDark"
    static let folderNameColorHexLightKey = "folderNameColorHexLight"
    static let folderNameColorHexDarkKey = "folderNameColorHexDark"
    static let fileNameColorHexLightKey = "fileNameColorHexLight"
    static let fileNameColorHexDarkKey = "fileNameColorHexDark"
    static let selectedNameColorHexLightKey = "selectedNameColorHexLight"
    static let selectedNameColorHexDarkKey = "selectedNameColorHexDark"
    static let cursorNameColorHexLightKey = "cursorNameColorHexLight"
    static let cursorNameColorHexDarkKey = "cursorNameColorHexDark"
    static let cursorBackgroundColorHexLightKey = "cursorBackgroundColorHexLight"
    static let cursorBackgroundColorHexDarkKey = "cursorBackgroundColorHexDark"
    static let cursorUnderNameColorHexLightKey = "cursorUnderNameColorHexLight"
    static let cursorUnderNameColorHexDarkKey = "cursorUnderNameColorHexDark"

    // ON/OFF switches also remembered per theme: the "custom cursor colour" flag and
    // the "beauty mode" (feathered cursor) flag — each theme keeps its own state.
    static let cursorUsesCustomColorLightKey = "cursorUsesCustomColorLight"
    static let cursorUsesCustomColorDarkKey = "cursorUsesCustomColorDark"
    static let beautyModeEnabledLightKey = "beautyModeEnabledLight"
    static let beautyModeEnabledDarkKey = "beautyModeEnabledDark"

    /// (effective, light, dark) for every BOOL stored per theme (mirrored like colours).
    static let themedBoolKeys: [(effective: String, light: String, dark: String)] = [
        (cursorUsesCustomColorKey, cursorUsesCustomColorLightKey, cursorUsesCustomColorDarkKey),
        (beautyModeEnabledKey, beautyModeEnabledLightKey, beautyModeEnabledDarkKey),
        (cursorOutlineEnabledKey, cursorOutlineEnabledLightKey, cursorOutlineEnabledDarkKey),
        (CursorMaskStore.enabledKey, CursorMaskStore.enabledLightKey, CursorMaskStore.enabledDarkKey),
    ]

    /// (effective, light, dark) for every colour stored per theme.
    static let themedColorKeys: [(effective: String, light: String, dark: String)] = [
        (accentColorHexKey, accentColorHexLightKey, accentColorHexDarkKey),
        (folderIconColorHexKey, folderIconColorHexLightKey, folderIconColorHexDarkKey),
        (folderNameColorHexKey, folderNameColorHexLightKey, folderNameColorHexDarkKey),
        (fileNameColorHexKey, fileNameColorHexLightKey, fileNameColorHexDarkKey),
        (selectedNameColorHexKey, selectedNameColorHexLightKey, selectedNameColorHexDarkKey),
        (cursorNameColorHexKey, cursorNameColorHexLightKey, cursorNameColorHexDarkKey),
        (cursorBackgroundColorHexKey, cursorBackgroundColorHexLightKey, cursorBackgroundColorHexDarkKey),
        (cursorUnderNameColorHexKey, cursorUnderNameColorHexLightKey, cursorUnderNameColorHexDarkKey),
        (cursorOutlineColorHexKey, cursorOutlineColorHexLightKey, cursorOutlineColorHexDarkKey),
        (tabActiveTitleColorHexKey, tabActiveTitleColorHexLightKey, tabActiveTitleColorHexDarkKey),
    ]

    /// Какая тема СЧИТАЕТСЯ действующей для зеркала «по темам».
    ///
    /// Чистая функция: принудительная тема из настройки (1 — светлая, 2 — тёмная) знает
    /// себя сразу; «Система» (0) идёт за текущим состоянием экрана. Живое
    /// `NSApp.effectiveAppearance` при старте отстаёт: приложение форсирует тёмную поверх
    /// светлой системы, а effectiveAppearance успевает перевернуться на такт позже — и
    /// зеркало копировало СВЕТЛЫЕ значения (в том числе «красоту», от которой зависит
    /// маска курсора). Спрашивать настройку напрямую убирает эту гонку целиком.
    static func mirrorThemeIsDark(appearanceMode: Int, systemIsDark: Bool) -> Bool {
        switch appearanceMode {
        case 1: return false
        case 2: return true
        default: return systemIsDark
        }
    }

    /// То же для живого приложения: режим из настройки, экран — как запасной вариант.
    @MainActor
    static var mirrorThemeIsDark: Bool {
        mirrorThemeIsDark(appearanceMode: UserDefaults.standard.integer(forKey: appearanceModeKey),
                          systemIsDark: isDarkAppearance)
    }

    /// Copy the current theme's remembered colour into each effective key. Call at
    /// launch and on every `.fcxlAppearanceChanged` (system or manual theme switch).
    @MainActor
    static func syncThemedColorsToEffective() {
        let d = UserDefaults.standard
        let dark = mirrorThemeIsDark
        for c in themedColorKeys {
            let remembered = d.string(forKey: dark ? c.dark : c.light) ?? ""
            let current = d.string(forKey: c.effective) ?? ""
            if remembered == current { continue }
            if remembered.isEmpty { d.removeObject(forKey: c.effective) }
            else { d.set(remembered, forKey: c.effective) }
        }
        var maskChanged = false
        for b in themedBoolKeys {
            let remembered = d.bool(forKey: dark ? b.dark : b.light)
            if d.bool(forKey: b.effective) != remembered {
                d.set(remembered, forKey: b.effective)
                if b.effective == CursorMaskStore.enabledKey { maskChanged = true }
            }
        }
        // The mask's key is dotted: defaults KVO never fires for it, the panels listen to
        // this instead.
        if maskChanged { NotificationCenter.default.post(name: .fcxlCursorMaskChanged, object: nil) }
    }

    /// One-time seed: copy each existing shared colour into BOTH themes so nothing
    /// visually changes until the user diverges them.
    static func migrateColorsPerThemeIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "colorsPerThemeMigrated") else { return }
        for c in themedColorKeys {
            let shared = d.string(forKey: c.effective) ?? ""
            guard !shared.isEmpty else { continue }
            if d.object(forKey: c.light) == nil { d.set(shared, forKey: c.light) }
            if d.object(forKey: c.dark) == nil { d.set(shared, forKey: c.dark) }
        }
        d.set(true, forKey: "colorsPerThemeMigrated")
    }

    /// Seed the per-theme BOOLs from their shared value. Flagless + per-key idempotent
    /// (a bool key, once set, is never nil again — the settings toggles always write
    /// true/false, never remove) so newly-added themed bools auto-migrate on next launch.
    /// Write a per-theme bool to BOTH its theme key and the effective mirror the UI reads.
    ///
    /// Every per-theme setting is stored three times: light, dark, and an "effective" mirror that
    /// views and the renderer read. Updating only some of them leaves the app disagreeing with
    /// itself — the cursor painted from the mirror while the toggle showed the theme key. Go
    /// through here instead of setting the keys by hand.
    @MainActor
    static func setThemedBool(_ value: Bool, effective: String, light: String, dark: String) {
        let d = UserDefaults.standard
        d.set(value, forKey: isDarkAppearance ? dark : light)
        d.set(value, forKey: effective)
    }

    /// Turn the custom cursor colour on or off, keeping the theme keys and the mirror in step.
    @MainActor
    static func setCursorUsesCustomColor(_ value: Bool) {
        setThemedBool(value,
                      effective: cursorUsesCustomColorKey,
                      light: cursorUsesCustomColorLightKey,
                      dark: cursorUsesCustomColorDarkKey)
    }

    static func migrateThemedBoolsIfNeeded() {
        let d = UserDefaults.standard
        for b in themedBoolKeys {
            let shared = d.bool(forKey: b.effective)
            if d.object(forKey: b.light) == nil { d.set(shared, forKey: b.light) }
            if d.object(forKey: b.dark) == nil { d.set(shared, forKey: b.dark) }
        }
    }

    /// Seed both per-theme panel-background keys from the old single key once, so
    /// existing custom backgrounds keep applying after the light/dark split.
    static func migratePanelBackgroundPerThemeIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: panelBackgroundColorHexLightKey) == nil,
              defaults.object(forKey: panelBackgroundColorHexDarkKey) == nil else { return }
        let old = defaults.string(forKey: panelBackgroundColorHexKey) ?? ""
        guard !old.isEmpty else { return }
        defaults.set(old, forKey: panelBackgroundColorHexLightKey)
        defaults.set(old, forKey: panelBackgroundColorHexDarkKey)
    }

    static let defaultIconScale: Double = 1.0
    static let defaultUpIconScale: Double = 1.0
    /// Default ".." chevron weight = index 2 (`.light`) in `upIconWeights`.
    static let defaultUpIconWeight: Double = 2

    /// Selectable line weights for the ".." chevron, thin → thick.
    static let upIconWeights: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold]

    static func upIconWeight(forIndex index: Int) -> NSFont.Weight {
        upIconWeights[max(0, min(upIconWeights.count - 1, index))]
    }

    /// The user-chosen ".." chevron weight (defaults to `.light`).
    static var upIconSymbolWeight: NSFont.Weight {
        let raw = (UserDefaults.standard.object(forKey: upIconWeightKey) as? Double) ?? defaultUpIconWeight
        return upIconWeight(forIndex: Int(raw.rounded()))
    }

    /// Default ".." symbol — the double chevron.
    static let defaultUpIconSymbol = "chevron.up.2"

    /// Selectable SF Symbols for the ".." (go up) entry. First is the default.
    static let upIconSymbolOptions: [(symbol: String, nameKey: String)] = [
        ("chevron.up.2", "upicon.chevrons"),
        ("chevron.up", "upicon.chevron"),
        ("arrow.up", "upicon.arrow"),
        ("arrow.up.circle", "upicon.arrowCircle"),
        ("square.inset.filled", "upicon.squareInset"),
        ("arrow.up.to.line", "upicon.toLine"),
    ]

    /// The user-chosen ".." symbol name (validated against the options).
    static var upIconSymbol: String {
        let s = UserDefaults.standard.string(forKey: upIconSymbolKey) ?? defaultUpIconSymbol
        return upIconSymbolOptions.contains(where: { $0.symbol == s }) ? s : defaultUpIconSymbol
    }

    // MARK: - Accent

    /// The app accent (interactive elements: buttons, active tab, focus, cursor).
    /// Default is purple (preserves the previous tab accent look).
    static var accentColor: Color {
        swiftUIColor(from: UserDefaults.standard.string(forKey: accentColorHexKey) ?? "", fallback: .purple)
    }

    static var accentNSColor: NSColor {
        nsColor(from: UserDefaults.standard.string(forKey: accentColorHexKey) ?? "", fallback: .systemPurple)
    }

    /// The colour a file name is drawn in, given whether its row is the cursor and/or marked.
    ///
    /// The CURSOR wins for the text colour, because our cursor is a solid filled bar (not an
    /// outline): the name has to stay readable against that bar, and the cursor colour is the
    /// one picked to contrast with it. A marked file that also sits under the cursor still
    /// shows it IS marked — via the accent wash the row background paints over the cursor bar
    /// (see the row views' drawBackground) — so the mark isn't lost, only the unreadable
    /// accent-on-cursor-bar text is avoided.
    /// Цвет выделенных файлов: свой, если задан в «Дизайне», иначе акцент. Выделение
    /// акцентом на светлой строке читалось как случайная окраска — человек не понимал,
    /// что выделено; теперь цвет его собственный, отдельно для каждой темы.
    static var selectedNameNSColor: NSColor {
        let hex = UserDefaults.standard.string(forKey: selectedNameColorHexKey) ?? ""
        return hex.isEmpty ? accentNSColor : nsColor(from: hex, fallback: accentNSColor)
    }

    static func fileNameColor(isCursor: Bool, isSelected: Bool,
                              cursor: NSColor, selected: NSColor, normal: NSColor) -> NSColor {
        if isCursor { return cursor }
        if isSelected { return selected }
        return normal
    }

    /// The ".." (go up) icon — a thin double chevron, as a TEMPLATE image.
    ///
    /// `size` is the folder-icon footprint: the chevron is drawn CENTRED inside a
    /// `size`×`size` box so the ".." entry always lines up with the folder icons,
    /// whatever its own size. `scale` (the user's "up icon" slider) grows/shrinks the
    /// glyph *within* that box; the fill is capped so it never clips the box edges.
    ///
    /// The result is a template (shape only) — the COLOUR comes from the image view's
    /// `contentTintColor`, set to EXACTLY the ".." text colour (folder-name colour
    /// normally, accent when selected, cursor contrast on the cursor row).
    static func upArrowIcon(size: CGFloat, scale: CGFloat = 1) -> NSImage {
        let clamped = max(0.3, min(2.0, scale))
        let fill = min(0.92, 0.74 * clamped)   // ~0.74 of the box at 1.0×, capped so it never clips
        let config = NSImage.SymbolConfiguration(pointSize: max(6, size * fill), weight: upIconSymbolWeight)
        guard let symbol = (NSImage(systemSymbolName: upIconSymbol, accessibilityDescription: "Up")
            ?? NSImage(systemSymbolName: "chevron.up.2", accessibilityDescription: "Up"))?
            .withSymbolConfiguration(config) else { return NSImage() }
        // Resolution-independent: the handler draws at the display's scale (crisp on
        // Retina), so the thin strokes don't blur into a washed-out tint. lockFocus
        // would bake a 1× bitmap that looks faded when scaled up to 2×.
        let out = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let r = NSRect(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2,
                           width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: r)
            return true
        }
        out.isTemplate = true
        return out
    }

    /// WCAG relative-luminance contrast ratio between two colours: 1 for a colour on itself,
    /// 21 for black on white. The app's one answer to "can this be read on that" — the volume
    /// bar asks it before keeping the user's cursor name colour on a chip, and
    /// `contrastingTextColor(on:)` asks it twice to choose its ink.
    ///
    /// A colour with no sRGB reading (a pattern fill) counts as black, which lands ink on it as
    /// if it were the darkest possible background — the safe side to be wrong on.
    static func contrast(between a: NSColor, and b: NSColor) -> CGFloat {
        func luminance(_ colour: NSColor) -> CGFloat {
            guard let c = colour.usingColorSpace(.sRGB) else { return 0 }
            // sRGB is gamma-encoded: the channels have to be linearised before they can be
            // weighted, which is exactly the step a raw 0.299R + 0.587G + 0.114B average skips.
            func channel(_ v: CGFloat) -> CGFloat {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
                 + 0.0722 * channel(c.blueComponent)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Black or white on `background` — whichever MEASURES more readable, not whichever a
    /// brightness threshold guesses.
    ///
    /// This used to compare a raw 0.299R + 0.587G + 0.114B average against 0.6, and the
    /// mid-tones paid for it: hot pink came out "dark" and got white text at ratio 3.5 where
    /// black reads at 6.1; pure green got white at 1.4 where black reads at 15.3. Asking the
    /// contrast ratio for both inks and keeping the winner cannot be wrong by construction —
    /// there are only two candidates.
    ///
    /// An unmeasurable colour (a pattern fill) reads as black and so still gets white ink,
    /// exactly as the old explicit guard did.
    static func contrastingTextColor(on background: NSColor) -> NSColor {
        contrast(between: .black, and: background) >= contrast(between: .white, and: background)
            ? .black : .white
    }

    static func contrastingTextColor(on background: Color) -> Color {
        Color(nsColor: contrastingTextColor(on: NSColor(background)))
    }

    /// One-time seed: if no accent is set yet but the user previously chose a tab
    /// accent preset, carry that colour over so their choice is respected.
    static func migrateAccentFromTabAccentIfNeeded() {
        let defaults = UserDefaults.standard
        guard (defaults.string(forKey: accentColorHexKey) ?? "").isEmpty else { return }
        guard let raw = defaults.string(forKey: "tabAccentColor"),
              let preset = TabAccentColor(rawValue: raw),
              let hex = hexString(from: preset.color) else { return }
        defaults.set(hex, forKey: accentColorHexKey)
    }

    /// One-time seed: if the user already had a custom cursor colour, keep using it
    /// (enable the "custom cursor" flag) instead of switching them to the accent.
    @MainActor
    static func migrateCursorCustomFlagIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: cursorUsesCustomColorKey) == nil else { return }
        let hasCustom = !(defaults.string(forKey: cursorBackgroundColorHexKey) ?? "").isEmpty
            || !(defaults.string(forKey: cursorNameColorHexKey) ?? "").isEmpty
        if hasCustom { setCursorUsesCustomColor(true) }   // all three keys, not just the mirror
    }

    /// Colour of the cursor BAR: the Cursor section's colour while its custom mode is on, otherwise
    /// the app accent. The Design page's "colour under cursor" is about the name, not the bar.
    static func resolvedCursorBackground() -> NSColor {
        let d = UserDefaults.standard
        if d.bool(forKey: cursorUsesCustomColorKey),
           let custom = optionalNSColor(from: d.string(forKey: cursorBackgroundColorHexKey) ?? "") {
            return custom
        }
        return accentNSColor
    }

    /// Colour of the file or folder NAME under the cursor.
    ///
    /// The Cursor section wins while its custom mode is on (it has its own "name under cursor"),
    /// then the Design page's "colour under cursor", and failing both we pick black or white for
    /// readability against whatever the bar ended up being.
    static func resolvedCursorNameColor() -> NSColor {
        let d = UserDefaults.standard
        if d.bool(forKey: cursorUsesCustomColorKey) {
            return nsColor(from: d.string(forKey: cursorNameColorHexKey) ?? "", fallback: .systemOrange)
        }
        if let design = optionalNSColor(from: d.string(forKey: cursorUnderNameColorHexKey) ?? "") {
            return design
        }
        return contrastingTextColor(on: resolvedCursorBackground())
    }

    static func nsColor(from hex: String, fallback: NSColor) -> NSColor {
        optionalNSColor(from: hex) ?? fallback
    }

    static func optionalNSColor(from hex: String) -> NSColor? {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return parseHexColor(normalized)
    }

    static func swiftUIColor(from hex: String, fallback: Color) -> Color {
        guard let nsColor = optionalNSColor(from: hex) else { return fallback }
        return Color(nsColor: nsColor)
    }

    static func hexString(from color: Color) -> String? {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return hexString(from: nsColor)
    }

    static func hexString(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#FFFFFFFF" }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        let alpha = Int((rgb.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    // MARK: - HSB (for the custom color picker)

    /// Hue/saturation/brightness (each 0…1) parsed from a hex string, in sRGB.
    static func hsbComponents(fromHex hex: String) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)? {
        guard let color = optionalNSColor(from: hex)?.usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    /// Same components for an arbitrary SwiftUI Color (used to seed the picker from a fallback).
    static func hsbComponents(from color: Color) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let ns = (NSColor(color).usingColorSpace(.sRGB)) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    /// Hex (#RRGGBBAA) built from HSB via the standard HSV→sRGB formula, so that
    /// `hsbComponents(fromHex:)` round-trips exactly (no colour-space drift).
    static func hexString(hue h: CGFloat, saturation s: CGFloat, brightness v: CGFloat) -> String {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        let r, g, b: CGFloat
        switch Int(i) % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return hexString(from: NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
    }

    static func scaledImage(_ image: NSImage, size: NSSize) -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        output.unlockFocus()
        return output
    }

    static func tintedImage(_ image: NSImage, tintColor: NSColor, size: NSSize) -> NSImage {
        let base = scaledImage(image, size: size)
        let output = NSImage(size: size)
        output.lockFocus()
        base.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        tintColor.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        output.unlockFocus()
        return output
    }

    private static func parseHexColor(_ hex: String) -> NSColor? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }

        guard cleaned.count == 6 || cleaned.count == 8 else {
            return nil
        }
        guard let value = UInt64(cleaned, radix: 16) else {
            return nil
        }

        let hasAlpha = cleaned.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255.0
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255.0
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255.0
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255.0 : 1.0
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - Interface background (window chrome) SwiftUI modifier

/// Fills a chrome surface (bars, tabs, divider, footer) with the per-theme interface
/// tint, falling back to the system window background. Reacts to both the colour
/// setting (@AppStorage) and light/dark switches (@Environment colorScheme).
private struct InterfaceBackgroundModifier: ViewModifier {
    @AppStorage(PanelAppearanceSettings.interfaceColorHexLightKey) private var lightHex = ""
    @AppStorage(PanelAppearanceSettings.interfaceColorHexDarkKey) private var darkHex = ""
    @Environment(\.colorScheme) private var colorScheme
    var opacity: Double

    func body(content: Content) -> some View {
        content
            .background(color.opacity(opacity))
            // Text and icons on this surface read on ITS colour, not the theme's: a dark
            // interface colour under the light theme turns the subtree dark, so every
            // `.secondary` label and system-coloured icon on it goes light.
            .environment(\.colorScheme,
                         PanelAppearanceSettings.chromeColorScheme(hex: hex, fallback: colorScheme))
    }

    private var hex: String { colorScheme == .dark ? darkHex : lightHex }

    private var color: Color {
        PanelAppearanceSettings.swiftUIColor(
            from: hex, fallback: Color(nsColor: .windowBackgroundColor))
    }
}

extension PanelAppearanceSettings {
    /// The colour scheme whose text reads on a chrome surface painted `hex`: dark chrome gets
    /// light text whatever the theme (ContrastAppearance's rule). No custom colour, or one
    /// that does not parse — the theme's own scheme.
    static func chromeColorScheme(hex: String, fallback: ColorScheme) -> ColorScheme {
        guard let color = optionalNSColor(from: hex) else { return fallback }
        return ContrastAppearance.isDark(color) ? .dark : .light
    }

    /// The same rule for a surface whose colour is already known.
    static func colorScheme(on background: NSColor) -> ColorScheme {
        ContrastAppearance.isDark(background) ? .dark : .light
    }
}

extension View {
    /// Backs the view with the per-theme interface tint (see `InterfaceBackgroundModifier`).
    func interfaceBackground(opacity: Double = 1.0) -> some View {
        modifier(InterfaceBackgroundModifier(opacity: opacity))
    }
}
