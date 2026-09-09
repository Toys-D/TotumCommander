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

    /// Warn once per launch, and only when there is something to say. The dialog names the
    /// keys, the likely kind of owner, and where the cure is — the app cannot take a key back,
    /// so telling the user is the whole fix.
    @MainActor
    static func warnIfPanelKeysAreTaken() {
        let taken = takenKeys()
        guard !taken.isEmpty else { return }
        let list = taken.joined(separator: ", ")
        DialogService.shared.showInfo(
            title: L("fkeys.takenTitle"),
            message: String(format: L("fkeys.takenMessage"), list))
    }
}
