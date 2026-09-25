import AppKit
import QuartzCore

/// Появление списков при запуске: строки выезжают справа налево лесенкой, каждая чуть позже
/// предыдущей, проявляясь по пути, и встают на свои места. Один раз за запуск на каждую
/// панель; дальше папки открываются как обычно. Пункт красоты «Плавная анимация».
///
/// При запуске список наполняется не за раз: сначала имена, потом подробности, а следом
/// метки и git — и каждый проход строит ряды заново. Поэтому показ не начинается с первого
/// же наполнения: ряды прячутся, а выезд назначается через короткую паузу и переназначается
/// каждым новым наполнением, пока список не утрясётся.
@MainActor
enum LaunchEntrance {
    static let duration: TimeInterval = 0.26
    /// Шаг лесенки между соседними рядами.
    static let stagger: TimeInterval = 0.014
    /// Дальше этого все ряды идут вместе: длинный список не должен выезжать секундами.
    static let maxStagger: TimeInterval = 0.42
    /// Пауза, за которую список успевает утрястись.
    static let settle: TimeInterval = 0.08
    static let animationKey = "fcxl.entrance"

    static func delay(forIndex index: Int) -> TimeInterval {
        min(Double(max(0, index)) * stagger, maxStagger)
    }

    /// Откуда выезжать: заметно, но не через всю панель.
    static func offset(forWidth width: CGFloat) -> CGFloat {
        max(40, min(width * 0.3, 180))
    }

    private static var done: Set<ObjectIdentifier> = []
    private static var pending: [ObjectIdentifier: DispatchWorkItem] = [:]
    /// Когда у панели начался выезд и с каким сдвигом: перезагрузка списка во время выезда
    /// строит ряды заново, и новые ряды продолжают то же расписание с того же места.
    private static var started: [ObjectIdentifier: (at: CFTimeInterval, offset: CGFloat, until: Date)] = [:]
    /// Кого прятали: ряд, спрятанный перед выездом и не попавший в него (список перезагрузился,
    /// таблица отдала его в запас), возвращался пустой строкой. Всё спрятанное возвращается.
    private static var hidden: [ObjectIdentifier: [Weak]] = [:]

    private struct Weak { weak var view: NSView? }

    /// Для проверок: забыть, кому уже показывали.
    static func reset() {
        done.removeAll()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        started.removeAll()
        for views in hidden.values { restore(views.compactMap(\.view)) }
        hidden.removeAll()
    }

    /// Идёт ли выезд у панели прямо сейчас.
    static func isRunning(_ key: ObjectIdentifier) -> Bool {
        guard let run = started[key] else { return false }
        return Date() < run.until
    }

    static func isPending(_ key: ObjectIdentifier, enabled: Bool) -> Bool {
        enabled && !done.contains(key)
    }

    /// Ряды подробной таблицы для видимой части — созданные принудительно: сразу после
    /// перезагрузки их нет, а раскладка после повторной перезагрузки их уже не рождает
    /// (замерено: 4 после первой, 0 после второй).
    static func tableRows(_ table: NSTableView) -> [NSView] {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return [] }
        let rows = (range.location..<(range.location + range.length)).compactMap {
            table.rowView(atRow: $0, makeIfNecessary: true)
        }
        return ordered(rows)
    }

    /// Список наполнился. Выезд ещё не показан — спрятать ряды и (пере)назначить его через
    /// `settle`; идёт — продолжить на новых рядах с того же расписания. Пустой список ничего
    /// не назначает — ждём наполнения; ответ говорит, назначен ли (или продолжен) показ.
    @discardableResult
    static func request(key: ObjectIdentifier, enabled: Bool,
                        views: @escaping @MainActor () -> [NSView],
                        width: @escaping @MainActor () -> CGFloat) -> Bool {
        guard enabled else { return false }
        if isRunning(key) {
            continueRun(key: key, views: views())
            return true
        }
        guard !done.contains(key) else { return false }
        let current = views()
        guard !current.isEmpty else { return false }
        // Прежде спрятанные, которых в новом списке нет, — вернуть: таблица могла отдать их в
        // запас, и они всплыли бы пустыми.
        restore(hidden[key, default: []].compactMap(\.view).filter { view in !current.contains { $0 === view } })
        hide(current, offset: offset(forWidth: width()))
        hidden[key] = current.map { Weak(view: $0) }
        pending[key]?.cancel()
        let work = DispatchWorkItem {
            pending[key] = nil
            done.insert(key)
            let rows = views()
            let offset = offset(forWidth: width())
            let now = CACurrentMediaTime()
            started[key] = (at: now, offset: offset,
                            until: Date().addingTimeInterval(duration + delay(forIndex: rows.count - 1)))
            restore(hidden[key, default: []].compactMap(\.view).filter { view in !rows.contains { $0 === view } })
            hidden[key] = nil
            run(rows, offset: offset, startedAt: now)
        }
        pending[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
        return true
    }

    /// Убрать за правый край и погасить — до выезда.
    static func hide(_ views: [NSView], offset: CGFloat) {
        for view in views {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            layer.removeAnimation(forKey: animationKey)
            layer.opacity = 0
            layer.transform = CATransform3DMakeTranslation(offset, 0, 0)
        }
    }

    /// Вернуть на место и в видимость — тем, кому выезд не достался.
    static func restore(_ views: [NSView]) {
        for view in views {
            guard let layer = view.layer else { continue }
            layer.removeAnimation(forKey: animationKey)
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
        }
    }

    /// Выезд лесенкой: ряд за рядом, с задержкой по номеру, из-за правого края на своё место,
    /// проявляясь по пути. Модель сразу ставится в конечное положение, а анимация с
    /// `fillMode = .backwards` держит ряд за краем, пока не подошла его очередь.
    static func run(_ views: [NSView], offset: CGFloat, startedAt: CFTimeInterval = CACurrentMediaTime()) {
        for (index, view) in views.enumerated() {
            animate(view, offset: offset, beginTime: startedAt + delay(forIndex: index))
        }
    }

    /// Список перезагрузился посреди выезда: новые ряды подхватывают то же расписание —
    /// чей черёд прошёл, тот показывается с полпути, чей нет — ждёт за краем.
    static func continueRun(key: ObjectIdentifier, views: [NSView]) {
        guard let run = started[key] else { return }
        for (index, view) in views.enumerated() where view.layer?.animation(forKey: animationKey) == nil {
            animate(view, offset: run.offset, beginTime: run.at + delay(forIndex: index))
        }
    }

    private static func animate(_ view: NSView, offset: CGFloat, beginTime: CFTimeInterval) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = CATransform3DMakeTranslation(offset, 0, 0)
        move.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = duration
        group.beginTime = beginTime
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .backwards
        layer.removeAnimation(forKey: animationKey)
        layer.add(group, forKey: animationKey)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
    }

    /// Порядок лесенки: сверху вниз, а в кратком режиме — колонка за колонкой.
    static func ordered(_ views: [NSView]) -> [NSView] {
        views.sorted {
            if abs($0.frame.minX - $1.frame.minX) > 0.5 { return $0.frame.minX < $1.frame.minX }
            return $0.frame.minY < $1.frame.minY
        }
    }
}
