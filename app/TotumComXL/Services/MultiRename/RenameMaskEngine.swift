import Foundation

/// Pure Total-Commander-style rename engine. Turns original names + a RenameRule into target
/// names. No UI, no disk access, fully deterministic (dates/sizes come from the FileItem, which
/// the caller supplies). See docs/superpowers/specs/2026-07-22-multi-rename-tc-reference.md.
struct RenameMaskEngine {

    /// Calendar used to read date components for the [Y]/[M]/[D]/... tags. Injectable so tests can
    /// pin a fixed time zone (default is the user's current calendar).
    let calendar: Calendar
    init(calendar: Calendar = .current) { self.calendar = calendar }

    /// One input row. Kept separate from FileItem so the engine tests need no FileItem plumbing
    /// and so date/size are explicit and injectable.
    struct Input: Equatable {
        var path: String
        var name: String            // full name WITH extension, no path
        var isDirectory: Bool
        var modified: Date
        var created: Date?
        var size: UInt64
        var width: Int?             // image pixel dims where cheaply known, else nil
        var height: Int?
    }

    /// Per-mask counter bookkeeping (supports multiple parameterized [C] in one mask).
    struct CounterState {
        var listIndex: Int          // 0-based position in the selection (advances per row)
        var lastValue: Int = 0      // value emitted by the most recent [C], reused by [c]
    }

