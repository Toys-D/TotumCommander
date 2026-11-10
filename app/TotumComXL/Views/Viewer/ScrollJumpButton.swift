import AppKit
import SwiftUI

/// Где сейчас прокрутка показанного документа и как прыгнуть в его конец или начало.
///
/// Большой документ тащить ползунком неудобно: он тонкий, прячется, а на длинном файле от
/// малейшего движения уезжает на сотни строк. Кнопка в углу делает то же, что «наверх» на
/// сайтах, только сначала — вниз. Сам документ бывает трёх родов: текст AppKit (обычный
/// и большой файл, разметка Markdown) и страница WebKit; каждый сообщает сюда, где он, и
/// оставляет, чем его прокрутить.
@MainActor
final class ScrollJumpController: ObservableObject {
    /// Документ длиннее окна — есть куда прыгать.
    @Published private(set) var canScroll = false
    /// Уже внизу: кнопка смотрит вверх и ведёт в начало.
    @Published private(set) var atEnd = false

    /// Меньше этого запаса прыгать некуда — кнопка над почти помещающимся текстом только мешает.
    static let minimumOverflow: CGFloat = 40
    /// Насколько не дойти до низа и всё равно считаться внизу: последняя строка уже видна.
    static let endSlack: CGFloat = 4

    private weak var trackedScrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var jumpAction: ((_ toEnd: Bool) -> Void)?
    /// Кому принадлежат сведения сейчас: прокрутка AppKit или страница. Ушедший вид не должен
    /// стирать то, что уже сообщил пришедший на его место.
    private var ownerID: ObjectIdentifier?

    /// Нажатие кнопки: вниз, а если уже внизу — в начало.
    func jump() {
        jumpAction?(!atEnd)
    }

    /// Положение прокрутки сообщает сам документ — страница WebKit.
    func report(owner: AnyObject, overflow: CGFloat, offset: CGFloat) {
        guard ownerID == ObjectIdentifier(owner) else { return }
        apply(overflow: overflow, offset: offset)
    }

    /// Документ, который прокручивается сам, и чем его прокрутить.
    func adopt(owner: AnyObject, jump: @escaping (_ toEnd: Bool) -> Void) {
        stopObserving()
        trackedScrollView = nil
        ownerID = ObjectIdentifier(owner)
        jumpAction = jump
        apply(overflow: 0, offset: 0)
    }

    /// Вид ушёл с экрана — если сведения были его, кнопка пропадает.
    func release(owner: AnyObject) {
        guard ownerID == ObjectIdentifier(owner) else { return }
        stopObserving()
        trackedScrollView = nil
        ownerID = nil
        jumpAction = nil
        apply(overflow: 0, offset: 0)
    }

    /// Следить за прокруткой AppKit: её сдвиг, размер окна и рост документа (текст большого
    /// файла приезжает позже и раскладывается по мере прокрутки).
    func track(_ scrollView: NSScrollView) {
        stopObserving()
        trackedScrollView = scrollView
        ownerID = ObjectIdentifier(scrollView)
        jumpAction = { [weak scrollView] toEnd in
            guard let scrollView else { return }
            Self.jump(scrollView, toEnd: toEnd)
        }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        let refresh: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromScrollView() }
        }
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                             object: clip, queue: .main, using: refresh))
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                             object: clip, queue: .main, using: refresh))
        if let document = scrollView.documentView {
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                                 object: document, queue: .main, using: refresh))
        }
        refreshFromScrollView()
    }

    func refreshFromScrollView() {
        guard let scrollView = trackedScrollView else { return }
        let metrics = Self.metrics(of: scrollView)
        apply(overflow: metrics.overflow, offset: metrics.offset)
    }

    private func apply(overflow: CGFloat, offset: CGFloat) {
        let scrollable = overflow > Self.minimumOverflow
        let end = scrollable && offset >= overflow - Self.endSlack
        if canScroll != scrollable { canScroll = scrollable }
        if atEnd != end { atEnd = end }
    }

    private func stopObserving() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
    }

    // MARK: - Прокрутка AppKit

    /// Сколько документа не помещается и сколько от него уже прокручено сверху.
    static func metrics(of scrollView: NSScrollView) -> (overflow: CGFloat, offset: CGFloat) {
        guard let document = scrollView.documentView else { return (0, 0) }
        let clip = scrollView.contentView
        let overflow = max(document.bounds.height - clip.bounds.height, 0)
        let fromTop = document.isFlipped
            ? clip.bounds.minY - document.bounds.minY
            : document.bounds.maxY - clip.bounds.maxY
        return (overflow, min(max(fromTop, 0), overflow))
    }

    /// Прыжок в конец или в начало. У текста — через его же раскладку: она ленивая
    /// (allowsNonContiguousLayout), высота документа до прокрутки только прикинута, и
    /// голый сдвиг по ней останавливался бы посреди файла.
    static func jump(_ scrollView: NSScrollView, toEnd: Bool) {
        if let text = scrollView.documentView as? NSTextView {
            let length = text.textStorage?.length ?? 0
            text.scrollRangeToVisible(NSRange(location: toEnd ? length : 0, length: 0))
            if toEnd { text.scrollToEndOfDocument(nil) } else { text.scrollToBeginningOfDocument(nil) }
            return
        }
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let overflow = max(document.bounds.height - clip.bounds.height, 0)
        let y: CGFloat = document.isFlipped == toEnd ? overflow : 0
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: document.bounds.minY + y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Связь прокрутки AppKit с кнопкой: заводится, когда вид сделан, и снимается, когда он уходит
/// с экрана, — держит её координатор вида.
final class ScrollJumpLink {
    private weak var controller: ScrollJumpController?
    private weak var scrollView: NSScrollView?

    @MainActor
    func attach(_ controller: ScrollJumpController?, to scrollView: NSScrollView) {
        self.controller = controller
        self.scrollView = scrollView
        controller?.track(scrollView)
    }

    @MainActor
    func detach() {
        guard let controller, let scrollView else { return }
        controller.release(owner: scrollView)
    }
}

/// Круглая кнопка в правом нижнем углу документа: стрелка вниз — в конец, внизу — стрелка
/// вверх, в начало. Видна, только когда документ длиннее окна.
struct ScrollJumpButton: View {
    @ObservedObject var controller: ScrollJumpController
    /// После нажатия клавиатура возвращается туда, где была (курсор панели не гаснет).
    var afterJump: () -> Void = {}

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    @State private var isHovered = false

    static let diameter: CGFloat = 34

    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    var body: some View {
        if controller.canScroll {
            let title = L(controller.atEnd ? "viewer.scroll.toTop" : "viewer.scroll.toEnd")
            Button {
                controller.jump()
                afterJump()
            } label: {
                Image(systemName: controller.atEnd ? "arrow.up" : "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isHovered ? accent : Color.primary.opacity(0.75))
                    .frame(width: Self.diameter, height: Self.diameter)
                    // Подложка — непрозрачное стекло: кнопка лежит поверх текста, и в обеих
                    // темах буквы под ней не должны просвечивать сквозь стрелку.
                    .background(Circle().fill(.regularMaterial))
                    .background(Circle().fill(isHovered ? accent.opacity(0.18) : Color.clear))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(isHovered ? 0.25 : 0.15)))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.85)
            .onHover { isHovered = $0 }
            .help(title)
            .accessibilityLabel(title)
            .transition(.opacity)
        }
    }
}
