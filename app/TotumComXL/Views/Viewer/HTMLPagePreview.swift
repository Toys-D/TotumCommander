import AppKit
import SwiftUI
import WebKit

/// Какие файлы просмотр показывает страницей, а не текстом разметки.
enum HTMLPage {
    static let extensions: Set<String> = ["html", "htm", "xhtml", "shtml"]

    static func isPage(fileName: String) -> Bool {
        extensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// Правила WebKit: странице нельзя в сеть — ни за картинкой, ни за скриптом, ни с запросом
    /// из своего кода. Просмотр идёт за курсором, и любой скачанный html начинает работать,
    /// едва на него встанешь; отправить наружу он не должен ничего, даже сам факт, что его
    /// открыли. Свои файлы рядом (картинки, стили, скрипты) остаются доступны.
    ///
    /// Выражения url-filter у WebKit без «или», поэтому по правилу на схему.
    static let networkBlockRules = """
    [
      {"trigger": {"url-filter": "^https?:"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss?:"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^ftps?:"}, "action": {"type": "block"}}
    ]
    """

    static let ruleListID = "fcxl.viewer.html.noNetwork"

    /// Что страница может открыть у себя сама: только местное. Всё остальное — отказ.
    static let localSchemes: Set<String> = ["file", "about", "data", "blob"]

    /// Что уходит наружу по щелчку на ссылке: в браузер, в почту, в программу по умолчанию.
    static let externalSchemes: Set<String> = ["http", "https", "mailto", "file"]

    /// Та же страница, только другое место на ней (#раздел) — это прокрутка, а не переход.
    static func isSameDocument(_ target: URL, as current: URL?) -> Bool {
        guard let current,
              var a = URLComponents(url: target, resolvingAgainstBaseURL: false),
              var b = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return false }
        a.fragment = nil
        b.fragment = nil
        return a.url == b.url
    }

    /// Сколько после настоящего щелчка ссылка ещё считается нажатой человеком. Ссылку,
    /// «нажатую» кодом страницы без него, наружу не открываем: иначе страница могла бы сама
    /// засыпать браузер вкладками.
    static let clickWindow: TimeInterval = 1.5

    static func isUserClick(lastClick: Date?, now: Date = Date()) -> Bool {
        guard let lastClick else { return false }
        let elapsed = now.timeIntervalSince(lastClick)
        return elapsed >= 0 && elapsed <= clickWindow
    }
}

/// Правила без сети, собранные один раз на всю программу: WebKit компилирует их не сразу,
/// и все страницы, открытые до готовности, ждут в очереди.
@MainActor
enum HTMLNetworkBlock {
    private static var compiled: WKContentRuleList?
    private static var failed = false
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    /// Где WebKit держит собранные правила. Тесты подменяют на временную папку.
    static var makeStore: () -> WKContentRuleListStore? = { WKContentRuleListStore.default() }

    static func ruleList(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { done(compiled); return }
        if failed { done(nil); return }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        guard let store = makeStore() else { finish(nil); return }
        store.compileContentRuleList(forIdentifier: HTMLPage.ruleListID,
                                     encodedContentRuleList: HTMLPage.networkBlockRules) { list, _ in
            DispatchQueue.main.async { finish(list) }
        }
    }

    private static func finish(_ list: WKContentRuleList?) {
        compiled = list
        failed = list == nil
        let queue = waiting
        waiting = []
        for done in queue { done(list) }
    }
}

