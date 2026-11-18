import Foundation
import zlib

/// Сжатый SVG (.svgz): тот же рисунок SVG, упакованный gzip. Так сохраняют Inkscape («Сжатый
/// SVG») и Illustrator («SVG Compressed»).
///
/// Система такой файл рисунком считает (тип public.svg-image), но не распаковывает: быстрый
/// просмотр показывал вместо картинки страницу «This page contains the following errors:
/// Encoding error», а текстом шли байты архива. Здесь файл распаковывается во временную копию
/// с расширением .svg, и на показ — рисунком, текстом, эскизом — отдаётся она. Сам файл не
/// трогается; HEX показывает его таким, как он лежит на диске.
enum CompressedSVG {
    /// Больше не распаковываем: маленький файл может разворачиваться в гигабайты.
    static let outputLimit = 64 * 1024 * 1024
    /// И больше не читаем: рисунков такого размера не бывает, а читать придётся целиком.
    static let inputLimit: UInt64 = 32 * 1024 * 1024

    static func isCompressed(_ path: String) -> Bool {
        (path as NSString).pathExtension.caseInsensitiveCompare("svgz") == .orderedSame
    }

    /// Распаковать gzip. nil — не gzip, оборван или разворачивается больше предела.
    static func unpack(_ data: Data, limit: Int = outputLimit) -> Data? {
        guard data.count > 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }
        var stream = z_stream()
        // 16 + MAX_WBITS — разбирать заголовок и хвост gzip, а не голый поток.
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { inflateEnd(&stream) }

        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var output = Data()
        return data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data? in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                // Оборванный файл: распаковщику нужны ещё байты, а их нет (Z_BUF_ERROR).
                guard status == Z_OK || status == Z_STREAM_END else { return nil }
                output.append(contentsOf: buffer[0..<(chunk - Int(stream.avail_out))])
                guard output.count <= limit else { return nil }
                if status == Z_STREAM_END { return output }
            }
        }
    }

    // MARK: - Копия на показ

    private static let lock = NSLock()
    private static var copies: [String: (stamp: TimeInterval, size: UInt64, url: URL)] = [:]

    /// Своя папка у каждого запуска: рядом могут работать и установленная программа, и
    /// проверочная копия. Папки запусков, которых уже нет, убираются при первом обращении.
    private static let folder: URL = {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TotumSVGPreview", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let pid = pid_t(name), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        let own = root.appendingPathComponent(String(getpid()), isDirectory: true)
        try? fm.createDirectory(at: own, withIntermediateDirectories: true)
        return own
    }()

    /// Что отдать на показ: у сжатого SVG — распакованную копию, у любого другого файла — его
    /// самого. Не распаковался (битый, не сжат вовсе, слишком велик) — тоже сам файл: несжатый
    /// SVG под именем .svgz система читает и так.
    static func previewURL(for url: URL) -> URL {
        guard isCompressed(url.path) else { return url }
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return url }
        let stamp = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        lock.lock()
        let known = copies[url.path]
        lock.unlock()
        if let known, known.stamp == stamp, known.size == size, fm.fileExists(atPath: known.url.path) {
            return known.url
        }

        let fresh = size <= inputLimit ? makeCopy(of: url) : nil
        lock.lock()
        let old = copies[url.path]
        if let fresh {
            copies[url.path] = (stamp, size, fresh)
        } else {
            copies[url.path] = nil
        }
        lock.unlock()
        // Прежняя копия этого файла больше не нужна.
        if let old, old.url != fresh { try? fm.removeItem(at: old.url.deletingLastPathComponent()) }
        return fresh ?? url
    }

    static func previewPath(for path: String) -> String {
        isCompressed(path) ? previewURL(for: URL(fileURLWithPath: path)).path : path
    }

    /// Копия лежит в своей папке и носит имя файла — его показывает заголовок быстрого просмотра.
    private static func makeCopy(of url: URL) -> URL? {
        guard let packed = try? Data(contentsOf: url, options: .mappedIfSafe),
              let plain = unpack(packed) else { return nil }
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".svg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try plain.write(to: copy, options: .atomic)
            return copy
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    /// Программа закрывается — копии убрать.
    static func removeCopies() {
        lock.lock()
        copies = [:]
        lock.unlock()
        try? FileManager.default.removeItem(at: folder)
    }
}
