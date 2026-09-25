import Foundation

/// Turning the F9 form into a Spotlight query — the whole translation, with no query object
/// and no index in sight, so it can be tested on any machine.
///
/// Spotlight speaks predicates over indexed attributes, not fnmatch over a directory walk, and
/// the two do not line up: there is no regex, no `?`, and a `*` inside a mask has no operator.
/// What survives is translated exactly; what does not is turned into the widest predicate that
/// cannot lose a match, and the leftovers are sieved out afterwards by the real fnmatch.
enum SpotlightQueryBuilder {

    /// A mask, translated. `postFilter` is true when the predicate is deliberately wider than
    /// the mask — the caller must then run the returned names through fnmatch as well.
    struct MaskPlan: Equatable {
        let predicate: NSPredicate?
        let postFilter: Bool

        static let everything = MaskPlan(predicate: nil, postFilter: false)

        static func == (a: MaskPlan, b: MaskPlan) -> Bool {
            a.postFilter == b.postFilter
                && a.predicate?.predicateFormat == b.predicate?.predicateFormat
        }
    }

    /// The name mask. `*` and an empty mask mean "every file" — no name predicate at all.
    ///
    /// The literal always goes in through `%@`, never string interpolation: a mask carrying a
    /// quote or a backslash would otherwise build a malformed format string, and NSPredicate
    /// answers malformed formats with an exception, not an error.
    nonisolated static func maskPlan(_ raw: String) -> MaskPlan {
        let mask = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mask.isEmpty, mask != "*" else { return .everything }

        let key = NSMetadataItemFSNameKey
        let hasQuestion = mask.contains("?")
        let stars = mask.filter { $0 == "*" }.count
        let inner = String(mask.dropFirst(mask.hasPrefix("*") ? 1 : 0)
                               .dropLast(mask.hasSuffix("*") ? 1 : 0))

        // The four shapes Spotlight has an operator for — but only while the leftover has no
        // wildcard of its own; "a*b" is a star in the middle and belongs to the sieve below.
        if !hasQuestion, !inner.contains("*"), !inner.isEmpty {
            switch (mask.hasPrefix("*"), mask.hasSuffix("*")) {
            case (true, true):
                return MaskPlan(predicate: NSPredicate(format: "%K CONTAINS[cd] %@", key, inner),
                                postFilter: false)
            case (false, true):
                return MaskPlan(predicate: NSPredicate(format: "%K BEGINSWITH[cd] %@", key, inner),
                                postFilter: false)
            case (true, false):
                return MaskPlan(predicate: NSPredicate(format: "%K ENDSWITH[cd] %@", key, inner),
                                postFilter: false)
            case (false, false):
                // A bare word is a substring search, as everywhere else in this program —
                // typing "отчёт" must find "отчёт 2026.pdf".
                return MaskPlan(predicate: NSPredicate(format: "%K CONTAINS[cd] %@", key, inner),
                                postFilter: false)
            }
        }

        // Anything else — a star in the middle, several stars, a "?" — has no operator. Ask the
        // index for the longest literal run (a superset that cannot lose a match) and let
        // fnmatch do the exact work on what comes back. A mask of pure wildcards ("*?*") has no
        // literal to lean on, so everything is fetched and sieved.
        let literal = longestLiteralRun(mask)
        guard !literal.isEmpty else { return MaskPlan(predicate: nil, postFilter: true) }
        return MaskPlan(predicate: NSPredicate(format: "%K CONTAINS[cd] %@", key, literal),
                        postFilter: true)
    }

    /// The longest stretch of a mask with no wildcard in it.
    nonisolated static func longestLiteralRun(_ mask: String) -> String {
        let runs: [Substring] = mask.split(omittingEmptySubsequences: true) { $0 == "*" || $0 == "?" }
        return runs.max(by: { $0.count < $1.count }).map(String.init) ?? ""
    }