/// HTML-файл как страница в браузере: стили, картинки и скрипты рядом с ним работают, сеть
/// закрыта (HTMLPage.networkBlockRules). Если правила почему-то не собрались, скрипты
/// выключаются — страница без сети важнее страницы со скриптами.
struct HTMLPagePreview: NSViewRepresentable {
    let url: URL
    /// ⌘+ / ⌘− / ⌘0 — тот же механизм, что у документов Word.
    let zoom: DocumentZoomController
    let scroll: ScrollJumpController
    /// Ссылка, по которой щёлкнули: страница сама никуда не уходит.
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(scroll: scroll, openLink: openLink) }

    func makeNSView(context: Context) -> PageWebView {
        let web = Self.makeWebView(coordinator: context.coordinator, zoom: zoom)
        context.coordinator.load(url)
        return web
    }

    /// Веб-вид страницы со всеми её запретами — отдельно от SwiftUI, чтобы тесты проверяли
    /// ровно то, что видит человек.
    @MainActor
    static func makeWebView(coordinator: Coordinator, zoom: DocumentZoomController?) -> PageWebView {
        let config = WKWebViewConfiguration()
        // Ничего не копится между файлами: ни куки, ни хранилище одной страницы не видны другой.
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let content = config.userContentController
        // В мир самой страницы: её код не должен дотянуться до прямых соединений WebRTC —
        // единственной дороги наружу, которую правила WebKit не закрывают.
        content.addUserScript(WKUserScript(source: Self.noPeerConnections,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false))
        // Свой, отдельный мир: страница не видит ни этот скрипт, ни его канал, и подделать
        // положение прокрутки не может.
        content.addUserScript(WKUserScript(source: Self.scrollReporter,
                                           injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true,
                                           in: .defaultClient))
        content.add(coordinator, contentWorld: .defaultClient, name: Self.scrollChannel)

        let web = PageWebView(frame: .zero, configuration: config)
        web.allowsMagnification = true
        web.navigationDelegate = coordinator
        zoom?.webView = web
        coordinator.web = web
        coordinator.scroll.adopt(owner: coordinator) { [weak web] toEnd in
            web?.evaluateJavaScript(toEnd ? Self.scrollToEnd : Self.scrollToTop,
                                    in: nil, in: .defaultClient, completionHandler: nil)
        }
        return web
    }

    func updateNSView(_ web: PageWebView, context: Context) {
        zoom.webView = web
        guard context.coordinator.requestedURL != url else { return }
        context.coordinator.load(url)
    }

    static func dismantleNSView(_ web: PageWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        coordinator.scroll.release(owner: coordinator)
    }

    static let scrollChannel = "fcxlScroll"

    static let noPeerConnections = """
    (function () {
      ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel'].forEach(function (name) {
        try { Object.defineProperty(window, name, {value: undefined, writable: false, configurable: false}); }
        catch (e) {}
      });
    })();
    """

    static let scrollReporter = """
    (function () {
      var post = function () {
        var el = document.scrollingElement || document.documentElement;
        if (!el) { return; }
        var overflow = Math.max(el.scrollHeight - window.innerHeight, 0);
        window.webkit.messageHandlers.\(scrollChannel).postMessage(
          {overflow: overflow, offset: window.scrollY || el.scrollTop || 0});
      };
      // Прямо, без requestAnimationFrame: тот не приходит, пока окно не на экране, а
      // события прокрутки WebKit и так шлёт не чаще кадра.
      window.addEventListener('scroll', post, {passive: true});
      window.addEventListener('resize', post);
      window.addEventListener('load', post);
      if (window.ResizeObserver) { new ResizeObserver(post).observe(document.documentElement); }
      post();
    })();
    """

    static let scrollToEnd = """
    (function (el) { el.scrollTop = el.scrollHeight; })(document.scrollingElement || document.documentElement);
    """

    static let scrollToTop = """
    (function (el) { el.scrollTop = 0; })(document.scrollingElement || document.documentElement);
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let scroll: ScrollJumpController
        let openLink: (URL) -> Void
        weak var web: PageWebView?
        /// Файл, который должен быть на экране, — даже пока правила ещё собираются.
        private(set) var requestedURL: URL?
        /// Правила без сети на месте — значит, скриптам страницы можно работать.
        private var networkBlocked = false
        private var rulesInstalled = false

        init(scroll: ScrollJumpController, openLink: @escaping (URL) -> Void) {
            self.scroll = scroll
            self.openLink = openLink
        }

        @MainActor
        func load(_ url: URL) {
            requestedURL = url
            HTMLNetworkBlock.ruleList { [weak self] list in
                guard let self, let web = self.web, self.requestedURL == url else { return }
                if let list, !self.rulesInstalled {
                    web.configuration.userContentController.add(list)
                    self.rulesInstalled = true
                }
                self.networkBlocked = self.rulesInstalled
                web.magnification = 1          // новая страница — в натуральную величину
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     preferences: WKWebpagePreferences,
                     decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            preferences.allowsContentJavaScript = networkBlocked
            guard let target = action.request.url else {
                decisionHandler(.cancel, preferences)
                return
            }
            if action.navigationType == .linkActivated {
                if HTMLPage.isSameDocument(target, as: webView.url) {
                    decisionHandler(.allow, preferences)
                    return
                }
                let clicked = HTMLPage.isUserClick(lastClick: (webView as? PageWebView)?.lastUserClick)
                if clicked, let scheme = target.scheme?.lowercased(),
                   HTMLPage.externalSchemes.contains(scheme) {
                    openLink(target)
                }
                decisionHandler(.cancel, preferences)
                return
            }
            // Сама страница (её рамки, переходы из кода) — только по местным адресам и без
            // новых окон.
            let scheme = target.scheme?.lowercased() ?? ""
            let allowed = action.targetFrame != nil && HTMLPage.localSchemes.contains(scheme)
            decisionHandler(allowed ? .allow : .cancel, preferences)
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let overflow = (body["overflow"] as? NSNumber)?.doubleValue,
                  let offset = (body["offset"] as? NSNumber)?.doubleValue,
                  overflow.isFinite, offset.isFinite else { return }
            let scale = web?.magnification ?? 1
            MainActor.assumeIsolated {
                scroll.report(owner: self, overflow: CGFloat(overflow) * scale,
                              offset: CGFloat(offset) * scale)
            }
        }
    }
}

/// WebKit без своего «кто нажал»: помнит, когда по странице последний раз щёлкнули мышью или
/// нажали клавишу — по этому отличается ссылка, нажатая человеком, от нажатой кодом страницы.
final class PageWebView: WKWebView {
    private(set) var lastUserClick: Date?

    override func mouseDown(with event: NSEvent) {
        lastUserClick = Date()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        lastUserClick = Date()
        super.keyDown(with: event)
    }
}
