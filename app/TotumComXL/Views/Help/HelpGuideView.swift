import AppKit
import SwiftUI
import WebKit

/// Полная справка по программе — Markdown из бандла, на языке программы.
///
/// Файлы `Help/help.ru.md` и `Help/help.en.md` — те же, что лежат в `docs/` репозитория
/// (там они ссылки сюда): одна справка и для читателя на GitHub, и для окна ⌘?.
enum HelpGuide {

    /// Текст справки на языке программы; нет своего — русский.
    static func markdown(language code: String = AppLanguage.current.resolvedCode) -> String {
        for candidate in [code, "ru", "en"] {
            if let url = url(forLanguage: candidate),
               let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return ""
    }

    static func url(forLanguage code: String) -> URL? {
        let name = "help.\(code)"
        // .process("Resources") может как сохранить папку Help, так и разложить файлы
        // по верху бандла — ищем и там, и там.
        return Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Help")
            ?? Bundle.module.url(forResource: name, withExtension: "md")
    }

    /// Разделы, где встречается запрос (заголовок или текст); пустой запрос — всё.
    static func sections(matching query: String, in markdown: String)
    -> [(title: String, body: String)] {
        let all = MarkdownLite.sections(of: markdown)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            !$0.title.isEmpty
                && ($0.title.lowercased().contains(q) || $0.body.lowercased().contains(q))
        }
    }

    /// Готовая страница: разделы по запросу, в цветах программы.
    static func page(markdown: String, query: String, dark: Bool, accent: NSColor,
                     background: NSColor, noResults: String) -> String {
        let sections = sections(matching: query, in: markdown)
        let body: String
        if sections.isEmpty {
            body = "<p class=\"empty\">" + MarkdownLite.escape(noResults) + "</p>"
        } else {
            body = sections.map { section in
                let head = section.title.isEmpty ? "" : "## \(section.title)\n"
                return MarkdownLite.html(from: head + section.body)
            }.joined(separator: "\n")
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\"><style>"
            + css(dark: dark, accent: accent, background: background)
            + "</style></head><body>" + body + "</body></html>"
    }

    // MARK: - Оформление

    static func cssColor(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "rgba(%d,%d,%d,%.3f)",
                      Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)), c.alphaComponent)
    }

    private static func css(dark: Bool, accent: NSColor, background: NSColor) -> String {
        let text = dark ? "rgba(235,235,240,0.92)" : "rgba(20,20,25,0.92)"
        let muted = dark ? "rgba(235,235,240,0.62)" : "rgba(20,20,25,0.62)"
        let line = dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.12)"
        let codeBackground = dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)"
        let rowBackground = dark ? "rgba(255,255,255,0.035)" : "rgba(0,0,0,0.03)"
        let accentText = cssColor(accent)
        return """
        html { background: \(cssColor(background)); }
        body { margin: 0; padding: 18px 24px 32px; color: \(text); font: 13px/1.5 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }
        h1 { font-size: 22px; font-weight: 600; margin: 0 0 12px; }
        h2 { font-size: 17px; font-weight: 600; margin: 28px 0 8px; color: \(accentText); }
        h3 { font-size: 14px; font-weight: 600; margin: 18px 0 6px; }
        h4 { font-size: 13px; font-weight: 600; margin: 14px 0 4px; }
        p { margin: 0 0 10px; }
        ul, ol { margin: 0 0 10px; padding-left: 22px; }
        li { margin: 2px 0; }
        hr { border: 0; border-top: 1px solid \(line); margin: 22px 0; }
        code { font: 12px "SF Mono", Menlo, monospace; background: \(codeBackground); padding: 1px 5px; border-radius: 4px; }
        strong { font-weight: 600; }
        a { color: \(accentText); text-decoration: none; }
        table { border-collapse: collapse; width: 100%; margin: 6px 0 14px; font-size: 12.5px; }
        th, td { text-align: left; vertical-align: top; padding: 6px 10px; border-bottom: 1px solid \(line); }
        th { font-weight: 600; color: \(muted); font-size: 11.5px; text-transform: uppercase; letter-spacing: 0.02em; }
        tbody tr:nth-child(even) { background: \(rowBackground); }
        .empty { color: \(muted); padding: 20px 0; }
        ::selection { background: \(accentText); color: white; }
        """
    }
}

/// Веб-вид со справкой: перестраивается при смене запроса, темы и акцента.
struct HelpGuideView: View {
    let query: String
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""

    var body: some View {
        let dark = colorScheme == .dark
        HelpGuideWebView(html: HelpGuide.page(
            markdown: HelpGuide.markdown(), query: query, dark: dark,
            accent: PanelAppearanceSettings.nsColor(from: accentColorHex, fallback: .systemPurple),
            background: PanelAppearanceSettings.interfaceNSColor(dark: dark),
            noResults: L("help.noResults")))
    }
}

struct HelpGuideWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(html, baseURL: nil)
        context.coordinator.loaded = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    /// Ссылки из справки открываются в браузере, а не внутри окна.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = ""

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
