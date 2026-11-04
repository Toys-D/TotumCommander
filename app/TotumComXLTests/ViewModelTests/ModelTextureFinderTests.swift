import AppKit
import SceneKit
import XCTest
@testable import TotumComXLApp

/// Поиск картинок модели там, где их держат люди, а не там, где написано в файле.
///
/// Путь внутри модели верен только на машине, где её собирали: `C:/tex/skin.png`,
/// `D:\work\skin.tga`. На диске рядом лежит папка `textures`, `Texture`, `tex`,
/// «Текстуры» — или те же картинки россыпью, иногда пересохранённые в другой формат.
final class ModelTextureFinderTests: XCTestCase {

    // MARK: - Какая папка похожа на текстурную

    func test_узнаётПапкуСТекстурами() {
        for name in ["textures", "Textures", "TEXTURES", "texture", "Tex", "tex_files",
                     "TextureMaps", "maps", "Maps", "materials", "images", "img", "skins",
                     "Текстуры", "текстуры", "картинки"] {
            XCTAssertTrue(ModelTextureFinder.looksLikeTextureFolder(name), name)
        }
        for name in ["scenes", "docs", "sources", "anim", "рендеры"] {
            XCTAssertFalse(ModelTextureFinder.looksLikeTextureFolder(name), name)
        }
    }

    func test_узнаётКартинкуПоРасширению() {
        for name in ["a.png", "b.JPG", "c.jpeg", "d.tga", "e.bmp", "f.tif", "g.webp", "h.dds"] {
            XCTAssertTrue(ModelTextureFinder.isImage(name), name)
        }
        for name in ["model.obj", "readme.txt", "scene.bin", "материалы.mtl"] {
            XCTAssertFalse(ModelTextureFinder.isImage(name), name)
        }
    }

    // MARK: - Поиск по вымышленной раскладке папок

    /// Раскладка задаётся словарём, а не файлами на диске: так проверяется именно порядок
    /// поиска, а не файловая система.
    private func finder(_ tree: [String: [(name: String, isDirectory: Bool)]],
                        at folder: String = "/модели/машина") -> ModelTextureFinder {
        ModelTextureFinder(modelFolder: URL(fileURLWithPath: folder)) { url in
            tree[url.path] ?? []
        }
    }

    func test_находитРядомСМоделью() {
        let tree = ["/модели/машина": [("scene.gltf", false), ("skin.png", false)]]
        XCTAssertEqual(finder(tree).locate("C:/work/skin.png"), "/модели/машина/skin.png")
    }

    func test_находитВПапкеTextures() {
        let tree = [
            "/модели/машина": [("scene.gltf", false), ("Textures", true)],
            "/модели/машина/Textures": [("skin.png", false)]
        ]
        XCTAssertEqual(finder(tree).locate("D:\\art\\skin.png"),
                       "/модели/машина/Textures/skin.png")
    }

    /// Модель лежит в `source`, картинки — в соседней `textures`: смотрим и на уровень выше.
    func test_находитВСоседнейПапкеНаУровеньВыше() {
        let tree = [
            "/модели/машина/source": [("scene.fbx", false)],
            "/модели/машина": [("source", true), ("textures", true)],
            "/модели/машина/textures": [("skin.png", false)]
        ]
        XCTAssertEqual(finder(tree, at: "/модели/машина/source").locate("skin.png"),
                       "/модели/машина/textures/skin.png")
    }

    /// В файле `.tga`, а на диске `.png` — обычное дело после пересохранения.
    func test_находитТуЖеКартинкуВДругомФормате() {
        let tree = [
            "/модели/машина": [("model.obj", false), ("tex", true)],
            "/модели/машина/tex": [("skin.png", false)]
        ]
        XCTAssertEqual(finder(tree).locate("C:/skin.tga"), "/модели/машина/tex/skin.png")
    }

    func test_регистрИмениНеМешает() {
        let tree = [
            "/модели/машина": [("TEX", true)],
            "/модели/машина/TEX": [("Skin_BaseColor.PNG", false)]
        ]
        XCTAssertEqual(finder(tree).locate("skin_basecolor.png"),
                       "/модели/машина/TEX/Skin_BaseColor.PNG")
    }

    /// Своё важнее соседского: если имя есть и рядом с моделью, и в чужой папке, берём
    /// то, что лежит у модели.
    func test_своёРядомВажнееДальнего() {
        let tree = [
            "/модели/машина": [("skin.png", false), ("textures", true)],
            "/модели/машина/textures": [("skin.png", false)]
        ]
        XCTAssertEqual(finder(tree).locate("skin.png"), "/модели/машина/skin.png")
    }

    /// В чужие папки (не похожие на текстурные) внутри модели не заходим: там бывают
    /// тысячи файлов, а открытие модели ждать не должно.
    func test_вЧужиеПапкиНеЗаходит() {
        let tree = [
            "/модели/машина": [("scene.obj", false), ("renders", true)],
            "/модели/машина/renders": [("skin.png", false)]
        ]
        XCTAssertNil(finder(tree).locate("skin.png"))
    }

    func test_ничегоНеНашлось_ЭтоNil() {
        let tree = ["/модели/машина": [("scene.obj", false)]]
        XCTAssertNil(finder(tree).locate("skin.png"))
        XCTAssertNil(finder(tree).locate("   "))
    }

    // MARK: - На настоящих файлах

    /// Полный путь: модель из Blender с виндовым путём в .mtl, картинка — в папке
    /// `Textures` и в другом формате. Должна доехать до материала.
    func test_наДискеНаходитИПодставляетВМатериал() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-tex-\(UUID().uuidString)")
        let textures = root.appendingPathComponent("Textures")
        try FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let png = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        try png.write(to: textures.appendingPathComponent("Skin.png"))

        // В файле материалов — путь с чужой машины И другое расширение.
        try """
        newmtl painted
        map_Kd C:\\\\work\\\\tex\\\\skin.tga
        """.write(to: root.appendingPathComponent("thing.mtl"), atomically: true, encoding: .utf8)
        try """
        mtllib thing.mtl
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vn 0 0 1
        usemtl painted
        f 1/1/1 2/2/1 3/3/1
        """.write(to: root.appendingPathComponent("thing.obj"), atomically: true, encoding: .utf8)

        let model = try Model3DLoader.load(path: root.appendingPathComponent("thing.obj").path)
        var found = false
        func walk(_ node: SCNNode) {
            for material in node.geometry?.materials ?? [] {
                if material.diffuse.contents is NSImage { found = true }
            }
            node.childNodes.forEach(walk)
        }
        walk(model.scene.rootNode)
        XCTAssertTrue(found, "картинка из папки Textures не доехала до материала")
    }
}
