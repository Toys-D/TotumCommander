import WebKit

extension WKWebView {
    /// Убрать белую подложку веб-вида, ничем не рискуя.
    ///
    /// Прозрачность у `WKWebView` включается приватным ключом `drawsBackground` — открытого
    /// способа Apple не дала. Беда в том, что `setValue(_:forKey:)` на пропавшем ключе не
    /// возвращает ошибку, а роняет программу исключением, — а WebKit Apple переписывает
    /// каждый год, и сборка под новый SDK берёт новый WebKit.
    ///
    /// Измерено на macOS 15: открытого `setDrawsBackground:` у вида нет вовсе, а
    /// подчёркнутый `_setDrawsBackground:` — есть, через него KVC и добирается до ключа.
    /// Поэтому сначала спрашиваем про подчёркнутый сеттер и ставим ключ только если он на
    /// месте. Заодно задаём открытый `underPageBackgroundColor`: он появился в macOS 12 и
    /// делает ту же работу там, где приватного ключа однажды не станет.
    func fcxlMakeBackgroundTransparent() {
        if responds(to: Selector(("_setDrawsBackground:"))) {
            setValue(false, forKey: "drawsBackground")
        }
        underPageBackgroundColor = .clear
    }

    /// Есть ли ещё тот самый приватный ключ. Отдельно — чтобы это проверял тест: когда Apple
    /// его уберёт, тест погаснет первым, до людей.
    static var knowsPrivateBackgroundKey: Bool {
        WKWebView(frame: .zero).responds(to: Selector(("_setDrawsBackground:")))
    }
}
