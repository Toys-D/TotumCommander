import AppKit

struct ContextMenuBuilder {
    static func fileMenu(for item: FileItem, provider: (FileItem) -> NSMenu) -> NSMenu {
        provider(item)
    }

    static func backgroundMenu(provider: () -> NSMenu) -> NSMenu {
        provider()
    }

    static func moveItems(from source: NSMenu, to target: NSMenu) {
        let items = source.items
        for item in items {
            source.removeItem(item)
            target.addItem(item)
        }
    }
}
