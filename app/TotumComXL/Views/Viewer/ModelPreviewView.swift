import AppKit
import SceneKit
import SwiftUI

/// Трёхмерная модель в панели просмотра: вращается мышью, приближается колесом.
///
/// Рисует SceneKit — фреймворк системы, поверх Metal. Сама модель уже прочитана
/// (Model3DLoader), здесь только показ: камера по размеру модели, свет, каркас по просьбе
/// и строка о том, из чего модель состоит.
struct ModelPreviewView: View {

    let model: Model3DScene

    @State private var wireframe = false
    /// Счётчик «поставить камеру заново»: вью следит за его изменением.
    @State private var resetToken = 0

    var body: some View {
        VStack(spacing: 0) {
            ModelSceneView(model: model, wireframe: wireframe, resetToken: resetToken)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(ModelStats.line(model: model))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
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

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        // Цвет фона — системный оконный: он сам переворачивается со сменой темы, и модель
        // одинаково читается и в светлой, и в тёмной.
        view.backgroundColor = .windowBackgroundColor
        apply(model: model, to: view)
        context.coordinator.shownScene = model.scene
        context.coordinator.shownToken = resetToken
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
        context.coordinator.shownToken = resetToken
        view.debugOptions = wireframe ? [.showWireframe] : []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shownScene: SCNScene?
        var shownToken = 0
    }

    private func apply(model: Model3DScene, to view: SCNView) {
        view.scene = model.scene
        placeCamera(for: model, in: view)
    }

    /// Камера — по размеру модели: иначе она или не влезает в кадр, или теряется точкой
    /// в середине. Модели бывают и в миллиметрах, и в километрах.
    private func placeCamera(for model: Model3DScene, in view: SCNView) {
        let distance = Model3DLoader.cameraDistance(radius: model.radius)
        let camera = SCNCamera()
        camera.fieldOfView = 60
        // Ближнюю и дальнюю границы тоже от размера: постоянные 1 и 100 режут и мелкую
        // модель, и крупную.
        camera.zNear = Double(distance) / 100
        camera.zFar = Double(distance) * 20
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(model.center.x,
                                   model.center.y,
                                   model.center.z + CGFloat(distance))
        node.look(at: model.center)
        view.pointOfView = node
    }
}
