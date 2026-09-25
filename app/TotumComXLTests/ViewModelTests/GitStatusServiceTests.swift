import AppKit
import Foundation
import XCTest

@testable import TotumComXLApp

/// Reading Git. The letters and the folding are pure text work and are checked as such; the
/// last two tests build a real repository in a temporary folder, because a reader of `git` is
/// only right if it is right about what `git` actually prints.
final class GitStatusServiceTests: XCTestCase {

    // MARK: - The letters

    func testStatusLetters() {
        XCTAssertEqual(GitStatusService.mark(fromCode: "??"), .untracked)
        XCTAssertEqual(GitStatusService.mark(fromCode: "!!"), .ignored)
        XCTAssertEqual(GitStatusService.mark(fromCode: " M"), .modified, "изменён, но не в индексе")
        XCTAssertEqual(GitStatusService.mark(fromCode: "M "), .modified, "изменён и в индексе")
        XCTAssertEqual(GitStatusService.mark(fromCode: "MM"), .modified)
        XCTAssertEqual(GitStatusService.mark(fromCode: "A "), .added)
        XCTAssertEqual(GitStatusService.mark(fromCode: "R "), .renamed)
        XCTAssertEqual(GitStatusService.mark(fromCode: " D"), .deleted)
        XCTAssertEqual(GitStatusService.mark(fromCode: "UU"), .conflicted)
        XCTAssertEqual(GitStatusService.mark(fromCode: "AA"), .conflicted, "оба добавили своё")
        XCTAssertEqual(GitStatusService.mark(fromCode: "DU"), .conflicted)
        XCTAssertNil(GitStatusService.mark(fromCode: "  "), "чистый файл не помечается")
        XCTAssertNil(GitStatusService.mark(fromCode: "M"), "обрезанный код — не код")
    }

    /// A folder wears the strongest thing inside it, so the order has to hold.
    func testMarksAreOrderedByImportance() {
        XCTAssertGreaterThan(GitMark.conflicted, GitMark.modified)
        XCTAssertGreaterThan(GitMark.modified, GitMark.untracked)
        XCTAssertGreaterThan(GitMark.untracked, GitMark.ignored)
    }

    // MARK: - Reading the output

    func testParsingNulSeparatedRecords() {
        let raw = " M src/main.swift\0?? new.txt\0!! build/\0"
        let parsed = GitStatusService.parse(porcelain: raw)
        XCTAssertEqual(parsed["src/main.swift"], .modified)
        XCTAssertEqual(parsed["new.txt"], .untracked)
        XCTAssertEqual(parsed["build/"], .ignored, "целую игнорируемую папку git сворачивает")
    }

    /// A rename prints TWO records: the new name, then the old one. Reading the old one as a
    /// record of its own would put a mark on a file that is no longer there.
    func testRenameSwallowsTheOldName() {
        let raw = "R  новое.txt\0старое.txt\0?? третий.txt\0"
        let parsed = GitStatusService.parse(porcelain: raw)
        XCTAssertEqual(parsed["новое.txt"], .renamed)
        XCTAssertNil(parsed["старое.txt"], "старого имени на диске нет")
        XCTAssertEqual(parsed["третий.txt"], .untracked, "разбор не сбился со счёта")
    }

    func testStrongerReadingWins() {
        let raw = " M x.txt\0UU x.txt\0"
        XCTAssertEqual(GitStatusService.parse(porcelain: raw)["x.txt"], .conflicted)
    }

    // MARK: - Folding onto the rows of one folder

    func testDeepChangesFoldIntoTheFolderRow() {
        let statuses: [String: GitMark] = [
            "app/views/panel/list.swift": .modified,
            "app/views/panel/row.swift": .conflicted,
            "readme.md": .untracked,
            "docs/plan.md": .modified,
        ]
        let folded = GitStatusService.fold(statuses, repoRoot: "/repo", directory: "/repo")
        XCTAssertEqual(folded["/repo/app"], .conflicted, "папка носит сильнейшее из того, что внутри")
        XCTAssertEqual(folded["/repo/readme.md"], .untracked)
        XCTAssertEqual(folded["/repo/docs"], .modified)
        XCTAssertEqual(folded.count, 3, "и ничего сверх строк этой папки")
    }

