import FCXLDjVuUI
import SwiftUI
import QuickLook
import QuickLookUI
import PDFKit
import WebKit
import AVKit
import FCXLBridgeObjC

// MARK: - Shared Types

struct ViewerTextLine: Identifiable {
    let number: Int
    let value: String
    var id: Int { number }
}

struct ViewerHexLine: Identifiable {
    let index: Int
    let offset: UInt64
    let bytesText: String
    let asciiText: String
    var id: Int { index }
}

struct PreviewMetadataEntry: Identifiable, Sendable {
    let key: String
    let value: String
    var id: String { key }
}

private struct FolderEntry: Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64
    var id: String { path }
}

private struct EncodingProbe {
    let name: String
    let bomLength: Int
    let value: String.Encoding
}

// MARK: - UnifiedFileViewer

struct UnifiedFileViewer: View {
    @ObservedObject var viewModel: PanelViewModel
    var onClose: (() -> Void)?
    /// Needed to extract the file under the cursor when previewing inside an archive.
    var operations: FileOperationsService?
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    /// The page strip beside a PDF. Remembered between files and between launches — a person
    /// who works with documents wants it every time, and one who does not never sees it again.
    @AppStorage("fcxl.pdfThumbnails") private var showsPDFThumbnails = true
    /// Pages in the PDF on screen, counted once when it loads. Asking the file inside the body
    /// would open the document again on every redraw.
    @State private var pdfPageCount = 0
    /// Whether the document on screen has any page WITHOUT text of its own. Decided with the
    /// page count, for the same reason: once per file, never per redraw.
    @State private var pdfNeedsRecognition = true
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    // MARK: State

    /// On-disk temp item for the archived file under the cursor, refreshed as the cursor moves
    /// so the preview follows the cursor inside an archive.
    @State private var archiveTempItem: FileItem?
    /// Местная копия файла из облака или с сервера. Просмотрщик умеет читать только диск,
    /// а удалённый путь для него — пустое место.
    @State private var remoteTempItem: FileItem?
    @State private var remoteLoading = false
    @State private var remoteTrouble: String?
    /// Крупный файл сам не качается: человек не просил ждать полгигабайта ради просмотра.
    @State private var remoteHeavyItem: FileItem?
    @State private var remoteTask: Task<Void, Never>?
    /// Сколько байт уже приехало и какой файл едет — полосе и надписи.
    @State private var remoteDone: Int64 = 0
    @State private var remoteTotal: Int64 = 0
    /// Человек нажал «Отмена» — просьба доходит до загрузки через это.
    ///
    /// Коробка, а не обычное состояние вида: о ходе загрузки спрашивают из чужого потока,
    /// а состояние SwiftUI оттуда читать нельзя — это гонка, и до загрузки просьба не
    /// доходила вовсе. Кнопка была, отмены не было.
    @State private var remoteCancel = CancelBox()
    @State private var forcedMode: PreviewMode? = nil
    @State private var encoding: String = "UTF-8"
    @State private var textLines: [ViewerTextLine] = []
    @State private var fastPreviewFilePath: String = ""
    @State private var useFastPreview: Bool = false
    @State private var markdownContent: NSAttributedString?
    @State private var isMarkdownFile: Bool = false
    @State private var hexLines: [ViewerHexLine] = []
    @State private var image: NSImage?
    /// What the person has done to the picture with the editing bar — see ImageEdits. Kept
    /// apart from `image`: the screen shows the preview with the edits applied, while Save
    /// puts the very same edits on the ORIGINAL file at full size.
    @State private var imageEdits = ImageEdits()
    /// The preview with the edits on it; nil while nothing has been changed.
    @State private var editedPreview: NSImage?
    @State private var imageSaving = false
    @State private var showImageColours = false
    @State private var showImageInfo = false
    /// Пока кнопка «Было» нажата, на экране исходная картинка — сравнить правки.
    @State private var showingOriginal = false
    @State private var keepImageMetadata = true
    @State private var imageSaveNote: String?
    /// Text found INSIDE a picture (Vision), as opposed to `textLines` — the lines of a text
    /// file the viewer is showing.
    @State private var pictureText: [RecognizedLine] = []
    @State private var isReadingText = false
    /// Set when the button was pressed before the picture had loaded.
    @State private var wantsTextAfterLoad = false
    /// Which page of a document is on screen as a picture (0-based), and how many there are.
    /// Non-nil only while a PDF or a DjVu is being read as a picture.
    @State private var readingDocPage: Int?
    @State private var readingDocPages = 0
    /// Which highlight is flashing "copied" right now: "<line>" or "<line>.<word>".
    @State private var copiedKey: String?
    /// Words chosen by dragging across the picture, and where the drag began.
    @State private var selectedKeys: Set<String> = []
    @State private var selectionAnchor: CGPoint?
    @State private var djvuReader: FCXLDjVuReader?
    @State private var book: BookDocument?
    @State private var bookState = BookReaderState()
    @State private var bookStart: ReaderLocation?
    @State private var positionSaver: Task<Void, Never>?
    @State private var readerMarks: [ReaderMark] = []
    @State private var djvuPages: DjVuPagesView?
    @State private var djvuPage = 0
    @AppStorage("fcxl.bookContents") private var showsBookContents = true
    /// Какие главы раскрыты в содержании. Раскрытая глава показывает свои страницы; всё
    /// остальное остаётся списком названий, по которому видно книгу целиком.
    @State private var expandedChapters: Set<Int> = []
    /// Лист, на котором напечатана страница 1. У скана перед ней лежат обложка, титул и его
    /// оборот, и «стр. 9 из 282» расходится с тем, что человек читает в книге.
    @State private var numberingStart = 0
    @AppStorage("fcxl.djvuThumbnails") private var showsDjVuThumbnails = true
    /// Открытый PDF. Держится здесь, а не внутри представления: тяжёлому документу при
    /// загрузке включается кэш готовых страниц (см. PDFPageCache), и решение об этом
    /// принимается один раз — там же, где документ читается с диска.
    @State private var pdfDocument: PDFDocument?
    @State private var pdfPage = 0
    /// Свой показанный PDF. Мост знает только про последний открытый на всю программу, а
    /// просмотрщиков бывает два — встроенный и в окне; закладка обязана вести в свой.
    @State private var pdfView: PDFView?
    /// Книга показывается ЛЕНТОЙ, и только ею. Колоночный (постраничный) вид был вторым
    /// режимом с собственной кнопкой, и оказался лишней сущностью: он ломает привычную
    /// прокрутку трекпадом ради вида бумажной страницы, а номера страниц, полоса сбоку и
    /// закладки прекрасно работают и в ленте.
    @State private var drawing: DXFDocument?
    @State private var mediaPlayer: AVPlayer?
    @State private var folderEntries: [FolderEntry] = []
    @State private var folderCount: Int = 0
    @State private var folderSize: UInt64 = 0
    @State private var genericIcon: NSImage?
    @State private var metadataEntries: [PreviewMetadataEntry] = []
    @State private var loadError: String?
    @State private var isLoading: Bool = false
    @State private var loadTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    /// The window the viewer lives in — the main one when it is embedded, its own when it is not.
    @State private var hostWindow: NSWindow?

    /// Detail the current PostScript bitmap was rendered for. Zooming past it triggers a
    /// sharper re-render (see scheduleSharperRenderIfNeeded).
    @State private var psRenderedEdge: Double = PostScriptRenderer.baseLongEdgePixels
    @State private var psRerenderTask: Task<Void, Never>?

    /// Zoom for the document mode. A plain @State reference type: the value lives on the web view,
    /// so this object only needs to survive re-renders, not publish anything.
    @State private var documentZoom = DocumentZoomController()
    @State private var imgScale: CGFloat = 1.0
    @State private var imgScaleBase: CGFloat = 1.0
    @State private var imgOffset: CGSize = .zero
    @State private var imgOffsetBase: CGSize = .zero

    private let bytesPerHexLine: Int = 16

    // MARK: Computed

    private var targetItem: FileItem? {
        if viewModel.insideArchive { return archiveTempItem }
        if viewModel.insideRemote {
            // Папку показываем как есть — её содержимое уже в панели, качать нечего.
            if let item = viewModel.cursorItem, item.isDirectory, item.name != ".." {
                return item
            }
            return remoteTempItem
        }
        guard let item = viewModel.cursorItem else { return nil }
        guard item.name != ".." else { return nil }
        return item
    }

    /// Скачать файл под курсором во временную копию (вне удалённой панели — ничего).
    private func refreshRemoteTemp() {
        remoteTask?.cancel()
        remoteTrouble = nil
        remoteHeavyItem = nil
        guard viewModel.insideRemote,
              let item = viewModel.cursorItem, !item.isDirectory, item.name != "..",
              let session = viewModel.remoteSession else {
            remoteTempItem = nil
            remoteLoading = false
            return
        }
        // Уже скачанное показываем сразу: листая папку туда-сюда, человек не должен
        // ждать одну и ту же картинку по второму разу.
        if let ready = RemoteFileCache.shared.readyCopy(of: item,
                                                        connectionID: session.connection.id) {
            remoteTempItem = FileItem.fromPath(ready)
            remoteLoading = false
            return
        }
        remoteTempItem = nil
        // Размер неизвестен — у документов Google его нет вовсе — значит и предел
        // проверить нечем; такой файл качаем, но остальные крупные спрашивают согласия.
        guard item.size == 0 || Int64(item.size) <= RemoteFileCache.quietLimit else {
            remoteHeavyItem = item
            remoteLoading = false
            return
        }
        // Курсор ещё едет — не хватаемся за файл сразу. Пролистывая папку стрелками,
        // человек проходит десяток файлов, и каждый из них означал бы выгрузку, которую
        // тут же бросят. Ждём, пока курсор остановится.
        fetchRemote(item, session: session, after: 0.3)
    }

    private func fetchRemote(_ item: FileItem, session: RemoteSession,
                             after delay: TimeInterval = 0) {
        remoteHeavyItem = nil
        remoteLoading = true
        let cancel = CancelBox()
        remoteCancel = cancel
        remoteDone = 0
        remoteTotal = Int64(item.size)
        remoteTask = Task { @MainActor in
            defer { remoteLoading = false }
            do {
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                let local = try await RemoteFileCache.shared.localCopy(
                    of: item, session: session,
                    progress: { done, total in
                        Task { @MainActor in
                            remoteDone = done
                            if total > 0 { remoteTotal = total }
                        }
                        return cancel.raised
                    })
                // Курсор мог уехать, пока файл ехал: показать не то, что под курсором,
                // хуже, чем не показать ничего.
                guard !Task.isCancelled, viewModel.cursorItem?.path == item.path else { return }
                remoteTempItem = FileItem.fromPath(local)
            } catch let error as RemoteFileSystemError {
                guard !Task.isCancelled else { return }
                if case .transferCancelled = error { return }
                remoteTrouble = error.errorDescription
            } catch {
                guard !Task.isCancelled else { return }
                remoteTrouble = error.localizedDescription
            }
        }
    }

    /// Extract the archived file under the cursor to a temp file (no-op outside an archive).
    private func refreshArchiveTemp() {
        guard viewModel.insideArchive,
              let item = viewModel.cursorItem, !item.isDirectory, item.name != "..",
              let archivePath = viewModel.archivePath,
              let operations else {
            archiveTempItem = nil
            return
        }
        if let tempPath = operations.extractArchiveEntryForPreview(
            archivePath: archivePath, entryPath: item.path) {
            archiveTempItem = FileItem.fromPath(tempPath)
        } else {
            archiveTempItem = nil
        }
    }

