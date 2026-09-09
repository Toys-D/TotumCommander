import SwiftUI
import WebKit

/// Where the reader is standing: which chapter, which page inside it.
struct BookReaderState: Equatable, Sendable {
    var chapterIndex = 0
    var chapterCount = 0
    var page = 0
    var pageCount = 1
    /// A locator for the topmost visible text, so a bookmark survives a resize: the pages of
    /// a book are not fixed the way a PDF's are — change the window width and they renumber.
    var anchor: String?
}

/// The book itself, laid out in columns like a real page.
///
/// One chapter at a time in the web view — that, and not any clever streaming, is what keeps
/// a forty-megabyte book from choking: the DOM never holds the whole thing.
struct BookReaderView: NSViewRepresentable {
    let document: BookDocument
    @Binding var state: BookReaderState
    /// Where to land when the book opens — a remembered position or a bookmark.
    var startAt: ReaderLocation?
    /// Always true now. Kept as a parameter rather than deleted outright because the paging
    /// machinery below still numbers pages by screenfuls — the counter, the side strip and
    /// the bookmarks all rely on it.
    var scrolling: Bool = true
    var onStateChange: (BookReaderState) -> Void = { _ in }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "fcxlBook")
        configuration.userContentController.addUserScript(
            WKUserScript(source: "window.fcxlScrolling = \(scrolling);",
                         injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.pagingScript, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        // Paper is white — asked for in as many words, and right: a wall of text on black is
        // tiring to read, and every reader from Preview to a Kindle shows a page, not a hole.
        context.coordinator.web = web
        context.coordinator.load(chapter: state.chapterIndex, document: document,
                                 startAt: startAt)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedChapter != state.chapterIndex {
            context.coordinator.load(chapter: state.chapterIndex, document: document,
                                     startAt: nil)
        } else if context.coordinator.reportedPage != state.page {
            context.coordinator.goToPage(state.page)
        }
    }

    /// Without this the coordinator is kept alive by the configuration and the book never lets
    /// go of its files — the same leak already fixed once for the DjVu reader.
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "fcxlBook")
        web.navigationDelegate = nil
        coordinator.web = nil
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(parent: self)
        BookReaderBridge.shared.current = coordinator
        return coordinator
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: BookReaderView
        weak var web: WKWebView?
        private(set) var loadedChapter = -1
        private(set) var reportedPage = 0
        private var pendingAnchor: String?
        /// Set when the previous chapter was entered backwards: it must open at its end.
        private var landOnLastPage = false

        init(parent: BookReaderView) {
            self.parent = parent
        }

        func load(chapter index: Int, document: BookDocument, startAt: ReaderLocation?) {
            guard document.chapters.indices.contains(index), let web else { return }
            loadedChapter = index
            pendingAnchor = startAt?.anchor
            let file = document.chapters[index].file
            // Read access to the book's own folder — pictures and CSS live beside the chapter.
            web.loadFileURL(file, allowingReadAccessTo: document.root)
        }

        func goToPage(_ page: Int) {
            web?.evaluateJavaScript("window.fcxlBook && fcxlBook.goto(\(page))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if landOnLastPage {
                landOnLastPage = false
                webView.evaluateJavaScript("window.fcxlBook && fcxlBook.gotoEnd()")
                return
            }
            if let anchor = pendingAnchor {
                pendingAnchor = nil
                let escaped = anchor.replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript(
                    "window.fcxlBook && fcxlBook.scrollToAnchor('\(escaped)')")
            }
        }

        /// Only the book's own files may be shown. A link out to the web in a pirated book
        /// must not turn the reader into a browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            decisionHandler(url.isFileURL ? .allow : .cancel)
        }

        /// Move a page from outside — the header buttons and the viewer's key monitor.
        func turn(_ direction: Int) {
            web?.evaluateJavaScript("window.fcxlBook && fcxlBook.turn(\(direction))")
        }

        /// Go straight to a page — this is what a click in the side strip does. Going through
        /// the binding did not work: the reported page and the requested one chased each
        /// other and the view decided nothing had changed.
        func goto(page: Int) {
            web?.evaluateJavaScript("window.fcxlBook && fcxlBook.goto(\(page))")
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any] else { return }

            // The page ran off the end of a chapter: give it the next one, opened at the
            // right end — forward means its first page, back means its last.
            if (payload["event"] as? String) == "chapter" {
                let step = payload["step"] as? Int ?? 1
                let target = loadedChapter + step
                guard parent.document.chapters.indices.contains(target) else { return }
                landOnLastPage = step < 0
                var next = parent.state
                next.chapterIndex = target
                next.page = 0
                parent.state = next
                parent.onStateChange(next)
                load(chapter: target, document: parent.document, startAt: nil)
                return
            }
            var next = parent.state
            next.pageCount = max(1, payload["count"] as? Int ?? 1)
            next.page = payload["page"] as? Int ?? 0
            next.anchor = payload["anchor"] as? String
            next.chapterIndex = loadedChapter
            next.chapterCount = parent.document.chapters.count
            reportedPage = next.page
            guard next != parent.state else { return }
            parent.state = next
            parent.onStateChange(next)
        }
    }

    /// Columns are what make pages: the text flows sideways in page-width columns, and moving
    /// a page is scrolling by exactly one column. The publisher's own CSS is kept — ours is
    /// added last, so it wins only where it must.
    private static let pagingScript = """
    (function () {
      var scrolling = !!window.fcxlScrolling;
      var style = document.createElement('style');
      style.textContent = scrolling ? `
        /* Лента: обычная вертикальная прокрутка, как у страницы в браузере или PDF. */
        html, body { margin: 0; background: #ffffff; }
        body {
          max-width: 42em; margin: 0 auto; padding: 30px 36px 60px;
          hyphens: auto; color: #1a1a1a;
          font: 17px/1.62 -apple-system, "Helvetica Neue", serif;
        }
        img, svg { max-width: 100%; height: auto; }
        a { color: #0b5cad; }
      ` : `
        html, body { margin: 0; height: 100%; overflow: hidden; }
        body {
          height: 100%; padding: 28px 34px; box-sizing: border-box;
          column-width: 34em; column-gap: 52px; column-fill: auto;
          -webkit-column-width: 34em; -webkit-column-gap: 52px;
          hyphens: auto; orphans: 2; widows: 2;
          font: 17px/1.62 -apple-system, "Helvetica Neue", serif;
          color: #1a1a1a; background: #ffffff;
        }
        img, svg { max-width: 100%; max-height: 92%; height: auto; break-inside: avoid; }
        html { background: #ffffff; }
        a { color: #0b5cad; }
      `;
      document.head.appendChild(style);

      function step() {
        if (scrolling) return document.documentElement.clientHeight;
        var s = getComputedStyle(document.body);
        return document.documentElement.clientWidth + (parseFloat(s.columnGap) || 0);
      }
      function pageCount() {
        if (scrolling) {
          return Math.max(1, Math.ceil(document.body.scrollHeight / step()));
        }
        return Math.max(1, Math.round(document.body.scrollWidth / step()));
      }
      function current() {
        var el = document.scrollingElement;
        if (scrolling) return Math.round((el.scrollTop || 0) / step());
        return Math.round((el.scrollLeft || 0) / step());
      }
      function anchor() {
        var range = document.caretRangeFromPoint(10, 10);
        if (!range) return null;
        var node = range.startContainer, path = [];
        while (node && node !== document.body) {
          var parent = node.parentNode;
          if (!parent) break;
          path.unshift(Array.prototype.indexOf.call(parent.childNodes, node));
          node = parent;
        }
        return path.join('/') + ':' + range.startOffset;
      }
      function report() {
        window.webkit.messageHandlers.fcxlBook.postMessage({
          count: pageCount(), page: current(), anchor: anchor()
        });
      }
      window.fcxlBook = {
        goto: function (p) {
          var el = document.scrollingElement;
          if (scrolling) { el.scrollTop = Math.max(0, p) * step(); }
          else { el.scrollLeft = Math.max(0, p) * step(); }
          report();
        },
        turn: function (direction) {
          var page = current(), last = pageCount() - 1;
          if (direction > 0 && page >= last) {
            window.webkit.messageHandlers.fcxlBook.postMessage({ event: 'chapter', step: 1 });
            return;
          }
          if (direction < 0 && page <= 0) {
            window.webkit.messageHandlers.fcxlBook.postMessage({ event: 'chapter', step: -1 });
            return;
          }
          this.goto(page + (direction > 0 ? 1 : -1));
        },
        gotoEnd: function () { this.goto(pageCount() - 1); },
        pageCount: pageCount,
        current: current,
        scrollToAnchor: function (locator) {
          if (!locator) return;
          var parts = locator.split(':')[0].split('/').filter(function (x) { return x !== ''; });
          var node = document.body;
          for (var i = 0; i < parts.length && node; i++) {
            node = node.childNodes[parseInt(parts[i], 10)];
          }
          if (!node) return;
          var element = node.nodeType === 3 ? node.parentElement : node;
          if (!element) return;
          element.scrollIntoView();
          // Land ON a page boundary, not halfway through a column.
          document.scrollingElement.scrollLeft = current() * step();
          report();
        }
      };
      // The body does not scroll (overflow:hidden), so an ordinary wheel gesture does
      // NOTHING — which is exactly what "листать не могу" looked like. Vertical wheel is
      // turned into page movement by hand.
      var wheelBusy = false;
      window.addEventListener('wheel', function (e) {
        // В ленте колесо и трекпад работают сами — вот это и есть «прокручивать как pdf».
        if (scrolling) return;
        e.preventDefault();
        if (wheelBusy) return;
        var delta = Math.abs(e.deltaY) > Math.abs(e.deltaX) ? e.deltaY : e.deltaX;
        if (Math.abs(delta) < 4) return;
        wheelBusy = true;
        setTimeout(function () { wheelBusy = false; }, 180);
        window.fcxlBook.turn(delta > 0 ? 1 : -1);
      }, { passive: false });

      // Keys have to work with the focus INSIDE the web view too: those events never reach
      // the AppKit monitor outside.
      window.addEventListener('keydown', function (e) {
        var forward = ['ArrowRight', 'PageDown', 'ArrowDown', ' '];
        var back = ['ArrowLeft', 'PageUp', 'ArrowUp'];
        if (forward.indexOf(e.key) >= 0) { e.preventDefault(); window.fcxlBook.turn(1); }
        else if (back.indexOf(e.key) >= 0) { e.preventDefault(); window.fcxlBook.turn(-1); }
      });
      document.body.setAttribute('tabindex', '0');
      document.body.focus();

      if (scrolling) {
        var scrollTimer = null;
        window.addEventListener('scroll', function () {
          if (scrollTimer) clearTimeout(scrollTimer);
          scrollTimer = setTimeout(report, 120);
        }, { passive: true });
      }

      // A resize renumbers every page — the strip and the bookmarks must hear about it.
      new ResizeObserver(function () { report(); }).observe(document.body);
      setTimeout(report, 30);
    })();
    """
}


/// A thin way for the viewer's header to reach the reader that is on screen — the buttons
/// live in SwiftUI, the paging lives in the web view, and they must not be wired through
/// half a dozen bindings to meet.
@MainActor
final class BookReaderBridge {
    static let shared = BookReaderBridge()
    weak var current: BookReaderView.Coordinator?

    func turn(_ direction: Int) { current?.turn(direction) }
    func goto(page: Int) { current?.goto(page: page) }
}
