import SwiftUI
import AppKit

/// Two-column old-name -> new-name preview grid for the Multi-Rename tool. The new-name cell is
/// editable (double-click / Enter) and pins a manual override on that row. Problem rows (error /
/// duplicate / on-disk collision) are shown in red; unchanged rows are dimmed. Built on
/// NSTableView because the app has no reusable multi-column table (the file panel's table is
/// bound tightly to PanelViewModel).
struct RenamePreviewTable: NSViewRepresentable {
    @ObservedObject var vm: MultiRenameViewModel

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 20
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true

        let oldCol = NSTableColumn(identifier: .init("old"))
        oldCol.title = L("mrt.column.old")
        oldCol.minWidth = 120
        let newCol = NSTableColumn(identifier: .init("new"))
        newCol.title = L("mrt.column.new")
        newCol.minWidth = 120
        table.addTableColumn(oldCol)
        table.addTableColumn(newCol)

        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.vm = vm
        context.coordinator.table?.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }

    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
        var vm: MultiRenameViewModel
        weak var table: NSTableView?
        init(vm: MultiRenameViewModel) { self.vm = vm }

        func numberOfRows(in tableView: NSTableView) -> Int { vm.plans.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < vm.plans.count, let col = tableColumn else { return nil }
            let plan = vm.plans[row]
            let isNew = col.identifier.rawValue == "new"
            let id = NSUserInterfaceItemIdentifier(isNew ? "newCell" : "oldCell")
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
                field = reused
            } else {
                field = NSTextField()
                field.identifier = id
                field.isBordered = false
                field.drawsBackground = false
                field.font = .systemFont(ofSize: 12)
                field.lineBreakMode = .byTruncatingMiddle
                if isNew {
                    field.isEditable = true
                    field.delegate = self
                } else {
                    field.isEditable = false
                }
            }
            field.tag = row
            if isNew {
                field.stringValue = plan.newName
                field.textColor = Self.color(for: plan.status)
                field.toolTip = Self.tooltip(for: plan.status)
            } else {
                field.stringValue = plan.originalName
                field.textColor = .secondaryLabelColor
                field.toolTip = nil
            }
            return field
        }

        private static func color(for status: RenameStatus) -> NSColor {
            switch status {
            case .ok: return .labelColor
            case .unchanged: return .tertiaryLabelColor
            case .error, .duplicate, .collidesOnDisk: return .systemRed
            }
        }

        private static func tooltip(for status: RenameStatus) -> String? {
            switch status {
            case .ok, .unchanged: return nil
            case .duplicate: return L("mrt.issue.duplicate")
            case .collidesOnDisk: return L("mrt.issue.collides")
            case .error(let reason): return L("mrt.issue.\(reason)")
            }
        }

        /// Commit a hand-edited new name back to the view model as an override.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let row = field.tag
            guard row >= 0, row < vm.plans.count else { return }
            vm.setManualName(field.stringValue, for: vm.plans[row].sourcePath)
        }
    }
}