    /// Text to find INSIDE files. Spotlight answers from the text it extracted when the file
    /// was written, which is why it can look inside PDF, Pages and Word — and why it is
    /// file-level: there is no line number to report.
    nonisolated static func contentPredicate(_ raw: String) -> NSPredicate? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemTextContentKey, text)
    }

    /// Size limits, in bytes. Folders carry no size attribute at all, so any size limit
    /// silently means "files only" — said out loud in the dialog's hint rather than hidden.
    nonisolated static func sizePredicates(minBytes: UInt64, maxBytes: UInt64) -> [NSPredicate] {
        var parts: [NSPredicate] = []
        if minBytes > 0 {
            parts.append(NSPredicate(format: "%K >= %lld", NSMetadataItemFSSizeKey, Int64(minBytes)))
        }
        if maxBytes > 0 {
            parts.append(NSPredicate(format: "%K <= %lld", NSMetadataItemFSSizeKey, Int64(maxBytes)))
        }
        return parts
    }

    nonisolated static func datePredicates(from: Date?, to: Date?) -> [NSPredicate] {
        var parts: [NSPredicate] = []
        let key = NSMetadataItemFSContentChangeDateKey
        if let from {
            parts.append(NSPredicate(format: "%K >= %@", key, from as NSDate))
        }
        if let to {
            // The user picks a day, not an instant: "to 5 May" must include all of 5 May.
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1,
                                                 to: Calendar.current.startOfDay(for: to)) ?? to
            parts.append(NSPredicate(format: "%K < %@", key, endOfDay as NSDate))
        }
        return parts
    }

    /// The whole form as one predicate. Nil means "this query would ask for everything on the
    /// disk" — the caller must refuse it rather than start it: an unbounded Spotlight query
    /// returns hundreds of thousands of rows and answers no question anyone asked.
    nonisolated static func predicate(mask: String,
                                      contentQuery: String,
                                      minBytes: UInt64,
                                      maxBytes: UInt64,
                                      dateFrom: Date?,
                                      dateTo: Date?) -> (predicate: NSPredicate?, postFilter: Bool) {
        let plan = maskPlan(mask)
        var parts: [NSPredicate] = []
        if let namePredicate = plan.predicate { parts.append(namePredicate) }
        if let content = contentPredicate(contentQuery) { parts.append(content) }
        parts.append(contentsOf: sizePredicates(minBytes: minBytes, maxBytes: maxBytes))
        parts.append(contentsOf: datePredicates(from: dateFrom, to: dateTo))

        guard !parts.isEmpty else { return (nil, plan.postFilter) }
        let combined = parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        return (combined, plan.postFilter)
    }

    // MARK: - Sieving what the index hands back

    /// True for a path with a dot-directory or dot-file anywhere in it. Spotlight's own
    /// treatment of invisible files is inconsistent, so hidden results are dropped by us
    /// instead — a deterministic answer beats whatever the index happened to keep.
    nonisolated static func isHidden(path: String) -> Bool {
        (path as NSString).pathComponents.dropFirst().contains { $0.hasPrefix(".") }
    }

    /// The exact mask, applied to a name the index offered. Only used when `postFilter` said
    /// the predicate was widened.
    ///
    /// `LIKE[cd]` rather than fnmatch, and not for taste: fnmatch compares bytes, while macOS
    /// hands back file names in DECOMPOSED Unicode — the "ё" read off the disk is two code
    /// points where the "ё" typed into the mask is one, and a byte comparison calls them
    /// different. The `d` flag folds exactly that difference away (and `c` folds case, which
    /// FNM_CASEFOLD only ever managed for ASCII). Same operator the content-mode name filter
    /// already uses, so both sieves answer alike.
    nonisolated static func nameMatches(mask raw: String, name: String) -> Bool {
        let mask = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mask.isEmpty, mask != "*" else { return true }
        return NSPredicate(format: "SELF LIKE[cd] %@", mask).evaluate(with: name)
    }
}
