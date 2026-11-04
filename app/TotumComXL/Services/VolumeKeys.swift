import AppKit
import AudioToolbox
import CoreAudio

/// Клавиши громкости, которые наш же режим F-клавиш отнял у системы.
///
/// Режим переключает ВСЮ клавиатуру разом (`HIDFKeyMode`), по отдельной клавише его не
/// настроить: пока окно программы впереди, F10–F12 перестают быть «звук выкл / тише /
/// громче». Программе они не нужны — и нажатие уходит в пустоту. Значит, работу клавиатуры
/// делаем за неё сами.
enum VolumeKeys {
    enum Action: Equatable { case mute, down, up }

    /// Что должна сделать клавиша.
    ///
    /// Кто перевёл клавиатуру в режим F-клавиш — мы своей кнопкой Fn или человек настройкой
    /// macOS, — неважно: раз клавиша дошла до нас, значит звуком она уже не управляет, а
    /// другого дела у программы для неё нет. На клавише нарисован звук — пусть звук и будет.
    /// Сначала было иначе, по нашей настройке, и во второй учётной записи, где режим не
    /// включали, клавиши так и остались мёртвыми.
    ///
    /// Модификатор отменяет подмену: ⌘F12 — это не «громче».
    static func action(forKeyCode code: UInt16,
                       flags: NSEvent.ModifierFlags) -> Action? {
        guard flags.intersection([.command, .shift, .option, .control]).isEmpty else { return nil }
        switch code {
        case 109: return .mute   // F10
        case 103: return .down   // F11
        case 111: return .up     // F12
        default:  return nil
        }
    }

    static func perform(_ action: Action) {
        switch action {
        case .mute: SystemVolume.toggleMute()
        case .down: SystemVolume.nudge(up: false)
        case .up:   SystemVolume.nudge(up: true)
        }
    }
}

/// Громкость вывода через CoreAudio.
///
/// Не отправкой системных клавиш: измерено — неподписанной программе без «Универсального
/// доступа» такие события уходят в никуда, громкость не меняется. Просить это разрешение
/// ради кнопки громкости незачем, а CoreAudio работает без спроса.
enum SystemVolume {
    /// Шаг громкости macOS — шестнадцатая часть шкалы.
    static let step: Float = 1.0 / 16.0

    /// Следующее значение громкости: в пределах шкалы и по сетке шагов, чтобы нажатия не
    /// уводили значение в дробную кашу и попадали в те же деления, что и клавиши Mac.
    static func stepped(from current: Float, up: Bool, step: Float = step) -> Float {
        let clamped = min(max(current, 0), 1)
        let moved = clamped + (up ? step : -step)
        let snapped = (moved / step).rounded() * step
        return min(max(snapped, 0), 1)
    }

    /// Громкость, к которой возвращаемся, снимая приглушение с устройства без своего «mute».
    private static var volumeBeforeMute: Float = 0.5

    static func nudge(up: Bool) {
        guard let device = defaultOutputDevice(), let current = volume(of: device) else { return }
        // Прибавили громкость на приглушённом устройстве — значит, слушать снова хотят.
        if up, isMuted(device) == true { setMuted(false, on: device) }
        setVolume(stepped(from: current, up: up), on: device)
    }

    static func toggleMute() {
        guard let device = defaultOutputDevice() else { return }
        if let muted = isMuted(device) {
            setMuted(!muted, on: device)
            return
        }
        // Устройство без собственного «mute» — глушим громкостью, запомнив прежнюю.
        guard let current = volume(of: device) else { return }
        if current > 0 {
            volumeBeforeMute = current
            setVolume(0, on: device)
        } else {
            setVolume(volumeBeforeMute, on: device)
        }
    }

    // MARK: - CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    static func volume(of device: AudioDeviceID) -> Float? {
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                           scope: kAudioDevicePropertyScopeOutput)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    static func setVolume(_ value: Float, on device: AudioDeviceID) -> Bool {
        var value = min(max(value, 0), 1)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                           scope: kAudioDevicePropertyScopeOutput)
        return AudioObjectSetPropertyData(device, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float>.size), &value) == noErr
    }

    /// nil — устройство не умеет приглушаться само.
    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    @discardableResult
    static func setMuted(_ muted: Bool, on device: AudioDeviceID) -> Bool {
        var value = UInt32(muted ? 1 : 0)
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        return AudioObjectSetPropertyData(device, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
