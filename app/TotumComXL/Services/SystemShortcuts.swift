import Foundation

/// Ярлыки macOS, сидящие на клавишах звука, — и как их отпустить.
///
/// «Показать рабочий стол» на F11 система забирает раньше любой программы: нажатие до неё
/// не доходит, и вместо «тише» окна разъезжаются по краям экрана. В новой учётной записи
/// ярлык включён, поэтому человек видит это сразу, а где выключить — не догадывается.
///
/// Список живёт в `com.apple.symbolichotkeys` — там же, откуда его читают и системные
/// настройки; правка применяется без перезахода.
enum SystemShortcuts {
    static let domain = "com.apple.symbolichotkeys"
    static let listKey = "AppleSymbolicHotKeys"

    /// Ярлык macOS на клавише звука: номер записи, клавиша и её описание для списка.
    struct Hotkey {
        let id: String
        let key: String
        /// (символ, код клавиши, модификаторы) — как их пишет сама macOS.
        let parameters: [Int]
    }

    /// Единственный, который macOS вешает на клавишу звука: «Показать рабочий стол» на F11.
    /// Измерено на macOS 15 — Mission Control и «Окна программы» сидят на ⌃↑ и ⌃↓ и клавишам
    /// звука не мешают.
    static let onVolumeKeys = [Hotkey(id: "36", key: "F11", parameters: [65535, 103, 8_388_608])]

    /// Какие клавиши звука сейчас держит macOS.
    ///
    /// Записи нет — значит ярлык работает: список заводится только тогда, когда его правили,
    /// а до тех пор в силе настройка по умолчанию. Свежая учётная запись — как раз этот случай.
    static func heldKeys(in list: [String: Any]) -> [String] {
        onVolumeKeys.compactMap { hotkey in
            guard let entry = list[hotkey.id] as? [String: Any] else { return hotkey.key }
            guard let enabled = entry["enabled"] as? Bool
                    ?? (entry["enabled"] as? NSNumber)?.boolValue else { return hotkey.key }
            return enabled ? hotkey.key : nil
        }
    }

    static func heldKeys() -> [String] {
        heldKeys(in: UserDefaults(suiteName: domain)?.dictionary(forKey: listKey) ?? [:])
    }

    /// Как выглядит выключенный ярлык. Параметры сохраняем: человек сможет включить его
    /// обратно в системных настройках, и клавиша там останется прежней.
    static func disabledEntry(for hotkey: Hotkey) -> [String: Any] {
        ["enabled": false,
         "value": ["parameters": hotkey.parameters, "type": "standard"]]
    }

    /// Отпустить клавиши звука. Меняется только состояние наших ярлыков — остальной список
    /// переписывается как есть.
    @discardableResult
    static func freeVolumeKeys() -> Bool {
        guard let defaults = UserDefaults(suiteName: domain) else { return false }
        var list = defaults.dictionary(forKey: listKey) ?? [:]
        for hotkey in onVolumeKeys {
            list[hotkey.id] = disabledEntry(for: hotkey)
        }
        defaults.set(list, forKey: listKey)
        applySettings()
        return heldKeys().isEmpty
    }

    /// Система перечитывает список ярлыков только по этой команде — без неё правка вступила
    /// бы в силу лишь после перезахода в учётную запись.
    private static func applySettings() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-u"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
