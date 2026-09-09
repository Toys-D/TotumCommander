import Foundation

/// The numbers behind the `NSError`s that come out of the C++ core.
///
/// The bridges turn `fcxl::common::ErrorCode` into an `NSError` whose code is the enum's
/// ORDINAL, so this list must stay in step with `core/include/fcxl/common/error.h`. It lives
/// in one place because a bare `error.code == 2` at a call site says nothing about what it
/// means — and the same number arrives under two different domains depending on which bridge
/// raised it.
enum CoreErrorCode: Int {
    case ok = 0
    case notFound = 1
    case permissionDenied = 2
    case alreadyExists = 3
    case ioError = 4
    case invalidArgument = 5
    case notSupported = 6
    case cancelled = 7
    case timeout = 8
    case archiveError = 9
    case networkError = 10
    case notADirectory = 11
    case notAFile = 12
    case diskFull = 13
    case nameTooLong = 14
    case unknown = 15

    /// The file and archive bridges stamp the first domain, the network bridge the second.
    static let domains: Set<String> = ["com.fcxl.error", "com.fcxl.network"]

    /// The core's own code behind an error — nil when the error came from somewhere else and
    /// its number means something entirely different.
    static func of(_ error: Error) -> CoreErrorCode? {
        let nsError = error as NSError
        guard domains.contains(nsError.domain) else { return nil }
        return CoreErrorCode(rawValue: nsError.code)
    }
}
