import Foundation

/// Rules in the manner of Hazel: "a file that looks like THIS gets THAT done to it".
///
/// The whole engine below is pure — items in, a plan of what would happen out. Nothing here
/// touches the disk, which is what makes it possible to SHOW the plan before anything is done,
/// and to test every rule without a folder full of bait files.

// MARK: - One test a file has to pass

struct RuleCondition: Codable, Equatable, Identifiable {
    /// What is being looked at.
    enum Field: String, Codable, CaseIterable {
        case name, ext, kind, size, modified, created, added, tag
    }

    /// How it is being looked at. Not every test suits every field — `Field.tests` says which.
    enum Test: String, Codable, CaseIterable {
        case matches, notMatches      // name, by the panel's own mask language
        case isOneOf, isNotOneOf      // extension, kind, tag
        case isBigger, isSmaller      // size, in megabytes
        case isOlder, isNewer         // a date, in days
    }

    var id = UUID()
    var field: Field = .name
    var test: Test = .matches
    /// The mask, the list of extensions, the kind or the tag — whatever the field asks for.
    var text: String = ""
    /// Megabytes for a size, days for a date.
    var number: Double = 0

    init(id: UUID = UUID(), field: Field = .name, test: Test = .matches,
         text: String = "", number: Double = 0) {
        self.id = id
        self.field = field
        self.test = test
        self.text = text
        self.number = number
    }
}

extension RuleCondition.Field {
    /// The tests this field can be asked. The editor offers these and nothing else, so a
    /// nonsense pair like "size matches *.jpg" cannot be built in the first place.
    var tests: [RuleCondition.Test] {
        switch self {
        case .name:                       return [.matches, .notMatches]
        case .ext, .kind, .tag:           return [.isOneOf, .isNotOneOf]
        case .size:                       return [.isBigger, .isSmaller]
        case .modified, .created, .added: return [.isOlder, .isNewer]
        }
    }

    var localizedName: String { L("rules.field.\(rawValue)") }
}

extension RuleCondition.Test {
    var localizedName: String { L("rules.test.\(rawValue)") }
}

// MARK: - What gets done

struct RuleAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case move, copy, rename, trash, tag, shelf, unpack
    }

    var kind: Kind = .move
    /// Where to, for move and copy. Empty for the rest.
    var destination: String = ""
    /// A date pattern ("yyyy" or "yyyy/MM") sorting the file into a subfolder of the
    /// destination. Empty means straight into it.
    var subfolder: String = ""
    /// The rename masks — the same language as the group rename, so what is learnt once works
    /// in both places.
    var nameMask: String = "[N]"
    var extMask: String = "[E]"
    /// Which colour to hang on the file.
    var tag: String = FinderTag.red.rawValue

    var localizedName: String { L("rules.action.\(kind.rawValue)") }
}

// MARK: - The rule itself

struct FolderRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String = ""
    var isEnabled = true
    /// Every condition, or any one of them.
    var matchAll = true
    /// Folders are left alone unless asked for: a rule written for downloads should not sweep
    /// up the folder they were unpacked into.
    var includeFolders = false
    var conditions: [RuleCondition] = []
    var action = RuleAction()

    init(id: UUID = UUID(), name: String = "", isEnabled: Bool = true, matchAll: Bool = true,
         includeFolders: Bool = false, conditions: [RuleCondition] = [],
         action: RuleAction = RuleAction()) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.matchAll = matchAll
        self.includeFolders = includeFolders
        self.conditions = conditions
        self.action = action
    }
}

/// One line of the plan: what would happen to one file, and why.
struct RuleStep: Equatable, Identifiable {
    var id: String { source }
    let source: String
    let ruleName: String
    let action: RuleAction
    /// Where the file ends up, for the actions that move it somewhere. Empty for the rest.
    let target: String
}

// MARK: - The engine

enum FolderRules {

    // MARK: Matching

