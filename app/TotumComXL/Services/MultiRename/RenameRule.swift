import Foundation

/// Case-conversion mode of the Multi-Rename dropdown. Applied LAST in the pipeline.
enum CaseMode: String, CaseIterable, Codable {
    case unchanged, lower, upper, firstUpper, eachWord
}

/// Everything the user configured in the dialog. Pure data; no file references.
/// Codable so a preset is just a stored RenameRule.
struct RenameRule: Codable, Equatable {
    var nameMask: String = "[N]"
    var extMask: String = "[E]"
    var search: String = ""
    var replace: String = ""
    var useRegex: Bool = false
    var respectCase: Bool = false       // the "^" checkbox
    var replaceOnce: Bool = false       // the "1x" checkbox
    var searchInExtension: Bool = false // the "[E]" checkbox
    var caseMode: CaseMode = .unchanged
    var counterStart: Int = 1
    var counterStep: Int = 1
    var counterDigits: Int = 1
}

/// One row of the preview: the computed target for one file.
/// `newName` may contain "/" meaning a relative subfolder path (TC's "\" feature).
struct RenamePlan: Equatable {
    let sourcePath: String
    let originalName: String
    let isDirectory: Bool
    var newName: String
    var status: RenameStatus
}

/// Result of validating/classifying a computed target, drives grid tint + Start gating.
enum RenameStatus: Equatable {
    case ok
    case unchanged             // target == original: skip, no rename
    case error(String)         // empty name / illegal char / bad regex; String is a short reason key
    case duplicate             // two rows produce the same target
    case collidesOnDisk        // target exists on disk and is not part of the batch
}
