import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Как выглядит окно «Новое подключение».
///
/// Внешность проверяется картинкой: окно рисуется в файл, и на него можно посмотреть — это
/// быстрее и надёжнее, чем щёлкать по живой программе и описывать увиденное словами.
/// Заодно это проверка, что вид вообще собирается: SwiftUI умеет разваливаться только
/// в работе, и без такой отрисовки поломка нашлась бы у человека.
@MainActor
final class NewConnectionLookTests: XCTestCase {

    private static var folder: String {
        ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] ?? NSTemporaryDirectory()
    }

    func test_окноРисуетсяВОбеихТемах() throws {
        for (name, scheme) in [("светлая", ColorScheme.light), ("тёмная", ColorScheme.dark)] {
            // Тема задаётся окружением SwiftUI, а не `NSAppearance.current`: последнее
            // ImageRenderer не слушает, и «тёмная» картинка выходила такой же светлой —
            // проверка врала бы, показывая одно и то же дважды.
            NSAppearance.current = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)

            // Рисуются сами плитки: ImageRenderer не умеет разворачивать ScrollView и
            // отдаёт пустоту вместо содержимого — проверять было бы нечего.
            let view = NewConnectionDialogView(session: FCXLDialogSession()).chooser
                .frame(width: 520)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: 520, height: nil)

            let image = try XCTUnwrap(renderer.nsImage, "окно нарисовалось (\(name))")
            XCTAssertGreaterThan(image.size.width, 100)

            let data = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: data)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: Self.folder + "/подключение-\(name).png"))
        }
    }
}
