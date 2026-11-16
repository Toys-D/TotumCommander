import AppKit
import XCTest

@testable import TotumComXLApp

/// «Показать дальше» в просмотре большого текста: порция, ссылка, дописывание по щелчку.
@MainActor
final class ChunkedTextFeederTests: XCTestCase {

    private func makeFeeder(limit: Int) -> (ChunkedTextFeeder, NSTextView) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = false
        let feeder = ChunkedTextFeeder()
        feeder.totalLimit = limit
        feeder.textView = tv
        tv.delegate = feeder
        return (feeder, tv)
    }

    private func lines(_ count: Int) -> NSString {
        (0..<count).map { "строка \($0)" }.joined(separator: "\n") + "\n" as NSString
    }

    /// Щелчок по ссылке, как его отдаёт текстовый вид делегату, — и ждать, пока порция допишется.
    private func clickMore(_ feeder: ChunkedTextFeeder, _ tv: NSTextView) async {
        let before = feeder.shownEnd
        XCTAssertTrue(feeder.textView(tv, clickedOnLink: ChunkedTextFeeder.moreLink, at: 0))
        let deadline = Date().addingTimeInterval(3)
        while feeder.shownEnd == before, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_перваяПорцияИСсылка() {
        let source = lines(1_000)
        let (feeder, tv) = makeFeeder(limit: 2_000)
        feeder.show(LongLineClip.chunk(of: source, from: 0, totalLimit: 2_000), of: source)
        let range = try? XCTUnwrap(feeder.moreRange)
        XCTAssertNotNil(range)
        let storage = tv.textStorage!
        XCTAssertTrue(storage.string.hasPrefix("строка 0\nстрока 1\n"))
        XCTAssertTrue(storage.string.contains(String(format: L("viewer.showMore"),
                                                     (source.length - feeder.shownEnd).formatted(.number))))
        var linked = false
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if (value as? String) == ChunkedTextFeeder.moreLink { linked = true }
        }
        XCTAssertTrue(linked, "ссылка нажимается")
    }

    /// Щелчки дописывают порции подряд; в конце файла ссылки нет, и показан весь текст.
    func test_дописываниеДоКонца() async {
        let source = lines(1_000)
        let (feeder, tv) = makeFeeder(limit: 2_000)
        feeder.show(LongLineClip.chunk(of: source, from: 0, totalLimit: 2_000), of: source)
        var clicks = 0
        while feeder.moreRange != nil, clicks < 50 {
            await clickMore(feeder, tv)
            clicks += 1
        }
        XCTAssertGreaterThan(clicks, 3)
        XCTAssertNil(feeder.moreRange, "в конце ссылки нет")
        XCTAssertEqual(tv.textStorage!.string, source as String, "весь текст, без швов и пометок")
    }

    /// Пока порция читалась, открыли другой файл — опоздавшая порция не дописывается.
    func test_опоздавшаяПорцияНеДописывается() async {
        let first = lines(1_000)
        let (feeder, tv) = makeFeeder(limit: 2_000)
        feeder.show(LongLineClip.chunk(of: first, from: 0, totalLimit: 2_000), of: first)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            feeder.showMore { done.resume() }
            feeder.showPlain("другой файл")
        }
        XCTAssertEqual(tv.string, "другой файл")
    }
}
