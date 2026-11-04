import AppKit
import SceneKit
import SwiftUI

/// Трёхмерная модель в панели просмотра: вращается мышью, приближается колесом.
///
/// Рисует SceneKit — фреймворк системы, поверх Metal. Сама модель уже прочитана
/// (Model3DLoader), здесь только показ: камера по размеру модели, свет и фон на выбор,
/// каркас по просьбе, полоса воспроизведения у анимированной модели, сбоку — узлы,
/// материалы и размеры, внизу — строка о том, из чего модель состоит.
struct ModelPreviewView: View {

    let model: Model3DScene
    /// Файл модели — рядом с ним ложится «Сохранить как». nil — сохранять некуда.
    var path: String?

    @State private var wireframe = false
    /// Счётчик «поставить камеру заново»: вью следит за его изменением.
    @State private var resetToken = 0
    @State private var showsSide = false
    @State private var measurements: ModelMeasurements?
    @State private var hidden: Set<ObjectIdentifier> = []
    @State private var note: String?
    @StateObject private var playback = ModelPlayback()
    @AppStorage(ModelLighting.key) private var lightingRaw = ModelLighting.standard.rawValue
    @AppStorage(ModelBackdrop.key) private var backdropRaw = ModelBackdrop.window.rawValue

    private var lighting: ModelLighting { ModelLighting(rawValue: lightingRaw) ?? .standard }
    private var backdrop: ModelBackdrop { ModelBackdrop(rawValue: backdropRaw) ?? .window }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ModelSceneView(model: model, wireframe: wireframe, resetToken: resetToken,
                               lighting: lighting, backdrop: backdrop, playback: playback)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsSide {
                    Divider()
                    ModelSidePanel(model: model, measurements: measurements, hidden: $hidden)
                        .frame(width: 240)
                }
            }
            if playback.duration > 0 { animationBar }
            footer
        }
        .onDisappear { playback.pause() }
        .task(id: ObjectIdentifier(model.scene)) {
            hidden = []
            note = nil
            measurements = nil
            let root = model.scene.rootNode
            measurements = await Task.detached(priority: .utility) {
                ModelMeasurements.measure(root)
            }.value
        }
    }

    private var animationBar: some View {
        HStack(spacing: 10) {
            Button {
                playback.playing ? playback.pause() : playback.play()
            } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(L(playback.playing ? "viewer.model.pause" : "viewer.model.play"))
            Slider(value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 0.01))
            Text(String(format: L("viewer.model.time"), playback.time, playback.duration))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.25))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(note ?? ModelStats.line(model: model))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                showsSide.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showsSide ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(L("viewer.model.side"))
            ProgramMenuButton(makeMenu: lookMenu) {
                Image(systemName: "lightbulb")
            }
            .fixedSize()
            .help(L("viewer.model.look"))
            if path != nil {
                ProgramMenuButton(makeMenu: saveMenu) {
                    Image(systemName: "square.and.arrow.down")
                }
                .fixedSize()
                .help(L("viewer.model.saveAs"))
            }
            Button {
                wireframe.toggle()
            } label: {
                Image(systemName: "grid")
                    .foregroundStyle(wireframe ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(L("viewer.model.wireframe"))
            Button {
                resetToken += 1
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help(L("viewer.model.reset"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }

    /// Свет и фон — одним меню: оба про то, как модель видна, и оба запоминаются.
    private func lookMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addNote(L("viewer.model.light"))
        for option in ModelLighting.allCases {
            menu.addChoiceItem(title: L(option.titleKey), checked: option == lighting) {
                lightingRaw = option.rawValue
            }
        }
        menu.addItem(.separator())
        menu.addNote(L("viewer.model.backdrop"))
        for option in ModelBackdrop.allCases {
            menu.addChoiceItem(title: L(option.titleKey), checked: option == backdrop) {
                backdropRaw = option.rawValue
            }
        }
        return menu
    }

    private func saveMenu() -> NSMenu {
        let menu = NSMenu()
        for format in ModelExportFormat.available {
            menu.addChoiceItem(title: String(format: L("viewer.model.saveAsFormat"), format.title)) {
                save(as: format)
            }
        }
        return menu
    }

    /// Рядом с моделью, новым файлом: исходник не трогается никогда.
    private func save(as format: ModelExportFormat) {
        guard let path else { return }
        let target = ModelExporter.destination(for: path, format: format)
        do {
            try ModelExporter.write(model.scene, to: target, format: format)
            note = String(format: L("viewer.model.saved"), (target as NSString).lastPathComponent)
        } catch {
            DialogService.shared.showOperationError(title: L("viewer.model.saveAs"), error: error)
        }
    }
}

/// Узлы, материалы и размеры — сбоку от модели.
struct ModelSidePanel: View {
    let model: Model3DScene
    let measurements: ModelMeasurements?
    @Binding var hidden: Set<ObjectIdentifier>

    /// Строки узлов одной высоты, глазки — в одном столбце слева: так по строке под мышью
    /// видно, какой глазок она проходит.
    private static let rowHeight: CGFloat = 20
    private static let eyeColumn: CGFloat = 20
    @State private var sweep: ModelVisibilitySweep?
    /// Повёл не с глазка — это не переключение, до отпускания ничего не делаем.
    @State private var sweepIgnored = false

    var body: some View {
        let nodes = ModelNodeRow.rows(of: model.scene.rootNode)
        let materials = ModelMaterialRow.rows(of: model.scene.rootNode)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                heading(L("viewer.model.size"))
                if let measurements {
                    sizeRows(measurements)
                } else {
                    ProgressView().controlSize(.small)
                }

                heading(String(format: L("viewer.model.nodes"), nodes.count)).padding(.top, 6)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(nodes) { row in
                        HStack(spacing: 4) {
                            Image(systemName: hidden.contains(row.id) ? "eye.slash" : "eye")
                                .font(.system(size: 10))
                                .foregroundStyle(hidden.contains(row.id) ? Color.secondary : Color.primary)
                                .frame(width: Self.eyeColumn, height: Self.rowHeight)
                                .contentShape(Rectangle())
                                .help(L("viewer.model.toggleNode"))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { set([row], hidden: !hidden.contains(row.id)) }
                            HStack(spacing: 4) {
                                Image(systemName: row.hasMesh ? "cube" : "folder")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(row.title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.leading, CGFloat(min(row.depth, 8)) * 10)
                        }
                        .frame(height: Self.rowHeight)
                        .opacity(hidden.contains(row.id) ? 0.5 : 1)
                    }
                }
                .gesture(sweepGesture(nodes))

                heading(String(format: L("viewer.model.materials"), materials.count)).padding(.top, 6)
                ForEach(materials) { row in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(row.colour.map { Color(nsColor: $0) } ?? Color.secondary.opacity(0.2))
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.25)))
                            .overlay {
                                if row.hasTexture {
                                    Image(systemName: "photo").font(.system(size: 8)).foregroundStyle(.secondary)
                                }
                            }
                        Text(row.title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func sizeRows(_ m: ModelMeasurements) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            line(L("viewer.model.extent"), "\(ModelMeasurements.number(m.width)) × "
                 + "\(ModelMeasurements.number(m.height)) × \(ModelMeasurements.number(m.depth))")
            line(L("viewer.model.area"), ModelMeasurements.number(m.area))
            line(L("viewer.model.volume"), "≈ " + ModelMeasurements.number(m.volume))
            Text(L("viewer.model.units"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 11)).monospacedDigit().textSelection(.enabled)
        }
    }

    /// Щелчок по глазку переключает узел; нажал и повёл по глазкам — они становятся такими же,
    /// как первый (ModelVisibilitySweep). Начатое не с глазка — не переключение.
    private func sweepGesture(_ nodes: [ModelNodeRow]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !nodes.isEmpty, !sweepIgnored else { return }
                let row = { ModelVisibilitySweep.row(at: $0, rowHeight: Self.rowHeight, count: nodes.count) }
                if sweep == nil {
                    guard value.startLocation.x < Self.eyeColumn else {
                        sweepIgnored = true
                        return
                    }
                    let first = row(value.startLocation.y)
                    sweep = ModelVisibilitySweep(from: first, wasHidden: hidden.contains(nodes[first].id))
                }
                guard var current = sweep else { return }
                current.reach(row(value.location.y))
                sweep = current
                set(current.rows.map { nodes[$0] }, hidden: current.hide)
            }
            .onEnded { _ in
                sweep = nil
                sweepIgnored = false
            }
    }

    private func set(_ rows: [ModelNodeRow], hidden hide: Bool) {
        for row in rows where hidden.contains(row.id) != hide {
            if hide { hidden.insert(row.id) } else { hidden.remove(row.id) }
            row.node.isHidden = hide
        }
    }
}

