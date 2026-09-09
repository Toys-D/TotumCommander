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
