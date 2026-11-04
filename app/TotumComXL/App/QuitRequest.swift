import AppKit

/// Просьба выйти, пришедшая не из меню: от macOS при выключении и перезагрузке, от Dock, от
/// другой программы (Apple Event «quit»).
///
/// Настройки открыты модально, и пока они на экране, AppKit такую просьбу отклонял: действие
/// terminate: в модальном окне не проходит проверку, и выход отменяется — а вместе с ним
/// выключение и перезагрузка Mac. Закрыть настройки не страшно: всё в них сохраняется сразу.
/// Поэтому при открытых настройках они закрываются, и программа выходит. Модальный вопрос
/// («Заменить файл?») — другое дело: там важен ответ человека, и выход, как и прежде,
/// отклоняется — так же, как его отклонял AppKit.
@MainActor
enum QuitRequest {
    enum Decision: Equatable { case quit, closeSettingsAndQuit, refuse }

    static func decide(modal: NSWindow?, settings: NSWindow?) -> Decision {
        guard let modal else { return .quit }
        return modal === settings ? .closeSettingsAndQuit : .refuse
    }

    /// Окно настроек — его держит AppDelegate.
    static var settingsWindow: () -> NSWindow? = { nil }
    static var terminate: () -> Void = { NSApp.terminate(nil) }

    /// Встать вместо обработчика AppKit. Звать после запуска: AppKit ставит свой при запуске.
    static func install() {
        NSAppleEventManager.shared().setEventHandler(
            handler, andSelector: #selector(Handler.handle(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    private static let handler = Handler()

    private final class Handler: NSObject {
        @objc func handle(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
            MainActor.assumeIsolated { QuitRequest.respond(reply: reply) }
        }
    }

    static func respond(reply: NSAppleEventDescriptor) {
        switch decide(modal: NSApp.modalWindow, settings: settingsWindow()) {
        case .quit:
            terminate()
        case .closeSettingsAndQuit:
            NSApp.stopModal()
            settingsWindow()?.orderOut(nil)
            terminate()
        case .refuse:
            // «Отменено пользователем» — тот же ответ, что давал AppKit: Dock и macOS
            // понимают его как «программа не вышла».
            reply.setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)),
                           forKeyword: AEKeyword(keyErrorNumber))
        }
    }
}
