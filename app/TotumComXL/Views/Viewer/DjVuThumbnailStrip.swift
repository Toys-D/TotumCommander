import FCXLBridgeObjC
import FCXLDjVuUI
import SwiftUI

/// The side strip of page thumbnails for a scanned book — the same thing a PDF has, and for
/// the same reason: with a scan the pages genuinely differ, and the eye finds the map or the
/// diagram it remembers faster than any page number.
///
/// Thumbnails are drawn in the background, only for what is on screen, and remembered — a
/// decode costs hundreds of milliseconds and a book runs to hundreds of pages.
struct DjVuThumbnailStrip: View {
    let reader: FCXLDjVuReader
    let currentPage: Int
    let onSelect: (Int) -> Void
    /// Лист, на котором напечатана страница 1. Обложка и титул номера не имеют — и подпись
    /// под ними обязана говорить то же, что счётчик наверху, иначе полоса и шапка называют
    /// одно и то же место разными номерами.
    var numberingStart: Int = 0

    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var inFlight: Set<Int> = []

    private let width: CGFloat = 132
    private let thumbHeight: CGFloat = 150

    /// Одна очередь на все полосы: декодирование djvulibre не переносит, когда его дёргают
    /// сразу из двух мест.
    private static let decodeQueue = DispatchQueue(label: "com.fcxl.djvu.thumbnails",
                                                   qos: .utility)

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<Int(reader.pageCount), id: \.self) { index in
                        pageCell(index)
                            .id(index)
                            .onAppear { requestThumbnail(index) }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: currentPage) { _, page in
                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(page, anchor: .center) }
            }
        }
        .frame(width: width)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func pageCell(_ index: Int) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .textBackgroundColor))
                if let image = thumbnails[index] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: width - 32, height: thumbHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(index == currentPage
                                  ? PanelAppearanceSettings.accentColor : Color.secondary.opacity(0.35),
                                  lineWidth: index == currentPage ? 2 : 0.5))
            Text(index >= numberingStart ? "\(index - numberingStart + 1)"
                                         : L("viewer.page.coverShort"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(index == currentPage ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(index) }
    }

    /// Одна страница за раз, в фоне, и никогда дважды.
    ///
    /// Через обычную очередь, а не через `Task.detached`: замыкание задачи наследовало
    /// изоляцию представления и уезжало на ГЛАВНЫЙ поток — там же, где оно ждало
    /// декодирования, и вставала вся программа. Размер страницы спрашивается тоже отсюда:
    /// он тоже качает очередь сообщений djvulibre и на главном потоке ему делать нечего.
    private func requestThumbnail(_ index: Int) {
        guard thumbnails[index] == nil, !inFlight.contains(index) else { return }
        inFlight.insert(index)
        let reader = self.reader
        let height = thumbHeight
        Self.decodeQueue.async {
            let size = reader.pageSize(at: index)
            // Scale chosen from the page's own height, so a wide scan and a tall one both land
            // at roughly the strip's height instead of one of them coming back enormous.
            let scale = size.height > 1 ? min(1, height * 1.6 / size.height) : 0.2
            let image = DjVuPagesView.render(reader: reader, index: index, scale: max(scale, 0.05))
            DispatchQueue.main.async {
                inFlight.remove(index)
                guard let image else { return }
                // A whole book of thumbnails is still megabytes; keep a window of them.
                if thumbnails.count > 80 {
                    let far = thumbnails.keys.filter { abs($0 - currentPage) > 40 }
                    for key in far.prefix(40) { thumbnails.removeValue(forKey: key) }
                }
                thumbnails[index] = image
            }
        }
    }
}
