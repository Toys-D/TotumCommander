import WebKit
import XCTest

@testable import TotumComXLApp

/// Прозрачная подложка веб-вида держится на приватном ключе WebKit, а `setValue(_:forKey:)`
/// на пропавшем ключе роняет программу исключением. Этот тест — сторож: когда Apple ключ
/// уберёт, он погаснет первым, до людей.
final class WebViewBackgroundTests: XCTestCase {

    @MainActor
    func test_приватныйКлючПодложкиВсёЕщёНаМесте() {
        XCTAssertTrue(WKWebView.knowsPrivateBackgroundKey,
                      "WebKit больше не знает _setDrawsBackground: — прозрачность надо делать иначе")
    }

    @MainActor
    func test_открытыйЗапаснойПутьРаботает() {
        // То, чем прозрачность делается там, где приватного ключа не станет.
        let view = WKWebView(frame: .zero)
        view.fcxlMakeBackgroundTransparent()
        // Сравнивать сами цвета нельзя: WebKit переводит их в своё цветовое пространство,
        // и «прозрачный» перестаёт быть равен NSColor.clear, оставаясь прозрачным.
        XCTAssertEqual(view.underPageBackgroundColor?.alphaComponent, 0)
    }
}
