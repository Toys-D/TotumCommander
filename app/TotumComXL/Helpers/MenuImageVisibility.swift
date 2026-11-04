import AppKit

/// Menu icons stay on show.
///
/// From macOS 27 AppKit decides by itself whether a menu item shows its image, and mostly it
/// hides it — the Tools menu lost every icon it had on Sequoia and Tahoe. This program's menus
/// were made to be read by their icons, so every item that carries an image asks to keep it.
///
/// One rule for the whole program instead of a line at each of the many places that give an
/// item its image: menus announce every item added and every image set, and the rule answers
/// those announcements — a menu written tomorrow is covered the same way.
enum MenuImageVisibility {

    private nonisolated(unsafe) static var observers: [NSObjectProtocol] = []

    /// Start keeping images visible. Called once, before the menu bar is built.
    static func keepVisible() {
        guard #available(macOS 27, *), observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { note in
                guard let menu = note.object as? NSMenu,
                      let index = note.userInfo?["NSMenuItemIndex"] as? Int else { return }
                MainActor.assumeIsolated {
                    guard menu.items.indices.contains(index) else { return }
                    show(menu.items[index])
                }
            })
        }
    }

    /// The same for a menu built before the rule was in place, submenus included.
    static func keepVisible(in menu: NSMenu) {
        guard #available(macOS 27, *) else { return }
        for item in menu.items {
            show(item)
            if let submenu = item.submenu { keepVisible(in: submenu) }
        }
    }

    @available(macOS 27, *)
    private static func show(_ item: NSMenuItem) {
        guard item.image != nil, item.preferredImageVisibility != .visible else { return }
        item.preferredImageVisibility = .visible
    }
}
