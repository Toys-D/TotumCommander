import AppKit

/// Полоска выполнения в цвете программы.
///
/// Системная `NSProgressIndicator` красится акцентом ВСЕЙ системы и всегда была синей, чужой
/// среди своих окон: рядом с ней — кнопки, курсор и вкладки в цвете, который человек выбрал
/// сам. Рисуем сами: дорожка, заливка и бегунок неопределённости — три прямоугольника со
/// скруглением, ничего сложнее.
final class FCXLProgressBar: NSView {

    /// 0…1. Значения за пределами приводятся к ним: доля больше единицы — это ошибка счёта,
    /// а не повод рисовать заливку за краем.
    var value: Double = 0 {
        didSet {
            value = min(max(value, 0), 1)
            guard value != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Идёт работа, но сколько её осталось — неизвестно: по дорожке ходит бегунок.
    var isIndeterminate: Bool = false {
        didSet {
            guard isIndeterminate != oldValue else { return }
            isIndeterminate ? startRunner() : stopRunner()
            needsDisplay = true
        }
    }

    /// Доля дорожки, которую занимает бегунок неопределённости.
    static let runnerWidth: CGFloat = 0.25

    private var runnerStart: Double = -Double(FCXLProgressBar.runnerWidth)
    private var runnerTimer: Timer?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    deinit { runnerTimer?.invalidate() }

    /// Где стоит бегунок на такте `tick`: от «весь за левым краем» до «весь за правым»,
    /// потом сначала. Вынесено отдельно, чтобы движение можно было проверить без окна.
    static func runnerOrigin(tick: Int, ticksPerRun: Int) -> Double {
        let steps = max(1, ticksPerRun)
        let phase = Double(tick % steps) / Double(steps)
        return -Double(runnerWidth) + phase * (1 + Double(runnerWidth))
    }

    private func startRunner() {
        runnerTimer?.invalidate()
        var tick = 0
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            tick += 1
            self.runnerStart = Self.runnerOrigin(tick: tick, ticksPerRun: 45)
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        runnerTimer = timer
    }

    private func stopRunner() {
        runnerTimer?.invalidate()
        runnerTimer = nil
    }

    /// Цвет заливки — акцент программы, тот же, что у кнопок и вкладок.
    var fillColor: NSColor { PanelAppearanceSettings.accentNSColor }

    /// Дорожка внутри вью: полоска в шесть точек по центру, какой бы высоты ни было место.
    static func trackRect(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: 0, dy: max(0, (bounds.height - 6) / 2))
    }

    /// Залитая часть дорожки. Не тоньше собственного скругления: узкая заливка иначе
    /// вырождается в точку и читается как сор на экране.
    static func fillRect(track: NSRect, value: Double) -> NSRect {
        guard value > 0 else { return .zero }
        let width = max(track.height, track.width * CGFloat(min(max(value, 0), 1)))
        return NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
    }

    /// Где стоит бегунок неопределённости на дорожке.
    static func runnerRect(track: NSRect, origin: Double) -> NSRect {
        NSRect(x: track.minX + CGFloat(origin) * track.width, y: track.minY,
               width: track.width * runnerWidth, height: track.height).intersection(track)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = Self.trackRect(in: bounds)
        let radius = track.height / 2
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        fillColor.setFill()
        let piece = isIndeterminate ? Self.runnerRect(track: track, origin: runnerStart)
                                    : Self.fillRect(track: track, value: value)
        guard !piece.isEmpty else { return }
        NSBezierPath(roundedRect: piece, xRadius: radius, yRadius: radius).fill()
    }
}
