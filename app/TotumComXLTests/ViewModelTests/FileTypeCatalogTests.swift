import AppKit
import XCTest
@testable import TotumComXLApp

/// Свои значки узнают файл по расширению, а без расширения — по имени, месту и праву на
/// запуск: HEAD и index из .git, Makefile, LICENSE, id_rsa, /usr/bin/ls.
final class FileTypeCatalogTests: XCTestCase {

    private func key(_ name: String, path: String? = nil, permissions: String = "644",
                     style: FileIconStyle = .totum) -> String {
        let ext = (name as NSString).pathExtension
        return FileIcons.typeKey(name: name, fileExtension: ext, path: path ?? "/Users/u/project/\(name)",
                                 permissions: permissions, style: style)
    }

    private func kind(_ name: String, path: String? = nil, permissions: String = "644") -> FileKind {
        FileKind.of(key(name, path: path, permissions: permissions))
    }

    // MARK: - Каталог в порядке

    /// Все расширения каталога: по видам и по семействам — откуда каждое.
    private func allExtensions() -> [(ext: String, owner: String)] {
        var out: [(String, String)] = []
        for (kind, list) in FileTypeCatalog.extensionsByKind {
            out += list.split(separator: " ").map { (String($0), "\(kind)") }
        }
        for family in FileTypeCatalog.families {
            out += family.extensions.map { ($0, family.id) }
        }
        return out
    }

    func test_расширениеВОдномМестеИЗаписаноКакНадо() {
        var seen: [String: String] = [:]
        for (ext, owner) in allExtensions() {
            XCTAssertNil(seen[ext], ".\(ext) — и \(seen[ext] ?? ""), и \(owner)")
            seen[ext] = owner
            XCTAssertEqual(ext, ext.lowercased(), ext)
            XCTAssertFalse(ext.contains(".") || ext.contains(" ") || ext.isEmpty, "расширение без точки: \(ext)")
        }
        XCTAssertGreaterThan(seen.count, 1400, "расширений — больше тысячи")
    }

