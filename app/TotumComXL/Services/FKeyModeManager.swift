import AppKit
import Combine
import Darwin
import IOKit
import os.log

private let fkLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FCP", category: "FKeyMode")

// NSLog-обёртка: уровень Default, всегда виден в Console.app без спецнастроек
private func fkNSLog(_ msg: String) {
    NSLog("[FKeyMode] %@", msg)
}

// MARK: - FKeyModeManager

/// Управляет F-key режимом в двух вариантах:
///
/// **App-only** (`isSystemWide == false`, по умолчанию):
///   При получении фокуса переключает HIDFKeyMode=1 (F-клавиши) через IOKit.
///   При потере фокуса переключает HIDFKeyMode=0 (медиа-клавиши) — другие приложения
///   продолжают работать штатно.
///
/// **System-wide** (`isSystemWide == true`):
///   Меняет глобальную настройку macOS (IOKit + CFPreferences) для всех приложений
///   на весь период работы Fn-режима.
///
/// ВАЖНО: При выключении Fn — ВСЕГДА сбрасывает глобальную настройку
/// (защита от «зависания» fnState=true после crash или force-quit).
@MainActor
final class FKeyModeManager: ObservableObject {

    // MARK: - Singleton

    static let shared = FKeyModeManager()

    // MARK: - Published state

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSystemWide: Bool

    // MARK: - Private: focus observers (app-only режим)

    /// Наблюдатели за активностью приложения.
    /// Устанавливаются только при isEnabled=true + isSystemWide=false.
    /// При получении фокуса → IOKit F-keys; при потере фокуса → IOKit media keys.
    private var appFocusObservers: [NSObjectProtocol] = []

    // MARK: - Init

    private init() {
        isEnabled    = UserDefaults.standard.bool(forKey: "fKeyMode")
        isSystemWide = UserDefaults.standard.bool(forKey: "fKeyModeSystemWide")
    }

    // MARK: - Original system fnState (so we never clobber the user's macOS setting)

    private static let originalFnStateKey = "fKeyModeOriginalFnState"

    /// The user's macOS "Use F1, F2… as standard function keys" setting, captured ONCE before
    /// we ever touch it. Restoring to this (instead of a hard `false`) means a user who prefers
    /// standard F-keys system-wide doesn't get it silently reset every launch/quit.
    private var originalFnState: Bool {
        UserDefaults.standard.bool(forKey: Self.originalFnStateKey)
    }

