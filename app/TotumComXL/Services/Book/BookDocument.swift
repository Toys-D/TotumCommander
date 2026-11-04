import Foundation

/// A book, once it has been turned into something showable: a folder of chapter files with
/// its pictures beside them.
///
/// FB2 and EPUB arrive by different roads and meet here, in ONE shape — so that the reader
/// itself knows nothing about formats and there is no chance of two book engines drifting
/// apart.
struct BookDocument: Sendable {
    let sourcePath: String        // the original .fb2/.epub — the key bookmarks hang on
    let format: BookFormat
    let root: URL                 // the unpacked/generated folder
    let title: String
    let author: String
    let cover: URL?
    /// In READING order (EPUB: the spine, never the manifest).
    let chapters: [BookChapter]
}

enum BookFormat: String, Sendable {
    case fb2
    case fb2zip
    case epub
}

struct BookChapter: Sendable, Identifiable, Equatable {
    let id: String                // EPUB: spine idref; FB2: "b0.s3"
    let title: String             // may be empty — a section without a heading
    let file: URL
    let fragment: String?         // an anchor inside the file
    let level: Int                // nesting, for the indent in the contents strip
}

enum BookError: LocalizedError {
    case unreadable
    case empty
    case notABook

    var errorDescription: String? {
        switch self {
        case .unreadable: return L("viewer.book.unreadable")
        case .empty:      return L("viewer.book.empty")
        case .notABook:   return L("viewer.book.notABook")
        }
    }
}
