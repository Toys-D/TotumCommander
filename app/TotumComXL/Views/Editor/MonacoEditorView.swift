import AppKit
import WebKit

/// Breaks the WKUserContentController → handler retain cycle. The content controller is
/// owned by the webView, the webView by the controller, so a direct `add(self,…)` keeps the
/// controller alive forever (every editor open leaked a full Monaco WebView — tens of MB).
/// This proxy holds the real handler weakly.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: MonacoEditorController?
    init(_ target: MonacoEditorController) { self.target = target }
    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

/// Monaco Editor wrapper using WKWebView.
/// Provides VS Code-level editing with syntax highlighting, minimap, indent guides, etc.
@MainActor
final class MonacoEditorController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var onDirtyChanged: ((Bool) -> Void)?
    var onCursorChanged: ((Int, Int, Int, Int) -> Void)?  // line, col, totalLines, selLen
    var onReady: (() -> Void)?
    var onSaveRequested: (() -> Void)?  // Cmd+S from inside the editor (used by the embedded panel)

    private var pendingContent: (String, String)?  // (text, language)
    private var isReady = false

    override init() {
        let config = WKWebViewConfiguration()
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        let userController = WKUserContentController()
        config.userContentController = userController

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        super.init()

        // Weak proxy — see WeakScriptMessageProxy. A direct add(self) leaks the controller.
        userController.add(WeakScriptMessageProxy(self), name: "editorEvent")
        webView.navigationDelegate = self

        // Load Monaco HTML with file:// access to local Monaco bundle
        let bundle = Bundle.module
        if let htmlURL = bundle.url(forResource: "monaco-editor", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else if let htmlPath = Bundle.main.path(forResource: "monaco-editor", ofType: "html") {
            let htmlURL = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
    }

    // MARK: - JS Escape Utility

    /// Escape a string for safe insertion into a JS template literal (`...`)
    /// The trailing `\r` step is essential: inside a template literal ECMAScript
    /// normalizes a raw CR / CRLF to LF, so a Windows file would silently lose its
    /// line endings on the round-trip. Emitting the `\r` escape preserves them.
    static func escapeForJSTemplate(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "`", with: "\\`")
         .replacingOccurrences(of: "$", with: "\\$")
         .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Escape a string for safe insertion into a JS single-quoted string ('...')
    static func escapeForJSString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Shared Constants

    static let editorFonts = ["SF Mono", "Menlo", "Monaco", "Courier New", "Fira Code", "JetBrains Mono", "Consolas", "Source Code Pro"]

    static let editorThemes: [(name: String, id: String)] = [
        (L("editor.theme.dark"), "vs-dark"), (L("editor.theme.light"), "vs"), (L("editor.theme.highContrast"), "hc-black")
    ]

    static let editorLanguages: [(name: String, id: String)] = [
        ("Text", "plaintext"),
        ("C", "c"), ("C++", "cpp"), ("C#", "csharp"), ("CSS", "css"),
        ("Dart", "dart"), ("Dockerfile", "dockerfile"),
        ("Go", "go"), ("GraphQL", "graphql"),
        ("HTML", "html"), ("INI", "ini"),
        ("Java", "java"), ("JavaScript", "javascript"), ("JSON", "json"),
        ("Kotlin", "kotlin"), ("Lua", "lua"),
        ("Markdown", "markdown"), ("MySQL", "mysql"),
        ("Objective-C", "objective-c"),
        ("PHP", "php"), ("PowerShell", "powershell"),
        ("Python", "python"), ("R", "r"), ("Ruby", "ruby"), ("Rust", "rust"),
        ("SCSS", "scss"), ("Shell", "shell"), ("SQL", "sql"),
        ("Swift", "swift"), ("TypeScript", "typescript"),
        ("XML", "xml"), ("YAML", "yaml"),
    ]

    static func languageName(for id: String) -> String {
        editorLanguages.first(where: { $0.id == id })?.name ?? "Text"
    }

    static func languageID(for name: String) -> String {
        editorLanguages.first(where: { $0.name == name })?.id ?? "plaintext"
    }

    // MARK: - Public API

    func setContent(_ text: String, language: String) {
        if isReady {
            let escaped = Self.escapeForJSTemplate(text)
            let langEsc = Self.escapeForJSString(language)
            webView.evaluateJavaScript("setContent(`\(escaped)`, '\(langEsc)')")
        } else {
            pendingContent = (text, language)
        }
    }

    func getContent(completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("getContent()") { result, _ in
            completion(result as? String ?? "")
        }
    }

    /// Async version — no RunLoop spinning
    func getContentAsync() async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("getContent()") { result, _ in
                continuation.resume(returning: result as? String ?? "")
            }
        }
    }

    func markSaved() {
        webView.evaluateJavaScript("markSaved()")
    }

    /// Move keyboard focus into the Monaco editor so the user can type immediately after the
    /// editor opens (F4), instead of the focus staying on the file panel.
    func focusEditor() {
        webView.evaluateJavaScript("focusEditor()")
    }

    func setLanguage(_ lang: String) {
        let escaped = Self.escapeForJSString(lang)
        webView.evaluateJavaScript("setLanguage('\(escaped)')")
    }

    func setFontSize(_ size: Int) {
        webView.evaluateJavaScript("setFontSize(\(size))")
    }

    func setTheme(_ theme: String) {
        let escaped = Self.escapeForJSString(theme)
        webView.evaluateJavaScript("setTheme('\(escaped)')")
    }

    func toggleMinimap(_ show: Bool) {
        webView.evaluateJavaScript("toggleMinimap(\(show))")
    }

    func toggleWordWrap(_ wrap: Bool) {
        webView.evaluateJavaScript("toggleWordWrap(\(wrap))")
    }

    func toggleWhitespace(_ mode: String) {
        let escaped = Self.escapeForJSString(mode)
        webView.evaluateJavaScript("toggleWhitespace('\(escaped)')")
    }

    func toggleIndentGuides(_ show: Bool) {
        webView.evaluateJavaScript("toggleIndentGuides(\(show))")
    }

    func goToLine(_ line: Int) {
        webView.evaluateJavaScript("goToLine(\(line))")
    }

    func showFind() {
        webView.evaluateJavaScript("findText()")
    }

    func showReplace() {
        webView.evaluateJavaScript("replaceText()")
    }

    func isDirty(completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript("getIsDirty()") { result, _ in
            completion(result as? Bool ?? false)
        }
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "ready":
                isReady = true
                if let (text, lang) = pendingContent {
                    setContent(text, language: lang)
                    pendingContent = nil
                }
                onReady?()

            case "contentChanged":
                let dirty = body["isDirty"] as? Bool ?? false
                onDirtyChanged?(dirty)

            case "cursorChanged":
                let line = body["line"] as? Int ?? 1
                let col = body["column"] as? Int ?? 1
                let total = body["totalLines"] as? Int ?? 0
                let selLen = body["selectionLength"] as? Int ?? 0
                onCursorChanged?(line, col, total, selLen)

            case "save":
                onSaveRequested?()

            default:
                break
            }
        }
    }

    // MARK: - Language Detection

    static let extensionToMonacoLanguage: [String: String] = [
        // Web
        "html": "html", "htm": "html", "xhtml": "html", "vue": "html", "svelte": "html",
        "css": "css", "scss": "scss", "less": "less", "sass": "scss",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "typescript", "mts": "typescript",
        "json": "json", "jsonc": "json",
        "xml": "xml", "svg": "xml", "xsl": "xml", "xslt": "xml", "plist": "xml",
        "graphql": "graphql", "gql": "graphql",
        // Systems
        "c": "c", "h": "c",
        "cpp": "cpp", "cxx": "cpp", "cc": "cpp", "hpp": "cpp", "hxx": "cpp",
        "m": "objective-c", "mm": "objective-c",
        "swift": "swift",
        "rs": "rust",
        "go": "go",
        "java": "java", "jar": "java",
        "kt": "kotlin", "kts": "kotlin",
        "cs": "csharp",
        "fs": "fsharp", "fsx": "fsharp",
        "scala": "scala", "sc": "scala",
        "dart": "dart",
        // Scripting
        "py": "python", "pyw": "python", "pyi": "python",
        "rb": "ruby", "erb": "ruby", "gemspec": "ruby",
        "pl": "perl", "pm": "perl",
        "php": "php", "phtml": "php",
        "lua": "lua",
        "r": "r", "rmd": "r",
        "jl": "julia",
        "ex": "elixir", "exs": "elixir",
        "clj": "clojure", "cljs": "clojure", "cljc": "clojure",
        "coffee": "coffeescript",
        "tcl": "tcl",
        // Shell & config
        "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell", "ksh": "shell",
        "bat": "bat", "cmd": "bat",
        "ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
        "yaml": "yaml", "yml": "yaml",
        "toml": "ini", "ini": "ini", "conf": "ini", "cfg": "ini", "env": "ini",
        "properties": "ini",
        // Data & docs
        "sql": "sql", "mysql": "mysql", "pgsql": "pgsql",
        "md": "markdown", "markdown": "markdown", "mdx": "markdown",
        "rst": "restructuredtext",
        "tex": "latex", "latex": "latex",
        "csv": "plaintext", "tsv": "plaintext",
        // DevOps
        "dockerfile": "dockerfile",
        "makefile": "makefile",
        "tf": "hcl", "hcl": "hcl",
        "proto": "protobuf",
        "sol": "sol",
        // Misc
        "vb": "vb", "bas": "vb", "vbs": "vb",
        "pas": "pascal", "dpr": "pascal",
        "asm": "mips", "s": "mips",
        "v": "verilog", "sv": "systemverilog",
        "txt": "plaintext", "log": "plaintext",
        "gitignore": "ini", "editorconfig": "ini",
        "razor": "razor", "cshtml": "razor",
        "hbs": "handlebars", "handlebars": "handlebars",
        "twig": "twig",
        "liquid": "liquid",
    ]

    /// Decode file bytes to text, remembering which encoding worked so a later save writes
    /// the same encoding back. When nothing decodes, returns a placeholder flagged
    /// non-decodable so the caller can open the document read-only. Shared by both the
    /// standalone editor window and the embedded editor panel.
    static func decodeText(_ data: Data) -> (text: String, encoding: String.Encoding, decodable: Bool) {
        if let t = String(data: data, encoding: .utf8) { return (t, .utf8, true) }
        if let t = String(data: data, encoding: .windowsCP1251) { return (t, .windowsCP1251, true) }
        if let t = String(data: data, encoding: .isoLatin1) { return (t, .isoLatin1, true) }
        return ("(Cannot decode file)", .utf8, false)
    }

    static func detectLanguage(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent.lowercased()

        // Check filename first
        if name == "dockerfile" { return "dockerfile" }
        if name == "makefile" || name == "gnumakefile" { return "makefile" }
        if name.hasSuffix(".d.ts") { return "typescript" }

        return extensionToMonacoLanguage[ext] ?? "plaintext"
    }
}
