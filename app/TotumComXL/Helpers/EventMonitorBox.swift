import AppKit

/// Перехватчик событий (`NSEvent.addLocalMonitorForEvents`) для вида SwiftUI.
///
/// Замыкание перехватчика держит копию вида, а вид держит перехватчик. Если хранить его в
/// `@State` и снимать в `onDisappear` записью `nil`, кольцо не рвётся: SwiftUI, убирая вид,
/// такую запись не сохраняет, и вид со всем показанным — картинками, текстом, PDF — оставался
/// в памяти после закрытия. Коробка — обычный объект: снятие обнуляет её поле напрямую, и
/// кольцо рвётся всегда. Держать в `@State` саму коробку: `@State private var monitor = EventMonitorBox()`.
final class EventMonitorBox {
    private var token: Any?

    var isInstalled: Bool { token != nil }

    /// Ставит перехватчик, если его ещё нет.
    func install(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { remove() }
}