    /// Пока файл едет: сколько уже приехало и чем это прервать.
    ///
    /// Одного вертящегося кружка мало. Документ Google (Docs, Sheets, Slides) Диск собирает
    /// в файл на лету, и это стоит двадцати секунд — без цифр перед глазами такое ожидание
    /// неотличимо от зависшей программы, о чём и был разговор.
    private var remoteWaiting: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(L("viewer.remote.loading")).foregroundStyle(.secondary)
            if remoteTotal > 0 {
                Text(ByteText.file(remoteDone)
                     + " / "
                     + ByteText.file(remoteTotal))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                // У документа Google размера нет заранее — показываем, сколько уже пришло,
                // и говорим, почему это дольше обычного.
                Text(remoteDone > 0
                     ? ByteText.file(remoteDone)
                     : L("viewer.remote.converting"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(L("button.cancel")) { remoteCancel.raise() }
                .buttonStyle(FCXLToolbarButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Крупный файл — со спросом. Молча тянуть полгигабайта из облака ради взгляда
    /// одним глазом нельзя: это и время, и чужой трафик.
    private func remoteTooBig(_ item: FileItem) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 28)).foregroundStyle(.secondary)
            Text(L("viewer.remote.heavy", ByteText.file(Int64(item.size))))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("viewer.remote.download")) {
                if let session = viewModel.remoteSession { fetchRemote(item, session: session) }
            }
            .buttonStyle(FCXLToolbarButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewIdentity: String {
        targetItem?.path ?? "__none__"
    }

    private var currentCategory: FileCategory {
        guard let item = targetItem else { return .other }
        // По имени, а не по расширению: у «книги.fb2.zip» расширение «zip», и книгой её
        // делает как раз имя целиком.
        return fileCategory(forFileName: (item.path as NSString).lastPathComponent)
    }

    private var autoResolvedMode: PreviewMode {
        guard let item = targetItem else { return .info }
        if item.isDirectory { return .info }
        // RTF renders with its real fonts, colours and layout through Quick Look — far better
        // than dumping the raw RTF markup as plain text (what the .text category would do).
        let ext = normalizedExtension(for: item)
        if ext == "rtf" || ext == "rtfd" { return .quickLook }
        // Raster images go through Apple QuickLook — its built-in pinch
        // zoom, double-tap and bounds-respecting gestures behave better
        // than our SwiftUI .scaleEffect implementation, and it doesn't
        // bleed past the embedded panel.
        if currentCategory == .image { return .quickLook }
        // Illustrator files go to Ghostscript, NOT Quick Look or PDFKit. Measured on a real
        // file (Allumiera "for BOX.ai", 10 embedded font subsets): both Apple engines draw
        // only the background rectangle and drop every glyph, while Ghostscript renders the
        // artwork correctly. PDFKit even reports the text via page.string, so the file is
        // fine — Apple's PDF interpreter just cannot draw what Illustrator writes.
        if ext == "ai" { return .postScript }
        // Quick Look lays Word documents out in a FIXED 620pt column (measured: unchanged at panel
        // widths of 700 and 1400), so most of the panel stays empty. Our own HTML rendering fills
        // the width, reflows and allows text selection; Quick Look stays one click away.
        if isWordProcessingDocument(extension: ext) { return .document }
        return autoMode(for: currentCategory)
    }

    private var effectiveMode: PreviewMode {
        forcedMode ?? autoResolvedMode
    }

    private var formattedFileSize: String {
        guard let item = targetItem else { return "" }
        return ByteText.file(Int64(item.size))
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            contentSection
            imageEditBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .background(HostWindowReader { hostWindow = $0 })
        .onAppear {
            refreshArchiveTemp()
            refreshRemoteTemp()
            startLoadingPreview()
            installKeyMonitor()
            installScrollMonitor()
            loadReaderMarks()
        }
        .onDisappear {
            // Let go of the file, not just of playback. A paused AVPlayer still owns its item and
            // asset, and an open DjVu reader still owns its handle — on a network volume that is
            // enough to keep the share busy and refuse to unmount long after the viewer is gone.
            // Moving the cursor to another file has always done this properly; closing did not.
            mediaPlayer?.pause()
            mediaPlayer = nil
            djvuReader?.close()
            djvuReader = nil
            removeKeyMonitor()
            removeScrollMonitor()
            psRerenderTask?.cancel()
            cancelLoadTask()
            // Скачивание брошенного просмотра никому не нужно — но копия, если она уже
            // доехала, остаётся: следующий взгляд на тот же файл будет мгновенным.
            remoteTask?.cancel()
        }
        .onChange(of: viewModel.cursorItem?.path) { _ in
            // Cursor moved inside an archive → extract the new file; previewIdentity then
            // changes and the reload below fires.
            refreshArchiveTemp()
            refreshRemoteTemp()
        }
        .onChange(of: previewIdentity) { _ in
            loadReaderMarks()
            book = nil
            bookState = BookReaderState()
            // Новая книга открывается с раскрытой первой главой: содержание сразу
            // показывает, из чего книга сделана, а свернуть его теперь есть чем.
            expandedChapters = [0]
            bookStart = nil
            djvuPage = 0
            forcedMode = nil
            pictureText = []
            selectedKeys = []
            readingDocPage = nil
            readingDocPages = 0
            pdfPageCount = 0
            pdfDocument = nil
            pdfPage = 0
            pdfView = nil
            // Until the document is read, assume it needs nothing: a button that appears and
            // then vanishes is worse than one that appears a moment late.
            pdfNeedsRecognition = false
            startLoadingPreview()
        }
        .onChange(of: forcedMode) { _ in
            startLoadingPreview()
        }
        .onChange(of: bookState.chapterIndex) { chapter in
            // Дочитали до следующего рассказа — содержание едет следом. Раскрытой остаётся
            // одна глава, и это всегда та, которую читают.
            guard !expandedChapters.isEmpty else { return }
            expandedChapters = [chapter]
        }
        .onChange(of: imgScale) { _ in
            scheduleSharperRenderIfNeeded()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text(targetItem?.name ?? L("viewer.noFile"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                pdfPageStripToggle
                bookContentsToggle
                djvuStripToggle
                bookTurnControls
                pageCounter
                bookmarkControls
                textRecognitionControls
                if let onClose {
                    Button(L("button.close"), action: onClose)
                        .frame(minWidth: 44, minHeight: 30)
                        .contentShape(Rectangle())
                }
            }
            HStack(spacing: 14) {
                if targetItem != nil && !(targetItem?.isDirectory ?? true) {
                    Text("\(L("properties.size")): \(formattedFileSize)")
                    Text("\(L("viewer.encoding")): \(encoding)")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            modeBar
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Чем показывать этот файл.
    ///
    /// Раньше здесь стояли в ряд ВСЕ четырнадцать режимов, и на любой разумной ширине окна
    /// их подписи стирались в огрызки — «Изо…», «До…», «Dj…». Выбор одного из многих — это
    /// список, а не частокол кнопок: в списке помещаются полные названия, видно, что доступно
    /// для этого файла, а освободившееся место досталось тому, чем действительно пользуются.
    ///
    /// Рядом со списком остаются две кнопки — «Авто» и подходящий этому файлу режим: девять
    /// раз из десяти нужен один из них, и терять на них лишний щелчок было бы обидно.
    private var modeBar: some View {
        HStack(spacing: 6) {
            quickModeButton(.auto)
            let natural = autoMode(for: currentCategory)
            if natural != .auto, natural != .quickLook {
                quickModeButton(natural)
            }

            Menu {
                ForEach(PreviewMode.allCases) { mode in
                    Button {
                        applyMode(mode)
                    } label: {
                        // Галочка у выбранного, полное имя, свой значок — всё, чего не влезало
                        // в кнопку шириной в три буквы.
                        Label(isModeSelected(mode) ? "✓ " + mode.title : mode.title,
                              systemImage: mode.iconName)
                    }
                    .disabled(isModeDisabled(mode))
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: effectiveMode.iconName).font(.system(size: 11))
                    Text(effectiveMode.title).font(.caption).lineLimit(1)
                }
                .frame(minHeight: 30)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("viewer.mode.choose"))

            Spacer()
        }
    }

    /// Кнопка режима «в один щелчок» — для тех двух, что нужны почти всегда.
    private func quickModeButton(_ mode: PreviewMode) -> some View {
        let selected = isModeSelected(mode)
        let disabled = isModeDisabled(mode)
        return Button {
            applyMode(mode)
        } label: {
            Label(mode.quickViewLabel, systemImage: mode.iconName)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? accent.opacity(0.18) : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(selected ? accent.opacity(0.55) : Color.secondary.opacity(0.25),
                                lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(selected ? 1.0 : disabled ? 0.2 : 0.7)
        .disabled(disabled)
        .help(mode.title)
    }

    // MARK: - Content

    private var contentSection: some View {
        Group {
            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .padding(12)
            } else {
                ZStack {
                    activeContent
                    if isLoading {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var activeContent: some View {
        if remoteLoading {
            remoteWaiting
        } else if let heavy = remoteHeavyItem {
            remoteTooBig(heavy)
        } else if let remoteTrouble {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text(remoteTrouble).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let item = targetItem, item.isDirectory {
            folderPreview
        } else {
            switch effectiveMode {
            case .quickLook:
                if let item = targetItem {
                    QuickLookPreviewView(url: URL(fileURLWithPath: item.path))
                } else {
                    Text(L("viewer.noFile")).foregroundStyle(.secondary)
                }
            case .image:
                imageContent
            case .text:
                textContent
            case .hex:
                hexContent
            case .document:
                if let item = targetItem {
                    WordDocumentPreview(url: URL(fileURLWithPath: item.path), zoom: documentZoom)
                } else {
                    Text(L("viewer.noFile")).foregroundStyle(.secondary)
                }
            case .pdf:
                // The frame is spelt out: the representable hands back a CONTAINER of two
                // views, and a container has no size of its own to offer SwiftUI — it
                // collapsed to nothing and the page vanished with it.
                if let document = pdfDocument {
                    PDFKitPreviewView(document: document,
                                      showsThumbnails: showsPDFThumbnails,
                                      onPageChange: { pdfPage = $0 },
                                      onReady: { pdfView = $0 })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if targetItem != nil || isLoading {
                    // Документ читается с диска и заодно взвешивается — доли секунды.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(L("viewer.pdfNotLoaded")).foregroundStyle(.secondary)
                }
            case .drawing:
                if let drawing {
                    if drawing.isBinary {
                        Text(L("viewer.dxf.binary")).foregroundStyle(.secondary)
                    } else if drawing.isEmpty {
                        Text(L("viewer.dxf.empty")).foregroundStyle(.secondary)
                    } else {
                        DXFView(document: drawing, ink: .primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(L("viewer.pdfNotLoaded")).foregroundStyle(.secondary)
                }
            case .book:
                if let book {
                    HStack(spacing: 0) {
                        if showsBookContents, book.chapters.count > 1 {
                            // The strip of a book shows CHAPTERS, not page thumbnails: the
                            // pages of a book renumber on every resize, and a column of
                            // identical grey rectangles tells nobody anything.
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 1) {
                                    ForEach(Array(book.chapters.enumerated()), id: \.offset) {
                                        index, chapter in
                                        chapterRow(index: index, chapter: chapter)
                                        // Страницы показывает только раскрытая глава — и
                                        // раскрыть можно ту, которую читают: число страниц
                                        // главы известно лишь после её вёрстки, а верстать
                                        // всю книгу ради боковой полосы бессмысленно.
                                        if index == bookState.chapterIndex,
                                           expandedChapters.contains(index),
                                           bookState.pageCount > 1 {
                                            pageGrid(count: bookState.pageCount)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(width: 200)
                            .background(Color(nsColor: .controlBackgroundColor))
                            Divider()
                        }
                        BookReaderView(document: book, state: $bookState, startAt: bookStart,
                                       scrolling: true,
                                       onStateChange: { rememberPlace($0) })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(L("viewer.book.unreadable")).foregroundStyle(.secondary)
                }
            case .djvu:
                if let djvuReader {
                    HStack(spacing: 0) {
                        if showsDjVuThumbnails, djvuReader.pageCount > 1 {
                            DjVuThumbnailStrip(
                                reader: djvuReader, currentPage: djvuPage,
                                onSelect: { page in
                                    (djvuPages ?? DjVuPageBridge.shared.current)?
                                        .scrollToPage(page)
                                },
                                numberingStart: numberingStart)
                                // Своё состояние на КАЖДУЮ книгу: без этого @State полосы
                                // переживал смену читателя, и вторая книга открывалась с
                                // миниатюрами первой.
                                .id(targetItem?.path ?? "")
                            Divider()
                        }
                    DjVuPreviewView(reader: djvuReader,
                                    onReady: { pages in
                                        djvuPages = pages
                                        DjVuPageBridge.shared.current = pages
                                    },
                                    onPageChange: { djvuPage = $0 })
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(L("viewer.pdfNotLoaded")).foregroundStyle(.secondary)
                }
            case .video:
                if let mediaPlayer {
                    GeometryReader { geo in
                        MediaPreviewView(player: mediaPlayer)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    Text(L("viewer.mediaNotLoaded")).foregroundStyle(.secondary)
                }
            case .postScript:
                imageContent
            case .font:
                if let item = targetItem {
                    FontSpecimenView(url: URL(fileURLWithPath: item.path))
                } else {
                    Text(L("viewer.noFile")).foregroundStyle(.secondary)
                }
            case .info:
                infoContent
            case .auto:
                EmptyView()
            }
        }
    }

    // MARK: - Text Content

    private var textContent: some View {
        Group {
            if isMarkdownFile, let markdownContent {
                // Not a SwiftUI Text: a document-sized one took seconds to lay out — see
                // MarkdownStyler.
                MarkdownPreview(content: markdownContent)
            } else {
                plainTextContent
            }
        }
    }

    private var plainTextContent: some View {
        Group {
            if useFastPreview {
                FastTextPreview(filePath: fastPreviewFilePath, encoding: encoding)
            } else if textLines.isEmpty && !isLoading {
                Text(L("viewer.emptyFile"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(textLines) { line in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(line.number))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                                Text(line.value)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    // MARK: - Image Content

    private var imageContent: some View { imagePreview }

    /// Rotate, mirror, invert, resize, format — under the picture, where a person looks for
    /// them. Only for a real picture file that can be written back: a page of a document or a
    /// PostScript rendering has no file of its own to save into.
    @ViewBuilder
    private var imageEditBar: some View {
        // For any real picture file, whatever is drawing it: in "auto" a photograph goes
        // through Quick Look, and the buttons must not vanish because of that. The first press
        // switches the view to our own renderer, which is the one that can show the result.
        if let item = targetItem, !item.isDirectory,
           currentCategory == .image,
           ImageSaveFormat.matching(extension: item.fileExtension) != nil {
            HStack(spacing: 14) {
                imageEditGeometryButtons
                Spacer(minLength: 0)
                imageEditSaveButtons
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4))
        }
    }

    /// Кнопки правки — своим вью: одна большая полоса компилятор Swift разбирает минутами.
    @ViewBuilder
    private var imageEditGeometryButtons: some View {
        Group {
            imageTurnButtons
            imageToolButtons
        }
    }

    @ViewBuilder
    private var imageTurnButtons: some View {
        Group {
            Text(L("viewer.image.rotate")).font(.system(size: 11)).foregroundStyle(.secondary)
            editButton("rotate.left", L("viewer.image.rotateLeft")) { changeImage { $0.rotateOnScreen(clockwise: false) } }
            editButton("rotate.right", L("viewer.image.rotateRight")) { changeImage { $0.rotateOnScreen(clockwise: true) } }

            Text(L("viewer.image.flip")).font(.system(size: 11)).foregroundStyle(.secondary)
            editButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                           L("viewer.image.flipHorizontal")) { changeImage { $0.flipOnScreen(horizontal: true) } }
            editButton("arrow.up.and.down.righttriangle.up.righttriangle.down",
                           L("viewer.image.flipVertical")) { changeImage { $0.flipOnScreen(horizontal: false) } }

            editButton("circle.righthalf.filled", L("viewer.image.invert")) { changeImage { $0.invert.toggle() } }
            Button {
                    if effectiveMode != .image { forcedMode = .image }
                    showImageColours.toggle()
            } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                        .foregroundStyle(imageEdits.hasColourChanges ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(L("viewer.image.colours"))
            .disabled(imageSaving)
            .popover(isPresented: $showImageColours, arrowEdge: .top) { imageColourPanel }
        }
    }

    @ViewBuilder
    private var imageToolButtons: some View {
        Group {
            editButton("aspectratio", L("viewer.image.resize")) { askImageResize() }
            Menu {
                    Button(L("viewer.image.cropWhole")) { changeImage { $0.crop = nil } }
                    Divider()
                    ForEach(Self.cropRatios, id: \.name) { ratio in
                        Button(ratio.name) { cropToRatio(ratio.value) }
                    }
            } label: {
                    Image(systemName: "crop").font(.system(size: 14))
                        .foregroundStyle(imageEdits.crop != nil ? Color.accentColor : Color.primary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("viewer.image.crop"))
            .disabled(imageSaving)
            editButton("info.circle", L("viewer.exif.title")) { showImageInfo.toggle() }
                    .popover(isPresented: $showImageInfo, arrowEdge: .top) { imageInfoPanel }
            editButton("doc.on.clipboard", L("viewer.image.copy")) { copyImageToClipboard() }

        }
    }

    @ViewBuilder
    private var imageEditSaveButtons: some View {
        Group {
            if imageSaving { ProgressView().controlSize(.small) }
                if let note = imageSaveNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                // Не Button: он забирает нажатие себе, и жест удержания поверх него не
                // приходил — «Было» просто не срабатывало. Своё вью со своим жестом,
                // который видит и нажатие, и отпускание.
                Text(L("viewer.image.compare"))
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(showingOriginal ? Color.accentColor.opacity(0.3)
                                                : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
                    .opacity(imageEdits.isIdentity ? 0.4 : 1)
                    .contentShape(Rectangle())
                    .help(L("viewer.image.compareTip"))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !imageEdits.isIdentity, !imageSaving else { return }
                                if !showingOriginal { showingOriginal = true }
                            }
                            .onEnded { _ in showingOriginal = false }
                    )
                Button(L("viewer.image.reset")) { resetImageEdits() }
                    .help(L("viewer.image.resetTip"))
                    .disabled(imageEdits.isIdentity || imageSaving)
                // One place for every way out, spelled out: replace the file, put a copy
                // beside it, or write it in another format. A bare "Save" that silently
                // overwrote the original told the person nothing about what it was doing.
                Menu {
                    Button(L("viewer.image.replaceOriginal")) { saveImageEdits(as: nil, asCopy: false) }
                    Button(L("viewer.image.saveCopy")) { saveImageEdits(as: nil, asCopy: true) }
                    Divider()
                    ForEach(ImageSaveFormat.allCases, id: \.rawValue) { format in
                        Button(String(format: L("viewer.image.saveAsFormat"), L(format.titleKey))) {
                            saveImageEdits(as: format, asCopy: true)
                        }
                    }
                } label: {
                    Text(L("viewer.image.save"))
                }
                .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("viewer.image.saveTip"))
            .disabled(imageEdits.isIdentity || imageSaving)
        }
    }

    /// The sliders: brightness, contrast, saturation, warmth, sharpness. Each sits at the
    /// value that means "as it was", so "Reset" here is just putting them back.
    private var imageColourPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            colourSlider(L("viewer.image.brightness"), value: Binding(
                get: { imageEdits.brightness }, set: { v in changeImage { $0.brightness = v } }),
                         range: -0.5...0.5, neutral: 0, display: { String(format: "%+.2f", $0) })
            colourSlider(L("viewer.image.contrast"), value: Binding(
                get: { imageEdits.contrast }, set: { v in changeImage { $0.contrast = v } }),
                         range: 0.4...2.0, neutral: 1, display: { String(format: "%.2f", $0) })
            colourSlider(L("viewer.image.saturation"), value: Binding(
                get: { imageEdits.saturation }, set: { v in changeImage { $0.saturation = v } }),
                         range: 0...2, neutral: 1, display: { String(format: "%.2f", $0) })
            colourSlider(L("viewer.image.warmth"), value: Binding(
                get: { imageEdits.warmth }, set: { v in changeImage { $0.warmth = v } }),
                         range: -100...100, neutral: 0, display: { String(format: "%+.0f", $0) })
            colourSlider(L("viewer.image.sharpness"), value: Binding(
                get: { imageEdits.sharpness }, set: { v in changeImage { $0.sharpness = v } }),
                         range: 0...2, neutral: 0, display: { String(format: "%.2f", $0) })
            Divider()
            colourSlider(L("viewer.image.straighten"), value: Binding(
                get: { imageEdits.straighten }, set: { v in changeImage { $0.straighten = v } }),
                         range: -15...15, neutral: 0, display: { String(format: "%+.1f°", $0) })
            HStack {
                Spacer()
                Button(L("viewer.image.reset")) { changeImage { $0.resetColours(); $0.straighten = 0 } }
                    .disabled(!imageEdits.hasColourChanges && imageEdits.straighten == 0)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func colourSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                              neutral: Double, display: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
                // Двойной щелчок по ползунку — обратно в исходное положение.
                .onTapGesture(count: 2) { value.wrappedValue = neutral }
        }
    }

    /// What the file says about itself, and whether to carry it over when saving.
    private var imageInfoPanel: some View {
        let rows = targetItem.flatMap { ImageEditor.metadata(ofFile: $0.path) }
            .map { ImageEditor.readableMetadata($0) } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("viewer.exif.title")).font(.system(size: 13, weight: .semibold))
            if rows.isEmpty {
                Text(L("viewer.exif.none")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .top) {
                        Text(row.0).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(row.1).font(.system(size: 12)).textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Divider()
            Toggle(L("viewer.exif.keep"), isOn: $keepImageMetadata)
            Text(L("viewer.exif.keepHint")).font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
    }

    /// Пропорции обрезки — списком за пределами тела вью: набор кортежей внутри `ForEach`
    /// компилятор Swift разбирает недопустимо долго.
    static let cropRatios: [(name: String, value: CGFloat)] = [
        ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("3:4", 0.75), ("9:16", 9.0 / 16),
    ]

    /// A crop of that proportion on the picture as it now stands.
    /// The proportion is measured against the FILE, not against what is on screen: in "auto"
    /// a photograph is drawn by Quick Look and the picture is not in memory at all — the crop
    /// used to walk out of this function on the spot and nothing happened. The size also has
    /// to be the FINAL one, after turning, or 1:1 on a picture standing on its side would cut
    /// the wrong way.
    private func cropToRatio(_ ratio: CGFloat) {
        guard let item = targetItem else { return }
        if effectiveMode != .image { forcedMode = .image }
        let sourcePath = item.path
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageEditor.loadOriginal(path: sourcePath)
            }.value
            guard let original = loaded else { return }
            var whole = imageEdits
            whole.crop = nil
            let size = whole.resultSize(source: CGSize(width: original.width, height: original.height))
            changeImage { $0.crop = ImageEdits.centredCrop(ratio: ratio, in: size) }
        }
    }

    /// The edited picture into the clipboard, ready to paste anywhere. From the FILE, so it
    /// works whoever is drawing the picture, and at full size rather than the screen's copy.
    private func copyImageToClipboard() {
        guard let item = targetItem else { return }
        let sourcePath = item.path
        let edits = imageEdits
        Task { @MainActor in
            let picture = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let original = ImageEditor.loadOriginal(path: sourcePath),
                      let edited = ImageEditor.apply(edits, to: original) else { return nil }
                return NSImage(cgImage: edited, size: NSSize(width: edited.width, height: edited.height))
            }.value
            guard let picture else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([picture])
            imageSaveNote = L("viewer.image.copy")
        }
    }

    private func editButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(imageSaving)
    }

    // MARK: - Image editing

    /// Change the edits and put the result on screen. The preview is a scaled copy, so the
    /// SIZE change is left out of it — it would look identical on a picture fitted to the
    /// window — and applied for real only when saving.
    private func changeImage(_ mutate: (inout ImageEdits) -> Void) {
        // Quick Look shows the FILE; the edits live in the program, so the picture has to be
        // drawn by us for the result to be visible.
        if effectiveMode != .image { forcedMode = .image }
        var edits = imageEdits
        mutate(&edits)
        imageEdits = edits
        imageSaveNote = nil
        refreshEditedPreview()
    }

    private func refreshEditedPreview() {
        guard let base = image, !imageEdits.isIdentity else { editedPreview = nil; return }
        var forPreview = imageEdits
        forPreview.resize = nil
        var rect = CGRect(origin: .zero, size: base.size)
        guard let source = base.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let edited = ImageEditor.apply(forPreview, to: source) else { editedPreview = nil; return }
        editedPreview = NSImage(cgImage: edited, size: NSSize(width: edited.width, height: edited.height))
    }

    private func resetImageEdits() {
        imageEdits = ImageEdits()
        editedPreview = nil
        imageSaveNote = nil
    }

    /// Width in pixels; the height follows so the picture keeps its proportion.
    private func askImageResize() {
        guard let item = targetItem else { return }
        if effectiveMode != .image { forcedMode = .image }
        let sourcePath = item.path
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageEditor.loadOriginal(path: sourcePath)
            }.value
            guard let original = loaded else { return }
            let size = CGSize(width: original.width, height: original.height)
            let current = imageEdits.resize ?? size
            let typed = await fcxlPresentModalAsync {
                DialogService.shared.showTextInput(
                    title: L("viewer.image.resizeTitle"),
                    message: String(format: L("viewer.image.resizeMessage"), original.width, original.height),
                    defaultValue: String(Int(current.width)),
                    confirmButtonTitle: L("button.ok"))
            }
            guard let typed, let width = Double(typed.trimmingCharacters(in: .whitespaces)), width > 0,
                  let wanted = ImageEdits.proportional(source: size, width: CGFloat(width), height: nil)
            else { return }
            imageEdits.resize = wanted == size ? nil : wanted
            imageSaveNote = "\(Int(wanted.width)) × \(Int(wanted.height))"
        }
    }

    /// Write the edits into the file. `format` nil — back into the same file in its own
    /// format; otherwise beside it under the new extension, asking before replacing.
    private func saveImageEdits(as format: ImageSaveFormat?, asCopy: Bool) {
        guard let item = targetItem, !imageSaving else { return }
        let sourcePath = item.path
        let own = ImageSaveFormat.matching(extension: item.fileExtension) ?? .png
        let target = format ?? own
        let destination = asCopy
            ? ImageEditor.copyPath(for: sourcePath, format: target, suffix: L("viewer.image.copySuffix"))
            : sourcePath
        Task { @MainActor in
            if destination == sourcePath {
                // Replacing the original cannot be undone — say so before doing it.
                let replace = await fcxlPresentModalAsync {
                    DialogService.shared.showDestructiveConfirmation(
                        title: L("viewer.image.replaceTitle"),
                        message: String(format: L("viewer.image.replaceMessage"),
                                        (sourcePath as NSString).lastPathComponent),
                        confirmTitle: L("viewer.image.replaceConfirm"),
                        icon: "photo", iconColor: .orange)
                }
                guard replace else { return }
            }
            imageSaving = true
            let edits = imageEdits
            let keepInfo = keepImageMetadata
            let failure: Error? = await Task.detached(priority: .userInitiated) { () -> Error? in
                guard let original = ImageEditor.loadOriginal(path: sourcePath) else {
                    return ImageEditor.SaveError.cannotWrite(target.rawValue)
                }
                guard let edited = ImageEditor.apply(edits, to: original) else {
                    return ImageEditor.SaveError.cannotWrite(target.rawValue)
                }
                let info = keepInfo ? ImageEditor.metadata(ofFile: sourcePath) : nil
                do {
                    try ImageEditor.write(edited, to: destination, format: target, metadata: info)
                } catch { return error }
                return nil
            }.value
            imageSaving = false
            if let failure {
                DialogService.shared.showOperationError(title: L("viewer.image.save"), error: failure)
                return
            }
            imageSaveNote = String(format: L("viewer.image.savedAs"),
                                   (destination as NSString).lastPathComponent)
            // The file on disk is now the edited one: start over from it, so a second round of
            // edits does not stack on top of what is already written.
            resetImageEdits()
            if destination == sourcePath { startLoadingPreview() }
        }
    }

    private var imagePreview: some View {
        GeometryReader { geometry in
            if let image {
                let shown = (showingOriginal ? nil : editedPreview) ?? image
                let maxW = max(1, geometry.size.width - 24)
                let maxH = max(1, geometry.size.height - 24)
                let fitted = fittedImageSize(original: shown.size, container: CGSize(width: maxW, height: maxH))

                Image(nsImage: shown)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitted.width, height: fitted.height)
                    // Inside the frame, so the highlights are zoomed and dragged with the
                    // picture instead of drifting away from the words they belong to.
                    .overlay { pictureTextOverlay(in: fitted) }
                    .scaleEffect(imgScale)
                    .offset(imgOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in imgScale = max(0.1, min(10, imgScaleBase * value)) }
                            .onEnded { value in
                                imgScale = max(0.1, min(10, imgScaleBase * value))
                                imgScaleBase = imgScale
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                imgOffset = CGSize(
                                    width: imgOffsetBase.width + value.translation.width,
                                    height: imgOffsetBase.height + value.translation.height
                                )
                            }
                            .onEnded { _ in imgOffsetBase = imgOffset },
                        // While the text is shown, a drag belongs to the text: it selects words
                        // rather than dragging the picture out from under them. Hiding the
                        // highlights gives the picture its drag back.
                        including: pictureText.isEmpty ? .all : .subviews
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            imgScale = 1.0; imgScaleBase = 1.0
                            imgOffset = .zero; imgOffsetBase = .zero
                        }
                    }
            } else if !isLoading {
                Text(L("viewer.imageLoadFailed"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clip the zoomed image to the panel's bounds — without this,
        // scaleEffect lets the image bleed outside the embedded viewer
        // and overlap the neighbouring file panel.
        .clipped()
        .contentShape(Rectangle())
    }

    /// Полоса страниц у сканированной книги — та же кнопка и то же место, что у PDF:
    /// «чтоб страницы тоже как в pdf можно было показывать и убирать».
    @ViewBuilder
    private var djvuStripToggle: some View {
        if effectiveMode == .djvu, (djvuReader?.pageCount ?? 0) > 1 {
            Button {
                showsDjVuThumbnails.toggle()
                returnFocusToPanel()
            } label: {
                Image(systemName: showsDjVuThumbnails ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 13))
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .help(L(showsDjVuThumbnails ? "viewer.pdf.hidePages" : "viewer.pdf.showPages"))
        }
    }

    @ViewBuilder
    private var bookContentsToggle: some View {
        if effectiveMode == .book, (book?.chapters.count ?? 0) > 1 {
            Button {
                showsBookContents.toggle()
                returnFocusToPanel()
            } label: {
                Image(systemName: showsBookContents ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 13))
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .help(L(showsBookContents ? "viewer.book.hideContents" : "viewer.book.showContents"))
        }
    }

    @ViewBuilder
    private var pdfPageStripToggle: some View {
        if effectiveMode == .pdf, pdfPageCount > 1 {
            Button {
                showsPDFThumbnails.toggle()
                returnFocusToPanel()
            } label: {
                Image(systemName: showsPDFThumbnails ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 13))
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .help(L(showsPDFThumbnails ? "viewer.pdf.hidePages" : "viewer.pdf.showPages"))
        }
    }

    // MARK: - Books and bookmarks

    /// Where the reader is standing, in the shape a bookmark keeps.
    private var currentLocation: ReaderLocation? {
        switch effectiveMode {
        case .book:
            guard book != nil else { return nil }
            return ReaderLocation(page: bookState.page, chapter: bookState.chapterIndex,
                                  anchor: bookState.anchor)
        case .djvu:
            guard djvuReader != nil else { return nil }
            return ReaderLocation(page: djvuPage)
        case .pdf:
            guard pdfDocument != nil else { return nil }
            return ReaderLocation(page: pdfPage)
        default:
            return nil
        }
    }

    /// How many pages this document has — the one condition the bookmark buttons hang on,
    /// exactly as asked: bookmarks appear when there is more than one page.
    private var viewerPageCount: Int {
        switch effectiveMode {
        case .book: return book?.chapters.count ?? 0
        case .djvu: return Int(djvuReader?.pageCount ?? 0)
        case .pdf:  return pdfPageCount
        default:    return 0
        }
    }

    /// Remember the place, a second after the page stops changing — turning pages must not
    /// beat on the disk.
    private func rememberPlace(_ state: BookReaderState) {
        guard let path = targetItem?.path else { return }
        positionSaver?.cancel()
        positionSaver = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            ReaderMarksStore.shared.rememberPosition(
                ReaderLocation(page: state.page, chapter: state.chapterIndex,
                               anchor: state.anchor), for: path)
        }
    }

    /// Bookmarks belong to the FILE, not to the kind of document — so they are read where the
    /// file arrives, once, for every kind at once. Reading them only in the book branch is
    /// what made a DjVu bookmark vanish the moment the viewer was closed and reopened: it was
    /// written to disk correctly and then never read back.
    private func loadReaderMarks() {
        guard let path = targetItem?.path else { readerMarks = []; return }
        readerMarks = ReaderMarksStore.shared.marks(for: path)
        numberingStart = ReaderMarksStore.shared.numberingStart(for: path)
            ?? PageNumbering.defaultStart(forFile: path)
    }

    /// Название листа для счётчика, закладки и всего остального, что называет страницу.
    private func pageTitle(of index: Int, title: String? = nil) -> String {
        BookmarkName.compose(number: PageNumbering.printed(index: index, start: numberingStart),
                             title: title)
    }

    private var currentPageIndex: Int {
        switch effectiveMode {
        case .djvu: return djvuPage
        case .pdf:  return pdfPage
        case .book: return bookState.page
        default:    return 0
        }
    }

    /// «Эта страница — первая». Одного указания хватает на весь файл: дальше и счётчик, и
    /// закладки говорят теми же номерами, что напечатаны в книге.
    private func setNumberingStart(_ index: Int) {
        guard let path = targetItem?.path else { return }
        numberingStart = index
        ReaderMarksStore.shared.setNumberingStart(index, for: path)
        // Закладки называются номерами страниц — значит, они едут вместе с нумерацией.
        // Названные рукой остаются как есть.
        ReaderMarksStore.shared.renumberMarks(for: path) { mark in
            pageTitle(of: mark.location.page, title: mark.autoTitle)
        }
        readerMarks = ReaderMarksStore.shared.marks(for: path)
        returnFocusToPanel()
    }

    /// "Стр. 42 из 282" — without it a long book looks like a single cover page, because
    /// nothing on screen says there is anything below.
    @ViewBuilder
    private var pageCounter: some View {
        let total = viewerPageCount
        if total > 1 {
            if effectiveMode == .book {
                // У книги страницы плывут от размера окна и шрифта — сдвигать в ней нечего.
                Text(bookState.chapterCount > 1
                     ? String(format: L("viewer.page.ofChapter"), bookState.page + 1,
                              bookState.pageCount, bookState.chapterIndex + 1, total)
                     : String(format: L("viewer.page.of"), bookState.page + 1, total))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                let index = currentPageIndex
                let printed = PageNumbering.printed(index: index, start: numberingStart)
                let numbered = PageNumbering.numberedCount(total: total, start: numberingStart)
                Menu {
                    Button(L("viewer.page.setFirst")) { setNumberingStart(index) }
                        .disabled(index == numberingStart)
                    Button(L("viewer.page.fileNumbering")) { setNumberingStart(0) }
                        .disabled(numberingStart == 0)
                } label: {
                    Text(printed.map { String(format: L("viewer.page.of"), $0, numbered) }
                         ?? L("viewer.page.cover"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("viewer.page.numberingHint"))
            }
        }
    }

    /// Строка содержания. Щелчок по той главе, которую читают, складывает и раскладывает её
    /// страницы; щелчок по другой — переходит в неё и раскрывает. Раньше страницы читаемой
    /// главы вываливались всегда и убрать их было нечем: в сборнике на две сотни страниц
    /// содержание переставало быть содержанием.
    private func chapterRow(index: Int, chapter: BookChapter) -> some View {
        let isCurrent = index == bookState.chapterIndex
        let isOpen = isCurrent && expandedChapters.contains(index)
        return HStack(spacing: 5) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 9)
            Text(chapter.title.isEmpty
                 ? String(format: L("viewer.book.chapterNumber"), index + 1) : chapter.title)
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isCurrent ? PanelAppearanceSettings.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCurrent {
                if expandedChapters.contains(index) { expandedChapters.remove(index) }
                else { expandedChapters.insert(index) }
                return
            }
            // Раскрыта всегда одна глава — читаемая, иначе содержание снова превращается
            // в ленту, по которой надо листать.
            expandedChapters = [index]
            var next = bookState
            next.chapterIndex = index
            next.page = 0
            bookState = next
        }
    }

    /// Страницы главы — сеткой номеров, а не столбиком строк: двести сорок две строки
    /// «Стр. N» превращали содержание в бесконечную ленту, а те же номера в четыре колонки
    /// видны целиком и нажимаются точно так же.
    private func pageGrid(count: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4),
                  spacing: 2) {
            ForEach(0..<count, id: \.self) { page in
                let isCurrent = page == bookState.page
                Text("\(page + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 18)
                    .background(isCurrent
                                ? PanelAppearanceSettings.accentColor.opacity(0.35) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
                    .onTapGesture { BookReaderBridge.shared.goto(page: page) }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }

    /// Buttons to turn the page — for the mouse hand, next to the counter. The wheel and the
    /// arrow keys do the same thing; a book should be turnable however you happen to be
    /// holding it.
    @ViewBuilder
    private var bookTurnControls: some View {
        if effectiveMode == .book, book != nil {
            Button { BookReaderBridge.shared.turn(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 12))
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .help(L("viewer.book.previousPage"))
            Button { BookReaderBridge.shared.turn(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 12))
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .help(L("viewer.book.nextPage"))
        }
    }

    @ViewBuilder
    private var bookmarkControls: some View {
        if let path = targetItem?.path, viewerPageCount > 1,
           ReaderMarksStore.shared.isRecordablePath(path) {
            let marks = readerMarks
            let here = currentLocation
            let isMarked = here.map { location in marks.contains { $0.location == location } }
                ?? false
            Button {
                toggleBookmark()
            } label: {
                Image(systemName: isMarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 13))
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .help(L(isMarked ? "viewer.bookmark.remove" : "viewer.bookmark.add"))

            Menu {
                if marks.isEmpty {
                    Text(L("viewer.bookmark.none"))
                } else {
                    ForEach(marks) { mark in
                        Button(mark.label) { jump(to: mark) }
                    }
                    Divider()
                    Menu(L("viewer.bookmark.rename")) {
                        ForEach(marks) { mark in
                            Button(mark.label) { renameBookmark(mark) }
                        }
                    }
                    Button(L("viewer.bookmark.removeAll"), role: .destructive) {
                        ReaderMarksStore.shared.removeAllMarks(for: path)
                        readerMarks = []
                    }
                }
            } label: {
                Image(systemName: "list.bullet").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help(L("viewer.bookmark.list"))
        }
    }

    private func toggleBookmark() {
        guard let path = targetItem?.path, let location = currentLocation else { return }
        let chapterTitle: String? = {
            guard effectiveMode == .book, let book,
                  book.chapters.indices.contains(bookState.chapterIndex) else { return nil }
            return book.chapters[bookState.chapterIndex].title
        }()
        // Имя даётся сразу, из того, что уже известно: закладка ставится одним нажатием и
        // ждать распознавания не должна.
        let label = pageTitle(of: location.page, title: chapterTitle)
        let added = ReaderMarksStore.shared.toggleMark(at: location, label: label,
                                                       autoTitle: chapterTitle, for: path)
        readerMarks = ReaderMarksStore.shared.marks(for: path)
        guard added, chapterTitle == nil,
              let mark = readerMarks.first(where: { $0.location == location }) else { return }

        // А настоящее имя приходит следом: у PDF из текстового слоя, у скана и DjVu — из
        // распознанной страницы. Это секунда работы, и держать ради неё палец на кнопке
        // незачем.
        Task.detached(priority: .utility) {
            guard let found = BookmarkName.title(ofFile: path, page: location.page) else { return }
            await MainActor.run {
                // Своё имя человека не трогается — за этим следит само хранилище.
                ReaderMarksStore.shared.updateAutoName(
                    id: mark.id, label: pageTitle(of: location.page, title: found),
                    title: found, for: path)
                guard targetItem?.path == path else { return }
                readerMarks = ReaderMarksStore.shared.marks(for: path)
            }
        }
    }

    /// Своё название закладке — «тут про коня». Угаданное имя годится, чтобы не потерять
    /// место, но человек помнит, ЗАЧЕМ он его отметил.
    private func renameBookmark(_ mark: ReaderMark) {
        guard let path = targetItem?.path else { return }
        guard let name = DialogService.shared.showTextInput(
            title: L("viewer.bookmark.renameTitle"),
            message: L("viewer.bookmark.renamePrompt"),
            defaultValue: mark.label) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ReaderMarksStore.shared.renameMark(id: mark.id, to: trimmed, for: path)
        readerMarks = ReaderMarksStore.shared.marks(for: path)
        returnFocusToPanel()
    }

    private func jump(to mark: ReaderMark) {
        switch effectiveMode {
        case .book:
            var next = bookState
            next.chapterIndex = mark.location.chapter ?? 0
            next.page = mark.location.page
            bookStart = mark.location
            bookState = next
        case .djvu:
            // Through the bridge: the @State reference can be lost when SwiftUI rebuilds the
            // representable, and a bookmark that does nothing when pressed is worse than no
            // bookmark at all.
            (djvuPages ?? DjVuPageBridge.shared.current)?.scrollToPage(mark.location.page)
        case .pdf:
            // Свой вид, а мост — запасной путь: ссылка из @State теряется, когда SwiftUI
            // пересобирает представление.
            if let view = pdfView ?? PDFPageBridge.shared.current,
               let page = view.document?.page(at: mark.location.page) {
                view.go(to: page)
            }
        default:
            break
        }
    }

    @ViewBuilder
    private var textRecognitionControls: some View {
        if let item = targetItem, !item.isDirectory,
           TextRecognitionService.canReadText(in: item.path),
           fileCategory(extension: item.fileExtension) != .image,
           // A document that already carries its own text is left alone: it can be selected and
           // copied in the viewer as it is, and recognising a picture of it would be worse.
           pdfNeedsRecognition {
            // A page of a document is read the same way a photograph is: the page itself goes
            // on screen, the words are marked on it, and the mouse drags across them. A window
            // full of plain text is a different thing, and it lives in the panel's own command.
            HStack(spacing: 8) {
                if readingDocPage != nil, readingDocPages > 1 {
                    Button { showDocumentPage((readingDocPage ?? 0) - 1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled((readingDocPage ?? 0) <= 0 || isReadingText)
                    Text("\((readingDocPage ?? 0) + 1)/\(readingDocPages)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button { showDocumentPage((readingDocPage ?? 0) + 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled((readingDocPage ?? 0) >= readingDocPages - 1 || isReadingText)
                }
                if isReadingText { ProgressView().controlSize(.small) }
                if !pictureText.isEmpty {
                    Button(L("viewer.ocr.copyAll")) { copyAllText() }
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                        .help(String(format: L("viewer.ocr.found"), pictureText.count))
                }
                Button(readingDocPage == nil ? L("viewer.ocr.read") : L("viewer.ocr.hide")) {
                    if readingDocPage == nil {
                        showDocumentPage(0)
                    } else {
                        readingDocPage = nil
                        pictureText = []
                        selectedKeys = []
                        forcedMode = nil
                        startLoadingPreview()
                    }
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
                .disabled(isReadingText)
            }
            .onChange(of: pictureText.count) { _ in returnFocusToPanel() }
        } else if let item = targetItem, !item.isDirectory,
           fileCategory(extension: item.fileExtension) == .image {
            HStack(spacing: 8) {
                if isReadingText {
                    ProgressView().controlSize(.small)
                }
                if !pictureText.isEmpty {
                    Button(L("viewer.ocr.copyAll")) { copyAllText() }
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                        .help(String(format: L("viewer.ocr.found"), pictureText.count))
                }
                Button(pictureText.isEmpty ? L("viewer.ocr.read") : L("viewer.ocr.hide")) {
                    // Reading needs the picture itself, so a file being shown some other way
                    // (Quick Look, hex) is switched over to the image first.
                    if effectiveMode != .image { forcedMode = .image }
                    toggleTextRecognition()
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
                .disabled(isReadingText)
            }
        }
    }

    /// The found lines, drawn where they are written. A click copies one line; the button in the
    /// corner copies them all.
    @ViewBuilder
    private func pictureTextOverlay(in size: CGSize) -> some View {
        if !pictureText.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(pictureText) { line in
                    let box = TextRecognitionService.rect(for: line.box, in: size)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(copiedKey == "\(line.id)" ? Color.accentColor.opacity(0.45)
                                                        : Color.yellow.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(copiedKey == "\(line.id)" ? Color.accentColor
                                                                  : Color.yellow.opacity(0.7),
                                        lineWidth: 1))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .help(line.text)
                        // A click on the line — but between the words, or on a line whose words
                        // Vision could not place — copies the whole line.
                        .onTapGesture { copy(line.text, key: "\(line.id)") }

                    // The words sit ON the line, each its own target: a click copies one word,
                    // which is what a person wants from a price, an article number or a code.
                    ForEach(line.words) { word in
                        let wordBox = TextRecognitionService.rect(for: word.box, in: size)
                        let key = "\(line.id).\(word.id)"
                        RoundedRectangle(cornerRadius: 2)
                            .fill(copiedKey == key || selectedKeys.contains(key)
                                  ? Color.accentColor.opacity(0.55) : Color.clear)
                            .frame(width: wordBox.width, height: wordBox.height)
                            .position(x: wordBox.midX, y: wordBox.midY)
                            .help(word.text)
                            .onTapGesture { copy(word.text, key: key) }
                            // Alt held: the whole line, from anywhere on it.
                            .modifier(AltClickCopy { copy(line.text, key: "\(line.id)") })
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            // Drag across the words the way a person drags across text: everything from where
            // the drag began to where it is now, whole lines in between included. Released, it
            // is on the clipboard — the same promise as a click on a single word.
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        let start = selectionAnchor ?? value.startLocation
                        selectionAnchor = start
                        selectedKeys = TextRecognitionService.selection(
                            from: start, to: value.location,
                            lines: pictureText, in: size).keys
                    }
                    .onEnded { value in
                        let start = selectionAnchor ?? value.startLocation
                        let picked = TextRecognitionService.selection(
                            from: start, to: value.location, lines: pictureText, in: size)
                        selectionAnchor = nil
                        selectedKeys = picked.keys
                        guard !picked.text.isEmpty else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(picked.text, forType: .string)
                    }
            )
        }
    }

    private func copy(_ text: String, key: String) {
        selectedKeys = []
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedKey = key
        // The flash is the only sign a click did anything — a copy leaves nothing on screen.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if copiedKey == key { copiedKey = nil }
        }
    }

    private func copyAllText() {
        guard !pictureText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TextRecognitionService.plainText(pictureText), forType: .string)
    }

    /// Put one page of a document on screen as a picture and read it.
    private func showDocumentPage(_ index: Int) {
        guard let item = targetItem, index >= 0 else { return }
        let path = item.path
        isReadingText = true
        pictureText = []
        selectedKeys = []
        forcedMode = .image          // the picture mode is what can carry the marks
        Task.detached(priority: .userInitiated) {
            let total = TextRecognitionService.pageCount(ofFile: path)
            let page = TextRecognitionService.renderPage(ofFile: path, index: index)
            let lines: [RecognizedLine]
            if let cgImage = page?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                lines = (try? TextRecognitionService.recognizeBestPolarity(cgImage)) ?? []
            } else {
                lines = []
            }
            await MainActor.run {
                guard targetItem?.path == path else { return }   // the cursor moved on
                readingDocPages = total
                readingDocPage = index
                if let page { image = page }
                pictureText = lines
                isReadingText = false
                imgOffset = .zero
                imgOffsetBase = .zero
            }
        }
    }

    /// Read the picture, or put the highlights away if they are already up.
    private func toggleTextRecognition() {
        guard !isReadingText else { return }
        if !pictureText.isEmpty { pictureText = []; return }
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // The picture is still loading (the button was pressed from another mode). Ask again
            // when it lands rather than doing nothing and looking broken.
            wantsTextAfterLoad = true
            return
        }
        isReadingText = true
        Task.detached(priority: .userInitiated) {
            let found = (try? TextRecognitionService.recognizeBestPolarity(cgImage)) ?? []
            await MainActor.run {
                pictureText = found
                isReadingText = false
            }
        }
    }

    // MARK: - Hex Content

    private var hexContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if hexLines.isEmpty && !isLoading {
                    Text(L("viewer.emptyFile"))
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(hexLines) { line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(String(format: "%08llX", line.offset))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .trailing)
                            Text(line.bytesText)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: CGFloat(bytesPerHexLine) * 3 + 4, alignment: .leading)
                            Text(line.asciiText)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(line.id)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Folder Preview

    private var folderPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("\(L("quickView.itemsCount")): \(folderCount)")
                Text("\(L("properties.size")): \(ByteText.file(Int64(folderSize)))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)

            List(folderEntries) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(entry.isDirectory ? .yellow : .secondary)
                    Text(entry.name)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.isDirectory ? "-" : ByteText.file(Int64(entry.size)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Info Content

    @ViewBuilder
    private var infoContent: some View {
        // A photograph has more to say than a name and a size, and this is where a person comes
        // looking for it.
        if let item = targetItem, !item.isDirectory,
           fileCategory(extension: item.fileExtension) == .image {
            PhotoInfoView(path: item.path)
        } else {
            genericInfoContent
        }
    }

    private var genericInfoContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let genericIcon {
                    Image(nsImage: genericIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                }
                Text(targetItem?.name ?? L("viewer.noFile"))
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                ForEach(metadataEntries) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.key + ":")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        Text(item.value)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading Logic

    private func startLoadingPreview() {
        cancelLoadTask()

        loadError = nil
        encoding = "UTF-8"
        textLines = []
        fastPreviewFilePath = ""
        useFastPreview = false
        markdownContent = nil
        isMarkdownFile = false
        hexLines = []
        image = nil
        imgScale = 1.0; imgScaleBase = 1.0
        imgOffset = .zero; imgOffsetBase = .zero
        djvuReader?.close()
        djvuReader = nil
        mediaPlayer?.pause()
        mediaPlayer = nil
        folderEntries = []
        folderCount = 0
        folderSize = 0
        genericIcon = nil
        metadataEntries = []
        isLoading = false

        guard let item = targetItem else { return }

        if item.isDirectory {
            isLoading = true
            let folderPath = item.path
            loadTask = Task {
                do {
                    let (entries, totalSize) = try await loadFolderPreviewSnapshotAsync(path: folderPath)
                    if Task.isCancelled { return }
                    folderEntries = entries.map {
                        FolderEntry(path: $0.path, name: $0.name, isDirectory: $0.isDirectory, size: $0.size)
                    }
                    folderCount = entries.count
                    folderSize = totalSize
                } catch {
                    if Task.isCancelled { return }
                    loadError = error.localizedDescription
                }
                isLoading = false
            }
            return
        }

        let filePath = item.path
        let selectedMode = effectiveMode

        switch selectedMode {
        case .quickLook, .document:
            break
        case .image:
            isLoading = true
            loadTask = Task {
                let loaded = await loadPreviewImageAsync(path: filePath, targetSize: CGSize(width: 1600, height: 1200))
                if Task.isCancelled { return }
                image = loaded
                // A freshly read picture is the truth on disk: unfinished edits belong to the
                // picture that was on screen a moment ago, not to this one.
                resetImageEdits()
                if wantsTextAfterLoad {
                    wantsTextAfterLoad = false
                    toggleTextRecognition()
                }
                if loaded == nil { loadError = L("viewer.imageLoadFailed") }
                isLoading = false
            }
        case .text:
            isLoading = true
            loadTask = Task {
                do {
                    // Read small probe (64KB) to detect encoding and binary
                    let probeData = try await readFileDataAsync(path: filePath, maxBytes: 64 * 1024)
                    if Task.isCancelled { return }
                    let encodingProbe = detectEncoding(probeData)
                    encoding = encodingProbe.name

                    let (_, isBinary) = decodeTextContent(data: probeData, probe: encodingProbe)

                    if isBinary {
                        textLines = [ViewerTextLine(number: 1, value: "(\(L("viewer.binaryFile")))"),
                                     ViewerTextLine(number: 2, value: ""),
                                     ViewerTextLine(number: 3, value: L("viewer.useBinaryHint"))]
                        useFastPreview = false
                    } else {
                        // Get file size to decide strategy
                        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
                        let fileSize = (attrs[.size] as? UInt64) ?? 0

                        if fileSize > 256 * 1024 {
                            // Large file — use FastTextPreview with direct file path (memory-mapped loading in NSTextView)
                            useFastPreview = true
                            fastPreviewFilePath = filePath
                            textLines = []
                        } else {
                            // Small file — use line-by-line SwiftUI view
                            let fullData = try await readFileDataAsync(path: filePath)
                            if Task.isCancelled { return }
                            let (decodedText, _) = decodeTextContent(data: fullData, probe: encodingProbe)
                            useFastPreview = false
                            let parts = decodedText.split(separator: "\n", omittingEmptySubsequences: false)
                            textLines = parts.enumerated().map { index, part in
                                ViewerTextLine(number: index + 1, value: String(part))
                            }
                        }
                    }

                    let isMd = currentCategory == .markdown
                    isMarkdownFile = isMd
                    if isMd {
                        let mdData = try await readFileDataAsync(path: filePath, maxBytes: 2 * 1024 * 1024)
                        if let mdString = String(data: mdData, encoding: .utf8) {
                            // Parsed and styled off the main thread; the window stays alive.
                            markdownContent = await Task.detached(priority: .userInitiated) {
                                MarkdownStyler.render(mdString)
                            }.value
                        }
                    } else {
                        markdownContent = nil
                    }
                } catch {
                    if Task.isCancelled { return }
                    loadError = error.localizedDescription
                }
                isLoading = false
            }
        case .hex:
            isLoading = true
            loadTask = Task {
                do {
                    let data = try await readFileDataAsync(path: filePath, maxBytes: 2 * 1024 * 1024)
                    if Task.isCancelled { return }
                    hexLines = buildHexLines(data: data, bytesPerLine: bytesPerHexLine)
                } catch {
                    if Task.isCancelled { return }
                    loadError = error.localizedDescription
                }
                isLoading = false
            }
        case .pdf:
            let path = filePath
            Task.detached(priority: .utility) {
                let pages = TextRecognitionService.pageCount(ofFile: path)
                let needsReading = TextRecognitionService.needsRecognition(pdf: path)
                // Насколько тяжело документ рисовать — измеряется, а не угадывается, и решает
                // это только одно: заводить ли кэш готовых страниц. Лёгкому документу он не
                // нужен — PDFKit и так рисует его быстрее, чем человек успевает заметить, а
                // память лучше оставить файлам.
                let url = URL(fileURLWithPath: path)
                let plain = PDFDocument(url: url)
                let heavy = plain.map { PDFWeight.secondsPerPage($0) > PDFWeight.slowPageSeconds }
                    ?? false
                let document: PDFDocument? = heavy ? PDFCachingDocument(url: url) : plain
                await MainActor.run {
                    guard targetItem?.path == path else { return }
                    pdfPageCount = pages
                    pdfNeedsRecognition = needsReading
                    pdfDocument = document
                }
            }
        case .drawing:
            isLoading = true
            loadTask = Task.detached(priority: .userInitiated) {
                // A big drawing is megabytes of text; reading and parsing it belongs off the
                // main thread, like every other format here.
                let parsed = (try? Data(contentsOf: URL(fileURLWithPath: filePath)))
                    .map(DXFDocument.read(data:))
                await MainActor.run {
                    drawing = parsed
                    loadError = parsed == nil ? L("viewer.dxf.unreadable") : nil
                    isLoading = false
                }
            }
        case .book:
            isLoading = true
            let bridge = CoreBridgeService()
            loadTask = Task.detached(priority: .userInitiated) {
                let loaded = try? BookLoader.load(path: filePath, bridge: bridge)
                await MainActor.run {
                    // The file may have changed under us while the book was being prepared —
                    // the same race already fixed once for the PDF page strip.
                    guard targetItem?.path == filePath else { return }
                    // Содержание раскрыто с самого начала — и в первый раз тоже. Раньше это
                    // делалось только при СМЕНЕ файла, и первая открытая книга показывала
                    // список названий без страниц.
                    expandedChapters = [bookStart?.chapter ?? 0]
                    isLoading = false
                    guard let loaded else {
                        loadError = L("viewer.book.unreadable")
                        return
                    }
                    book = loaded
                    bookStart = ReaderMarksStore.shared.lastPosition(for: filePath)
                    var fresh = BookReaderState()
                    fresh.chapterCount = loaded.chapters.count
                    fresh.chapterIndex = bookStart?.chapter ?? 0
                    bookState = fresh
                }
            }
        case .djvu:
            isLoading = true
            loadTask = Task.detached(priority: .userInitiated) {
                let reader: FCXLDjVuReader?
                do {
                    reader = try FCXLDjVuReader(path: filePath)
                } catch {
                    await MainActor.run {
                        loadError = error.localizedDescription
                        isLoading = false
                    }
                    return
                }
                await MainActor.run {
                    djvuReader = reader
                    isLoading = false
                }
            }
        case .video:
            let player = AVPlayer(url: URL(fileURLWithPath: filePath))
            mediaPlayer = player
            // Straight into playing: opening a film or a recording in a viewer IS the request
            // to hear it, and pressing play afterwards is a step nobody wanted. Moving to
            // another file pauses and lets go of this one, as it already did.
            player.play()
        case .postScript:
            isLoading = true
            psRerenderTask?.cancel()
            psRenderedEdge = PostScriptRenderer.baseLongEdgePixels
            loadTask = Task {
                let rendered = await Task.detached(priority: .userInitiated) {
                    PostScriptRenderer.renderToImage(path: filePath)
                }.value
                if Task.isCancelled { return }
                image = rendered
                if rendered == nil {
                    loadError = PostScriptRenderer.isAvailable
                        ? L("viewer.postScriptFailed")
                        : L("viewer.postScriptUnavailable")
                }
                isLoading = false
            }
        case .font:
            break   // FontSpecimenView loads the font from its URL itself
        case .info:
            isLoading = true
            loadTask = Task {
                let icon = FileTypeIconCache.icon(
                    fileExtension: URL(fileURLWithPath: filePath).pathExtension,
                    isDirectory: false,
                    targetSize: CGSize(width: 128, height: 128)
                )
                let items = await loadPreviewMetadataAsync(
                    path: filePath,
                    fileSize: item.size,
                    fallbackModifiedDate: item.dateModified
                )
                if Task.isCancelled { return }
                genericIcon = icon
                metadataEntries = items
                isLoading = false
            }
        case .auto:
            break
        }
    }

    private func cancelLoadTask() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Mode Logic

    private func isModeSelected(_ mode: PreviewMode) -> Bool {
        if mode == .auto { return forcedMode == nil }
        if let forcedMode { return forcedMode == mode }
        return autoResolvedMode == mode
    }

    private func isModeDisabled(_ mode: PreviewMode) -> Bool {
        guard let item = targetItem, !item.isDirectory else {
            return mode != .auto && mode != .info
        }
        let cat = currentCategory
        switch mode {
        case .auto, .info, .hex, .quickLook: return false
        case .text:
            switch cat {
            case .video, .audio, .image, .pdf, .officeDocument: return true
            case .vectorImage: return false   // SVG is text-readable XML
            case .other:
                let ext = item.fileExtension.lowercased()
                let bin: Set<String> = ["db","sqlite","sqlite3","mdb","exe","dll","dylib","so","o","a",
                    "zip","tar","gz","bz2","7z","rar","dmg","iso","class","pyc","wasm",
                    "ttf","otf","woff","woff2","icns","car"]
                return bin.contains(ext)
            default: return false
            }
        case .image: return cat != .image && cat != .vectorImage
        case .video: return cat != .video && cat != .audio
        case .pdf: return cat != .pdf
        // The drawing view has nothing to say about anything else, and a DXF is honest text
        // as well — so "Text" and "Hex" stay available on it.
        case .drawing: return cat != .drawing
        // Only offered for what textutil can actually read (Word-processing files).
        case .document: return !isWordProcessingDocument(extension: item.fileExtension)
        case .djvu: return cat != .djvu
        case .book: return cat != .book
        case .font: return cat != .font
        case .postScript: return cat != .postScript
        }
    }

    private func applyMode(_ mode: PreviewMode) {
        forcedMode = mode == .auto ? nil : mode
        returnFocusToPanel()
    }

    /// Give the keyboard back to the file list after a button here was pressed.
    ///
    /// The viewer sits in the other panel's place, and a click on one of its buttons makes THIS
    /// view first responder — at which point the panel stops being the active one and its cursor
    /// disappears from the list. The viewer needs no first responder of its own: its keys come
    /// from a monitor that sees them wherever they are typed.
    private func returnFocusToPanel() {
        guard let controller = hostWindow?.windowController as? MainWindowController else { return }
        DispatchQueue.main.async {
            controller.splitVC.activePanelVC.claimFirstResponder()
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [self] event in
            // A local monitor sees the keys of EVERY window of the app, this one included but
            // not only. Esc pressed in a share panel or any other window of ours used to close
            // the viewer and be swallowed here, so the window the person was actually looking
            // at never got its key and would not go away.
            guard isEventForThisViewer(event) else { return event }
            // Books turn on the arrows and on Page Up/Down. Handled BEFORE the general keys
            // so that a book in the panel does not move the panel's cursor instead.
            if effectiveMode == .book, book != nil,
               !event.modifierFlags.contains(.command) {
                switch event.keyCode {
                case 124, 121:            // → and Page Down
                    BookReaderBridge.shared.turn(1)
                    return nil
                case 123, 116:            // ← and Page Up
                    BookReaderBridge.shared.turn(-1)
                    return nil
                default:
                    break
                }
            }
            switch event.keyCode {
            case 53: // Escape
                if let onClose {
                    onClose()
                    return nil
                }
                return event
            case 49: // Space — closes the viewer, whatever inside it holds focus.
                // Space opens the viewer from the panel and must close it again. But the
                // panel only sees the key while IT is first responder: after zooming or
                // dragging the image, focus moves into the preview, the panel's handler
                // never fires and the key just beeped. Handling it here makes the toggle
                // work in every state. An editable text field still gets its space.
                if let onClose, !isEditingTextField {
                    onClose()
                    return nil
                }
                return event
            default:
                if handleZoomKey(event) { return nil }
                return event
            }
        }
    }

    /// Is this event ours to answer? Only if it belongs to the window the viewer is in. Until
    /// that window is known the viewer keeps its old reach, so the keys still work the moment
    /// it appears.
    private func isEventForThisViewer(_ event: NSEvent) -> Bool {
        guard let hostWindow else { return true }
        return event.window === hostWindow
    }

    /// True only while a field the user can TYPE into is focused, so Space stays a space
    /// there. A read-only text preview (the NSTextView the viewer uses for large files) is
    /// not editing, so Space still closes the viewer over it.
    private var isEditingTextField: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return false
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Trackpad two-finger swipe / mouse wheel arrives as scrollWheel events,
    /// not DragGesture, so SwiftUI's `.gesture(DragGesture())` doesn't see it.
    /// We forward those deltas to imgOffset so panning a zoomed image works
    /// with the trackpad as the user expects.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            guard self.isEventForThisViewer(event) else { return event }
            guard self.effectiveMode == .image || self.effectiveMode == .postScript,
                  self.image != nil else { return event }
            // hasPreciseScrollingDeltas is true for trackpads — use their
            // already-pixel-accurate deltas; for a mouse wheel, scale a bit.
            let dx = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaX
                : event.scrollingDeltaX * 8
            let dy = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 8
            let newOffset = CGSize(
                width: self.imgOffset.width + dx,
                height: self.imgOffset.height + dy
            )
            self.imgOffset = newOffset
            self.imgOffsetBase = newOffset
            return nil  // consume — don't let it scroll the file list
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    /// PostScript/AI files are rasterised, so zooming in eventually shows the pixel grid.
    /// When the user magnifies past what the current bitmap holds, quietly ask Ghostscript
    /// for a sharper one at the same logical size — the way a PDF reader re-renders a page.
    /// Debounced, because a pinch fires continuously, and cancelled if the zoom moves again.
    private func scheduleSharperRenderIfNeeded() {
        guard effectiveMode == .postScript, let path = targetItem?.path else { return }
        let wanted = min(PostScriptRenderer.baseLongEdgePixels * Double(max(imgScale, 1)),
                         PostScriptRenderer.maxLongEdgePixels)
        // Only bother when it buys a visible amount of detail, and never when zooming back out
        // (the existing bitmap is already finer than the view needs).
        guard wanted > psRenderedEdge * 1.3 else { return }

        psRerenderTask?.cancel()
        psRerenderTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)   // let the gesture settle
            if Task.isCancelled { return }
            let sharper = await Task.detached(priority: .userInitiated) {
                PostScriptRenderer.renderToImage(path: path, targetLongEdge: wanted)
            }.value
            if Task.isCancelled { return }
            // Same artwork at the same aspect ratio, so the fitted size is unchanged and the
            // picture does not jump — it just gains detail. Zoom and pan stay where they were.
            if let sharper {
                image = sharper
                psRenderedEdge = wanted
            }
        }
    }

    private func handleZoomKey(_ event: NSEvent) -> Bool {
        let zoomable = effectiveMode == .image || effectiveMode == .postScript || effectiveMode == .document
        guard zoomable else { return false }
        // The document renders in a WKWebView, which owns its own magnification; images and
        // PostScript scale through imgScale. Route each key to whichever applies.
        let isDocument = effectiveMode == .document
        switch event.keyCode {
        case 24, 69: // +
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) || event.keyCode == 69 {
                if isDocument { documentZoom.zoomIn() } else { imgScale += 0.25 }
                return true
            }
            return false
        case 27, 78: // -
            if event.modifierFlags.contains(.command) || event.keyCode == 78 || !event.modifierFlags.contains(.shift) {
                if isDocument { documentZoom.zoomOut() } else { imgScale = max(0.1, imgScale - 0.25) }
                return true
            }
            return false
        case 29, 82: // 0 — back to actual size (⌘0), for every zoomable mode
            guard event.modifierFlags.contains(.command) else { return false }
            if isDocument { documentZoom.reset() } else { imgScale = 1; imgOffset = .zero }
            return true
        default:
            return false
        }
    }
}

// MARK: - Helper Functions

private func normalizedExtension(for item: FileItem) -> String {
    let fromProperty = item.fileExtension
        .lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if !fromProperty.isEmpty { return fromProperty }
    return URL(fileURLWithPath: item.path).pathExtension.lowercased()
}

private func detectEncoding(_ data: Data) -> EncodingProbe {
    if data.count >= 4 {
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let b3 = data[data.startIndex + 3]
        if b0 == 0x00 && b1 == 0x00 && b2 == 0xFE && b3 == 0xFF {
            return EncodingProbe(name: "UTF-32BE", bomLength: 4, value: .utf32BigEndian)
        }
        if b0 == 0xFF && b1 == 0xFE && b2 == 0x00 && b3 == 0x00 {
            return EncodingProbe(name: "UTF-32LE", bomLength: 4, value: .utf32LittleEndian)
        }
        if b0 == 0xEF && b1 == 0xBB && b2 == 0xBF {
            return EncodingProbe(name: "UTF-8 (BOM)", bomLength: 3, value: .utf8)
        }
    }
    if data.count >= 2 {
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        if b0 == 0xFE && b1 == 0xFF {
            return EncodingProbe(name: "UTF-16BE", bomLength: 2, value: .utf16BigEndian)
        }
        if b0 == 0xFF && b1 == 0xFE {
            return EncodingProbe(name: "UTF-16LE", bomLength: 2, value: .utf16LittleEndian)
        }
    }
    return EncodingProbe(name: "UTF-8", bomLength: 0, value: .utf8)
}

private func decodeTextContent(data: Data, probe: EncodingProbe) -> (text: String, isBinary: Bool) {
    let payload = data.dropFirst(probe.bomLength)

    // The one binary-or-text rule the app has — the compare tool asks the same question and
    // the two must never disagree about a file.
    if FileDiffService.looksBinary(sample: Data(payload.prefix(8192))) {
        return (text: "", isBinary: true)
    }

    let decoded = String(data: payload, encoding: probe.value)
        ?? String(data: payload, encoding: .utf8)
        ?? String(decoding: payload, as: UTF8.self)

    // Single-pass normalization: \r\n → \n, \r → \n, strip \0
    var result = ""
    result.reserveCapacity(decoded.count)
    var prev: Character?
    for ch in decoded {
        if ch == "\0" { continue }
        if ch == "\r" {
            result.append("\n")
            prev = ch
            continue
        }
        if ch == "\n" && prev == "\r" {
            prev = ch
            continue
        }
        result.append(ch)
        prev = ch
    }

    return (text: result, isBinary: false)
}

private func buildHexLines(data: Data, bytesPerLine: Int) -> [ViewerHexLine] {
    guard !data.isEmpty else { return [] }

    var lines: [ViewerHexLine] = []
    lines.reserveCapacity((data.count + bytesPerLine - 1) / bytesPerLine)

    for offset in stride(from: 0, to: data.count, by: bytesPerLine) {
        let end = min(offset + bytesPerLine, data.count)
        let chunk = data[offset..<end]
        var bytesChunks: [String] = []
        bytesChunks.reserveCapacity(bytesPerLine)
        var ascii = ""
        ascii.reserveCapacity(chunk.count)

        for byte in chunk {
            bytesChunks.append(String(format: "%02X", byte))
            ascii.append(byte >= 32 && byte < 127 ? Character(Unicode.Scalar(byte)) : ".")
        }

        let paddingCount = bytesPerLine - chunk.count
        for _ in 0..<paddingCount {
            bytesChunks.append("  ")
        }

        lines.append(ViewerHexLine(
            index: lines.count,
            offset: UInt64(offset),
            bytesText: bytesChunks.joined(separator: " "),
            asciiText: ascii
        ))
    }

    return lines
}

private func fittedImageSize(original: NSSize, container: CGSize) -> CGSize {
    guard original.width > 0, original.height > 0 else {
        return CGSize(width: 1, height: 1)
    }
    let widthScale = container.width / original.width
    let heightScale = container.height / original.height
    let scale = min(1, widthScale, heightScale)
    return CGSize(width: original.width * scale, height: original.height * scale)
}

// MARK: - Font specimen

/// In-app preview for font files. Loads the faces straight from the file (no system
/// install) via CoreText and renders a type specimen: alphabets, digits, pangrams and a
/// size ladder, in Latin AND Cyrillic. CoreText opens ttf/otf/ttc/dfont directly; web
/// wrappers (woff/woff2/eot) and Type-1 (pfa/pfb) it can't, so those get a clear note.
private struct FontSpecimenView: View {
    let url: URL

    private struct Face: Identifiable {
        let id: Int
        let descriptor: CTFontDescriptor
        let name: String
        let glyphs: Int
    }

    private static let latinUpper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let latinLower = "abcdefghijklmnopqrstuvwxyz"
    private static let cyrUpper   = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
    private static let cyrLower   = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
    private static let glyphs     = "0123456789  &@#$%^*()  .,;:!?  «»\"'—–-  /\\|+=<>"
    private static let latinPangram = "The quick brown fox jumps over the lazy dog."
    private static let cyrPangram   = "Съешь же ещё этих мягких французских булок да выпей чаю."
    private static let ladderSample = "Съешь ещё булок · The quick fox 0123"
    private static let ladderSizes: [CGFloat] = [64, 48, 36, 28, 22, 18, 14, 12]

    private var faces: [Face] {
        guard let arr = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !arr.isEmpty else { return [] }
        return arr.enumerated().map { idx, desc in
            let f = CTFontCreateWithFontDescriptor(desc, 24, nil)
            let name = (CTFontCopyFullName(f) as String?) ?? url.lastPathComponent
            return Face(id: idx, descriptor: desc, name: name, glyphs: CTFontGetGlyphCount(f))
        }
    }

    private func font(_ face: Face, _ size: CGFloat) -> Font {
        Font(CTFontCreateWithFontDescriptor(face.descriptor, size, nil))
    }

    var body: some View {
        let loaded = faces
        if loaded.isEmpty {
            unsupported
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 28) {
                    // Cap the specimens: a font COLLECTION can carry hundreds of faces
                    // (the system font has ~370) and one specimen each would be unusable.
                    ForEach(Array(loaded.prefix(24))) { face in specimen(for: face) }
                    if loaded.count > 24 {
                        Text("+\(loaded.count - 24) …").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func specimen(for face: Face) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(face.name).font(.title3).bold()
                Text("· \(face.glyphs) \(L("font.glyphs"))").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                Text(Self.latinUpper).font(font(face, 26))
                Text(Self.latinLower).font(font(face, 26))
                Text(Self.cyrUpper).font(font(face, 26))
                Text(Self.cyrLower).font(font(face, 26))
                Text(Self.glyphs).font(font(face, 22)).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .lineLimit(1)

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
                Text(Self.latinPangram).font(font(face, 24))
                Text(Self.cyrPangram).font(font(face, 24))
            }
            .textSelection(.enabled)

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.ladderSizes, id: \.self) { size in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(Int(size))").font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                        Text(Self.ladderSample).font(font(face, size)).lineLimit(1)
                    }
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unsupported: some View {
        VStack(spacing: 12) {
            Image(systemName: "textformat.size").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(url.lastPathComponent).font(.headline)
            Text(L("font.unsupported")).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - NSViewRepresentable Sub-views

private struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        context.coordinator.appliedURL = url
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if context.coordinator.appliedURL != url {
            nsView.previewItem = url as NSURL
            nsView.refreshPreviewItem()
            context.coordinator.appliedURL = url
        }
    }

    class Coordinator {
        var appliedURL: URL?
    }
}

/// PDFKit-backed PDF preview. Unlike QLPreviewView, this view supports
/// native text selection, Cmd+C copy and a "Copy" context menu — exactly
/// what the user expects for a PDF reader.
/// A PDF with a strip of page thumbnails down its side.
///
/// The strip is PDFKit's own `PDFThumbnailView`, tied to the same view that shows the pages: it
/// scrolls with the document, marks the page being read and jumps to whichever page is clicked.
/// Written by hand it would be a worse copy of the same thing — and this one already knows how
/// to draw a page a person is only glancing at.
private struct PDFKitPreviewView: NSViewRepresentable {
    /// Уже прочитанный документ. Читать его здесь нельзя: тяжёлому PDF при загрузке
    /// подставляется кэширующий подкласс, и это решение принимается один раз, наверху.
    let document: PDFDocument
    /// Whether the strip is showing. A single-page document never shows one: a list of one is
    /// not a list.
    let showsThumbnails: Bool
    /// Номер показанной страницы — для счётчика «стр. 3 из 6» и для закладок.
    var onPageChange: (Int) -> Void = { _ in }
    /// Сам показанный PDF — чтобы закладка вела именно в него.
    var onReady: (PDFView) -> Void = { _ in }

    static let thumbnailStripWidth: CGFloat = 132

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        // The app's own context menu, in the app's language — see FCXLPDFView.
        let pdfView = FCXLPDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .clear
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        let strip = PDFThumbnailView()
        strip.pdfView = pdfView
        strip.thumbnailSize = NSSize(width: 96, height: 132)
        strip.maximumNumberOfColumns = 1
        strip.backgroundColor = .clear
        strip.translatesAutoresizingMaskIntoConstraints = false

        // A plain view rather than an NSBox separator. A box carries an intrinsic size of one
        // point in its thin direction, and SwiftUI sized the WHOLE representable to it: the
        // viewer came out one point tall and the page was nowhere to be seen.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(strip)
        container.addSubview(divider)
        container.addSubview(pdfView)

        let stripWidth = strip.widthAnchor.constraint(
            equalToConstant: Self.thumbnailStripWidth)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.topAnchor.constraint(equalTo: container.topAnchor),
            strip.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stripWidth,

            divider.leadingAnchor.constraint(equalTo: strip.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            pdfView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.pdfView = pdfView
        context.coordinator.strip = strip
        context.coordinator.divider = divider
        context.coordinator.stripWidth = stripWidth
        context.coordinator.onPageChange = onPageChange
        load(document, into: context.coordinator)
        apply(showsThumbnails, to: context.coordinator)
        onReady(pdfView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        if context.coordinator.appliedDocument !== document {
            load(document, into: context.coordinator)
        }
        apply(showsThumbnails, to: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopWatchingPages()
        // Кэш страниц отпускается здесь же, а не «когда-нибудь, когда документ отпустят»:
        // закрыли просмотрщик — сотни мегабайт картинок вернулись системе сразу. Ссылку на
        // экран тоже рвём, иначе фоновая страница попросит перерисовать закрытое окно.
        if let cache = (coordinator.appliedDocument as? PDFCachingDocument)?.cache {
            cache.view = nil
            cache.purge()
        }
        if PDFPageBridge.shared.current === coordinator.pdfView {
            PDFPageBridge.shared.current = nil
        }
    }

    private func load(_ document: PDFDocument, into coordinator: Coordinator) {
        guard let pdfView = coordinator.pdfView else { return }
        pdfView.document = document
        coordinator.appliedDocument = document
        (document as? PDFCachingDocument)?.cache.view = pdfView
        PDFPageBridge.shared.current = pdfView
        coordinator.watchPages(of: pdfView)
    }

    /// Width zero rather than a hidden view: a hidden strip that still holds its width would
    /// leave a band of nothing beside the page.
    private func apply(_ shows: Bool, to coordinator: Coordinator) {
        let pages = coordinator.pdfView?.document?.pageCount ?? 0
        let wanted = shows && pages > 1
        coordinator.strip?.isHidden = !wanted
        coordinator.divider?.isHidden = !wanted
        let width = wanted ? Self.thumbnailStripWidth : 0
        if coordinator.stripWidth?.constant != width {
            coordinator.stripWidth?.constant = width
        }
    }

    class Coordinator {
        var appliedDocument: PDFDocument?
        weak var pdfView: PDFView?
        weak var strip: PDFThumbnailView?
        weak var divider: NSView?
        var stripWidth: NSLayoutConstraint?
        var onPageChange: (Int) -> Void = { _ in }
        private var pageObserver: NSObjectProtocol?

        /// PDFView сам не рассказывает, где человек находится — об этом надо спросить его
        /// уведомление. Без этого закладке нечего запоминать, а счётчику нечего показывать.
        func watchPages(of pdfView: PDFView) {
            stopWatchingPages()
            pageObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: pdfView, queue: .main
            ) { [weak self, weak pdfView] _ in
                guard let self, let pdfView,
                      let page = pdfView.currentPage,
                      let index = pdfView.document?.index(for: page), index != NSNotFound
                else { return }
                self.onPageChange(index)
            }
            if let page = pdfView.currentPage,
               let index = pdfView.document?.index(for: page), index != NSNotFound {
                onPageChange(index)
            }
        }

        func stopWatchingPages() {
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            pageObserver = nil
        }

        deinit { stopWatchingPages() }
    }
}

private struct FastTextPreview: NSViewRepresentable {
    let filePath: String
    let encoding: String

    final class Coordinator {
        var loadedPath: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false

        // Performance: only layout visible text, not the entire document
        tv.layoutManager?.allowsNonContiguousLayout = true

        loadFile(into: tv, context: context)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if context.coordinator.loadedPath != filePath {
            loadFile(into: tv, context: context)
        }
    }

    private func loadFile(into tv: NSTextView, context: Context) {
        context.coordinator.loadedPath = filePath
        guard !filePath.isEmpty else {
            tv.string = ""
            return
        }
        // Load on background thread with memory-mapped I/O, set on main
        let path = filePath
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else {
                DispatchQueue.main.async { tv.string = "Failed to load file" }
                return
            }
            // Try UTF-8 first, then fallback encodings
            let text: String
            if let s = String(data: data, encoding: .utf8) {
                text = s
            } else if let s = String(data: data, encoding: .utf16) {
                text = s
            } else if let s = String(data: data, encoding: .windowsCP1251) {
                text = s
            } else if let s = String(data: data, encoding: .isoLatin1) {
                text = s
            } else {
                text = String(data: data, encoding: .ascii) ?? "Cannot decode file"
            }
            DispatchQueue.main.async {
                tv.string = text
                tv.scrollToBeginningOfDocument(nil)
            }
        }
    }
}

// MARK: - DjVu Preview View

/// Thin wrapper around the SHARED DjVuPagesView (module FCXLDjVuUI) — the same renderer the
/// standalone reader uses. This used to be a private copy of the page renderer, and when the
/// standalone one was optimised (background decoding, bounded cache) this copy kept
/// stuttering. One implementation now, so that cannot happen again.
private struct DjVuPreviewView: NSViewRepresentable {
    let reader: FCXLDjVuReader
    /// The pages view itself, handed back so the header can say which page this is and a
    /// bookmark can bring you back to it.
    var onReady: ((DjVuPagesView) -> Void)? = nil
    /// Какую страницу сейчас видно. Следит координатор, а не вызывающий: наблюдатель,
    /// заведённый снаружи, снять было некому — он оставался в NotificationCenter вместе с
    /// видом и открытым читателем DjVu, а тот держит файл (на сетевом томе — и сам том).
    var onPageChange: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        let pages = DjVuPagesView(reader: reader)
        scrollView.documentView = pages
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.observe(scrollView, onPageChange: onPageChange)
        onReady?(pages)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if context.coordinator.appliedReader !== reader {
            let pages = DjVuPagesView(reader: reader)
            nsView.documentView = pages
            context.coordinator.appliedReader = reader
            onReady?(pages)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }

    class Coordinator {
        var appliedReader: FCXLDjVuReader?
        private var observations: [NSObjectProtocol] = []
        init(reader: FCXLDjVuReader) { appliedReader = reader }

        func observe(_ scrollView: NSScrollView, onPageChange: ((Int) -> Void)?) {
            let center = NotificationCenter.default
            observations.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView, queue: .main
            ) { [weak scrollView] _ in
                scrollView?.documentView?.needsLayout = true
            })
            guard let onPageChange else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            observations.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main
            ) { [weak scrollView] _ in
                guard let pages = scrollView?.documentView as? DjVuPagesView else { return }
                MainActor.assumeIsolated { onPageChange(pages.currentPageIndex) }
            })
        }

        deinit {
            let center = NotificationCenter.default
            for observation in observations { center.removeObserver(observation) }
        }
    }
}


// MARK: - Word document preview

/// Word-processing documents rendered as reflowing HTML across the full panel width.
///
/// Quick Look hands these to Apple's WebKit-backed plugin, which lays the text out in a FIXED
/// 620pt column and centres it — measured, and unchanged whether the panel is 700 or 1400 wide, so
/// a wide panel is mostly empty bands and there is no API to influence it. Converting with the
/// system's `textutil` and drawing the result ourselves gives a view that uses the whole width,
/// reflows as the panel resizes and supports text selection. Quick Look remains one click away for
/// pixel-accurate page layout.
private struct WordDocumentPreview: View {
    let url: URL
    let zoom: DocumentZoomController

    @State private var converted: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let converted {
                WebArchiveView(url: converted, zoom: zoom)
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "doc.questionmark").font(.system(size: 28))
                    Text(L("viewer.document.failed")).font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) { await convert() }
    }

    private func convert() async {
        converted = nil
        failed = false
        let source = url
        let result: URL? = await Task.detached(priority: .userInitiated) {
            DocumentHTMLConverter.convert(source)
        }.value
        if let result { converted = result } else { failed = true }
    }
}

/// Draws a converted webarchive. Read-only: no navigation, no JavaScript — it is a document view.
private struct WebArchiveView: NSViewRepresentable {
    let url: URL
    let zoom: DocumentZoomController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // A Word document is authored for white paper: its own styling sets dark body text and
        // coloured headings. Rendering it over the app's dark background left dark text on dark.
        // Show it as a white sheet — which is also what Quick Look and Word itself do — and give
        // it margins so the text does not run into the panel edge.
        config.userContentController.addUserScript(WKUserScript(
            source: Self.paperStyle, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        // Pinch-to-zoom on the trackpad. WKWebView leaves this off by default (Safari turns it on
        // itself), which is why the document could not be zoomed while images and PDFs could.
        web.allowsMagnification = true
        web.navigationDelegate = context.coordinator
        zoom.webView = web
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        context.coordinator.loadedURL = url
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        web.magnification = 1          // a new document starts at 100%, not the last file's zoom
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        context.coordinator.loadedURL = url
    }

    /// Injected after the document loads: white page, comfortable margins, and images kept inside
    /// the panel. Deliberately does NOT touch text colours — that is the document's own design.
    private static let paperStyle = """
    var s = document.createElement('style');
    s.textContent = 'html,body{background:#fff !important;} \
        body{margin:0 !important;padding:28px 32px !important;box-sizing:border-box;} \
        img{max-width:100% !important;height:auto !important;} \
        table{max-width:100% !important;}';
    document.head.appendChild(s);
    """

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?

        /// A converted document is local content only — never let it navigate anywhere.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}

/// Drives the document view's zoom from the keyboard (⌘+ / ⌘− / ⌘0). The magnification lives on
/// the WKWebView — which also updates it on a trackpad pinch — so this reads the current value back
/// before stepping, and the two ways of zooming stay in agreement.
final class DocumentZoomController {
    weak var webView: WKWebView?

    private let step: CGFloat = 1.25
    private let limits: ClosedRange<CGFloat> = 0.25...8

    func zoomIn()  { apply { min(limits.upperBound, $0 * step) } }
    func zoomOut() { apply { max(limits.lowerBound, $0 / step) } }
    func reset()   { apply { _ in 1 } }

    private func apply(_ transform: (CGFloat) -> CGFloat) {
        guard let webView else { return }
        webView.magnification = transform(webView.magnification)
    }
}

/// Converts a word-processing document to a self-contained webarchive with `textutil`.
/// Results are cached per (path, modification date) so flipping between files does not re-convert.
enum DocumentHTMLConverter {
    private static let cacheDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TotumDocPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Runs off the main thread — `textutil` is a subprocess (~60 ms for a typical document).
    static func convert(_ source: URL) -> URL? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(abs(source.path.hashValue))-\(Int(stamp))"
        let output = cacheDirectory.appendingPathComponent("\(key).webarchive")
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        // webarchive (not html): a single self-contained file, so embedded images survive.
        p.arguments = ["-convert", "webarchive", "-output", output.path, source.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let size = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int,
              size > 0 else { return nil }
        return output
    }
}

/// Reports the window a SwiftUI view ended up in — there is no way to ask for it directly, and
/// an app-wide event monitor is useless without it.
private struct HostWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not set while the view is being made; one turn later it is.
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// Copy the whole line when the Option key is down, wherever on it the click landed.
///
/// A separate modifier because SwiftUI's `onTapGesture` says nothing about the keys being held —
/// the state has to be read from AppKit at the moment of the click.
private struct AltClickCopy: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.gesture(
            TapGesture().modifiers(.option).onEnded { action() }
        )
    }
}


/// The DjVu pages view that is on screen, so the header's bookmark list can reach it.
@MainActor
final class DjVuPageBridge {
    static let shared = DjVuPageBridge()
    weak var current: DjVuPagesView?
}
