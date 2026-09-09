import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - FileCategory

enum FileCategory {
    case video
    case audio
    case image
    case vectorImage     // SVG/SVGZ/PSD/AI — rendered via Quick Look
    case officeDocument  // doc/docx/xls/xlsx/ppt/pptx/pages/numbers/key/odt/ods/odp
    case pdf
    case djvu            // scanned documents — rendered in-app via DjVuLibre (macOS has no DjVu support)
    case book            // FB2 and EPUB — read page by page, like a real book
    case drawing         // CAD drawings (DXF) — read and drawn in-app; macOS shows them as text
    case font            // ttf/otf/ttc — rendered in-app as a type specimen (sample text at sizes)
    case postScript      // eps/ps — macOS dropped its PostScript rasteriser, so we render via bundled Ghostscript
    case text
    case markdown
    case other
}

// MARK: - File extension database
// Comprehensive, explicit categorisation so unknown/binary extensions don't
// fall through to .text (which would try to read e.g. a .mb Maya file as a
// string). Precedence: vectorImage, officeDocument, video, audio, image, pdf,
// markdown, text, binary→other, then a UTType fallback for anything else.

/// Rendered via Quick Look (NSImage misrenders SVG, only shows the embedded
/// preview of PSD/AI). QL gives full visual fidelity.
private let vectorImageExts: Set<String> = [
    "svg", "svgz",
    "psd", "psb",                 // Photoshop
    "ai", "indd", "indt", "idml"  // Illustrator / InDesign
]

/// Office / iWork / OpenOffice — rendered via Quick Look.
private let officeDocExts: Set<String> = [
    "doc", "docx", "docm", "dot", "dotx",
    "xls", "xlsx", "xlsm", "xlt", "xltx",
    "ppt", "pptx", "pptm", "pps", "ppsx", "potx",
    "pages", "numbers", "key", "keynote",
    "odt", "ott", "ods", "ots", "odp", "otp", "odg", "odf",
    "fodt", "fods", "fodp"
]

private let videoExts: Set<String> = [
    "mp4", "m4v", "mov", "qt", "avi", "mkv", "wmv", "asf", "flv", "webm",
    "mpeg", "mpg", "mpe", "m2v", "mts", "m2ts", "ts", "vob", "ogv",
    "3gp", "3g2", "divx", "xvid", "rm", "rmvb", "mxf", "f4v"
]

private let audioExts: Set<String> = [
    "mp3", "wav", "m4a", "flac", "aac", "ogg", "opus", "alac", "ape", "wma",
    "aiff", "aif", "aifc", "au", "snd", "voc", "ra",
    "mid", "midi", "mod", "s3m", "xm", "it", "amr", "dts", "ac3", "caf"
]

private let imageExts: Set<String> = [
    // Raster
    "png", "jpg", "jpeg", "jpe", "gif", "bmp", "tiff", "tif", "webp",
    "heic", "heif", "avif", "jp2", "jpx", "j2k", "jxl",
    // HDR
    "exr", "hdr", "rgbe",
    // Camera RAW
    "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf", "srw", "sr2", "pef", "x3f",
    // System icons
    "icns", "ico", "cur"
]

private let pdfExts: Set<String> = ["pdf"]

private let djvuExts: Set<String> = ["djvu", "djv"]
private let bookExts: Set<String> = ["fb2", "epub", "fbz"]

/// Категория по ИМЕНИ файла, а не по одному расширению.
///
/// «Книга.fb2.zip» — обычный способ хранить FB2, и расширение у неё «zip». Читать её мы
/// умеем (BookLoader эту пару как раз и разбирает), но по расширению она уезжала в архивы и
/// до чтения дело не доходило.
func fileCategory(forFileName name: String) -> FileCategory {
    let lower = name.lowercased()
    if lower.hasSuffix(".fb2.zip") { return .book }
    return fileCategory(extension: (name as NSString).pathExtension.lowercased())
}
/// CAD drawings this program reads itself. DXF is the exchange format every CAD tool writes;
/// macOS has no idea what it is and shows it as a wall of numbers.
private let drawingExts: Set<String> = ["dxf"]

private let markdownExts: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "rmd", "qmd"]

