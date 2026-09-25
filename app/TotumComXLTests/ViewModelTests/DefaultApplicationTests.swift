import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import TotumComXLApp

/// Binding a KIND of file to an application, system-wide. The binding itself belongs to
/// LaunchServices and is not touched by tests; what is tested is the decision of WHAT gets
/// bound — the step that turns a file into the kind the setting applies to.
final class DefaultApplicationTests: XCTestCase {

    func test_contentType_comesFromTheExtension() {
        XCTAssertEqual(DefaultApplication.contentType(ofFileAt: "/x/картинка.png"), .png)
        XCTAssertEqual(DefaultApplication.contentType(ofFileAt: "/x/ЗАМЕТКА.TXT"), .plainText)
    }

    /// A file with no extension names no kind — binding "everything like this file" would mean
    /// nothing, so the menu offers nothing and the service refuses.
    func test_noExtension_meansNoKindToBind() {
        XCTAssertNil(DefaultApplication.contentType(ofFileAt: "/x/README"))
        XCTAssertNil(DefaultApplication.kindLabel(forFileAt: "/x/README"))
        XCTAssertNil(DefaultApplication.contentType(ofFileAt: "/x/"))
    }

    /// An extension macOS has never heard of still gets a type of its own, and that type is
    /// bindable — which is the whole point for a home-made extension.
    func test_unknownExtension_stillGetsABindableType() {
        let type = DefaultApplication.contentType(ofFileAt: "/x/данные.мойформат")
        XCTAssertNotNil(type)
    }

    func test_kindLabel_isTheExtensionAsTheMenuSaysIt() {
        XCTAssertEqual(DefaultApplication.kindLabel(forFileAt: "/x/фото.JPEG"), ".jpeg")
        XCTAssertEqual(DefaultApplication.kindLabel(forFileAt: "/x/архив.tar.gz"), ".gz")
    }
}