    func testFoldingInsideASubfolder() {
        let statuses: [String: GitMark] = [
            "app/views/panel/list.swift": .modified,
            "docs/plan.md": .untracked,
        ]
        let folded = GitStatusService.fold(statuses, repoRoot: "/repo", directory: "/repo/app/views")
        XCTAssertEqual(folded, ["/repo/app/views/panel": .modified],
                       "чужие ветки дерева не попадают в эту папку")
    }

    func testFoldingOutsideTheRepositoryAnswersNothing() {
        XCTAssertTrue(GitStatusService.fold([" x": .modified], repoRoot: "/repo",
                                            directory: "/somewhere/else").isEmpty)
    }

    // MARK: - Which branch

    func testBranchFromHead() {
        XCTAssertEqual(GitStatusService.branchName(fromHead: "ref: refs/heads/main\n"), "main")
        XCTAssertEqual(GitStatusService.branchName(fromHead: "ref: refs/heads/feature/dxf\n"),
                       "feature/dxf", "косые черты — часть имени ветки")
        XCTAssertEqual(GitStatusService.branchName(fromHead: "0a74eb7c9f1d2e3a4b5c6d7e8f90112233445566"),
                       "0a74eb7", "отцепленная голова показывает начало коммита")
        XCTAssertNil(GitStatusService.branchName(fromHead: "  \n"))
    }

    /// A worktree and a submodule keep a FILE where a clone keeps a folder.
    func testGitDirectoryOfAWorktree() {
        XCTAssertEqual(
            GitStatusService.pointedGitDirectory("gitdir: /repo/.git/worktrees/dxf\n",
                                                 relativeTo: "/anywhere"),
            "/repo/.git/worktrees/dxf")
        XCTAssertEqual(
            GitStatusService.pointedGitDirectory("gitdir: ../.git/modules/core",
                                                 relativeTo: "/repo/core"),
            "/repo/.git/modules/core", "относительный путь считается от папки репозитория")
        XCTAssertNil(GitStatusService.pointedGitDirectory("что угодно", relativeTo: "/repo"))
    }

    // MARK: - Against a real repository

    private func makeRepository() throws -> String? {
        guard let git = GitStatusService.gitExecutable,
              FileManager.default.isExecutableFile(atPath: git) else {
            return nil     // no git on this machine: the panel simply shows no marks
        }
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = GitStatusService.run(["init", "--initial-branch=main"], at: root)
        _ = GitStatusService.run(["config", "user.email", "t@example.com"], at: root)
        _ = GitStatusService.run(["config", "user.name", "Тест"], at: root)
        return root
    }