private let textExts: Set<String> = [
    // Plain
    "txt", "text", "log", "rtf", "rtfd", "resolved",
    // Source code
    "swift", "c", "h", "cc", "cpp", "cxx", "c++", "hpp", "hxx", "h++", "ipp", "tpp", "inl",
    "m", "mm", "objc",
    "py", "pyw", "pyx", "pxd", "ipynb",
    "rb", "erb", "rake", "gemspec",
    "pl", "pm", "t", "pod",
    "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts",
    "html", "htm", "xhtml", "shtml",
    "css", "scss", "sass", "less", "styl", "stylus",
    "vue", "svelte", "astro",
    "java", "kt", "kts", "scala", "groovy", "gradle",
    "go", "rs", "dart", "lua", "r", "rlang", "php", "php3", "php4", "php5", "phtml",
    "sh", "bash", "zsh", "fish", "ksh", "csh", "tcsh", "command", "tool",
    "bat", "cmd", "ps1", "psm1", "ps1xml", "vbs", "vb", "ahk", "applescript",
    "ex", "exs", "erl", "hrl", "elixir",
    "clj", "cljs", "cljc", "edn", "lisp", "lsp", "scm", "rkt", "fnl",
    "ml", "mli", "fs", "fsi", "fsx", "fsproj",
    "hs", "lhs", "elm", "purs", "idr", "agda",
    "pas", "pp", "dpr", "ada", "adb", "ads",
    "for", "f", "f90", "f95", "f03", "f08",
    "asm", "s", "ll", "wat", "wasm-text",
    "nim", "zig", "v", "cr", "raku", "p6",
    "tcl", "expect",
    "j", "jl", "ne", "nix",
    // Markup / data
    "json", "jsonc", "json5", "ndjson",
    "xml", "xsl", "xslt", "xsd", "dtd", "rng",
    "yaml", "yml", "toml", "ini", "cfg", "conf", "config", "env",
    "properties", "props", "plist",
    "csv", "tsv", "psv",
    "sql", "graphql", "gql", "proto", "thrift", "capnp",
    "hcl", "tf", "tfvars",
    // Build / project
    "makefile", "make", "mak", "mk", "gnumakefile",
    "cmake", "cmakelists",
    "dockerfile", "containerfile",
    "vagrantfile", "rakefile", "gemfile", "podfile", "fastfile",
    "bazel", "build", "workspace", "starlark",
    "sln", "csproj", "vbproj", "fsproj", "vcxproj", "filters",
    "xcconfig", "xcscheme", "xcworkspacedata", "xcprivacy",
    "pbxproj",
    // Documentation
    "tex", "latex", "ltx", "bib", "cls", "sty",
    "rst", "adoc", "asciidoc", "asc",
    "org", "texi", "info", "man", "1", "2", "3", "5", "7", "8", "9",
    "nfo", "diz", "ans", "readme", "todo", "changelog", "changes", "license", "authors", "contributors",
    // Web meta
    "htaccess", "htpasswd", "nginx", "robots", "sitemap",
    "ejs", "pug", "jade", "haml", "slim", "mustache", "hbs", "handlebars", "twig", "tmpl", "tpl",
    "jsp", "asp", "aspx", "cshtml", "razor",
    // Subtitles
    "srt", "sub", "ass", "ssa", "vtt", "lrc", "sbv",
    // Patches / diffs
    "patch", "diff",
    // Crypto / cert (PEM-encoded text). `.key` is omitted to avoid conflict with Apple Keynote.
    "pem", "crt", "pub", "csr", "sig",
    // Tooling configs (filenames-as-extensions)
    "gitignore", "gitattributes", "gitconfig", "gitmodules",
    "editorconfig", "eslintrc", "prettierrc", "browserslistrc",
    "npmignore", "nvmrc", "babelrc", "stylelintrc",
    "ruby-version", "python-version", "tool-versions",
    "reg", "inf",
    // Lock files (text)
    "lock", "lockfile", "sum",
    // Misc
    "har", "map", "rsc", "ron"
]