    func test_семействаСвоиИНеПустые() {
        let ids = FileTypeCatalog.families.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "имена семейств не повторяются")
        XCTAssertGreaterThanOrEqual(ids.count, 120, "семейств — больше сотни")
        for family in FileTypeCatalog.families {
            XCTAssertFalse(family.extensions.isEmpty, family.id)
        }
    }

    /// Свой значок у каждого: у двух семейств (и видов) с одним знаком цвета заметно разные.
    func test_уКаждогоСемействаИВидаСвойОблик() {
        struct Look { let name: String; let symbol: String; let rgb: [CGFloat] }
        var looks = FileTypeCatalog.families.map { Look(name: $0.id, symbol: $0.symbol, rgb: [$0.red, $0.green, $0.blue]) }
        for kind in FileKind.allCases {
            guard let symbol = kind.symbol, let c = kind.color.usingColorSpace(.sRGB) else { continue }
            looks.append(Look(name: "\(kind)", symbol: symbol, rgb: [c.redComponent, c.greenComponent, c.blueComponent]))
        }
        for (i, a) in looks.enumerated() {
            for b in looks[(i + 1)...] where a.symbol == b.symbol {
                let distance = zip(a.rgb, b.rgb).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
                XCTAssertGreaterThan(distance, 0.1, "\(a.name) и \(b.name): один знак и почти один цвет")
            }
        }
    }

    /// Знаки — только те, что есть уже в macOS 15.0: по таблице доступности самой системы.
    func test_знакиЕстьВmacOS15() throws {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let symbols = try XCTUnwrap(plist["symbols"] as? [String: String])
        let used = FileTypeCatalog.families.map(\.symbol) + FileKind.allCases.compactMap(\.symbol)
        for name in Set(used) {
            let year = try XCTUnwrap(symbols[name], "\(name) — нет в системе")
            XCTAssertTrue(year.split(separator: ".").first.flatMap { Int($0) }.map { $0 < 2024 } == true || year == "2024",
                          "\(name) появился в \(year) — позже macOS 15.0")
        }
    }

    func test_каждыйВидДостижим() {
        var reachable = Set(FileTypeCatalog.extensionsByKind.keys)
        reachable.formUnion(FileTypeCatalog.families.map(\.kind))
        reachable.insert(.other)
        for kind in FileKind.allCases {
            XCTAssertTrue(reachable.contains(kind), "\(kind) — ни одного расширения")
        }
    }

    func test_семействоПоРасширению() {
        let expected: [String: (String, FileKind)] = [
            "blend": ("blender", .model3d), "c4d": ("cinema4d", .model3d), "hip": ("houdini", .model3d),
            "ma": ("maya", .model3d), "max": ("3dsmax", .model3d), "ztl": ("zbrush", .model3d),
            "usdz": ("usd", .model3d), "fbx": ("fbx", .model3d), "stl": ("print3d", .cad),
            "dwg": ("autocad", .cad), "sldprt": ("solidworks", .cad), "skp": ("sketchup", .cad),
            "step": ("cadexchange", .cad), "kicad_pcb": ("pcb", .cad), "aep": ("aftereffects", .video),
            "prproj": ("premiere", .video), "fcpxml": ("finalcut", .video), "drp": ("resolve", .video),
            "braw": ("cinemaraw", .video), "als": ("ableton", .audio), "flp": ("flstudio", .audio),
            "flac": ("lossless", .audio), "psd": ("photoshop", .image), "ai": ("illustrator", .design),
            "cr3": ("cameraraw", .image), "docx": ("word", .document), "xlsx": ("excel", .spreadsheet),
            "key": ("keynote", .presentation), "rar": ("rar", .archive), "swift": ("swift", .code),
        ]
        for (ext, (family, kind)) in expected {
            XCTAssertEqual(FileTypeCatalog.familyByExtension[ext]?.id, family, ext)
            XCTAssertEqual(FileKind.of(ext), kind, ext)
        }
    }

    /// Значок .blend — цвета своего семейства, а не общего цвета 3D.
    func test_значокСемействаСвоегоЦвета() {
        let blend = FileTypeCatalog.face(forKey: "blend")
        let fbx = FileTypeCatalog.face(forKey: "fbx")
        XCTAssertNotEqual(blend.color, fbx.color)
        XCTAssertEqual(blend.symbols.first, "circle.hexagonpath")
        XCTAssertEqual(blend.symbols.last, FileKind.model3d.symbol, "нет знака семейства — знак вида")
        XCTAssertEqual(FileTypeCatalog.face(forKey: "=git").symbols, [FileKind.git.symbol!], "у имени — облик вида")
    }

    // MARK: - По расширению

    func test_видПоРасширению() {
        let expected: [String: FileKind] = [
            "a.sh": .script, "a.zsh": .script, "a.ps1": .script, "a.exe": .executable, "a.dll": .binary,
            "a.dylib": .binary, "a.pkg": .package, "a.deb": .package, "a.apk": .package, "a.ipa": .package,
            "a.sqlite": .database, "a.sql": .database, "a.yaml": .config, "a.toml": .config,
            "a.plist": .config, "a.json": .data, "a.xml": .data, "a.html": .web, "a.css": .web,
            "a.md": .markup, "a.tex": .markup, "a.pem": .security, "a.gpg": .encrypted, "a.sha256": .checksum,
            "a.svg": .design, "a.sketch": .design, "a.stl": .cad, "a.usdz": .model3d, "a.dwg": .cad,
            "a.srt": .subtitle, "a.m3u": .playlist, "a.eml": .mail, "a.vcf": .contact, "a.ics": .calendar,
            "a.webloc": .link, "a.torrent": .download, "a.log": .log, "a.ips": .log, "a.bak": .backup,
            "a.nes": .game, "a.gpx": .map, "a.vmdk": .virtualMachine, "a.po": .translation,
            "a.strings": .translation, "a.nfo": .readme, "a.patch": .git, "a.ts": .code, "a.swift": .code,
            "a.djvu": .book, "a.docx": .document, "a.key": .presentation, "a.cr3": .image,
        ]
        for (name, kind) in expected {
            XCTAssertEqual(self.kind(name), kind, name)
        }
    }

    // MARK: - По имени

    func test_файлыИзGitБезРасширения() {
        let git = "/Users/u/project/.git"
        XCTAssertEqual(kind("HEAD", path: "\(git)/HEAD"), .git)
        XCTAssertEqual(kind("index", path: "\(git)/index"), .git, "двоичный указатель git")
        XCTAssertEqual(kind("description", path: "\(git)/description"), .git)
        XCTAssertEqual(kind("main", path: "\(git)/refs/heads/main"), .git)
        XCTAssertEqual(kind("pack-1.pack", path: "\(git)/objects/pack/pack-1.pack"), .git)
        XCTAssertEqual(kind("pre-commit.sample", path: "\(git)/hooks/pre-commit.sample"), .script)
        XCTAssertEqual(kind("config", path: "\(git)/config"), .config, "настройки — шестерёнкой, и в .git")
        XCTAssertEqual(FileIconArt.label(for: key("HEAD", path: "\(git)/HEAD")), "GIT")
        XCTAssertEqual(FileIconArt.label(for: key("config", path: "\(git)/config")), "CONF")
    }

    func test_извесныеИмена() {
        let expected: [String: (FileKind, String)] = [
            "Makefile": (.build, "MAKE"), "Dockerfile": (.build, "DOCK"), "package.json": (.build, "NPM"),
            "CMakeLists.txt": (.build, "CMAKE"), "Podfile": (.build, "POD"), "go.mod": (.build, "GOMOD"),
            "README": (.readme, "READ"), "README.md": (.readme, "READ"), "CHANGELOG.md": (.readme, "INFO"),
            "LICENSE": (.license, "LIC"), "LICENSE.txt": (.license, "LIC"), "COPYING": (.license, "LIC"),
            "SHA256SUMS.txt": (.checksum, "SUM"), "id_ed25519": (.security, "SSH"),
            "known_hosts": (.security, "SSH"), ".zshrc": (.script, "ZSH"), ".bashrc": (.script, "BASH"),
            ".zsh_history": (.log, "HIST"), ".gitignore": (.git, "GIT"), ".DS_Store": (.config, "DS"),
            ".env": (.config, "ENV"), ".env.local": (.config, "ENV"), ".editorconfig": (.config, "CONF"),
            ".vimrc": (.config, "VIM"), "notes.txt~": (.backup, "BAK"), "~$report.docx": (.backup, "TMP"),
        ]
        for (name, (kind, label)) in expected {
            XCTAssertEqual(self.kind(name), kind, name)
            XCTAssertEqual(FileIconArt.label(for: key(name)), label, name)
        }
    }

    func test_HEADТолькоЗаглавными_headВbinПрограмма() {
        XCTAssertEqual(kind("head", path: "/usr/bin/head", permissions: "755"), .executable)
        XCTAssertEqual(kind("HEAD", path: "/tmp/x/HEAD"), .git)
    }

    /// /etc/passwd — настройки системы, /usr/bin/passwd — программа.
    func test_имяСистемногоФайлаУступаетПрограмме() {
        XCTAssertEqual(kind("passwd", path: "/etc/passwd", permissions: "644"), .config)
        XCTAssertEqual(kind("passwd", path: "/usr/bin/passwd", permissions: "4555"), .executable)
        XCTAssertEqual(kind("hosts", path: "/etc/hosts", permissions: "644"), .config)
    }

    func test_безРасширения_программаИлиПростоЛист() {
        XCTAssertEqual(kind("ls", path: "/bin/ls", permissions: "755"), .executable)
        XCTAssertEqual(FileIconArt.label(for: key("ls", path: "/bin/ls", permissions: "755")), "EXEC")
        XCTAssertEqual(key("notes", permissions: "644"), "", "незнакомое без права на запуск — пустой лист")
        XCTAssertEqual(key("notes", permissions: ""), "", "прав не знаем (сеть) — тоже")
        XCTAssertEqual(key("run.sh", permissions: "755"), "sh", "с расширением — по расширению")
    }

    // MARK: - Значки macOS

    /// У значков macOS имени нет: только расширение и значок программы.
    func test_дляMacOSКлючПоРасширению() {
        XCTAssertEqual(key("Makefile", style: .macos), "")
        XCTAssertEqual(key("package.json", style: .macos), "json")
        XCTAssertEqual(key("HEAD", path: "/p/.git/HEAD", style: .macos), "")
        XCTAssertEqual(key("ls", path: "/bin/ls", permissions: "755", style: .macos), FileIcons.executableKey)
        let exec = FileIcons.icon(forExtension: FileIcons.executableKey, size: 16,
                                  look: FileIconLook(style: .macos, backgrounds: []))
        let plain = FileIcons.icon(forExtension: "", size: 16, look: FileIconLook(style: .macos, backgrounds: []))
        XCTAssertFalse(exec === plain, "у программы свой значок macOS")
    }

    // MARK: - Картинка

    /// Значок HEAD — с полосой цвета git, а не пустой серый лист.
    func test_значокGitСПолосойСвоегоЦвета() {
        let icon = FileIconArt.totum(extension: key("HEAD", path: "/p/.git/HEAD"), size: 44, darkBackground: false)
        guard let rep = icon.representations.compactMap({ $0 as? NSBitmapImageRep })
            .first(where: { $0.pixelsWide == 44 }),
              let band = rep.colorAt(x: 22, y: 40)?.usingColorSpace(.sRGB) else {
            return XCTFail("нет растра")
        }
        XCTAssertGreaterThan(band.redComponent, band.blueComponent + 0.4, "полоса оранжево-красная, как у git")
    }
}
