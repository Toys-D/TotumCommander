import Foundation

/// What Git says about one line of the panel.
///
/// The order is the order of importance: a folder wears the strongest mark of everything inside
/// it, so a repository with one conflict says "conflict" rather than "modified".
enum GitMark: Int, Comparable, CaseIterable {
    case ignored, untracked, added, renamed, modified, deleted, conflicted

    static func < (lhs: GitMark, rhs: GitMark) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The single character shown in the panel's Git gutter. Git's own letters, because anyone
    /// who has typed `git status` already reads them.
    var letter: String {
        switch self {
        case .ignored:    return "·"     // nothing to see: git was told to look away
        case .untracked:  return "?"
        case .added:      return "A"
        case .renamed:    return "R"
        case .modified:   return "M"
        case .deleted:    return "D"
        case .conflicted: return "!"
        }
    }

    var localizedName: String { L("git.mark.\(String(describing: self))") }
}

/// A repository, a file inside one, or a folder holding changes.
struct GitBadge: Equatable {
    /// The state of this entry, or of the strongest change inside it when it is a folder.
    var mark: GitMark?
    /// Set only on a folder that IS a repository: the branch it is on, or a short commit id
    /// when the head is detached.
    var branch: String?
    /// Set with `branch`: the repository has changes that are not committed.
    var dirty = false

    var isEmpty: Bool { mark == nil && branch == nil }
}

/// Reading Git's opinion of a folder.
///
/// The answers come from the installed `git` rather than from our own reading of `.git`. A
/// repository is not a file format so much as a set of rules — the ignore files, the index,
/// submodules, worktrees, sparse checkouts — and the only reader that is right about all of
/// them is the one the person also uses in the terminal. What we do keep for ourselves is the
/// cheap part: finding the repository, and reading which branch it is on, both of which are a
/// couple of file reads and would otherwise cost a process each.
enum GitStatusService {

    // MARK: - Finding the repository

    /// The repository a folder belongs to, or nil. Walks up looking for `.git`, which is a
    /// folder in a normal clone and a FILE in a worktree or a submodule — both count.
    static func repositoryRoot(for directory: String) -> String? {
        var path = (directory as NSString).standardizingPath
        let fileManager = FileManager.default
        // A path can only have so many components; the loop is bounded by the walk itself, but
        // a symlinked cycle would not end without this.
        for _ in 0..<128 {
            guard !path.isEmpty, path != "/" else { break }
            if fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                return path
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path else { break }
            path = parent
        }
        // The root of the disk itself can hold a repository, unusual as that is.
        if fileManager.fileExists(atPath: "/.git"), directory.hasPrefix("/") { return "/" }
        return nil
    }

