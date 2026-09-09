import Foundation

/// The classic Unix permission bits — three actors (owner / group / everyone) each with
/// read / write / execute — as nine plain booleans. This is the model behind the properties
/// window's permission grid: the checkboxes bind to these, and `mode` / `octalString` convert
/// to the forms `chmod` and the OS want. Pure value type, no filesystem access.
struct PosixPermissions: Equatable {
    var ownerRead = false
    var ownerWrite = false
    var ownerExecute = false
    var groupRead = false
    var groupWrite = false
    var groupExecute = false
    var otherRead = false
    var otherWrite = false
    var otherExecute = false

    init() {}

    /// Build from a raw mode (only the low 9 bits, `0o777`, are read — type/setuid bits ignored).
    init(mode: Int) {
        ownerRead     = mode & 0o400 != 0
        ownerWrite    = mode & 0o200 != 0
        ownerExecute  = mode & 0o100 != 0
        groupRead     = mode & 0o040 != 0
        groupWrite    = mode & 0o020 != 0
        groupExecute  = mode & 0o010 != 0
        otherRead     = mode & 0o004 != 0
        otherWrite    = mode & 0o002 != 0
        otherExecute  = mode & 0o001 != 0
    }

    /// Parse a 1–3 digit octal string like "644" or "755". Returns nil for anything that
    /// isn't a valid octal number ≤ 777. Shorter strings are right-aligned ("7" → 0o007).
    init?(octalString raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 3,
              trimmed.allSatisfy({ "0"..."7" ~= $0 }),
              let value = Int(trimmed, radix: 8) else { return nil }
        self.init(mode: value)
    }

    /// The low 9 permission bits as a single integer (what `chmod` / `setAttributes` take).
    var mode: Int {
        var m = 0
        if ownerRead     { m |= 0o400 }
        if ownerWrite    { m |= 0o200 }
        if ownerExecute  { m |= 0o100 }
        if groupRead     { m |= 0o040 }
        if groupWrite    { m |= 0o020 }
        if groupExecute  { m |= 0o010 }
        if otherRead     { m |= 0o004 }
        if otherWrite    { m |= 0o002 }
        if otherExecute  { m |= 0o001 }
        return m
    }

    /// Three octal digits, e.g. "644". Always zero-padded so it round-trips with `init?(octalString:)`.
    var octalString: String { String(format: "%03o", mode) }

    /// The `ls -l` style string, e.g. "rw-r--r--". Nine characters, a letter or a dash each.
    var symbolic: String {
        func triad(_ r: Bool, _ w: Bool, _ x: Bool) -> String {
            "\(r ? "r" : "-")\(w ? "w" : "-")\(x ? "x" : "-")"
        }
        return triad(ownerRead, ownerWrite, ownerExecute)
             + triad(groupRead, groupWrite, groupExecute)
             + triad(otherRead, otherWrite, otherExecute)
    }
}
