import AppKit
import ApplicationServices

/// F-клавиши Totum Commander — ему, пока он на переднем плане, даже если другая программа
/// держит их глобальной клавишей: заменитель Launchpad на F4 (macOS 27 убрал свой Launchpad),
/// Parallels на F6.
///
/// Глобальную клавишу Carbon окно-сервер отдаёт её владельцу раньше программы на переднем
/// плане, и вежливо её не отобрать — FKeyAvailability умеет только сказать, что клавиша занята.
/// Перехватчик CGEventTap на уровне сеанса стоит РАНЬШЕ этой раздачи: проверено опытом —
/// нажатие, которое он забрал, до владельца глобальной клавиши уже не доходит. Он забирает
/// нажатие и кладёт его в очередь этой программы, откуда оно идёт обычным путём: меню,
/// панель, свои перехватчики.
///
/// Берутся только F-клавиши, которые сейчас назначены командам (пункты меню, KeyBindings), и
/// только без ⌘ и ⌃: с ними — сочетания самой системы (⌘F5 — VoiceOver, ⌃F2 — строка меню).
/// Нужно разрешение «Универсальный доступ»; без него всё как раньше.
@MainActor
final class FKeyCapture {
    static let shared = FKeyCapture()

    /// Настройка «Забирать F-клавиши у других программ». По умолчанию включена: без
    /// разрешения она ничего не делает, а с ним человек сам выбрал, чтобы клавиши были здесь.
    static let enabledKey = "fcxl.captureFKeys"

    /// Ключ Info.plist, которым программа говорит «мне нужны F-клавиши». Его читает наш
    /// заменитель Launchpad и отпускает F4, пока эта программа впереди; launch.sh его ставит.
    /// Соглашение открытое — его может поддержать любой, кто держит голые F-клавиши.
    static let infoPlistKey = "UsesFunctionKeys"

    /// Коды F1–F12 и номера клавиш — первым делом отсеять всё остальное.
    nonisolated static let functionKeyNumbers: [Int64: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6,
        98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
    ]

    private let isWanted: @MainActor (Int64, CGEventFlags) -> Bool
    private let isActive: @MainActor () -> Bool
    private let deliver: @MainActor (CGEvent) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    init(isWanted: @escaping @MainActor (Int64, CGEventFlags) -> Bool = { FKeyCapture.isBoundFKey(code: $0, flags: $1) },
         isActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         deliver: @escaping @MainActor (CGEvent) -> Void = { FKeyCapture.deliverToApp($0) }) {
        self.isWanted = isWanted
        self.isActive = isActive
        self.deliver = deliver
    }

    static var isEnabledInSettings: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    var isRunning: Bool { tap != nil }

    /// Следить за тем, впереди ли программа: перехват работает только тогда.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    /// Привести перехват к настройке и разрешению. Разрешение человек выдаёт в Системных
    /// настройках, пока программа в фоне, — поэтому проверка и при каждом возвращении.
    func refresh() {
        let wanted = Self.isEnabledInSettings && Self.isTrusted
        if wanted, tap == nil { install() }
        if !wanted, tap != nil { uninstall() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: isActive()) }
    }

    /// Попросить разрешение: система покажет своё окно со ссылкой в Системные настройки.
    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Поставить перехватчик (без проверки настройки и разрешения — это делает refresh).
    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: fkeyCaptureCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        tap = created
        source = runLoopSource
        CGEvent.tapEnable(tap: created, enable: isActive())
        return true
    }

    func uninstall() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Система выключает перехватчик, который долго думал; снова включить, раз мы впереди.
            if let tap, isActive() { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if isActive(), isWanted(code, event.flags) {
                deliver(event.copy() ?? event)
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Какие нажатия наши

    /// F-клавиша без ⌘ и ⌃, назначенная сейчас какой-нибудь команде этой программы.
    static func isBoundFKey(code: Int64, flags: CGEventFlags) -> Bool {
        guard let combo = combo(code: code, flags: flags) else { return false }
        return boundFunctionCombos(in: NSApp.mainMenu).contains(combo)
    }

    /// Нажатие как сочетание меню; nil — не F-клавиша или с ⌘/⌃.
    static func combo(code: Int64, flags: CGEventFlags) -> KeyCombo? {
        guard let number = functionKeyNumbers[code],
              !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        return KeyCombo.function(number, modifiers)
    }

    /// F-сочетания пунктов меню — те, что сейчас на них лежат (KeyBindings кладёт туда и свои).
    static func boundFunctionCombos(in menu: NSMenu?) -> Set<KeyCombo> {
        var found: Set<KeyCombo> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let combo = KeyCombo(item: item), KeyCombo.functionKeys[combo.key] != nil {
                    found.insert(combo)
                }
                if let sub = item.submenu { walk(sub) }
            }
        }
        if let menu { walk(menu) }
        return found
    }

    /// В очередь этой программы — оттуда нажатие идёт обычным путём, к окну впереди.
    static func deliverToApp(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        NSApp.postEvent(nsEvent, atStart: false)
    }
}

/// Перехватчик зовёт эту функцию на главном потоке: его источник стоит в главном цикле.
private func fkeyCaptureCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<FKeyCapture>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { capture.handle(type: type, event: event) }
}
