import Darwin
import Foundation

/// Признак карантина скачанного архива — и перенос его на всё, что из архива вынуто.
///
/// Система ставит `com.apple.quarantine` на файл, пришедший из сети, и по нему спрашивает
/// человека, прежде чем запустить такую программу. Вынутое из архива — то же скачанное: без
/// признака программа или скрипт из архива запустились бы без вопроса. Системная распаковка
/// признак переносит; здесь то же самое.
struct ArchiveQuarantine {
    static let attribute = "com.apple.quarantine"

    /// Значение признака, как оно записано у архива, байт в байт.
    private let value: [UInt8]

    /// `nil`, когда архив не в карантине: переносить нечего, и записи перебирать незачем.
    init?(archivePath: String) {
        // Сквозь ссылку: содержимое берётся из самого архива, а не из ссылки на него.
        let size = getxattr(archivePath, Self.attribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(archivePath, Self.attribute, &bytes, size, 0, 0)
        guard read > 0 else { return nil }
        value = Array(bytes.prefix(read))
    }

    // MARK: - Распаковка целиком

    /// Ведёт распаковку целиком и переносит признак на вынутое.
    ///
    /// `entries` зовётся только для архива в карантине и до распаковки: без перезаписи ядро
    /// пропускает уже лежащие файлы, а после неё старый файл от нового не отличить. Ошибка
    /// перечисления — ошибка всей распаковки: без списка вынутое осталось бы без признака, а
    /// «Отмена», нажатая в это время, пропала бы (начало распаковки её сбрасывает).
    static func extracting(_ archivePath: String, into destination: String,
                           overwriteExisting: Bool,
                           entries: () throws -> [ArchiveListEntry],
                           extract: () throws -> Void) throws {
        guard let quarantine = ArchiveQuarantine(archivePath: archivePath) else {
            try extract()
            return
        }
        let listed = try entries()
        let untouched = overwriteExisting
            ? [] : quarantine.filesInPlace(of: listed, under: destination)
        // И при отмене, и при ошибке: вышедшая часть — тоже из архива.
        defer { quarantine.mark(entries: listed, under: destination, except: untouched) }
        try extract()
    }

    /// Файлы, уже лежащие на местах записей: распаковка без перезаписи их пропустит, они не из
    /// архива. Снимается до распаковки — после неё старый файл от нового не отличить.
    func filesInPlace(of entries: [ArchiveListEntry], under root: String) -> Set<String> {
        var present: Set<String> = []
        for entry in entries where !entry.isDirectory {
            guard let parts = Self.components(of: entry.path) else { continue }
            let path = Self.join(root, parts)
            var info = stat()
            if lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR { present.insert(path) }
        }
        return present
    }

    /// После распаковки целиком: признак на место каждой записи и на папки по пути к ней.
    /// Папка приёмника может быть обжитой, поэтому помечается не всё, что в ней лежит, а только
    /// названное архивом; `untouched` — то, что распаковка пропустила.
    func mark(entries: [ArchiveListEntry], under root: String, except untouched: Set<String> = []) {
        guard let base = Self.resolved(root) else { return }
        var inside: [String: Bool] = [:]
        var done: Set<String> = []
        for entry in entries {
            guard let parts = Self.components(of: entry.path) else { continue }
            var current = root
            for part in parts {
                // Родитель должен на деле лежать в приёмнике: сквозь ссылку наружу ядро не
                // пишет, и чужое по ту сторону ссылки не помечается.
                let allowed = inside[current] ?? Self.isInside(current, base: base)
                inside[current] = allowed
                guard allowed else { break }
                current = (current as NSString).appendingPathComponent(part)
                if done.insert(current).inserted, !untouched.contains(current) {
                    apply(to: current)
                }
            }
        }
    }

    // MARK: - Одна запись

    /// После извлечения одной записи — файла или папки целиком: признак на всё вынутое и на
    /// папки по пути к нему.
    func mark(extracted entryPath: String, under root: String) {
        guard let base = Self.resolved(root), let parts = Self.components(of: entryPath) else {
            return
        }
        var current = root
        for part in parts {
            guard Self.isInside(current, base: base) else { return }
            current = (current as NSString).appendingPathComponent(part)
            apply(to: current)
        }
        markContents(of: current)
    }

    private func markContents(of folder: String) {
        var info = stat()
        // Только настоящая папка: сквозь ссылку вглубь не ходим.
        guard lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              let walker = FileManager.default.enumerator(atPath: folder) else { return }
        for case let relative as String in walker {
            apply(to: (folder as NSString).appendingPathComponent(relative))
        }
    }

    // MARK: - Сам признак

    /// Ставит признак на саму вещь, не на цель ссылки. Чего нет — того нет: запись могла не
    /// выйти из-за отмены или ошибки.
    private func apply(to path: String) {
        if setxattr(path, Self.attribute, value, value.count, 0, XATTR_NOFOLLOW) == 0 { return }
        guard errno == EACCES || errno == EPERM else { return }
        // Файл или папка только для чтения: признак пишется лишь с правом записи. Право даётся
        // на миг и возвращается, как было.
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR, info.st_uid == geteuid() else { return }
        let mode = info.st_mode & 0o7777
        guard chmod(path, mode | S_IWUSR) == 0 else { return }
        _ = setxattr(path, Self.attribute, value, value.count, 0, XATTR_NOFOLLOW)
        _ = chmod(path, mode)
    }

    // MARK: - Пути

    /// Части пути записи; `nil` — пусто или с «..»: такое ядро не распаковывает.
    private static func components(of entryPath: String) -> [String]? {
        let parts = entryPath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts
    }

    private static func join(_ root: String, _ parts: [String]) -> String {
        parts.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
    }

    private static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func isInside(_ folder: String, base: String) -> Bool {
        guard let real = resolved(folder) else { return false }
        return real == base || real.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