/// Время анимации модели. Анимации переведены на время сцены (ModelAnimation), и это
/// время ведём мы: так полоса показывает, где мы, и ставит в любой момент.
@MainActor
final class ModelPlayback: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var playing = false
    @Published private(set) var duration: TimeInterval = 0
    weak var view: SCNView?
    private var timer: Timer?
    private var lastTick: Date?

    func attach(_ view: SCNView, duration: TimeInterval) {
        self.view = view
        self.duration = duration
        time = 0
        view.sceneTime = 0
        if duration > 0 { play() } else { pause() }
    }

    func play() {
        guard duration > 0 else { return }
        playing = true
        view?.isPlaying = true
        lastTick = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor in self.tick() }
        }
    }

    func pause() {
        playing = false
        timer?.invalidate()
        timer = nil
        view?.isPlaying = false
    }

    func seek(to value: TimeInterval) {
        time = min(max(value, 0), duration)
        view?.sceneTime = time
    }

    private func tick() {
        guard playing, let lastTick else { return }
        let now = Date()
        self.lastTick = now
        var next = time + now.timeIntervalSince(lastTick)
        if duration > 0 { next = next.truncatingRemainder(dividingBy: duration) }
        time = next
        view?.sceneTime = next
    }

}

/// Что сказать о модели одной строкой.
enum ModelStats {

    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func line(meshes: Int, vertices: Int, faces: Int) -> String {
        [String(format: L("viewer.model.meshes"), number(meshes)),
         String(format: L("viewer.model.vertices"), number(vertices)),
         String(format: L("viewer.model.faces"), number(faces))]
            .joined(separator: " · ")
    }