    /// Does one file answer one condition?
    static func passes(_ item: FileItem, condition: RuleCondition, now: Date,
                       tags: [FinderTag]) -> Bool {
        switch condition.field {
        case .name:
            // The panel's own mask language, so "*.jpg *.png" means here what it means in the
            // quick filter and in search.
            let expression = PanelViewModel.MaskExpression(condition.text)
            let hit = condition.text.trimmingCharacters(in: .whitespaces).isEmpty
                ? false : expression.matches(item.name, tags: tags)
            return condition.test == .matches ? hit : !hit

        case .ext:
            // Both sides are stripped of the dot before comparing. The listing carries the
            // extension the way std::filesystem gives it — ".zip", dot included — while a person
            // writing a rule types "zip" as often as ".zip".
            let wanted = list(condition.text).map { $0.lowercased() }
            let hit = wanted.contains(bareExtension(item.fileExtension))
            return condition.test == .isOneOf ? hit : !hit

        case .kind:
            let wanted = Set(list(condition.text).map { $0.lowercased() })
            let kind = item.isDirectory ? "folder"
                : String(describing: fileCategory(extension: item.fileExtension))
            let hit = wanted.contains(kind.lowercased())
            return condition.test == .isOneOf ? hit : !hit

        case .tag:
            let wanted = Set(list(condition.text).map { $0.lowercased() })
            let hit = tags.contains { wanted.contains($0.rawValue.lowercased()) }
            return condition.test == .isOneOf ? hit : !hit

        case .size:
            let bytes = Double(item.size)
            let limit = condition.number * 1024 * 1024
            return condition.test == .isBigger ? bytes > limit : bytes < limit

        case .modified, .created, .added:
            guard let date = date(of: item, field: condition.field) else { return false }
            let age = now.timeIntervalSince(date) / 86_400
            return condition.test == .isOlder ? age > condition.number : age < condition.number
        }
    }

    /// Does one file answer a whole rule?
    static func matches(_ item: FileItem, rule: FolderRule, now: Date,
                        tags: [FinderTag] = []) -> Bool {
        guard rule.isEnabled, item.name != ".." else { return false }
        guard !item.isDirectory || rule.includeFolders else { return false }
        // A rule with no conditions matches nothing. The other reading — "matches everything" —
        // turns a half-written rule into a folder-wide sweep.
        guard !rule.conditions.isEmpty else { return false }
        return rule.matchAll
            ? rule.conditions.allSatisfy { passes(item, condition: $0, now: now, tags: tags) }
            : rule.conditions.contains { passes(item, condition: $0, now: now, tags: tags) }
    }

    // MARK: Planning

    /// What would be done to a folder, in the order the rules are written.
    ///
    /// The FIRST rule that matches a file takes it, and the rest are not asked. Two rules that
    /// both want to move the same file would otherwise fight over it, and the loser's move would
    /// happen to a file that is no longer where the plan said it was.
    static func plan(items: [FileItem], rules: [FolderRule], now: Date = Date(),
                     tags: [String: [FinderTag]] = [:],
                     calendar: Calendar = .current) -> [RuleStep] {
        var steps: [RuleStep] = []
        for item in items {
            guard item.name != ".." else { continue }
            guard let rule = rules.first(where: {
                matches(item, rule: $0, now: now, tags: tags[item.path] ?? [])
            }) else { continue }
            steps.append(RuleStep(source: item.path,
                                  ruleName: rule.name,
                                  action: rule.action,
                                  target: target(for: item, action: rule.action,
                                                 calendar: calendar)))
        }
        return steps
    }

    /// Where a file lands. Empty for the actions that leave it where it is.
    static func target(for item: FileItem, action: RuleAction,
                       calendar: Calendar = .current) -> String {
        switch action.kind {
        case .move, .copy:
            guard !action.destination.isEmpty else { return "" }
            var folder = action.destination
            if !action.subfolder.isEmpty {
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = action.subfolder
                // The file's OWN date, not today's: sorting last year's photographs into this
                // year's folder is the one thing such a rule must never do.
                let stamped = formatter.string(from: item.dateModified)
                if !stamped.isEmpty {
                    folder = (folder as NSString).appendingPathComponent(stamped)
                }
            }
            return (folder as NSString).appendingPathComponent(item.name)

        case .rename:
            let engine = RenameMaskEngine(calendar: calendar)
            let input = RenameMaskEngine.Input(
                path: item.path, name: item.name, isDirectory: item.isDirectory,
                modified: item.dateModified, created: item.dateCreated, size: item.size,
                width: nil, height: nil)
            var rule = RenameRule()
            rule.nameMask = action.nameMask
            rule.extMask = action.extMask
            guard let plan = engine.preview([input], rule: rule).first else { return "" }
            let folder = (item.path as NSString).deletingLastPathComponent
            return (folder as NSString).appendingPathComponent(plan.newName)

        case .unpack:
            // Beside the archive, in a folder named after it — the same place the panel's own
            // "unpack here" puts things.
            let folder = (item.path as NSString).deletingLastPathComponent
            let stem = RenameMaskEngine.splitName(item.name, isDirectory: false).stem
            return (folder as NSString).appendingPathComponent(stem.isEmpty ? item.name : stem)

        case .trash, .tag, .shelf:
            return ""
        }
    }