private let binaryExts: Set<String> = [
    // Executables / shared libraries / object files
    "exe", "dll", "msi", "msp", "scr", "com", "ocx", "sys", "drv", "vxd",
    "so", "dylib", "a", "o", "obj", "lib", "bin", "elf",
    "app", "framework", "bundle", "kext", "saver",
    "class", "jar", "war", "ear",
    "pyc", "pyo", "pyd",
    "wasm", "cso", "fxc", "spv",
    "rom",
    // Archives
    "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar",
    "lz", "lzma", "lzo", "zst", "zstd", "lzh", "lha", "ar", "cpio",
    "sit", "sitx", "sea", "hqx",
    "dmg", "iso", "img", "vcd", "mdf", "nrg", "cue", "toast",
    "cab", "msu",
    "deb", "rpm", "pkg", "ipa", "apk", "xpi", "crx",
    // Databases
    "db", "db3", "sqlite", "sqlite3", "sqlitedb",
    "mdb", "accdb", "frm", "ibd", "myd", "myi",
    "realm", "leveldb",
    // macOS / iOS resources
    "car", "nib", "xib", "storyboard",
    "momd", "mom", "omo", "dat", "pak", "rsrc",
    // 3D / CAD / DCC
    "blend", "blend1", "blend2",
    "fbx", "glb", "usdz", "usd", "usda", "usdc",
    "mb", "ma", "mll",                        // Maya
    "max", "prj", "matlib",                   // 3ds Max
    "c4d",                                    // Cinema 4D
    "3dm", "3dmbak",                          // Rhino
    "ztl", "zpr",                             // ZBrush
    "hip", "hipnc", "hiplc", "bgeo", "geo",   // Houdini
    "spp", "sbsar", "sbs",                    // Substance
    "abc",                                    // Alembic
    "3ds", "stl", "ply", "off",
    "dwg", "step", "stp", "iges", "igs",   // .dxf is read in-app — see drawingExts
    "skp",                                    // SketchUp
    // Adobe / design (non-image: project files)
    "prproj", "aep", "xd", "sketch", "fig",
    // Game / proprietary
    "swf", "fla",
    "wad", "vpk", "bsp", "mpq", "sav",
    // Media containers / scene formats not viewable as plain media
    "iff", "lwo", "lws",
    // Misc
    "pdb", "dsym", "exp", "ilk", "tlog", "ipch", "suo",
    "ds_store", "thumbs"
]

/// PostScript documents. macOS has had no PostScript rasteriser since 10.15, so Quick Look
/// renders nothing for these; we hand them to the bundled Ghostscript instead.
private let postScriptExts: Set<String> = ["eps", "epsf", "epsi", "ps"]

/// Font files we can render an in-app specimen for. CoreText loads ttf/otf/ttc/dfont
/// directly; woff/woff2/eot are web-compressed wrappers CoreText can't open, so the
/// specimen view shows a graceful "can't preview this format" note for those.
private let fontExts: Set<String> = [
    "ttf", "otf", "ttc", "dfont", "woff", "woff2", "eot", "fon", "fnt", "pfa", "pfb"
]

func fileCategory(extension fileExtension: String) -> FileCategory {
    let ext = fileExtension
        .lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))

    if ext.isEmpty { return .other }

    // 1) Manual database — fast, deterministic, beats the system DB for
    //    ambiguous cases. Order matters: vector/office before image/text.
    if postScriptExts.contains(ext)  { return .postScript }
    if vectorImageExts.contains(ext) { return .vectorImage }
    if officeDocExts.contains(ext)   { return .officeDocument }
    if videoExts.contains(ext)       { return .video }
    if audioExts.contains(ext)       { return .audio }
    if imageExts.contains(ext)       { return .image }
    if pdfExts.contains(ext)         { return .pdf }
    if djvuExts.contains(ext)        { return .djvu }
    // Before the text branch on purpose: an FB2 IS xml, and left to the text rules it would
    // open as a wall of tags instead of a book.
    if bookExts.contains(ext)        { return .book }
    if drawingExts.contains(ext)     { return .drawing }
    if markdownExts.contains(ext)    { return .markdown }
    if textExts.contains(ext)        { return .text }
    if fontExts.contains(ext)        { return .font }
    if binaryExts.contains(ext)      { return .other }

    // 2) Fallback — ask the system (UTType has thousands of registered types).
    if let utType = UTType(filenameExtension: ext) {
        if utType.conforms(to: .movie) { return .video }
        if utType.conforms(to: .audio) { return .audio }
        if utType.conforms(to: .image) { return .image }
        if utType.conforms(to: .pdf)   { return .pdf }
        if utType.identifier == "net.daringfireball.markdown" { return .markdown }
        if utType.conforms(to: .sourceCode) || utType.conforms(to: .plainText) ||
           utType.conforms(to: .script) || utType.conforms(to: .text) {
            return .text
        }
        return .other
    }

    // 3) Truly unknown → info card (NOT .text — don't read binaries as strings).
    return .other
}

