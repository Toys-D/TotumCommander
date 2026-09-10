import AppKit
import Foundation
import PDFKit

/// Renders PostScript / EPS to a bitmap using Ghostscript.
///
/// macOS itself cannot do this any more: Apple removed the PostScript rasteriser in
/// 10.15 for security reasons, so Quick Look shows nothing for .eps/.ps on macOS 15.
/// Ghostscript is shipped inside our bundle, so the user installs nothing.
///
/// Ghostscript runs as a SEPARATE PROCESS on purpose, not as a linked library:
/// PostScript is a full programming language and a malformed (or hostile) file can
/// loop forever or crash the interpreter. A child process can be killed on a timeout;
/// an in-process interpreter doing the same would freeze the whole app. `-dSAFER`
/// additionally sandboxes the interpreter so a file cannot read or write the disk.
enum PostScriptRenderer {

    /// Where Ghostscript lives once bundled, and the dev fallbacks used before/outside a build.
    private static var executableURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Ghostscript/bin/gs")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for path in ["/opt/homebrew/bin/gs", "/usr/local/bin/gs", "/usr/bin/gs"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Ghostscript needs its Resource tree (init files + the base 35 fonts) at runtime;
    /// without it the interpreter cannot even start. Bundled copy first, Homebrew second.
    private static var resourceRoots: [String] {
        var roots: [String] = []
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Ghostscript/share/ghostscript/Resource")
        if FileManager.default.fileExists(atPath: bundled.path) { roots.append(bundled.path) }
        if roots.isEmpty {
            // Dev fallback: whatever Homebrew has installed.
            let base = "/opt/homebrew/share/ghostscript"
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: base) {
                for v in versions.sorted().reversed() {
                    let p = "\(base)/\(v)/Resource"
                    if FileManager.default.fileExists(atPath: p) { roots.append(p); break }
                }
            }
            let direct = "\(base)/Resource"
            if roots.isEmpty, FileManager.default.fileExists(atPath: direct) { roots.append(direct) }
        }
        return roots
    }

    /// Цветовые профили рядом со встроенным Ghostscript, если они там есть.
    ///
    /// Замер на нашей отрисовке разницы не дал — CMYK выходит побайтово одинаково с ними и
    /// без них, — но файл, который ССЫЛАЕТСЯ на профиль, без них рисовать нечем, и вместо
    /// цвета получится подстановка наугад.
    private static var iccProfilesDir: String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Ghostscript/share/ghostscript/iccprofiles")
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled.path : nil
    }

    /// Доводы про цвет, которые получает Ghostscript. Отдельной функцией — чтобы проверялось
    /// тестом: путь должен кончаться косой чертой, иначе Ghostscript его не примет.
    nonisolated static func colourArguments(iccProfilesDir dir: String?) -> [String] {
        guard let dir, !dir.isEmpty else { return [] }
        return ["-sICCProfilesDir=" + (dir.hasSuffix("/") ? dir : dir + "/")]
    }

    static var isAvailable: Bool { executableURL != nil }

    /// Longest edge we aim for, in pixels. Ghostscript hands back a bitmap, so this is what
    /// decides how far the user can zoom before it looks jagged. 3500 keeps normal design
    /// files crisp well past 100%; the resolution is capped so an A0 poster can't blow up
    /// into a hundred-megapixel image.
    static let baseLongEdgePixels: Double = 3500
    /// Ceiling for the zoom re-render. 8000px on the long edge is ~2.3x the base detail and
    /// still a sane bitmap (an 8000x3600 RGBA buffer is ~115 MB at worst, and most artwork is
    /// far less square than that).
    static let maxLongEdgePixels: Double = 8000
    private static let minDPI: Double = 150
    private static let maxDPI: Double = 1200

    /// Page size in PostScript points — to pick a resolution: a business card and a poster
    /// must not be rasterised at the same dpi.
    ///
    /// Три дороги, от дешёвой к дорогой. Современный `.ai` — это PDF: PDFKit отдаёт размер
    /// страницы за миллисекунды. У EPS размер записан в шапке (`%%BoundingBox`) — читаются
    /// первые килобайты. И только когда ни того ни другого нет — устройство `bbox`
    /// Ghostscript, которое исполняет весь файл: на одном настоящем `.ai` с картинкой
    /// внутри это заняло 48 секунд, и без предела просмотр выглядел так, будто не грузится
    /// вовсе. Предел есть: не успел — размер неизвестен, рендер идёт на 300 dpi.
    static func pageSizePoints(path: String, bboxTimeout: TimeInterval = 5) -> (w: Double, h: Double)? {
        if let size = pdfPageSize(path) { return size }
        if let size = dscBoundingBox(path) { return size }
        guard let gs = executableURL else { return nil }
        return bboxDevicePageSize(gs, path, timeout: bboxTimeout)
    }

    /// PDF под именем .ai (или настоящий PDF): размер первой страницы от PDFKit.
    private static func pdfPageSize(_ path: String) -> (w: Double, h: Double)? {
        guard let handle = FileHandle(forReadingAtPath: path),
              let head = try? handle.read(upToCount: 5), head == Data("%PDF-".utf8),
              let document = PDFDocument(url: URL(fileURLWithPath: path)),
              let page = document.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        return (Double(box.width), Double(box.height))
    }

    /// `%%HiResBoundingBox` или `%%BoundingBox` из шапки EPS — первые 64 КБ файла.
    private static func dscBoundingBox(_ path: String) -> (w: Double, h: Double)? {
        guard let handle = FileHandle(forReadingAtPath: path),
              let head = try? handle.read(upToCount: 65_536),
              let text = String(data: head, encoding: .isoLatin1) else { return nil }
        for key in ["%%HiResBoundingBox:", "%%BoundingBox:"] {
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where line.hasPrefix(key) {
                let n = line.dropFirst(key.count).split(separator: " ").compactMap { Double($0) }
                if n.count == 4, n[2] > n[0], n[3] > n[1] { return (n[2] - n[0], n[3] - n[1]) }
            }
        }
        return nil
    }

    private static func bboxDevicePageSize(_ gs: URL, _ path: String,
                                           timeout: TimeInterval) -> (w: Double, h: Double)? {
        var args = ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dFirstPage=1", "-dLastPage=1",
                    "-sDEVICE=bbox"]
        for root in resourceRoots { args.append("-I\(root)/Init"); args.append("-I\(root)") }
        args.append(contentsOf: colourArguments(iccProfilesDir: iccProfilesDir))
        args.append(path)

        let task = Process()
        task.executableURL = gs
        task.arguments = args
        let pipe = Pipe()
        task.standardError = pipe          // bbox reports on stderr
        task.standardOutput = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        // Читать до конца нельзя: убитый по пределу процесс канал не закроет, и мы бы
        // ждали вечно. Ждём с пределом, потом забираем, что накопилось.
        guard waitOrKill(task, timeout: timeout) else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("%%HiResBoundingBox:") {
            let n = line.dropFirst("%%HiResBoundingBox:".count)
                .split(separator: " ").compactMap { Double($0) }
            if n.count == 4, n[2] > n[0], n[3] > n[1] { return (n[2] - n[0], n[3] - n[1]) }
        }
        return nil
    }

    /// Дождаться процесса или убить его по пределу. PostScript — язык, и файл может крутиться
    /// вечно; отдельный процесс тем и хорош, что его можно снять.
    /// - Returns: true, если процесс завершился сам.
    private static func waitOrKill(_ task: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if task.isRunning {
            task.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            return false
        }
        return true
    }

    /// Rasterise the first page of an EPS/PS/AI file. Returns nil if Ghostscript is missing,
    /// the file is not renderable, or the render exceeded `timeout` (the process is killed).
    /// Blocking — call it off the main thread.
    ///
    /// `dpi` is picked from the page size when not given, so small artwork is rendered with
    /// enough pixels to survive zooming instead of turning into jagged edges.
    /// `targetLongEdge` is how many pixels we want along the page's longest side. The viewer
    /// raises it when the user zooms in, so the bitmap gains real detail instead of being
    /// stretched. Resolution is derived from it and clamped, so a poster and a business card
    /// both end up with a sane bitmap.
    static func renderToImage(path: String,
                              targetLongEdge: Double = baseLongEdgePixels,
                              timeout: TimeInterval = 20) -> NSImage? {
        guard let gs = executableURL else { return nil }

        let wanted = min(max(targetLongEdge, 800), maxLongEdgePixels)
        let resolvedDPI: Int
        if let size = pageSizePoints(path: path) {
            let longEdgeInches = max(size.w, size.h) / 72.0
            let ideal = longEdgeInches > 0 ? wanted / longEdgeInches : minDPI
            resolvedDPI = Int(min(max(ideal, minDPI), maxDPI))
        } else {
            resolvedDPI = 300   // couldn't measure — still far better than the old flat 150
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-ps-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outURL) }

        var args = [
            "-dSAFER",          // sandbox: no file/O access from the PostScript program
            "-dBATCH",          // exit when done
            "-dNOPAUSE",        // no per-page prompt
            "-dQUIET",
            "-dEPSCrop",        // honour the EPS BoundingBox instead of padding to a page
            "-dFirstPage=1", "-dLastPage=1",
            "-sDEVICE=png16m",
            "-r\(resolvedDPI)",
            "-sOutputFile=\(outURL.path)",
        ]
        for root in resourceRoots {
            args.append("-I\(root)/Init")
            args.append("-I\(root)")
        }
        args.append(contentsOf: colourArguments(iccProfilesDir: iccProfilesDir))
        args.append(path)

        let task = Process()
        task.executableURL = gs
        task.arguments = args
        // Ghostscript is chatty on both pipes; discard rather than risk filling a pipe buffer
        // and blocking the child forever (a classic subprocess deadlock).
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return nil }

        // Kill a runaway interpreter — a looping PostScript program would never exit.
        guard waitOrKill(task, timeout: timeout) else { return nil }

        guard FileManager.default.fileExists(atPath: outURL.path),
              let image = NSImage(contentsOf: outURL) else { return nil }
        return image
    }
}
