import Foundation
import FCXLBridgeObjC

/// Comparing two files line by line: what the C++ core reports, and how it is laid out as two
/// columns side by side.
///
/// The core answers with ONE list, in reading order, each entry belonging to the left file, to
/// the right file, or to both. A side-by-side view needs pairs instead — a line that was changed
/// must sit opposite the line it replaced — and building those pairs is this file's real work.
enum FileDiffService {

    /// One line, as the core reports it.
    struct Line: Equatable {
        enum Kind: String {
            /// The same on both sides.
            case equal
            /// Present on the right only.
            case added
            /// Present on the left only.
            case removed
            /// Both sides have this line and they differ — only the fallback path for very large
            /// files reports this; the exact comparison says removed + added instead.
            case modified
        }

        /// Line numbers count from 1. Nil on the side that does not have this line.
        let leftNumber: Int?
        let rightNumber: Int?
        let kind: Kind
        let text: String
    }

    /// One row of the two columns.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case equal
            /// A line replaced by another: the two stand opposite each other.
            case changed
            /// Only one side has it; the other is blank.
            case removed
            case added
            /// Not a line at all: a strip standing for the lines folded away, with how many.
            /// Without it, folding a file whose differences are everywhere looks like a switch
            /// that does nothing.
            case gap(hidden: Int)
        }

        let id: Int
        let kind: Kind
        let leftNumber: Int?
        let leftText: String?
        let rightNumber: Int?
        let rightText: String?

        var isDifference: Bool {
            switch kind {
            case .equal: return false
            case .gap: return false
            case .changed, .removed, .added: return true
            }
        }

        /// The strip standing in for what was folded away.
        var hiddenCount: Int? {
            if case .gap(let hidden) = kind { return hidden }
            return nil
        }
    }

    // MARK: - Asking the core

    enum Failure: Error {
        /// One of the files is not text: comparing it line by line says nothing useful.
        case binary(left: Bool, right: Bool)
        /// Not an ordinary file at all — a FIFO, a device, a socket. Opening one of those
        /// BLOCKS: a named pipe with no writer hangs the reader forever, and every read here
        /// runs on the main thread.
        case notAFile(String)
        case core(String)
    }

    /// Compare two files. Throws `.binary` before bothering the core with something that has no
    /// lines to speak of.
    static func compare(_ pathA: String, _ pathB: String) throws -> [Line] {
        // BEFORE anything opens them: even the binary probe's open() would hang on a FIFO.
        for path in [pathA, pathB] where !isRegularFile(at: path) {
            throw Failure.notAFile((path as NSString).lastPathComponent)
        }
        let leftBinary = looksBinary(at: pathA)
        let rightBinary = looksBinary(at: pathB)
        guard !leftBinary, !rightBinary else {
            throw Failure.binary(left: leftBinary, right: rightBinary)
        }

        let bridge = FCXLCompareBridge()
        do {
            let raw = try bridge.compareFile(atPath: pathA, withFileAtPath: pathB)
            return raw.map(line(from:))
        } catch {
            throw Failure.core(error.localizedDescription)
        }
    }

    /// Byte-for-byte, whatever is inside. Nil when the files could not be read.
    static func areIdentical(_ pathA: String, _ pathB: String) -> Bool? {
        var identical: ObjCBool = false
        let bridge = FCXLCompareBridge()
        guard (try? bridge.areFilesIdentical(atPath: pathA, andPath: pathB,
                                             identical: &identical)) != nil else { return nil }
        return identical.boolValue
    }

    private static func line(from raw: [String: Any]) -> Line {
        // The core numbers lines from 1 and leaves 0 on the side that has none.
        func number(_ key: String) -> Int? {
            let value = (raw[key] as? NSNumber)?.intValue ?? 0
            return value > 0 ? value : nil
        }
        return Line(leftNumber: number("lineLeft"),
                    rightNumber: number("lineRight"),
                    kind: Line.Kind(rawValue: raw["type"] as? String ?? "") ?? .equal,
                    text: raw["content"] as? String ?? "")
    }

    // MARK: - Is there anything to compare?

    /// An ordinary file — not a FIFO, a device or a socket. Symlinks are followed first, so a
    /// link to a real file passes and a link to a pipe does not.
    static func isRegularFile(at path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    /// A file with NUL bytes in it is not text. The same rule the viewer uses to decide between
    /// showing text and showing hex — one answer to that question in the app, not two.
    static func looksBinary(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 8192)) ?? Data()
        return looksBinary(sample: sample)
    }

    static func looksBinary(sample: Data) -> Bool {
        guard !sample.isEmpty else { return false }
        let nulls = sample.reduce(0) { $1 == 0 ? $0 + 1 : $0 }
        return Double(nulls) / Double(sample.count) > 0.1
    }

    // MARK: - Two columns

    /// Lay the core's single list out as pairs.
    ///
    /// A change reads as a run of removed lines followed by a run of added ones. Standing them
    /// opposite each other — first removed against first added, and so on — is what turns "this
    /// line went, that line came" into "this line BECAME that one". Whatever is left over when
    /// one run is longer than the other keeps an empty cell beside it.
    static func rows(from lines: [Line]) -> [Row] {
        var rows: [Row] = []
        var removed: [Line] = []
        var added: [Line] = []

        func flush() {
            for index in 0..<max(removed.count, added.count) {
                let left = index < removed.count ? removed[index] : nil
                let right = index < added.count ? added[index] : nil
                let kind: Row.Kind = left != nil && right != nil ? .changed
                    : (left != nil ? .removed : .added)
                rows.append(Row(id: rows.count, kind: kind,
                                leftNumber: left?.leftNumber, leftText: left?.text,
                                rightNumber: right?.rightNumber, rightText: right?.text))
            }
            removed.removeAll()
            added.removeAll()
        }

        for line in lines {
            switch line.kind {
            case .removed:
                removed.append(line)
            case .added:
                added.append(line)
            case .equal, .modified:
                flush()
                rows.append(Row(id: rows.count,
                                kind: line.kind == .equal ? .equal : .changed,
                                leftNumber: line.leftNumber, leftText: line.text,
                                rightNumber: line.rightNumber,
                                rightText: line.text))
            }
        }
        flush()
        return rows
    }

    /// How many separate places the files differ — runs of neighbouring changed rows count as
    /// one. That is what a person means by "three differences", and what the next/previous
    /// buttons step through.
    static func differenceRuns(in rows: [Row]) -> [Int] {
        var starts: [Int] = []
        var previousWasDifference = false
        for (index, row) in rows.enumerated() {
            if row.isDifference, !previousWasDifference { starts.append(index) }
            previousWasDifference = row.isDifference
        }
        return starts
    }

    /// Only the differences, with a few unchanged lines around each so they can be read in
    /// context. What is left out is replaced by a strip saying how many lines went — a fold
    /// nobody can see is indistinguishable from a switch that does not work, and on a file that
    /// differs almost everywhere very little is folded at all.
    static func foldingEqualLines(in rows: [Row], context: Int = 2) -> [Row] {
        guard rows.contains(where: \.isDifference) else { return [] }
        var keep = Set<Int>()
        for (index, row) in rows.enumerated() where row.isDifference {
            for offset in -context...context {
                let neighbour = index + offset
                if rows.indices.contains(neighbour) { keep.insert(neighbour) }
            }
        }

        var folded: [Row] = []
        var hidden = 0
        func closeGap() {
            guard hidden > 0 else { return }
            folded.append(Row(id: -folded.count - 1, kind: .gap(hidden: hidden),
                              leftNumber: nil, leftText: nil,
                              rightNumber: nil, rightText: nil))
            hidden = 0
        }
        for (index, row) in rows.enumerated() {
            if keep.contains(index) {
                closeGap()
                folded.append(row)
            } else {
                hidden += 1
            }
        }
        closeGap()
        return folded
    }
}
