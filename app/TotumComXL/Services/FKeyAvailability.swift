import Carbon
import AppKit

/// Which of the panel's F-keys another program holds as a GLOBAL hotkey.
///
/// A key registered that way — Parallels Desktop does it to F6 — is handed to its owner by the
/// window server and never reaches anybody else. From inside this app that looks like a key
/// that simply does nothing, and a user can lose an evening to it. The probe is Carbon's own
/// answer: registering the same key exclusively FAILS with eventHotKeyExistsErr when somebody
/// already holds it, and succeeds (and is immediately released) when nobody does.
enum FKeyAvailability {

    /// The F-keys the panels answer to, by virtual key code.
    static let panelFKeys: [(code: UInt32, name: String)] = [
        (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"),
        (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9"),
    ]

    /// Names of the keys some other program owns right now.
    static func takenKeys() -> [String] {
        panelFKeys.compactMap { key in
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                key.code, 0, EventHotKeyID(signature: OSType(0x46435854), id: key.code),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr {
                if let ref { UnregisterEventHotKey(ref) }
                return nil
            }
            return key.name
        }
    }

    /// Проверить, когда программа впереди, и чуть погодя. Заменитель Launchpad, который знает
    /// соглашение UsesFunctionKeys, отпускает F4, едва впереди оказывается эта программа, —
    /// проверка в фоне застала бы его ещё с клавишей и предупредила бы зря.
    @MainActor
    static func warnOnceWhenActive(after delay: TimeInterval = 1.5) {
        let check = {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard NSApp.isActive else { return }
                warnIfPanelKeysAreTaken()
            }
        }
        if NSApp.isActive { check(); return }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            check()
        }
    }

    /// Warn once per launch, and only when there is something to say. The dialog names the
    /// keys and where the cure is. Если перехват F-клавиш уже работает (FKeyCapture), клавиши и
    /// так доходят сюда — говорить не о чем. Если он включён, но нет разрешения, — предложить
    /// его: это и есть лекарство. Выключен человеком — только сказать, кто виноват.
    @MainActor
    static func warnIfPanelKeysAreTaken() {
        guard !FKeyCapture.shared.isRunning else { return }
        let taken = takenKeys()
        guard !taken.isEmpty else { return }
        let list = taken.joined(separator: ", ")
        if FKeyCapture.isEnabledInSettings {
            let grant = DialogService.shared.showConfirmationCustom(
                title: L("fkeys.takenTitle"),
                message: String(format: L("fkeys.takenOffer"), list),
                confirmTitle: L("fkeys.grant"), cancelTitle: L("fkeys.later"))
            if grant { FKeyCapture.requestPermission() }
            return
        }
        DialogService.shared.showInfo(
            title: L("fkeys.takenTitle"),
            message: String(format: L("fkeys.takenMessage"), list))
    }
}