    /// Is this folder the top of a repository — the thing that carries a branch name?
    static func isRepositoryRoot(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    /// Where the repository keeps its files. Usually `<root>/.git`, but a worktree or submodule
    /// puts a one-line file there pointing at the real place.
    static func gitDirectory(repoRoot: String) -> String? {
        let dotGit = (repoRoot as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return dotGit }
        guard let line = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
        return pointedGitDirectory(line, relativeTo: repoRoot)
    }

    /// `gitdir: ../.git/worktrees/x` — the path may be relative to the repository folder.
    static func pointedGitDirectory(_ line: String, relativeTo repoRoot: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("gitdir:") else { return nil }
        let target = String(text.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") { return (target as NSString).standardizingPath }
        return ((repoRoot as NSString).appendingPathComponent(target) as NSString)
            .standardizingPath
    }

    /// The branch a repository is on. A detached head has no branch, so it answers with the
    /// short commit id instead — which is what the person needs to see in that state.
    static func headBranch(repoRoot: String) -> String? {
        guard let gitDir = gitDirectory(repoRoot: repoRoot) else { return nil }
        let head = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let text = try? String(contentsOfFile: head, encoding: .utf8) else { return nil }
        return branchName(fromHead: text)
    }

    /// `ref: refs/heads/main` → `main`; a bare commit id → its first seven characters.
    static func branchName(fromHead text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("ref:") {
            let reference = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            guard !reference.isEmpty else { return nil }
            // Branch names may hold slashes (feature/x), so only the known prefix is removed.
            if reference.hasPrefix("refs/heads/") {
                return String(reference.dropFirst("refs/heads/".count))
            }
            return (reference as NSString).lastPathComponent
        }
        return String(line.prefix(7))
    }

    // MARK: - Reading the state

    /// Git's own status letters for one entry.
    ///
    /// Two columns: what is staged, then what is not. Only the strongest thing they say is
    /// kept — the panel has one character to say it in.
    static func mark(fromCode code: String) -> GitMark? {
        let text = String(code.prefix(2))
        guard text.count == 2 else { return nil }
        if text == "??" { return .untracked }
        if text == "!!" { return .ignored }
        let staged = text.first!, unstaged = text.last!
        // Both sides claiming the same change, or either side saying "unmerged", is a conflict.
        if staged == "U" || unstaged == "U" || text == "AA" || text == "DD" { return .conflicted }
        if staged == "D" || unstaged == "D" { return .deleted }
        if staged == "R" || staged == "C" { return .renamed }
        if staged == "A" { return .added }
        if staged == "M" || unstaged == "M" || staged == "T" || unstaged == "T" { return .modified }
        return nil
    }

    /// `git status --porcelain -z` in full: NUL-separated records, each `XY <path>`, and a
    /// rename carries the old path as an extra record straight after the new one.
    ///
    /// Paths come back relative to the repository, and — because of `-z` — literal: no quoting,
    /// no escapes, so a Cyrillic or a spaced name arrives as itself.
    static func parse(porcelain raw: String) -> [String: GitMark] {
        var found: [String: GitMark] = [:]
        let records = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count > 3 else { continue }
            let code = String(record.prefix(2))
            guard let mark = mark(fromCode: code) else { continue }
            // Between the code and the path is one space.
            let path = String(record.dropFirst(3))
            guard !path.isEmpty else { continue }
            if mark == .renamed, index < records.count {
                index += 1      // the old name, which no longer exists on disk
            }
            // A path can appear twice (staged and not); the stronger reading wins.
            if let existing = found[path], existing >= mark { continue }
            found[path] = mark
        }
        return found
    }

    /// Turn repository-relative answers into marks for the rows of ONE folder.
    ///
    /// Everything Git names deeper than the folder is folded into the folder it sits in: a panel
    /// row for `src` says "modified" because something under `src` is. Git already collapses
    /// whole untracked and ignored folders into a single `name/` entry, and that folds the
    /// same way.
    static func fold(_ statuses: [String: GitMark], repoRoot: String,
                     directory: String) -> [String: GitMark] {
        let root = (repoRoot as NSString).standardizingPath
        let folder = (directory as NSString).standardizingPath
        // The folder's own path inside the repository, "" at the top.
        var prefix = ""
        if folder != root {
            guard folder.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return [:] }
            prefix = String(folder.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
            if !prefix.isEmpty { prefix += "/" }
        }

        var found: [String: GitMark] = [:]
        for (relative, mark) in statuses {
            guard relative.hasPrefix(prefix) else { continue }
            let rest = String(relative.dropFirst(prefix.count))
            guard !rest.isEmpty else { continue }
            let child = rest.split(separator: "/", maxSplits: 1,
                                   omittingEmptySubsequences: true).first.map(String.init)
            guard let child, !child.isEmpty else { continue }
            let path = (folder as NSString).appendingPathComponent(child)
            if let existing = found[path], existing >= mark { continue }
            found[path] = mark
        }
        return found
    }

    // MARK: - Asking git

    /// Run git and hand back what it printed, or nil when it could not run at all.
    ///
    /// A missing git is not an error to shout about: the panel simply shows no marks, exactly as
    /// it did before this feature existed.
    static func run(_ arguments: [String], at directory: String, timeout: TimeInterval = 10)
        -> String? {
        guard FileManager.default.isExecutableFile(atPath: gitExecutable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        // Git reads the user's config for colours, pagers and hooks; none of that helps a
        // program reading its output, and a pager would hang us.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_PAGER"] = "cat"
        environment["GIT_OPTIONAL_LOCKS"] = "0"   // never take the index lock just to look
        environment["LC_ALL"] = "C"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }

        // Read while it runs: a full pipe buffer stops the child, and a big repository prints
        // far more than one buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// Where git lives. The command-line tools put it here; anything else (Homebrew, Xcode's
    /// own copy) is reached through this same stub.
    static let gitExecutable = "/usr/bin/git"

    /// Marks for the rows of one folder, straight from git.
    static func marks(inDirectory directory: String, repoRoot: String) -> [String: GitMark] {
        // Scoped to the folder being shown: a status of the whole repository would read the
        // entire working tree to answer about twenty rows.
        let raw = run(["status", "--porcelain=v1", "-z", "--ignored",
                       "--untracked-files=normal", "--", "."], at: directory)
        guard let raw else { return [:] }
        // Paths come back relative to the REPOSITORY even when git ran inside a subfolder.
        return fold(parse(porcelain: raw), repoRoot: repoRoot, directory: directory)
    }

    /// Does this repository hold anything uncommitted? Asked without listing untracked files,
    /// which is the expensive part and not what the answer turns on.
    static func isDirty(repoRoot: String) -> Bool {
        let raw = run(["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
                      at: repoRoot)
        guard let raw else { return false }
        return !raw.isEmpty
    }
}