// MARK: - PreviewMode

enum PreviewMode: String, CaseIterable, Identifiable {
    case auto
    case quickLook
    case image
    case text
    case hex
    case video
    case pdf
    case document        // word-processing files as reflowing HTML — see wordProcessingExts
    case djvu
    case book
    case drawing
    case font
    case postScript
    case info

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .auto:
            return "wand.and.stars"
        case .quickLook:
            return "eye"
        case .image:
            return "photo"
        case .text:
            return "doc.text"
        case .hex:
            return "number"
        case .video:
            return "play.rectangle"
        case .pdf:
            return "doc.richtext"
        case .document:
            return "doc.plaintext"
        case .djvu:
            return "doc.richtext"
        case .book:
            return "book"
        case .drawing:
            return "scribble"
        case .font:
            return "textformat"
        case .postScript:
            return "scribble.variable"
        case .info:
            return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .auto:
            return L("preview.mode.auto")
        case .quickLook:
            return L("preview.mode.quicklook")
        case .image:
            return L("preview.mode.image")
        case .text:
            return L("preview.mode.text")
        case .hex:
            return L("preview.mode.hex")
        case .video:
            return L("preview.mode.video")
        case .pdf:
            return L("preview.mode.pdf")
        case .document:
            return L("preview.mode.document")
        case .djvu:
            return "DjVu"
        case .book:
            return L("preview.mode.book")
        case .drawing:
            return L("preview.mode.drawing")
        case .font:
            return L("preview.mode.font")
        case .postScript:
            return "PostScript"
        case .info:
            return L("preview.mode.info")
        }
    }

    var quickViewLabel: String {
        switch self {
        case .auto:
            return L("preview.mode.auto")
        case .quickLook:
            return L("preview.mode.quicklook")
        case .image:
            return L("preview.mode.image")
        case .text:
            return L("preview.mode.text")
        case .hex:
            return L("preview.mode.hex")
        case .video:
            return L("preview.mode.video")
        case .pdf:
            return L("preview.mode.pdf")
        case .document:
            return L("preview.mode.document")
        case .djvu:
            return "DjVu"
        case .book:
            return L("preview.mode.book")
        case .drawing:
            return L("preview.mode.drawing")
        case .font:
            return L("preview.mode.font")
        case .postScript:
            return "PostScript"
        case .info:
            return L("preview.mode.info")
        }
    }
}

/// Formats `textutil` can convert to HTML/webarchive — i.e. the ones our `.document` mode can show
/// full width with selectable, reflowing text. Verified against textutil's reader list; Excel and
/// PowerPoint are NOT here because textutil yields an empty document for them.
let wordProcessingExts: Set<String> = [
    "doc", "docx", "docm", "dot", "dotx",
    "odt", "ott", "fodt",
    "rtf", "rtfd", "wordml", "webarchive"
]

/// Can this file be shown in the reflowing `.document` mode?
func isWordProcessingDocument(extension ext: String) -> Bool {
    wordProcessingExts.contains(ext.lowercased())
}

func autoMode(for category: FileCategory) -> PreviewMode {
    switch category {
    case .image:
        return .image
    case .vectorImage:
        return .quickLook    // WebKit-backed QL renders SVG cleanly
    case .officeDocument:
        return .quickLook    // QL renders docx/xlsx/pptx with full fidelity
    case .text, .markdown:
        return .text
    case .video, .audio:
        return .video
    case .pdf:
        return .pdf          // Our .pdf mode uses PDFKit's PDFView — text
                             // selection + Cmd+C copy work natively, unlike
                             // the embedded QLPreviewView which blocks copy.
    case .djvu:
        return .djvu
    case .book:
        return .book
    case .drawing:
        return .drawing      // Quick Look has no CAD module — our own parser draws it
    case .font:
        return .font
    case .postScript:
        return .postScript
    case .other:
        return .info
    }
}

// MARK: - FolderPreviewEntrySnapshot

struct FolderPreviewEntrySnapshot: Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64
}

// MARK: - Async Preview Helpers

func readFileDataAsync(path: String, maxBytes: Int? = nil) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
        let url = URL(fileURLWithPath: path)
        if let maxBytes {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return handle.readData(ofLength: maxBytes)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }.value
}

