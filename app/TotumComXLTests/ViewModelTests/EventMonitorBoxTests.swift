import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Перехватчик событий у вида SwiftUI не должен держать вид после закрытия. В `@State`
/// напрямую он держал: замыкание перехватчика — копию вида, вид — перехватчик, и запись
/// `nil` в `onDisappear` это кольцо не рвала. Закрытый просмотрщик оставался в памяти со
/// всем показанным, а в тестах его модель панели, потеряв папку, уходила читать общую
/// временную папку на десятки тысяч записей.
@MainActor
final class EventMonitorBoxTests: XCTestCase {

    private final class Model: ObservableObject {
        @Published var value = 0
    }

    private struct Monitored: View {
        @ObservedObject var model: Model
        @State private var monitor = EventMonitorBox()

        var body: some View {
            Text("\(model.value)")
                .onAppear {
                    monitor.install(matching: .keyDown) { event in
                        _ = model.value
                        return event
                    }
                }
                .onDisappear { monitor.remove() }
        }
    }

    /// Вид в окне: показать, дать появиться, убрать из окна и закрыть окно.
    private func showAndClose(_ root: some View) {
        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            let until = Date().addingTimeInterval(0.5)
            while Date() < until {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            window.contentView = nil
            window.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func test_ставитсяОдинРазИСнимается() {
        let box = EventMonitorBox()
        XCTAssertFalse(box.isInstalled)
        box.install(matching: .keyDown) { $0 }
        box.install(matching: .keyDown) { _ in nil }
        XCTAssertTrue(box.isInstalled)
        box.remove()
        XCTAssertFalse(box.isInstalled)
        box.remove()
        XCTAssertFalse(box.isInstalled, "повторное снятие безопасно")
    }

    func test_закрытыйВидОтпускаетТоЧтоДержалПерехватчик() {
        weak var released: Model?
        autoreleasepool {
            let model = Model()
            released = model
            showAndClose(Monitored(model: model))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(released, "модель отпущена вместе с видом")
    }

    func test_закрытыйПросмотрщикОтпускаетМодельПанели() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fcxl-viewer-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "текст\nещё строка".write(to: root.appendingPathComponent("заметка.txt"), atomically: true, encoding: .utf8)

        weak var released: PanelViewModel?
        try autoreleasepool {
            let vm = PanelViewModel(service: CoreBridgeService(), initialPath: root.path,
                                    pathDefaultsKey: "viewer.\(UUID().uuidString)",
                                    viewModeDefaultsKey: "viewerm.\(UUID().uuidString)", showHiddenFiles: true)
            let listed = Date().addingTimeInterval(5)
            while vm.items.isEmpty, Date() < listed {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            vm.setCursor(index: try XCTUnwrap(vm.items.firstIndex { $0.name == "заметка.txt" }))
            released = vm
            showAndClose(UnifiedFileViewer(viewModel: vm, onClose: nil, operations: nil))
            vm.stopWatching()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(released, "закрытый просмотрщик не держит модель панели")
    }
}