    func testMarksOfARealRepository() throws {
        guard let root = try makeRepository() else {
            throw XCTSkip("git не установлен")
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = { (name: String) in (root as NSString).appendingPathComponent(name) }
        try FileManager.default.createDirectory(atPath: file("исходники"),
                                                withIntermediateDirectories: true)
        try "было\n".write(toFile: file("исходники/главный.txt"), atomically: true, encoding: .utf8)
        try "старьё\n".write(toFile: file("прежний.txt"), atomically: true, encoding: .utf8)
        try "мусор/\n".write(toFile: file(".gitignore"), atomically: true, encoding: .utf8)
        _ = GitStatusService.run(["add", "."], at: root)
        _ = GitStatusService.run(["commit", "-m", "первый"], at: root)

        // Now make one of each kind of change.
        try "стало\n".write(toFile: file("исходники/главный.txt"), atomically: true, encoding: .utf8)
        try "новьё\n".write(toFile: file("новый.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: file("прежний.txt"))
        try FileManager.default.createDirectory(atPath: file("мусор"),
                                                withIntermediateDirectories: true)
        try "хлам\n".write(toFile: file("мусор/х.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitStatusService.repositoryRoot(for: file("исходники")),
                       (root as NSString).standardizingPath, "репозиторий находится снизу вверх")
        XCTAssertEqual(GitStatusService.headBranch(repoRoot: root), "main")
        XCTAssertTrue(GitStatusService.isDirty(repoRoot: root))

        let marks = GitStatusService.marks(inDirectory: root, repoRoot: root)
        XCTAssertEqual(marks[file("исходники")], .modified, "папка носит правку изнутри себя")
        XCTAssertEqual(marks[file("новый.txt")], .untracked)
        XCTAssertEqual(marks[file("прежний.txt")], .deleted)
        XCTAssertEqual(marks[file("мусор")], .ignored)
        XCTAssertNil(marks[file(".gitignore")], "неизменённый файл ничем не помечен")

        // And inside the subfolder the row is the file itself, not its folder.
        let inner = GitStatusService.marks(inDirectory: file("исходники"), repoRoot: root)
        XCTAssertEqual(inner[file("исходники/главный.txt")], .modified)
    }

    func testACleanRepositoryIsNotDirty() throws {
        guard let root = try makeRepository() else { throw XCTSkip("git не установлен") }
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "раз\n".write(toFile: (root as NSString).appendingPathComponent("а.txt"),
                          atomically: true, encoding: .utf8)
        _ = GitStatusService.run(["add", "."], at: root)
        _ = GitStatusService.run(["commit", "-m", "всё"], at: root)
        XCTAssertFalse(GitStatusService.isDirty(repoRoot: root))
        XCTAssertTrue(GitStatusService.marks(inDirectory: root, repoRoot: root).isEmpty)
    }
}

/// The gutter the marks are drawn in. Its whole job is to be the same width on every row of a
/// folder, so the letters line up under one another.
final class GitBadgeChipTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 12)

    func testNothingToSayTakesNoSpace() {
        XCTAssertEqual(GitBadgeChip.width(GitBadge(), font: font), 0)
        XCTAssertNil(GitBadgeChip.image(GitBadge(), font: font))
        XCTAssertEqual(GitBadgeChip.gutterWidth([GitBadge(), GitBadge()], font: font), 0,
                       "папка без единой метки не отдаёт под столбец ни точки")
    }

    /// The gutter costs the names one letter and no more. A branch name in it would push every
    /// row of a folder aside for the sake of the one repository standing in it.
    func testGutterHoldsLettersOnlyAndBranchesRideAtTheEnd() {
        let letter = GitBadge(mark: .modified)
        let branch = GitBadge(mark: nil, branch: "feature/git-badges", dirty: true)
        let gutter = GitBadgeChip.gutterWidth([letter, branch], font: font)
        XCTAssertEqual(gutter, GitBadgeChip.gutterWidth([letter], font: font), accuracy: 0.01,
                       "ветка на ширину столбца не влияет")
        XCTAssertLessThan(gutter, GitBadgeChip.branchWidth(branch, font: font),
                          "столбец узкий, а имя ветки длинное")
        XCTAssertEqual(GitBadgeChip.branchWidth(letter, font: font), 0,
                       "у обычного файла ветки нет и места она не занимает")
        XCTAssertNotNil(GitBadgeChip.branchImage(branch, font: font))
        XCTAssertNil(GitBadgeChip.branchImage(letter, font: font))
        XCTAssertNotNil(GitBadgeChip.markImage(.modified, font: font))
    }

    /// Every state has to be drawable and tellable apart — a mark nobody can read is not a mark.
    func testEveryStateDrawsAndExplainsItself() {
        for mark in GitMark.allCases {
            let badge = GitBadge(mark: mark)
            XCTAssertNotNil(GitBadgeChip.image(badge, font: font), "\(mark) не нарисовался")
            XCTAssertGreaterThan(GitBadgeChip.width(badge, font: font), 0)
            XCTAssertFalse(GitBadgeChip.help(badge)?.isEmpty ?? true, "\(mark) без пояснения")
        }
        let letters = Set(GitMark.allCases.map(\.letter))
        XCTAssertEqual(letters.count, GitMark.allCases.count, "две метки одной буквой не пишутся")
    }

    func testARepositoryShowsItsBranchAndWhetherItIsClean() {
        let dirty = GitBadge(mark: nil, branch: "main", dirty: true)
        XCTAssertTrue(GitBadgeChip.text(dirty, font: font)?.string.contains("main") ?? false)
        XCTAssertGreaterThan(GitBadgeChip.branchWidth(dirty, font: font),
                             GitBadgeChip.branchWidth(GitBadge(mark: nil, branch: "main"),
                                                      font: font),
                             "точка «есть несохранённое» занимает своё место")
    }
}