    /// Split a file name into (stem, ext) the Total Commander way:
    /// - a name that STARTS with a dot is all-extension, stem empty (".gitignore" -> ("", "gitignore"))
    /// - otherwise split at the LAST dot; no dot -> ext empty.
    static func splitName(_ name: String, isDirectory: Bool, ignoreDots: Bool = false) -> (stem: String, ext: String) {
        if isDirectory && ignoreDots { return (name, "") }
        if name.hasPrefix(".") { return ("", String(name.dropFirst())) }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[name.startIndex..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Path components of the file's DIRECTORY, root-first. "/a/b/c/file.txt" -> ["a","b","c"].
    static func dirComponents(_ path: String) -> [String] {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.split(separator: "/").map(String.init)
    }

    /// Full pipeline for a list. Counter runs once over the list in order. `now` is the moment the
    /// bracket date/time tags ([Y][M][D][h][m][s]) stamp — the CURRENT date/time by default (the
    /// file's own dates are reached through [=tc.writedate]/[=tc.creationdate] instead). Injectable
    /// so tests are deterministic.
    func preview(_ inputs: [Input], rule: RenameRule, now: Date = Date()) -> [RenamePlan] {
        var plans: [RenamePlan] = []
        for (i, input) in inputs.enumerated() {
            var counter = CounterState(listIndex: i)
            let name = expand(mask: rule.nameMask, input: input, index: i, rule: rule, counter: &counter, now: now)
            let ext  = expand(mask: rule.extMask,  input: input, index: i, rule: rule, counter: &counter, now: now)
            let combined = ext.isEmpty ? name : "\(name).\(ext)"
            var status: RenameStatus = .ok
            var result = combined
            do {
                result = try applySearchReplace(result, rule: rule)
            } catch {
                status = .error("regex")
            }
            result = applyCase(result, mode: rule.caseMode)
            plans.append(RenamePlan(sourcePath: input.path, originalName: input.name,
                                    isDirectory: input.isDirectory, newName: result, status: status))
        }

        // Classify. Duplicates compared case-insensitively (case-insensitive volume assumption).
        var seen: [String: Int] = [:]
        for i in plans.indices {
            if case .error = plans[i].status { continue }
            let target = plans[i].newName
            if let reason = Self.validate(target) { plans[i].status = .error(reason); continue }
            if target == plans[i].originalName { plans[i].status = .unchanged; continue }
            seen[target.lowercased(), default: 0] += 1
        }
        for i in plans.indices {
            if case .ok = plans[i].status {
                if (seen[plans[i].newName.lowercased()] ?? 0) > 1 { plans[i].status = .duplicate }
            }
        }
        return plans
    }

    /// Returns a short reason key if the target is invalid on macOS, else nil.
    /// "/" separates subfolders; each component must be non-empty, not ".."/"." , no ":" or NUL.
    static func validate(_ target: String) -> String? {
        if target.isEmpty { return "empty" }
        if target.hasPrefix("/") { return "absolute" }
        let comps = target.split(separator: "/", omittingEmptySubsequences: false)
        for c in comps {
            if c.isEmpty { return "empty" }
            if c == ".." || c == "." { return "dotdot" }
            if c.contains(":") || c.contains("\0") { return "illegal" }
        }
        return nil
    }

    /// Search & replace applied to the combined name. Plain (all/first, "|" parallel pairs) or
    /// regex ($1 backrefs). By default hits the NAME only; searchInExtension extends it to the ext.
    private func applySearchReplace(_ s: String, rule: RenameRule) throws -> String {
        guard !rule.search.isEmpty else { return s }
        let (stem, ext) = Self.splitName(s, isDirectory: false)
        let hasExt = s != stem && !ext.isEmpty
        func transform(_ target: String) throws -> String {
            if rule.useRegex {
                let opts: NSRegularExpression.Options = rule.respectCase ? [] : [.caseInsensitive]
                let re = try NSRegularExpression(pattern: rule.search, options: opts)
                let range = NSRange(target.startIndex..., in: target)
                if rule.replaceOnce, let m = re.firstMatch(in: target, range: range) {
                    let ns = target as NSString
                    let rep = re.replacementString(for: m, in: target, offset: 0, template: rule.replace)
                    return ns.replacingCharacters(in: m.range, with: rep)
                }
                return re.stringByReplacingMatches(in: target, range: range, withTemplate: rule.replace)
            } else {
                let finds = rule.search.components(separatedBy: "|")
                let reps = rule.replace.components(separatedBy: "|")
                var out = target
                for (i, f) in finds.enumerated() where !f.isEmpty {
                    let rep = i < reps.count ? reps[i] : ""
                    let cmp: String.CompareOptions = rule.respectCase ? [] : [.caseInsensitive]
                    if rule.replaceOnce {
                        if let rng = out.range(of: f, options: cmp) { out.replaceSubrange(rng, with: rep) }
                    } else {
                        out = out.replacingOccurrences(of: f, with: rep, options: cmp)
                    }
                }
                return out
            }
        }
        if rule.searchInExtension || !hasExt {
            return try transform(s)
        }
        return try transform(stem) + "." + ext
    }

    /// Case conversion, applied LAST. Unicode-aware. Title-case leaves the extension untouched.
    private func applyCase(_ s: String, mode: CaseMode) -> String {
        switch mode {
        case .unchanged: return s
        case .lower: return s.localizedLowercase
        case .upper: return s.localizedUppercase
        case .firstUpper:
            guard let f = s.first else { return s }
            return String(f).localizedUppercase + s.dropFirst().localizedLowercase
        case .eachWord:
            let (stem, ext) = Self.splitName(s, isDirectory: false)
            let titled = stem.split(separator: " ", omittingEmptySubsequences: false)
                .map { part -> String in
                    guard let f = part.first else { return String(part) }
                    return String(f).localizedUppercase + part.dropFirst().localizedLowercase
                }.joined(separator: " ")
            return (s != stem && !ext.isEmpty) ? titled + "." + ext : titled
        }
    }

    /// Expand a single mask (name or extension) for one input at a given 0-based list index.
    /// Substitutes every [...] tag. Counter state is passed in and mutated by the caller.
    /// Running case applied by the inline switches [U]/[L]/[F]/[f]/[n].
    private enum InlineCase { case none, upper, lower }

    func expand(mask: String, input: Input, index: Int, rule: RenameRule,
                counter: inout CounterState, now: Date = Date()) -> String {
        let ignoreDots = rule.nameMask.contains("[I]") || rule.extMask.contains("[I]")
        let (stem, ext) = Self.splitName(input.name, isDirectory: input.isDirectory, ignoreDots: ignoreDots)
        var out = ""
        var mode: InlineCase = .none        // sticky: [U]/[L] on, [n] off
        var oneShot: InlineCase?            // one character: [F] next upper, [f] next lower
        let chars = Array(mask)
        var i = 0
        while i < chars.count {
            if chars[i] == "[", let close = nextClose(chars, from: i) {
                let token = String(chars[(i+1)..<close])          // contents without brackets
                switch token {
                case "U": mode = .upper
                case "L": mode = .lower
                case "n": mode = .none
                case "F": oneShot = .upper
                case "f": oneShot = .lower
                default:
                    let piece = evaluate(token, stem: stem, ext: ext, input: input, rule: rule, counter: &counter, now: now)
                    out += applyInline(piece, mode: mode, oneShot: &oneShot)
                }
                i = close + 1
            } else {
                out += applyInline(String(chars[i]), mode: mode, oneShot: &oneShot)
                i += 1
            }
        }
        return out
    }

    /// Apply the running inline case to a piece of output, consuming a pending one-shot [F]/[f] on
    /// its first character.
    private func applyInline(_ s: String, mode: InlineCase, oneShot: inout InlineCase?) -> String {
        guard mode != .none || oneShot != nil else { return s }
        var result = ""
        for ch in s {
            if let one = oneShot {
                result += one == .upper ? String(ch).localizedUppercase : String(ch).localizedLowercase
                oneShot = nil
            } else {
                switch mode {
                case .upper: result += String(ch).localizedUppercase
                case .lower: result += String(ch).localizedLowercase
                case .none:  result.append(ch)
                }
            }
        }
        return result
    }

    private func nextClose(_ chars: [Character], from open: Int) -> Int? {
        var j = open + 1
        while j < chars.count { if chars[j] == "]" { return j }; j += 1 }
        return nil
    }

    /// Evaluate ONE token (the text between [ and ]). Unknown tokens render as the literal
    /// "[token]" so a stray bracket in a name is preserved. Grows across Phase-1 tasks.
    private func evaluate(_ token: String, stem: String, ext: String, input: Input,
                          rule: RenameRule, counter: inout CounterState, now: Date) -> String {
        if token.hasPrefix("=") {
            return metadata(String(token.dropFirst()), input: input)   // "tc.size", "tc.size:01-8"
        }
        switch token.first {
        case "N": return substring(stem, spec: String(token.dropFirst()))
        case "E": return substring(ext,  spec: String(token.dropFirst()))
        case "A": return substring(input.name, spec: String(token.dropFirst()))
        case "P":
            let comps = Self.dirComponents(input.path)
            return substring(comps.last ?? "", spec: String(token.dropFirst()))
        case "G":
            let comps = Self.dirComponents(input.path)
            return substring(comps.count >= 2 ? comps[comps.count - 2] : "", spec: String(token.dropFirst()))
        case "B":
            let comps = Self.dirComponents(input.path)
            let rest = String(token.dropFirst())
            if rest.hasPrefix("+"), let n = Int(rest.dropFirst()) {           // from root
                return n < comps.count ? comps[n] : ""
            }
            if let n = Int(rest.prefix(while: { $0.isNumber })) {            // from file, 0 = parent
                let idx = comps.count - 1 - n
                return (idx >= 0 && idx < comps.count) ? comps[idx] : ""
            }
            return ""
        case "I":
            return ""   // [I] only affects folder-name dot-splitting; consumed, emits nothing
        case "C":
            let inline = String(token.dropFirst())
            if inline.first == "a" || inline.first == "A" {
                let upper = inline.first == "A"
                let n = rule.counterStart + rule.counterStep * counter.listIndex
                return Self.letters(n - rule.counterStart, uppercase: upper)   // 0-based -> a,b,c
            }
            // fractional "+step/den": advance step every `den` files
            if let slash = inline.firstIndex(of: "/"),
               let plus = inline.firstIndex(of: "+"), plus < slash {
                let step = Int(inline[inline.index(after: plus)..<slash]) ?? 1
                let den = max(1, Int(inline[inline.index(after: slash)...]) ?? 1)
                let value = rule.counterStart + step * (counter.listIndex / den)
                counter.lastValue = value
                return String(format: "%0\(max(1, rule.counterDigits))d", value)
            }
            let (start, step, digits) = parseCounter(inline, rule: rule)
            let value = start + step * counter.listIndex
            counter.lastValue = value
            return String(format: "%0\(max(1, digits))d", value)
        case "c":
            return String(counter.lastValue)
        default:
            // date tokens: a token made only of the date letters, e.g. [Y] [YMD] [hms].
            // These stamp the CURRENT date/time (`now`), not the file's — the file's own dates are
            // reached through [=tc.writedate]/[=tc.creationdate].
            if !token.isEmpty && token.allSatisfy({ "YyMDhms".contains($0) }) {
                return dateString(token, date: now)
            }
            // "[#-#]" / "[#]" — a leading digit or '-' with no letter: range over the whole name.
            if let f = token.first, f.isNumber || f == "-" {
                return substring(input.name, spec: token)
            }
            return "[\(token)]"
        }
    }

    /// Resolve a built-in metadata field: "tc.size", "tc.size.kbytes", "tc.width", "tc.fullname",
    /// "tc.writedate"… with an optional ":spec" substring/padding tail. Missing values render empty.
    private func metadata(_ body: String, input: Input) -> String {
        var field = body, spec = ""
        if let colon = body.firstIndex(of: ":") {
            field = String(body[body.startIndex..<colon]); spec = String(body[body.index(after: colon)...])
        }
        let parts = field.split(separator: ".").map(String.init)   // ["tc","size","kbytes"]
        guard parts.count >= 2, parts[0] == "tc" else { return "" }
        let unit = parts.count >= 3 ? parts[2] : ""
        let value: String
        switch parts[1] {
        case "size":     value = Self.formatSize(input.size, unit: unit)
        case "width":    value = input.width.map(String.init) ?? ""
        case "height":   value = input.height.map(String.init) ?? ""
        case "fullname": value = input.name
        case "writedate":     value = dateString("YMD", date: input.modified)
        case "writetime":     value = dateString("hms", date: input.modified)
        case "creationdate":  value = dateString("YMD", date: input.created ?? input.modified)
        default: value = ""
        }
        return spec.isEmpty ? value : substring(value, spec: spec)
    }

    static func formatSize(_ bytes: UInt64, unit: String) -> String {
        switch unit {
        case "kbytes": return String(bytes / 1024)
        case "Mbytes": return String(bytes / (1024*1024))
        case "Gbytes": return String(bytes / (1024*1024*1024))
        case "bkmG":
            let b = Double(bytes)
            if b < 1024 { return "\(bytes)" }
            if b < 1024*1024 { return "\(Int(b/1024))k" }
            if b < 1024*1024*1024 { return "\(Int(b/1024/1024))M" }
            return "\(Int(b/1024/1024/1024))G"
        default: return String(bytes)   // "bytes" or none
        }
    }

    /// Render a run of date letters (Y y M D h m s) using the engine's calendar.
    private func dateString(_ token: String, date: Date) -> String {
        let c = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        var out = ""
        for ch in token {
            switch ch {
            case "Y": out += String(format: "%04d", c.year ?? 0)
            case "y": out += String(format: "%02d", (c.year ?? 0) % 100)
            case "M": out += two(c.month)
            case "D": out += two(c.day)
            case "h": out += two(c.hour)
            case "m": out += two(c.minute)
            case "s": out += two(c.second)
            default: break
            }
        }
        return out
    }

    /// 0-based index to spreadsheet-style letters: 0->a, 25->z, 26->aa, 27->ab.
    static func letters(_ index: Int, uppercase: Bool) -> String {
        var n = max(0, index), s = ""
        repeat { s = String(UnicodeScalar(UInt8(97 + n % 26))) + s; n = n / 26 - 1 } while n >= 0
        return uppercase ? s.uppercased() : s
    }

    /// Parse the inline part of a [C...] token, inheriting unspecified fields from the dialog.
    /// Grammar: optional start digits, optional "+step", optional ":digits". e.g. "10+5:3".
    private func parseCounter(_ spec: String, rule: RenameRule) -> (start: Int, step: Int, digits: Int) {
        var start = rule.counterStart, step = rule.counterStep, digits = rule.counterDigits
        var s = Substring(spec)
        if let colon = s.firstIndex(of: ":") {
            digits = Int(s[s.index(after: colon)...]) ?? digits
            s = s[s.startIndex..<colon]
        }
        if let plus = s.firstIndex(of: "+") {
            step = Int(s[s.index(after: plus)...]) ?? step
            s = s[s.startIndex..<plus]
        }
        if !s.isEmpty, let st = Int(s) { start = st }
        return (start, step, digits)
    }

    /// Resolve a TC index spec against `base`. 1-based; positive = from start, negative = from end.
    /// Empty spec => whole string. Everything is clamped into range (out-of-range yields "").
    private func substring(_ base: String, spec: String) -> String {
        let chars = Array(base)
        let count = chars.count
        guard !spec.isEmpty else { return base }

        func toIndex(_ n: Int) -> Int { n < 0 ? count + n : n - 1 }   // -> 0-based

        // length forms contain a comma
        if let comma = spec.firstIndex(of: ",") {
            let startTok = Int(spec[spec.startIndex..<comma]) ?? 0
            let len = Int(spec[spec.index(after: comma)...]) ?? 0
            let s = max(0, toIndex(startTok))
            let e = min(count, s + max(0, len))
            return s < e ? String(chars[s..<e]) : ""
        }
        // "n--m": start-from-start .. end-from-end  (double dash: middle empty token)
        if let r = spec.range(of: "--") {
            let a = Int(spec[spec.startIndex..<r.lowerBound]) ?? 1
            let b = Int(spec[r.upperBound...]) ?? 1
            let s = max(0, a - 1)
            let e = min(count, count - b + 1)      // b-th from end, inclusive
            return s < e ? String(chars[s..<e]) : ""
        }
        // leading '-': starts from end. Could be "-n", "-n-m", "-n-"
        if spec.hasPrefix("-") {
            let rest = String(spec.dropFirst())
            if rest.hasSuffix("-") {                                  // "-n-": n-th last to end
                let n = Int(rest.dropLast()) ?? 1
                let s = max(0, count - n)
                return String(chars[s..<count])
            }
            if let dash = rest.firstIndex(of: "-") {                  // "-n-m": both from end
                let a = Int(rest[rest.startIndex..<dash]) ?? 1
                let b = Int(rest[rest.index(after: dash)...]) ?? 1
                let s = max(0, count - a)
                let e = min(count, count - b + 1)
                return s < e ? String(chars[s..<e]) : ""
            }
            let n = Int(rest) ?? 1                                    // "-n": single from end
            let idx = count - n
            return (idx >= 0 && idx < count) ? String(chars[idx]) : ""
        }
        // trailing '-': "n-" start to end
        if spec.hasSuffix("-") {
            let n = Int(spec.dropLast()) ?? 1
            let s = max(0, n - 1)
            return s < count ? String(chars[s..<count]) : ""
        }
        // "n-m": range from start
        if let dash = spec.firstIndex(of: "-") {
            let a = Int(spec[spec.startIndex..<dash]) ?? 1
            let b = Int(spec[spec.index(after: dash)...]) ?? count
            let s = max(0, a - 1)
            let e = min(count, b)
            return s < e ? String(chars[s..<e]) : ""
        }
        // "n": single from start
        if let n = Int(spec) { let i = n - 1; return (i >= 0 && i < count) ? String(chars[i]) : "" }
        return ""
    }
}
