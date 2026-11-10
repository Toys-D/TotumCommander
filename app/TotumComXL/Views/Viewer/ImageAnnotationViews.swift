import AppKit
import SwiftUI

/// The sheet over the picture while drawing. A drag makes an arrow, a frame or a blurred
/// patch; a click with the caption tool asks for the words. What is being dragged right now
/// is drawn here; once let go, the mark joins the edits and is burned into the preview.
///
/// Lives inside the picture's frame, under its zoom, so the marks are placed in the
/// picture's own coordinates however it is zoomed or dragged.
struct ImageAnnotationLayer: View {
    let size: CGSize
    let tool: ImageAnnotation.Tool
    let colour: ImageAnnotation.Colour
    let onAdd: (ImageAnnotation) -> Void
    let onCaption: (CGPoint) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
            if let dragStart, let dragEnd { draft(from: dragStart, to: dragEnd) }
        }
        .frame(width: size.width, height: size.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragStart = value.startLocation
                    dragEnd = value.location
                }
                .onEnded { value in
                    dragStart = nil
                    dragEnd = nil
                    let start = share(value.startLocation), end = share(value.location)
                    if tool == .text {
                        onCaption(start)
                        return
                    }
                    guard hypot(end.x - start.x, end.y - start.y) >= ImageAnnotation.shortestDrag else { return }
                    onAdd(ImageAnnotation(tool: tool, start: start, end: end, colour: colour))
                }
        )
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering { NSCursor.pop() }
            hovering = false
        }
    }

    private func share(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x / max(size.width, 1), 0), 1),
                y: min(max(point.y / max(size.height, 1), 0), 1))
    }

    @ViewBuilder
    private func draft(from start: CGPoint, to end: CGPoint) -> some View {
        let line = ImageAnnotation.lineWidth(longSide: max(size.width, size.height))
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch tool {
        case .arrow:
            let head = ImageAnnotationRenderer.arrowHead(from: start, to: end, lineWidth: line)
            Path { path in
                path.move(to: start)
                path.addLine(to: head.shaftEnd)
            }
            .stroke(colour.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
            Path { path in
                path.move(to: end)
                path.addLine(to: head.left)
                path.addLine(to: head.right)
                path.closeSubpath()
            }
            .fill(colour.color)
        case .frame:
            Path(roundedRect: box, cornerRadius: line)
                .stroke(colour.color, style: StrokeStyle(lineWidth: line, lineJoin: .round))
        case .blur:
            Path(box)
                .fill(Color.gray.opacity(0.35))
            Path(box)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .text:
            EmptyView()
        }
    }
}

/// The drawing tools — a row above the editing bar while drawing is on.
struct ImageAnnotationToolbar: View {
    @Binding var tool: ImageAnnotation.Tool
    @Binding var colour: ImageAnnotation.Colour
    let canUndo: Bool
    let onUndo: () -> Void
    let onDone: () -> Void

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    /// Подписи не режутся. Тесно — инструменты остаются одними значками (название — в подсказке и
    /// для чтения с экрана), как «Повернуть» и «Отразить» в полосе правки; совсем тесно —
    /// «Убрать последнее» и «Готово» уходят второй строкой (FCXLToolbarRow). Раньше это был HStack
    /// со Spacer, и в панели окна 1200 точек подписи обрезались до «Ar…», «U…», «D…».
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(toolTitles: true)
            row(toolTitles: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func row(toolTitles: Bool) -> some View {
        FCXLToolbarRow(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(ImageAnnotation.Tool.allCases, id: \.self) { item in
                    toolButton(item, showsTitle: toolTitles)
                }
                Divider().frame(height: 18).padding(.horizontal, 4)
                ForEach(ImageAnnotation.Colour.allCases, id: \.self) { item in
                    colourButton(item)
                }
            }
            HStack(spacing: 6) {
                Button(action: onUndo) { face(L("viewer.draw.undo"), "arrow.uturn.backward", selected: false) }
                    .buttonStyle(.plain)
                    .disabled(!canUndo)
                    .opacity(canUndo ? 1 : 0.4)
                Button(action: onDone) { face(L("viewer.draw.done"), "checkmark", selected: false) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func toolButton(_ item: ImageAnnotation.Tool, showsTitle: Bool) -> some View {
        let selected = item == tool
        return Button { tool = item } label: {
            face(L(item.titleKey), item.symbol, selected: selected, showsTitle: showsTitle)
        }
        .buttonStyle(.plain)
        .opacity(selected ? 1 : 0.75)
        .help(showsTitle ? "" : L(item.titleKey))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One look for every button of the row — the same as the viewer's mode buttons above
    /// the picture — so the tools and the two actions line up in size.
    private func face(_ title: String, _ symbol: String, selected: Bool,
                      showsTitle: Bool = true) -> some View {
        Group {
            if showsTitle {
                Label(title, systemImage: symbol)
            } else {
                // Название остаётся у значка — его читает VoiceOver.
                Label(title, systemImage: symbol).labelStyle(.iconOnly)
            }
        }
            .font(.caption)
            .lineLimit(1)
            // Подпись целиком: тесно — выбирается вид без подписей, а не «Стре…».
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? accent.opacity(0.18) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? accent.opacity(0.55) : Color.secondary.opacity(0.25), lineWidth: 1))
    }

    private func colourButton(_ item: ImageAnnotation.Colour) -> some View {
        let selected = item == colour
        return Button { colour = item } label: {
            Circle()
                .fill(item.color)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 1))
                .padding(3)
                .overlay(Circle().stroke(selected ? accent : Color.clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L(item.titleKey))
        // Кружок без подписи — имя для чтения с экрана то же, что в подсказке.
        .accessibilityLabel(L(item.titleKey))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