    static func line(model: Model3DScene) -> String {
        line(meshes: model.meshCount, vertices: model.vertexCount, faces: model.faceCount)
    }
}

/// Само окно SceneKit.
private struct ModelSceneView: NSViewRepresentable {

    let model: Model3DScene
    let wireframe: Bool
    let resetToken: Int
    let lighting: ModelLighting
    let backdrop: ModelBackdrop
    let playback: ModelPlayback

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        apply(model: model, to: view)
        context.coordinator.shownScene = model.scene
        context.coordinator.shownToken = resetToken
        context.coordinator.shownLook = (lighting, backdrop)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if context.coordinator.shownScene !== model.scene {
            context.coordinator.shownScene = model.scene
            apply(model: model, to: view)
        } else if context.coordinator.shownToken != resetToken {
            // Только просьба поставить камеру заново — сцену не пересобираем.
            placeCamera(for: model, in: view)
        }
        if context.coordinator.shownLook.0 != lighting || context.coordinator.shownLook.1 != backdrop {
            lighting.apply(to: model.scene, view: view, radius: model.radius)
            backdrop.apply(to: model.scene, view: view)
        }
        context.coordinator.shownLook = (lighting, backdrop)
        context.coordinator.shownToken = resetToken
        view.debugOptions = wireframe ? [.showWireframe] : []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shownScene: SCNScene?
        var shownToken = 0
        var shownLook: (ModelLighting, ModelBackdrop) = (.standard, .window)
    }

    private func apply(model: Model3DScene, to view: SCNView) {
        view.scene = model.scene
        // Цвет окна по умолчанию — системный оконный: он сам переворачивается со сменой
        // темы, и модель одинаково читается и в светлой, и в тёмной.
        lighting.apply(to: model.scene, view: view, radius: model.radius)
        backdrop.apply(to: model.scene, view: view)
        placeCamera(for: model, in: view)
        let duration = ModelAnimation.prepare(model.scene.rootNode)
        DispatchQueue.main.async { playback.attach(view, duration: duration) }
    }

    /// Камера — по размеру модели: иначе она или не влезает в кадр, или теряется точкой
    /// в середине. Модели бывают и в миллиметрах, и в километрах. Считается в
    /// Model3DLoader — там же, где её проверяют тесты.
    private func placeCamera(for model: Model3DScene, in view: SCNView) {
        view.pointOfView = Model3DLoader.camera(for: model)
    }
}
