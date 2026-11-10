import AppKit

/// Семейство форматов — файлы одной программы или одного дела. Свой цвет и знак поверх
/// вида файла: .blend, .c4d и .hip — все 3D, но с первого взгляда разные.
///
/// Знаки — только те, что есть уже в macOS 15 (сверяет тест по таблице доступности системы).
/// Цвета и знаки свои: значок говорит, чей это файл, но не повторяет ничей логотип.
struct FileFamily {
    let id: String
    let kind: FileKind
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let symbol: String
    let extensions: [String]

    init(_ id: String, _ kind: FileKind, _ rgb: (CGFloat, CGFloat, CGFloat), _ symbol: String, _ extensions: String) {
        self.id = id
        self.kind = kind
        (red, green, blue) = rgb
        self.symbol = symbol
        self.extensions = extensions.split(separator: " ").map(String.init)
    }

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

extension FileTypeCatalog {

    private static let codeSymbol = "chevron.left.forwardslash.chevron.right"

    static let families: [FileFamily] = [
        // MARK: 3D
        FileFamily("blender", .model3d, (0.92, 0.49, 0.13), "circle.hexagonpath", "blend blend1 blend2"),
        FileFamily("maya", .model3d, (0.09, 0.60, 0.64), "move.3d", "ma mb mel"),
        FileFamily("3dsmax", .model3d, (0.10, 0.40, 0.45), "cube.transparent", "max 3ds"),
        FileFamily("cinema4d", .model3d, (0.12, 0.33, 0.72), "rotate.3d", "c4d"),
        FileFamily("houdini", .model3d, (0.93, 0.33, 0.12), "flame", "hip hipnc hiplc hda hdanc hdalc otl"),
        FileFamily("volumes", .model3d, (0.36, 0.56, 0.86), "cloud", "vdb nvdb bgeo geo"),
        FileFamily("zbrush", .model3d, (0.78, 0.52, 0.22), "scribble.variable", "ztl zpr zbr zsc"),
        FileFamily("substance", .model3d, (0.82, 0.22, 0.33), "paintbrush", "spp sbs sbsar sbsprs spsm"),
        FileFamily("modo", .model3d, (0.30, 0.31, 0.38), "square.3.layers.3d", "lxo lxl lxp"),
        FileFamily("lightwave", .model3d, (0.38, 0.38, 0.80), "view.3d", "lwo lws lw"),
        FileFamily("keyshot", .model3d, (0.86, 0.68, 0.10), "lightbulb", "bip ksp kmp kpp"),
        FileFamily("usd", .model3d, (0.58, 0.33, 0.84), "square.stack.3d.up", "usd usda usdc usdz reality rcproject scn"),
        FileFamily("fbx", .model3d, (0.30, 0.53, 0.74), "figure.arms.open", "fbx"),
        FileFamily("mesh", .model3d, (0.30, 0.47, 0.86), "point.3.connected.trianglepath.dotted",
                   "obj mtl ply off x3d x3db x3dv wrl vrml dae amf vox"),
        FileFamily("gltf", .model3d, (0.45, 0.68, 0.22), "cube", "gltf glb"),
        FileFamily("alembic", .model3d, (0.70, 0.44, 0.30), "square.stack.3d.down.forward", "abc"),
        FileFamily("figures", .model3d, (0.72, 0.38, 0.62), "figure.stand", "duf pz3 pp2 pmx pmd vrm"),
        FileFamily("mocap", .model3d, (0.18, 0.64, 0.54), "figure.walk", "bvh c3d trc htr"),
        FileFamily("garment", .model3d, (0.86, 0.40, 0.56), "tshirt", "zprj zpac avt"),
        FileFamily("terrain", .model3d, (0.44, 0.56, 0.34), "mountain.2", "tmd ter tgd hgt"),
        FileFamily("pointcloud", .model3d, (0.32, 0.64, 0.74), "circle.hexagongrid", "las laz e57 pts pcd"),
        FileFamily("photogrammetry", .model3d, (0.48, 0.44, 0.76), "camera.viewfinder", "rcproj psx psz mg 3dk"),
        FileFamily("unreal", .model3d, (0.20, 0.22, 0.27), "gamecontroller", "uasset umap uproject uplugin"),
        FileFamily("unity", .model3d, (0.44, 0.47, 0.53), "cube.box",
                   "unity prefab anim controller overridecontroller physicmaterial meta"),
        FileFamily("godot", .model3d, (0.29, 0.53, 0.74), "puzzlepiece", "tscn tres godot"),
        FileFamily("materials", .model3d, (0.66, 0.46, 0.26), "drop.halffull", "mtlx osl mdl"),
        FileFamily("hdri", .image, (0.92, 0.66, 0.14), "sun.max", "hdr exr hdri"),
        FileFamily("lut", .design, (0.80, 0.35, 0.70), "camera.filters", "cube 3dl look csp cdl ccc lut"),

        // MARK: 3D-печать, ЧПУ, CAD, электроника
        FileFamily("print3d", .cad, (0.18, 0.62, 0.78), "printer",
                   "stl 3mf gcode bgcode ufp ctb photon pwmx sl1 lys chitubox"),
        FileFamily("cnc", .cad, (0.40, 0.42, 0.46), "gearshape.2", "ngc tap cnc mpf"),
        FileFamily("autocad", .cad, (0.80, 0.16, 0.20), "compass.drawing", "dwg dxf dwt dws dwf dwfx"),
        FileFamily("solidworks", .cad, (0.86, 0.32, 0.18), "wrench.adjustable", "sldprt sldasm slddrw slddrt"),
        FileFamily("inventor", .cad, (0.86, 0.56, 0.10), "wrench.and.screwdriver", "ipt iam idw ipn"),
        FileFamily("catia", .cad, (0.20, 0.40, 0.66), "screwdriver", "catpart catproduct catdrawing cgr prt neu"),
        FileFamily("fusion360", .cad, (0.94, 0.54, 0.16), "skew", "f3d f3z"),
        FileFamily("opencad", .cad, (0.26, 0.46, 0.76), "pencil.and.ruler", "fcstd fcstd1 scad fcmacro"),
        FileFamily("rhino", .cad, (0.46, 0.46, 0.52), "perspective", "3dm gh ghx"),
        FileFamily("sketchup", .cad, (0.12, 0.55, 0.85), "house", "skp skb skm"),
        FileFamily("bim", .cad, (0.16, 0.42, 0.70), "building.2", "rvt rfa rte rft ifc ifczip ifcxml"),
        FileFamily("architecture", .cad, (0.30, 0.56, 0.50), "building", "pln pla vwx dgn"),
        FileFamily("cadexchange", .cad, (0.46, 0.50, 0.60), "arrow.left.arrow.right",
                   "step stp stpz p21 iges igs x_t x_b sat sab jt brep"),
        FileFamily("pcb", .cad, (0.10, 0.55, 0.30), "memorychip",
                   "kicad_pcb kicad_sch kicad_pro kicad_mod kicad_sym brd sch lbr pcbdoc schdoc prjpcb pcblib schlib dsn"),
        FileFamily("gerber", .cad, (0.72, 0.55, 0.15), "square.3.layers.3d", "gbr gerber gbl gtl gto gts gbo gbs gko drl xln"),
        FileFamily("circuit", .cad, (0.90, 0.64, 0.10), "bolt", "cir spice sp fzz fzpz qucs"),
        FileFamily("arduino", .code, (0.00, 0.56, 0.60), "powerplug", "ino pde"),

        // MARK: Видео
        FileFamily("aftereffects", .video, (0.56, 0.36, 0.88), "sparkles", "aep aepx aet ffx mogrt"),
        FileFamily("premiere", .video, (0.40, 0.26, 0.78), "timeline.selection", "prproj prel ptl plb"),
        FileFamily("finalcut", .video, (0.34, 0.34, 0.44), "film", "fcpxml fcpxmld fcpbundle fcpevent"),
        FileFamily("resolve", .video, (0.20, 0.50, 0.86), "slider.horizontal.3", "drp drt dra drb"),
        FileFamily("vegas", .video, (0.22, 0.56, 0.36), "film.stack", "veg vf"),
        FileFamily("avid", .video, (0.50, 0.32, 0.80), "scissors", "avb avp"),
        FileFamily("interchange", .video, (0.46, 0.52, 0.62), "list.and.film", "aaf omf edl ale xmeml otio"),
        FileFamily("motion", .video, (0.70, 0.36, 0.86), "wand.and.stars", "motn moti moef motr"),
        FileFamily("nuke", .video, (0.90, 0.74, 0.16), "square.2.layers.3d", "nk nknc gizmo"),
        FileFamily("screenrecording", .video, (0.20, 0.62, 0.42), "record.circle", "tscproj trec cmproj camrec"),
        FileFamily("openeditors", .video, (0.30, 0.56, 0.72), "movieclapper", "kdenlive mlt osp olive"),
        FileFamily("cinemaraw", .video, (0.76, 0.20, 0.26), "video", "r3d braw ari crm cine"),
        FileFamily("discvideo", .video, (0.56, 0.30, 0.56), "tv", "vob ifo bup bdmv mpls clpi m2ts"),
        FileFamily("actioncam", .video, (0.25, 0.55, 0.86), "camera.rotate", "insv insp lrv thm 360"),
        FileFamily("streaming", .video, (0.40, 0.60, 0.80), "antenna.radiowaves.left.and.right", "mpd ism ismc f4m"),
        FileFamily("animation", .video, (0.95, 0.45, 0.35), "hare", "tbp xstage moho mohoproj spine riv lottie"),

        // MARK: Звук
        FileFamily("ableton", .audio, (0.22, 0.23, 0.26), "slider.vertical.3", "als alp adg adv agr ams alc"),
        FileFamily("flstudio", .audio, (0.94, 0.56, 0.16), "pianokeys.inverse", "flp fst"),
        FileFamily("cubase", .audio, (0.76, 0.20, 0.27), "dial.max", "cpr npr"),
        FileFamily("protools", .audio, (0.36, 0.36, 0.72), "waveform.path", "ptx ptf"),
        FileFamily("reaper", .audio, (0.30, 0.56, 0.36), "metronome", "rpp rpp-bak rpl"),
        FileFamily("studioone", .audio, (0.20, 0.46, 0.76), "music.mic", "song"),
        FileFamily("reason", .audio, (0.46, 0.46, 0.50), "hifireceiver", "reason rns rsn"),
        FileFamily("bitwig", .audio, (0.85, 0.38, 0.12), "dial.min", "bwproject bwpreset bwclip"),
        FileFamily("audioeditor", .audio, (0.24, 0.64, 0.56), "waveform.and.magnifyingglass", "sesx aup aup3 ardour"),
        FileFamily("notation", .audio, (0.40, 0.36, 0.72), "music.quarternote.3", "sib mscz mscx musx mus musicxml mxl ly"),
        FileFamily("guitar", .audio, (0.80, 0.46, 0.20), "guitars", "gp gp3 gp4 gp5 gp7 ptb tg"),
        FileFamily("midi", .audio, (0.86, 0.30, 0.56), "pianokeys", "mid midi kar rmi smf"),
        FileFamily("instruments", .audio, (0.60, 0.40, 0.80), "tuningfork", "nki nkm nkc nkx ncw exs sfz sf2 sf3 sfark"),
        FileFamily("presets", .audio, (0.50, 0.56, 0.64), "dial.low", "fxp fxb vstpreset aupreset h2p tfx nmsv"),
        FileFamily("lossless", .audio, (0.80, 0.22, 0.42), "hifispeaker", "flac alac ape wv tta dsf dff"),
        FileFamily("tracker", .audio, (0.30, 0.64, 0.46), "rectangle.grid.3x2", "mod xm s3m it mtm umx 669 med"),
        FileFamily("audiobook", .audio, (0.90, 0.56, 0.20), "headphones", "m4b aa aax"),
        FileFamily("ringtone", .audio, (0.86, 0.36, 0.36), "bell", "m4r"),
        FileFamily("voice", .audio, (0.45, 0.55, 0.65), "mic", "amr 3ga awb"),

        // MARK: Графика
        FileFamily("photoshop", .image, (0.20, 0.56, 0.92), "photo.on.rectangle", "psd psb pdd"),
        FileFamily("brushes", .design, (0.86, 0.46, 0.30), "pencil.tip", "abr brush brushset"),
        FileFamily("swatches", .design, (0.66, 0.36, 0.76), "swatchpalette", "aco ase act swatches clr gpl"),
        FileFamily("imageactions", .design, (0.36, 0.56, 0.86), "wand.and.rays", "atn asl pat grd"),
        FileFamily("illustrator", .design, (0.95, 0.60, 0.10), "pencil.and.outline", "ai ait"),
        FileFamily("layout", .document, (0.86, 0.22, 0.46), "newspaper", "indd indt idml inx indb qxd qxp afpub"),
        FileFamily("uidesign", .design, (0.60, 0.36, 0.90), "rectangle.and.pencil.and.ellipsis", "fig sketch xd penpot"),
        FileFamily("affinity", .design, (0.30, 0.36, 0.80), "lasso", "afdesign afphoto"),
        FileFamily("procreate", .image, (0.26, 0.26, 0.32), "hand.draw", "procreate"),
        FileFamily("paintapps", .image, (0.40, 0.66, 0.86), "paintpalette", "kra ora xcf pdn"),
        FileFamily("corel", .design, (0.22, 0.66, 0.36), "pencil.and.scribble", "cdr cmx cdt"),
        FileFamily("diagrams", .design, (0.30, 0.56, 0.76), "rectangle.3.offgrid",
                   "drawio dio excalidraw vsd vsdx vss vst graffle puml"),
        FileFamily("cameraraw", .image, (0.20, 0.56, 0.40), "camera",
                   "cr2 cr3 crw nef nrw arw srf sr2 dng orf rw2 raf pef srw x3f 3fr erf kdc mos mrw iiq rwl"),
        FileFamily("photocatalog", .image, (0.26, 0.46, 0.70), "photo.stack", "lrcat lrdata xmp cocatalog lrtemplate"),
        FileFamily("icons", .image, (0.42, 0.60, 0.95), "app", "ico icns cur ani"),

        // MARK: Документы
        FileFamily("word", .document, (0.17, 0.38, 0.72), "text.alignleft", "doc docx docm dot dotx dotm"),
        FileFamily("pages", .document, (0.95, 0.58, 0.16), "doc.text", "pages"),
        FileFamily("opendoctext", .document, (0.20, 0.55, 0.75), "text.justify.left", "odt ott fodt sxw"),
        FileFamily("excel", .spreadsheet, (0.12, 0.50, 0.30), "tablecells", "xls xlsx xlsm xlsb xlt xltx xltm"),
        FileFamily("numbers", .spreadsheet, (0.20, 0.70, 0.30), "chart.pie", "numbers"),
        FileFamily("opendoccalc", .spreadsheet, (0.10, 0.60, 0.50), "rectangle.split.3x3", "ods ots fods"),
        FileFamily("powerpoint", .presentation, (0.82, 0.30, 0.18), "chart.bar", "ppt pptx pptm pps ppsx ppsm potx potm"),
        FileFamily("keynote", .presentation, (0.15, 0.50, 0.90), "play.rectangle", "key"),
        FileFamily("opendocimpress", .presentation, (0.85, 0.45, 0.10), "rectangle.on.rectangle", "odp otp fodp sxi"),

        // MARK: Архивы
        FileFamily("rar", .archive, (0.56, 0.30, 0.66), "archivebox", "rar"),
        FileFamily("7z", .archive, (0.24, 0.30, 0.36), "archivebox", "7z"),
        FileFamily("tarball", .archive, (0.60, 0.42, 0.24), "archivebox",
                   "tar gz gzip tgz bz2 bzip2 tbz tbz2 xz txz lz lzma tlz zst zstd tzst lz4 lzo z"),
        FileFamily("volumeparts", .archive, (0.66, 0.56, 0.36), "square.stack", "001 r00 z01"),

        // MARK: Языки программирования
        FileFamily("swift", .code, (0.96, 0.38, 0.20), codeSymbol, "swift"),
        FileFamily("python", .code, (0.21, 0.40, 0.58), codeSymbol, "py pyw pyi pyx pxi"),
        FileFamily("javascript", .code, (0.86, 0.70, 0.08), codeSymbol, "js mjs cjs jsx"),
        FileFamily("typescript", .code, (0.18, 0.47, 0.78), codeSymbol, "ts tsx cts"),
        FileFamily("rust", .code, (0.62, 0.36, 0.22), codeSymbol, "rs"),
        FileFamily("go", .code, (0.00, 0.66, 0.84), codeSymbol, "go"),
        FileFamily("java", .code, (0.70, 0.22, 0.20), codeSymbol, "java"),
        FileFamily("kotlin", .code, (0.50, 0.36, 0.90), codeSymbol, "kt kts"),
        FileFamily("c", .code, (0.35, 0.45, 0.70), codeSymbol, "c h"),
        FileFamily("cpp", .code, (0.00, 0.35, 0.60), codeSymbol, "cpp cc cxx c++ hpp hh hxx inl ipp"),
        FileFamily("csharp", .code, (0.40, 0.20, 0.55), codeSymbol, "cs csx"),
        FileFamily("ruby", .code, (0.80, 0.15, 0.20), codeSymbol, "rb"),
        FileFamily("php", .code, (0.47, 0.48, 0.70), codeSymbol, "php phtml"),
        FileFamily("objc", .code, (0.30, 0.55, 0.85), codeSymbol, "m mm"),
        FileFamily("shaders", .code, (0.85, 0.50, 0.85), "sparkle",
                   "glsl vert frag geom tesc tese comp hlsl fx metal wgsl shader cginc gdshader"),
        FileFamily("notebook", .code, (0.95, 0.50, 0.15), "book.pages", "ipynb"),
    ]

    static let familyByExtension: [String: FileFamily] = {
        var out: [String: FileFamily] = [:]
        for family in families {
            for ext in family.extensions { out[ext] = family }
        }
        return out
    }()
}
