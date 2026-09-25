import AppKit

// MARK: - NSApplication + FKeyMode
//
// Swizzle sendEvent удалён: медиа-перехват теперь реализован через
// NSEvent.addLocalMonitorForEvents в FKeyModeManager.
// Local monitor автоматически не срабатывает при потере фокуса —
// это обеспечивает корректное поведение в app-only режиме без побочных эффектов.
extension NSApplication {

    /// Оставлено для обратной совместимости вызова в applicationDidFinishLaunching.
    /// Тело намеренно пустое — монитор устанавливается через FKeyModeManager.shared.syncOnLaunch().
    static func installFKeyModeSwizzle() {
        // no-op: replaced by NSEvent local monitor in FKeyModeManager
    }
}
