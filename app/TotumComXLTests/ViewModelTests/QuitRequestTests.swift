import AppKit
import XCTest
@testable import TotumComXLApp

/// Просьба выйти от macOS или Dock (Apple Event «quit») при открытых настройках: они
/// закрываются, программа выходит. Модальный вопрос выход по-прежнему не пускает.
///
/// Событие шлётся настоящее, самой программе, прямо посреди модального окна — так, как его
/// шлёт macOS при выключении. Сам выход подменён: проверка не должна завершать себя.
@MainActor
final class QuitRequestTests: XCTestCase {

    private var quits = 0

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        quits = 0
        QuitRequest.terminate = { [weak self] in self?.quits += 1 }
        QuitRequest.install()
    }

    override func tearDown() {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        QuitRequest.terminate = { NSApp.terminate(nil) }
        QuitRequest.settingsWindow = { nil }
        super.tearDown()
    }

    func test_решение() {
        let settings = NSWindow(), other = NSWindow()
        XCTAssertEqual(QuitRequest.decide(modal: nil, settings: settings), .quit)
        XCTAssertEqual(QuitRequest.decide(modal: settings, settings: settings), .closeSettingsAndQuit)
        XCTAssertEqual(QuitRequest.decide(modal: other, settings: settings), .refuse)
    }

    func test_настройкиОткрыты_просьбаВыйти_закрываетИхИВыходит() throws {
        let settings = window()
        QuitRequest.settingsWindow = { settings }
        let (ended, reply) = runModal(settings, sendingQuit: true)
        XCTAssertTrue(ended, "модальное окно настроек закрыто просьбой, а не сторожем")
        XCTAssertEqual(quits, 1, "программа выходит")
        XCTAssertFalse(settings.isVisible)
        XCTAssertNil(reply?.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), "просьба принята")
    }

    func test_модальныйВопрос_просьбаВыйти_отклоняется() throws {
        let settings = window(), question = window()
        QuitRequest.settingsWindow = { settings }
        let (ended, reply) = runModal(question, sendingQuit: true)
        XCTAssertFalse(ended, "вопрос остаётся на экране — закрыл его сторож проверки")
        XCTAssertEqual(quits, 0)
        XCTAssertEqual(reply?.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value,
                       Int32(userCanceledErr), "ответ — «отменено», как у AppKit")
    }

    func test_безМодальныхОкон_просьбаВыйти_выходит() throws {
        _ = try sendQuit()
        XCTAssertEqual(quits, 1)
    }

    // MARK: - Помощники

    private func window() -> NSWindow {
        let window = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 200, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.orderOut(nil) }
        return window
    }

    /// Настоящая просьба выйти — себе, тем же событием, что шлёт macOS.
    private func sendQuit() throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        return try event.sendEvent(options: [.neverInteract], timeout: 2)
    }

    /// Модальное окно, как у настроек; посреди него — просьба выйти. Сторож закрывает окно
    /// через две секунды, если просьба не закрыла. `ended` — закрыла просьба.
    private func runModal(_ window: NSWindow, sendingQuit: Bool) -> (ended: Bool, reply: NSAppleEventDescriptor?) {
        var reply: NSAppleEventDescriptor?
        var watchdogFired = false
        let send = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { reply = try? self?.sendQuit() }
        }
        let watchdog = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated { watchdogFired = true; NSApp.abortModal() }
        }
        RunLoop.main.add(send, forMode: .common)
        RunLoop.main.add(watchdog, forMode: .common)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        send.invalidate()
        watchdog.invalidate()
        return (!watchdogFired, reply)
    }
}
