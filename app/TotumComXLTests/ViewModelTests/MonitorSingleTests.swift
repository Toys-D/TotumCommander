import AppKit
import XCTest
@testable import TotumComXLApp

/// Монитор системы — один на окно. Кнопка при открытом мониторе закрывает его, а не открывает
/// второй в другой панели; Esc убирает его, даже когда курсор в другой панели.
@MainActor
final class MonitorSingleTests: XCTestCase {

    private func splitInWindow() -> (MainSplitViewController, NSWindow) {
        func vm(_ side: String) -> PanelViewModel {
            PanelViewModel(service: CoreBridgeService(), initialPath: NSTemporaryDirectory(),
                           pathDefaultsKey: "test.monitor.\(side).\(UUID().uuidString)",
                           viewModeDefaultsKey: "test.monitor.\(side).mode.\(UUID().uuidString)",
                           showHiddenFiles: false)
        }
        let split = MainSplitViewController(
            leftPanel: vm("left"), rightPanel: vm("right"),
            leftTabs: PanelTabsViewModel(panelKey: "test.monitor.ltabs.\(UUID().uuidString)", initialPath: NSTemporaryDirectory()),
            rightTabs: PanelTabsViewModel(panelKey: "test.monitor.rtabs.\(UUID().uuidString)", initialPath: NSTemporaryDirectory()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        split.loadViewIfNeeded()
        return (split, window)
    }

    private func closeAll(_ split: MainSplitViewController) {
        for vc in [split.leftPanelVC, split.rightPanelVC] where vc?.isMonitorMode == true { vc?.toggleMonitor() }
    }

    func test_кнопкаПриОткрытомМонитореЗакрываетЕгоАНеОткрываетВторой() {
        let (split, window) = splitInWindow()
        defer { closeAll(split); window.close() }

        split.setActivePanel(.left)
        split.toggleMonitorInActivePanel()
        XCTAssertTrue(split.leftPanelVC.isMonitorMode, "открылся в активной панели")

        split.setActivePanel(.right)
        split.toggleMonitorInActivePanel()
        XCTAssertFalse(split.leftPanelVC.isMonitorMode, "открытый закрылся")
        XCTAssertFalse(split.rightPanelVC.isMonitorMode, "второй не открылся")
        XCTAssertNil(split.monitorPanelVC)

        split.toggleMonitorInActivePanel()
        XCTAssertTrue(split.rightPanelVC.isMonitorMode, "когда ни одного нет — открывается в активной")
        XCTAssertFalse(split.leftPanelVC.isMonitorMode)
    }

    func test_escЗакрываетМониторИзДругойПанели() throws {
        let (split, window) = splitInWindow()
        defer { closeAll(split); window.close() }

        split.setActivePanel(.left)
        split.toggleMonitorInActivePanel()
        split.setActivePanel(.right)
        XCTAssertTrue(split.leftPanelVC.isMonitorMode)

        let esc = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApplication.shared.sendEvent(esc)
        XCTAssertFalse(split.leftPanelVC.isMonitorMode, "Esc в правой панели убрал монитор слева")
    }

    /// Пока человек печатает вне монитора (переименование, быстрый фильтр, строка пути), Esc —
    /// этому полю; внутри монитора (его поиск) и без набора — монитору.
    func test_escНеОтбираетсяУПоляВнеМонитора() {
        let monitor = NSView()
        let inside = FieldStub()
        monitor.addSubview(inside)
        let outside = FieldStub()

        let editorInside = NSTextView()
        editorInside.isFieldEditor = true
        editorInside.delegate = inside
        let editorOutside = NSTextView()
        editorOutside.isFieldEditor = true
        editorOutside.delegate = outside

        XCTAssertTrue(MainSplitViewController.escClosesMonitor(firstResponder: nil, monitorView: monitor))
        XCTAssertTrue(MainSplitViewController.escClosesMonitor(firstResponder: NSView(), monitorView: monitor),
                      "фокус в списке файлов")
        XCTAssertTrue(MainSplitViewController.escClosesMonitor(firstResponder: editorInside, monitorView: monitor),
                      "поиск в мониторе")
        XCTAssertFalse(MainSplitViewController.escClosesMonitor(firstResponder: editorOutside, monitorView: monitor),
                       "переименование в другой панели")
    }
}

/// Поле, которое служит делегатом редактора строки, как NSTextField в живом окне.
private final class FieldStub: NSTextField, NSTextViewDelegate {}