    private func captureOriginalFnStateIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.originalFnStateKey) == nil else { return }
        UserDefaults.standard.set(readSystemFnState(), forKey: Self.originalFnStateKey)
    }

    /// Read the current global fnState from CFPreferences (macOS default is media keys = false).
    private func readSystemFnState() -> Bool {
        let value = CFPreferencesCopyValue(
            "com.apple.keyboard.fnState" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        if let boolValue = value as? Bool { return boolValue }
        if let intValue = value as? Int { return intValue != 0 }
        return false
    }

    // MARK: - Синхронизация при запуске

    /// Вызывается из applicationDidFinishLaunching.
    /// Применяет сохранённое состояние: IOKit для system-wide, focus-observers для app-only.
    func syncOnLaunch() {
        // Capture the user's system fnState before we ever change it.
        captureOriginalFnStateIfNeeded()
        fkNSLog("syncOnLaunch: isEnabled=\(isEnabled), isSystemWide=\(isSystemWide)")
        if isEnabled {
            if isSystemWide {
                applyGlobalSetting(enabled: true)
            } else {
                installAppFocusObservers()
            }
        } else {
            // Our Fn mode is off → leave the system as the user had it, don't force media keys.
            applyGlobalSetting(enabled: originalFnState)
        }
        fkNSLog("syncOnLaunch done")
    }

    // MARK: - Public API: Fn toggle (кнопка в CommandFooterBar)

    func toggle() {
        isEnabled.toggle()
        fkNSLog("toggle: isEnabled=\(isEnabled), isSystemWide=\(isSystemWide)")
        UserDefaults.standard.set(isEnabled, forKey: "fKeyMode")

        if isEnabled {
            if isSystemWide {
                applyGlobalSetting(enabled: true)
            } else {
                installAppFocusObservers()
            }
        } else {
            removeAppFocusObservers()
            // Restore the user's original system setting (not a hard false), so turning our
            // Fn mode off doesn't wipe a "standard F-keys" preference.
            applyGlobalSetting(enabled: originalFnState)
        }
    }

    // MARK: - Public API: System-wide checkbox (Settings)

    func setSystemWide(_ value: Bool) {
        guard isSystemWide != value else { return }
        isSystemWide = value
        UserDefaults.standard.set(value, forKey: "fKeyModeSystemWide")

        if value {
            // → system-wide: снимаем focus-observers, включаем глобальную настройку
            removeAppFocusObservers()
            if isEnabled { applyGlobalSetting(enabled: true) }
        } else {
            // → app-only: restore the user's original system setting, then focus-observers
            applyGlobalSetting(enabled: originalFnState)
            if isEnabled { installAppFocusObservers() }
        }
    }

    // MARK: - Аварийное восстановление (кнопка в Settings)

    /// Called at app termination. Restores the user's ORIGINAL system fnState (not a hard media
    /// reset) and stops observing, so quitting never wipes a "standard F-keys" preference.
    func restoreSystemStateOnExit() {
        removeAppFocusObservers()
        applyGlobalSetting(enabled: originalFnState)
    }

    /// Принудительно сбрасывает глобальную настройку и выключает Fn режим.
    func forceRestoreMediaKeys() {
        fkNSLog("forceRestoreMediaKeys() called — isEnabled=\(isEnabled), isSystemWide=\(isSystemWide), observersActive=\(!appFocusObservers.isEmpty)")
        isEnabled = false
        UserDefaults.standard.set(false, forKey: "fKeyMode")
        removeAppFocusObservers()
        applyGlobalSetting(enabled: false)
        fkNSLog("forceRestoreMediaKeys() done")
    }

    // MARK: - App-only: focus-based IOKit switching

    /// Устанавливает наблюдателей за фокусом приложения.
    /// При получении фокуса: IOKit → HIDFKeyMode=1 (F-клавиши).
    /// При потере фокуса: IOKit → HIDFKeyMode=0 (медиа-клавиши, macOS default).
    private func installAppFocusObservers() {
        guard appFocusObservers.isEmpty else { return }
        fkNSLog("installAppFocusObservers()")

        let becomeActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, !self.isSystemWide else { return }
            fkNSLog("appBecameActive → apply F-keys (app-only)")
            self.applyGlobalSetting(enabled: true)
        }

        let resignActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, !self.isSystemWide else { return }
            fkNSLog("appResignedActive → restore original system setting (app-only)")
            self.applyGlobalSetting(enabled: self.originalFnState)
        }

        appFocusObservers = [becomeActive, resignActive]

        // Если приложение уже активно — применяем F-keys сразу
        if NSApp.isActive {
            fkNSLog("app already active → apply F-keys immediately")
            applyGlobalSetting(enabled: true)
        }
    }

    /// Снимает наблюдателей за фокусом и восстанавливает медиа-клавиши.
    private func removeAppFocusObservers() {
        guard !appFocusObservers.isEmpty else { return }
        fkNSLog("removeAppFocusObservers()")
        appFocusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        appFocusObservers.removeAll()
        // Restore the user's original system setting when removing observers.
        applyGlobalSetting(enabled: originalFnState)
    }

    // MARK: - Global setting

    /// Применяет fnState через два механизма:
    /// 1. IOKit — мгновенно меняет поведение HID без перезагрузки
    /// 2. CFPreferences — сохраняет на диск без внешних процессов, sandbox-safe
    private func applyGlobalSetting(enabled: Bool) {
        fkNSLog("applyGlobalSetting(enabled: \(enabled))")

        // Механизм 1: IOKit (самый надёжный, мгновенный)
        applyViaIOKit(functionKeysEnabled: enabled)

        // Механизм 2: CFPreferences (persistence, sandbox-safe, без Process)
        CFPreferencesSetValue(
            "com.apple.keyboard.fnState" as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let syncOK = CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        fkNSLog("CFPreferencesSynchronize(AnyApp) → \(syncOK ? "OK" : "FAILED")")

        // Readback: проверяем, что значение реально записалось
        let readback = CFPreferencesCopyValue(
            "com.apple.keyboard.fnState" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        fkNSLog("fnState readback (AnyApp): \(readback.map { String(describing: $0) } ?? "nil")")

        // Дополнительно пробуем GlobalPreferences домен напрямую
        let syncGlobal = CFPreferencesSynchronize(
            ".GlobalPreferences" as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let readbackGlobal = CFPreferencesCopyValue(
            "com.apple.keyboard.fnState" as CFString,
            ".GlobalPreferences" as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        fkNSLog("fnState readback (.GlobalPreferences, syncOK=\(syncGlobal)): \(readbackGlobal.map { String(describing: $0) } ?? "nil")")
    }

    // MARK: - IOKit: мгновенное изменение HID-параметра

    /// Напрямую говорит IOHIDSystem изменить режим F-клавиш.
    /// Работает без перезагрузки и (предположительно) без привилегий root.
    ///
    /// HIDFKeyMode: 0 = медиа-клавиши (яркость, громкость — «mac default», special_function_key)
    ///              1 = стандартные F-клавиши (F1–F12 без Fn, standard_function_key)
    private func applyViaIOKit(functionKeysEnabled: Bool) {
        // 0 = media keys (macOS default), 1 = standard F-keys — НЕ наоборот!
        let targetMode: UInt32 = functionKeysEnabled ? 1 : 0
        fkNSLog("applyViaIOKit: functionKeysEnabled=\(functionKeysEnabled) → HIDFKeyMode=\(targetMode) (\(targetMode == 0 ? "media keys" : "F-keys"))")

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem")
        )
        guard service != IO_OBJECT_NULL else {
            fkNSLog("❌ IOServiceGetMatchingService(IOHIDSystem) → IO_OBJECT_NULL")
            return
        }
        defer { IOObjectRelease(service) }
        fkNSLog("✓ IOServiceGetMatchingService OK (service=\(service))")

        var connect: io_connect_t = IO_OBJECT_NULL
        // kIOHIDParamConnectType = 1
        let krOpen = IOServiceOpen(service, mach_task_self_, 1, &connect)
        guard krOpen == kIOReturnSuccess, connect != IO_OBJECT_NULL else {
            fkNSLog("❌ IOServiceOpen FAILED: kr=0x\(String(krOpen, radix: 16)) connect=\(connect)")
            return
        }
        defer { IOServiceClose(connect) }
        fkNSLog("✓ IOServiceOpen OK (connect=\(connect))")

        var mode: UInt32 = targetMode
        let krSet = IOHIDSetParameter(connect, "HIDFKeyMode" as CFString, &mode, IOByteCount(MemoryLayout<UInt32>.size))
        fkNSLog("IOHIDSetParameter(HIDFKeyMode=\(mode)) → kr=0x\(String(krSet, radix: 16)) \(krSet == kIOReturnSuccess ? "✓ SUCCESS" : "❌ FAILED")")

        // Readback: проверяем, что параметр реально изменился
        var readMode: UInt32 = 99
        var readSize: IOByteCount = IOByteCount(MemoryLayout<UInt32>.size)
        let krGet = IOHIDGetParameter(connect, "HIDFKeyMode" as CFString, IOByteCount(MemoryLayout<UInt32>.size), &readMode, &readSize)
        if krGet == kIOReturnSuccess {
            fkNSLog("IOHIDGetParameter readback=\(readMode) expected=\(targetMode) \(readMode == targetMode ? "✓ MATCH" : "❌ MISMATCH")")
        } else {
            fkNSLog("❌ IOHIDGetParameter FAILED: kr=0x\(String(krGet, radix: 16))")
        }
    }

    // MARK: - Crash Guard

    /// Install signal handlers that restore media keys on crash/hang/kill.
    /// Uses raw POSIX signals + IOKit — no Swift runtime, no allocations, signal-safe.
    func installCrashGuard() {
        fkNSLog("installCrashGuard()")
        let signals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP, SIGTERM, SIGQUIT]
        for sig in signals {
            signal(sig, fkeyRestoreSignalHandler)
        }
        // Also handle uncaught exceptions
        NSSetUncaughtExceptionHandler { _ in
            fkeyRestoreIOKit()
        }
    }
}

// MARK: - Signal-safe IOKit restore (C-level, no Swift runtime)

/// Restore HIDFKeyMode=0 (media keys) via IOKit.
/// This function is signal-safe: no ObjC, no Swift runtime, no allocations.
private func fkeyRestoreIOKit() {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("IOHIDSystem")
    )
    guard service != IO_OBJECT_NULL else { return }

    var connect: io_connect_t = IO_OBJECT_NULL
    let kr = IOServiceOpen(service, mach_task_self_, 1, &connect)
    IOObjectRelease(service)
    guard kr == kIOReturnSuccess, connect != IO_OBJECT_NULL else { return }

    var mode: UInt32 = 0 // media keys
    IOHIDSetParameter(connect, "HIDFKeyMode" as CFString, &mode, IOByteCount(MemoryLayout<UInt32>.size))
    IOServiceClose(connect)
}

/// C-compatible signal handler.
private func fkeyRestoreSignalHandler(_ sig: Int32) {
    fkeyRestoreIOKit()
    // Re-raise the signal with default handler so the process actually terminates
    signal(sig, SIG_DFL)
    raise(sig)
}