    // MARK: Reading the file

    private static func date(of item: FileItem, field: RuleCondition.Field) -> Date? {
        switch field {
        case .modified: return item.dateModified
        case .created:  return item.dateCreated
        case .added:    return item.dateAdded
        default:        return nil
        }
    }

    /// Tidy an extension list AS IT IS TYPED.
    ///
    /// The moment a separator is typed the piece before it is finished, so it gets its dot and
    /// its comma and the person carries on with the next one: "jpg jpeg" becomes ".jpg, .jpeg"
    /// by itself. The piece still being typed is left exactly as typed — rewriting a half-typed
    /// word under the cursor is how a field starts fighting the person using it.
    static func tidiedExtensions(_ text: String) -> String {
        let separators = CharacterSet(charactersIn: ",; ")
        guard let last = text.unicodeScalars.last, separators.contains(last) else { return text }
        let finished = normalizedExtensions(text)
        return finished.isEmpty ? "" : finished + ", "
    }

    /// Every extension list in every rule put in its finished shape. Nothing else is touched —
    /// a name mask means what it says, spaces and all.
    static func tidied(_ rules: [FolderRule]) -> [FolderRule] {
        rules.map { rule in
            var rule = rule
            for index in rule.conditions.indices where rule.conditions[index].field == .ext {
                rule.conditions[index].text = normalizedExtensions(rule.conditions[index].text)
            }
            return rule
        }
    }

    /// The same list in its FINISHED shape, every piece included.
    ///
    /// Used when a condition is switched over to "Extension" with something already typed in it:
    /// the words were written while the field meant something else, so there is no half-typed
    /// piece to protect and the whole line can be put in order at once.
    static func normalizedExtensions(_ text: String) -> String {
        let pieces = list(text)      // strips dots, spaces, repeats
        guard !pieces.isEmpty else { return "" }
        return pieces.map { ".\($0.lowercased())" }.joined(separator: ", ")
    }

    /// An extension without its dot, lowercased. The one place that knows the listing spells it
    /// ".zip" while every rule, list and comparison here works in bare "zip".
    static func bareExtension(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
    }

    /// "jpg, png png" → ["jpg", "png"]. Commas and spaces both separate, and a leading dot on an
    /// extension is forgiven because everyone types one.
    static func list(_ text: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }) {
            let cleaned = piece.trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }
}

// MARK: - Where the rules are kept

/// The rules themselves, as JSON in the preferences.
///
/// Order matters and is the person's own: the first rule that matches a file takes it, so the
/// list is kept exactly as it was arranged rather than sorted by name behind their back.
final class FolderRuleStore {
    static let defaultsKey = "fcxl.folderRules"
    static let shared = FolderRuleStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func all() -> [FolderRule] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([FolderRule].self, from: data) else { return [] }
        return list
    }

    func replaceAll(_ rules: [FolderRule]) {
        // Tidied on the way in, not on the way out: the last extension typed never met a
        // separator, so it never got its dot — and nobody should have to type a trailing comma
        // to make a saved rule look finished. Every road to saving passes through here.
        guard let data = try? JSONEncoder().encode(FolderRules.tidied(rules)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// The rules that are switched on, in order — what an "apply to this folder" actually runs.
    func active() -> [FolderRule] { all().filter(\.isEnabled) }
}
