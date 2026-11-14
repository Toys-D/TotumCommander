import Foundation

/// Pure planner that turns desired (source -> finalAbsolutePath) renames into an ordered list of
/// filesystem steps that are safe on a case-insensitive volume and against cycles. It never
/// touches disk; the executor performs the emitted steps.
struct RenameExecutionPlanner {

    struct Step: Equatable, Hashable { let from: String; let to: String }
    /// A desired rename: absolute source path -> absolute final path (subfolders already resolved).
    struct Move: Equatable { let source: String; let final: String }

    /// Produce steps. Strategy: if any final path (case-insensitively) equals another move's source,
    /// or a move is case-only, stage everything that participates in such a conflict through a unique
    /// temp name first, then move temp->final. Non-conflicting moves go directly.
    func plan(_ moves: [Move], tempSuffix: (Int) -> String) -> [Step] {
        let sourcesLower = Set(moves.map { $0.source.lowercased() })
        func conflicts(_ m: Move) -> Bool {
            if m.source.lowercased() == m.final.lowercased() && m.source != m.final { return true } // case-only
            // another move's source occupies our final name
            return sourcesLower.contains(m.final.lowercased()) && m.final.lowercased() != m.source.lowercased()
        }
        var steps: [Step] = []
        var staged: [(temp: String, final: String)] = []
        var t = 0
        for m in moves {
            if conflicts(m) {
                let temp = (m.source as NSString).deletingLastPathComponent + "/" + tempSuffix(t)
                t += 1
                steps.append(Step(from: m.source, to: temp))
                staged.append((temp, m.final))
            } else {
                steps.append(Step(from: m.source, to: m.final))
            }
        }
        for s in staged { steps.append(Step(from: s.temp, to: s.final)) }
        return steps
    }
}

// MARK: - Учёт временных имён по ходу пакета

extension RenameExecutionPlanner {

    /// Следит за пакетом, пока исполнитель идёт по шагам: какой файл сейчас лежит под временным
    /// именем и какие имена пакет уже занял. Нужен, чтобы после отмены или сбоя ни один файл не
    /// остался под скрытым `.fcxl-mrt-…`: исполнитель спрашивает `nextStranded()` и возвращает
    /// файл на первое из свободных имён. Диска не касается — исполнитель сообщает исход шагов.
    struct Ledger {

        /// Файл, оставшийся на временном имени.
        struct Stranded: Equatable {
            /// Где он лежит сейчас.
            let temp: String
            /// Как назывался до пакета.
            let original: String
            /// Как должен был называться.
            let final: String
            /// Куда его можно вернуть, по порядку: сначала прежнее имя, потом новое — те из них,
            /// что пакет не занял другим файлом.
            let candidates: [String]
        }

        private var originalOf: [String: String] = [:]   // временное имя → исходное
        private var finalOf: [String: String] = [:]      // временное имя → конечное
        private var onTemp: [String] = []                // на этих временных именах сейчас лежит файл
        private var missing: Set<String> = []            // эти временные имена так и не появились
        private var held: Set<String> = []               // имена, занятые файлами пакета (нижний регистр)

        init(steps: [Step]) {
            // Временное имя — то, куда ведёт один шаг и откуда уходит более поздний.
            var firstTarget: [String: Int] = [:]
            for (index, step) in steps.enumerated() where firstTarget[step.to] == nil {
                firstTarget[step.to] = index
            }
            for (index, step) in steps.enumerated() {
                if let staged = firstTarget[step.from], staged < index {
                    originalOf[step.from] = steps[staged].from
                    finalOf[step.from] = step.to
                }
            }
            for step in steps where originalOf[step.from] == nil {
                held.insert(step.from.lowercased())
            }
        }

        /// Шаг выполнять незачем: его источник — временное имя, которое не появилось, потому что
        /// первый шаг для этого файла не удался (и уже попал в ошибки).
        func shouldSkip(_ step: Step) -> Bool {
            missing.contains(step.from)
        }

        /// Имя файла для сообщений: у шага с временного имени — исходное, а не `.fcxl-mrt-…`.
        func displayName(for step: Step) -> String {
            ((originalOf[step.from] ?? step.from) as NSString).lastPathComponent
        }

        /// Исполнитель сообщает исход шага.
        mutating func record(_ step: Step, succeeded: Bool) {
            guard succeeded else {
                if originalOf[step.to] != nil { missing.insert(step.to) }
                return
            }
            held.remove(step.from.lowercased())
            held.insert(step.to.lowercased())
            if originalOf[step.to] != nil { onTemp.append(step.to) }
            if originalOf[step.from] != nil { onTemp.removeAll { $0 == step.from } }
        }

        /// Очередной файл, оставшийся на временном имени, либо nil, когда таких нет.
        func nextStranded() -> Stranded? {
            guard let temp = onTemp.first, let original = originalOf[temp], let final = finalOf[temp] else {
                return nil
            }
            var candidates: [String] = []
            for name in [original, final] where !held.contains(name.lowercased()) {
                if !candidates.contains(where: { $0.lowercased() == name.lowercased() }) { candidates.append(name) }
            }
            return Stranded(temp: temp, original: original, final: final, candidates: candidates)
        }

        /// Файл вернули на одно из имён.
        mutating func settled(_ stranded: Stranded, at name: String) {
            record(Step(from: stranded.temp, to: name), succeeded: true)
        }

        /// Вернуть не вышло — файл остаётся на временном имени, больше о нём не спрашивать.
        mutating func abandon(_ stranded: Stranded) {
            onTemp.removeAll { $0 == stranded.temp }
        }
    }
}