func loadFolderPreviewSnapshotAsync(path: String) async throws -> ([FolderPreviewEntrySnapshot], UInt64) {
    try await Task.detached(priority: .userInitiated) {
        let folderURL = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        )
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }

        var entries: [FolderPreviewEntrySnapshot] = []
        entries.reserveCapacity(sorted.count)
        var totalSize: UInt64 = 0

        for url in sorted {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let size = UInt64(values?.fileSize ?? 0)
            if !isDirectory {
                totalSize += size
            }
            entries.append(
                FolderPreviewEntrySnapshot(
                    path: url.path,
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    size: size
                )
            )
        }
        return (entries, totalSize)
    }.value
}

func quickLookThumbnailAsync(path: String, targetSize: CGSize) async -> NSImage? {
    let request = QLThumbnailGenerator.Request(
        fileAt: URL(fileURLWithPath: path),
        size: targetSize,
        scale: NSScreen.main?.backingScaleFactor ?? 2.0,
        representationTypes: .thumbnail
    )
    return await withCheckedContinuation { continuation in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            continuation.resume(returning: representation?.nsImage)
        }
    }
}

func loadPreviewImageAsync(path: String, targetSize: CGSize) async -> NSImage? {
    if let thumbnail = await quickLookThumbnailAsync(path: path, targetSize: targetSize) {
        return thumbnail
    }
    guard let data = try? await readFileDataAsync(path: path) else {
        return nil
    }
    return NSImage(data: data)
}

func loadPreviewMetadataAsync(path: String, fileSize: UInt64, fallbackModifiedDate: Date) async -> [PreviewMetadataEntry] {
    await Task.detached(priority: .utility) {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .contentTypeKey,
            .typeIdentifierKey,
            .creationDateKey,
            .contentModificationDateKey,
            .isReadableKey,
            .isWritableKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let formatter = DateFormatter.fcxlDisplay(date: .medium, time: .short)

        var items: [PreviewMetadataEntry] = []
        items.append(PreviewMetadataEntry(key: L("properties.path"), value: path))
        items.append(
            PreviewMetadataEntry(
                key: L("properties.size"),
                value: ByteText.file(Int64(fileSize))
            )
        )

        if let identifier = values?.contentType?.identifier ?? values?.typeIdentifier {
            items.append(PreviewMetadataEntry(key: "UTI", value: identifier))
        }
        if let createdAt = values?.creationDate {
            items.append(PreviewMetadataEntry(key: L("properties.createdShort"), value: formatter.string(from: createdAt)))
        }
        let modifiedAt = values?.contentModificationDate ?? fallbackModifiedDate
        items.append(PreviewMetadataEntry(key: L("properties.modifiedShort"), value: formatter.string(from: modifiedAt)))

        let readable = values?.isReadable ?? true
        let writable = values?.isWritable ?? false
        let accessValue: String
        if readable {
            accessValue = writable ? L("properties.access.readWrite") : L("properties.access.readOnly")
        } else {
            accessValue = L("properties.access.noAccess")
        }
        items.append(PreviewMetadataEntry(key: L("properties.permissions"), value: accessValue))

        return items
    }.value
}

// MARK: - FileTypeIconCache

@MainActor
enum FileTypeIconCache {
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let fileIcon = NSWorkspace.shared.icon(for: .data)
    private static var iconCache: [String: NSImage] = [:]

    static func icon(for item: FileItem, targetSize: CGSize) -> NSImage {
        icon(
            fileExtension: item.fileExtension,
            isDirectory: item.isDirectory || item.name == "..",
            targetSize: targetSize
        )
    }

    static func icon(fileExtension: String, isDirectory: Bool, targetSize: CGSize) -> NSImage {
        let source: NSImage
        if isDirectory {
            source = folderIcon
        } else {
            let ext = fileExtension.lowercased()
            if ext.isEmpty {
                source = fileIcon
            } else if let cached = iconCache[ext] {
                source = cached
            } else {
                let resolved: NSImage
                if let contentType = UTType(filenameExtension: ext) {
                    resolved = NSWorkspace.shared.icon(for: contentType)
                } else {
                    resolved = fileIcon
                }
                iconCache[ext] = resolved
                source = resolved
            }
        }

        let icon = (source.copy() as? NSImage) ?? source
        icon.size = targetSize
        return icon
    }
}
