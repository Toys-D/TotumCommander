import AppKit
import UniformTypeIdentifiers

// MARK: - Вид файла — для своих значков

/// Вид файла: цвет листа и знак посередине своего значка (стиль Totum).
enum FileKind: String, CaseIterable {
    // Первые — те, что были с самого начала.
    case image, video, audio, archive, diskImage, pdf, document, spreadsheet, presentation
    case book, code, text, font, other
    // Разработка.
    case markup, web, data, config, script, executable, binary, package, database, build, git
    // Безопасность.
    case security, encrypted, checksum
    // Графика и модели.
    case design, model3d, cad
    // Медиа рядом с видео и звуком.
    case subtitle, playlist
    // Связь и ссылки.
    case mail, contact, calendar, link, download
    // Прочее.
    case log, backup, game, map, virtualMachine, translation, readme, license

    /// Вид по ключу значка (`FileTypeCatalog.typeKey`): расширение или узнанное имя.
    static func of(_ fileExtension: String) -> FileKind {
        let key = FileIcons.normalized(fileExtension)
        guard !key.isEmpty else { return .other }
        if let named = FileTypeCatalog.named(key) { return named.kind }
        return FileTypeCatalog.kind(forExtension: key)
    }
}

// MARK: - Каталог

/// Что за файл — по расширению, а у файлов без расширения — по имени, месту и праву на запуск.
///
/// Система знает не всё: docx и epub для неё zip-архивы, djvu и fb2 она не знает вовсе, а у
/// HEAD из .git, Makefile и id_rsa расширения нет совсем. Каталог узнаёт их сам; чего нет в
/// нём, о том спрашивается UTType.
///
/// Ключ значка — расширение (`pdf`) или узнанное имя (`=make`): один значок на ключ, его и
/// запоминает FileIcons.
enum FileTypeCatalog {

    /// Узнанное имя: вид и подпись на полосе.
    struct Named: Equatable {
        let kind: FileKind
        let label: String
    }

    static let namedPrefix = "="

    // MARK: Ключ

    /// Ключ значка файла. `permissions` — права восьмеричным числом, как в FileItem («755»);
    /// по ним файл без расширения с правом на запуск — программа.
    static func typeKey(name: String, fileExtension: String, path: String = "", permissions: String = "") -> String {
        let ext = FileIcons.normalized(fileExtension)
        if let id = namedID(name: name, ext: ext, path: path, permissions: permissions) {
            return namedPrefix + id
        }
        return ext
    }

    /// Узнанное имя по ключу (`=make` или `make`); nil — у ключа нет имени, это расширение.
    static func named(_ key: String) -> Named? {
        guard key.hasPrefix(namedPrefix) else { return nil }
        return ids[String(key.dropFirst(namedPrefix.count))]
    }

    /// Облик своего значка: цвет листа и знаки посередине — семейства, потом вида.
    struct Face {
        let color: NSColor
        let symbols: [String]
    }

    static func face(forKey key: String) -> Face {
        let normalized = FileIcons.normalized(key)
        let kind = FileKind.of(normalized)
        let kindSymbols = kind.symbol.map { [$0] } ?? []
        if named(normalized) == nil, let family = familyByExtension[normalized] {
            return Face(color: family.color, symbols: [family.symbol] + kindSymbols)
        }
        return Face(color: kind.color, symbols: kindSymbols)
    }

    static func kind(forExtension ext: String) -> FileKind {
        familyByExtension[ext]?.kind ?? byExtension[ext] ?? FileKind.systemKind(ofExtension: ext)
    }

    private static func namedID(name: String, ext: String, path: String, permissions: String) -> String? {
        // Копии и временные — по виду имени, какое бы ни было расширение.
        if name.hasSuffix("~") || (name.count > 2 && name.hasPrefix("#") && name.hasSuffix("#")) { return "bak" }
        if name.hasPrefix("~$") || name.hasPrefix(".~lock.") { return "tmp" }

        let lower = name.lowercased()
        let executable = isExecutable(permissions)
        if let entry = exactNames[name] ?? lowerNames[lower] {
            // /usr/bin/passwd — программа, /etc/passwd — настройки системы.
            if entry.yieldsToExecutable, executable, ext.isEmpty { return "exec" }
            return entry.id
        }
        if lower.hasPrefix(".env.") { return "env" }
        // README.md, LICENSE.txt, SHA256SUMS.txt — по имени, а не по расширению текста.
        if textExtensions.contains(ext) {
            let base = String(lower.dropLast(ext.count + 1))
            if let entry = lowerNames[base], entry.keepsTextExtension { return entry.id }
        }

        // Внутри .git — всё его: index, description, refs/heads/main, пакеты объектов.
        if path.contains("/.git/") {
            if ext == "sample", path.contains("/.git/hooks/") { return "hook" }
            if ext.isEmpty || gitObjectExtensions.contains(ext) { return "git" }
        }
        if ext.isEmpty, executable { return "exec" }
        return nil
    }

    /// Право на запуск у кого-нибудь: владельца, группы или всех.
    static func isExecutable(_ permissions: String) -> Bool {
        guard let mode = Int(permissions, radix: 8) else { return false }
        return mode & 0o111 != 0
    }

    private static let textExtensions: Set<String> = ["md", "markdown", "txt", "text", "rst", "adoc", "org"]
    private static let gitObjectExtensions: Set<String> = ["pack", "idx", "rev", "keep", "promisor", "bitmap", "midx"]

    // MARK: Имена

    /// Что подписать у узнанного имени.
    private static let ids: [String: Named] = [
        "git": Named(kind: .git, label: "GIT"), "hook": Named(kind: .script, label: "HOOK"),
        "ignore": Named(kind: .config, label: "IGN"),
        "conf": Named(kind: .config, label: "CONF"), "env": Named(kind: .config, label: "ENV"),
        "sys": Named(kind: .config, label: "SYS"), "ds": Named(kind: .config, label: "DS"),
        "vim": Named(kind: .config, label: "VIM"),
        "make": Named(kind: .build, label: "MAKE"), "dock": Named(kind: .build, label: "DOCK"),
        "cmake": Named(kind: .build, label: "CMAKE"), "npm": Named(kind: .build, label: "NPM"),
        "lock": Named(kind: .build, label: "LOCK"), "cargo": Named(kind: .build, label: "CARGO"),
        "pip": Named(kind: .build, label: "PIP"), "py": Named(kind: .build, label: "PY"),
        "gomod": Named(kind: .build, label: "GOMOD"), "gosum": Named(kind: .build, label: "GOSUM"),
        "spm": Named(kind: .build, label: "SPM"), "gem": Named(kind: .build, label: "GEM"),
        "pod": Named(kind: .build, label: "POD"), "brew": Named(kind: .build, label: "BREW"),
        "rake": Named(kind: .build, label: "RAKE"), "proc": Named(kind: .build, label: "PROC"),
        "vagr": Named(kind: .build, label: "VAGR"), "jenk": Named(kind: .build, label: "JENK"),
        "bazel": Named(kind: .build, label: "BAZEL"), "just": Named(kind: .build, label: "JUST"),
        "fast": Named(kind: .build, label: "FAST"), "build": Named(kind: .build, label: "BUILD"),
        "read": Named(kind: .readme, label: "READ"), "info": Named(kind: .readme, label: "INFO"),
        "lic": Named(kind: .license, label: "LIC"), "sums": Named(kind: .checksum, label: "SUM"),
        "ssh": Named(kind: .security, label: "SSH"), "keyfile": Named(kind: .security, label: "KEY"),
        "sh": Named(kind: .script, label: "SH"), "bash": Named(kind: .script, label: "BASH"),
        "zsh": Named(kind: .script, label: "ZSH"), "csh": Named(kind: .script, label: "CSH"),
        "ksh": Named(kind: .script, label: "KSH"),
        "hist": Named(kind: .log, label: "HIST"), "log": Named(kind: .log, label: "LOG"),
        "exec": Named(kind: .executable, label: "EXEC"),
        "bak": Named(kind: .backup, label: "BAK"), "tmp": Named(kind: .backup, label: "TMP"),
        "mail": Named(kind: .mail, label: "MAIL"), "icon": Named(kind: .image, label: "ICON"),
    ]

    private struct NameEntry {
        let id: String
        /// Тот же файл с расширением текста — тоже он: README.md, LICENSE.txt.
        var keepsTextExtension = false
        /// Такое же имя бывает у программы: /usr/bin/passwd — программа, /etc/passwd — нет.
        var yieldsToExecutable = false
    }

    /// Имена с точным написанием: `HEAD` — git, а `head` в /usr/bin — программа.
    private static let exactNames: [String: NameEntry] = entries([
        "git": "HEAD ORIG_HEAD FETCH_HEAD MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD AUTO_MERGE "
            + "BISECT_LOG COMMIT_EDITMSG MERGE_MSG MERGE_MODE SQUASH_MSG TAG_EDITMSG",
        "info": "INSTALL NEWS",
        "bazel": "BUILD WORKSPACE",
    ])

    /// Имена без учёта регистра.
    private static let lowerNames: [String: NameEntry] = {
        var all = entries([
            "git": ".gitignore .gitattributes .gitmodules .gitkeep .gitconfig .git .mailmap .gitmessage "
                + "packed-refs codeowners .git-blame-ignore-revs",
            "ignore": ".dockerignore .npmignore .eslintignore .prettierignore .slugignore .vscodeignore "
                + ".hgignore .cvsignore .stylelintignore .gcloudignore .helmignore",
            "conf": "config .editorconfig .npmrc .yarnrc .nvmrc .node-version .python-version .ruby-version "
                + ".tool-versions .swift-version .xcode-version .prettierrc .eslintrc .babelrc .stylelintrc "
                + ".browserslistrc .clang-format .clang-tidy .flake8 .pylintrc .rspec .gemrc .irbrc .pryrc "
                + ".htaccess .wgetrc .curlrc .screenrc .nanorc .inputrc .hushlogin .cfusertextencoding "
                + ".localized .condarc .pypirc .terraformrc .swiftformat .jshintrc .mocharc .nycrc "
                + ".watchmanconfig .flowconfig .gitpod caddyfile .ackrc .agignore .rgignore .lldbinit .gdbinit",
            "ds": ".ds_store",
            "env": ".env .envrc",
            "vim": ".vimrc .gvimrc .exrc .ideavimrc",
            "make": "makefile gnumakefile bsdmakefile",
            "dock": "dockerfile containerfile docker-compose.yml docker-compose.yaml compose.yml compose.yaml",
            "cmake": "cmakelists.txt",
            "npm": "package.json",
            "lock": "package-lock.json npm-shrinkwrap.json package.resolved",
            "cargo": "cargo.toml",
            "pip": "requirements.txt pipfile",
            "py": "pyproject.toml setup.cfg",
            "gomod": "go.mod", "gosum": "go.sum",
            "spm": "package.swift",
            "gem": "gemfile", "pod": "podfile", "brew": "brewfile", "rake": "rakefile", "proc": "procfile",
            "vagr": "vagrantfile", "jenk": "jenkinsfile", "just": "justfile",
            "fast": "fastfile appfile matchfile pluginfile deliverfile snapfile gymfile scanfile",
            "build": "guardfile capfile berksfile earthfile snakefile tiltfile cartfile pkgbuild apkbuild "
                + "meson.build sconstruct sconscript",
            "ssh": "id_rsa id_dsa id_ecdsa id_ed25519 id_ecdsa_sk id_ed25519_sk known_hosts authorized_keys "
                + "authorized_keys2",
            "keyfile": ".netrc .pgpass .htpasswd .git-credentials",
            "sh": ".profile .shrc profile",
            "bash": ".bashrc .bash_profile .bash_login .bash_logout .bash_aliases bashrc",
            "zsh": ".zshrc .zshenv .zprofile .zlogin .zlogout zshrc zprofile zshenv",
            "csh": ".cshrc .tcshrc .login .logout csh.cshrc csh.login",
            "ksh": ".kshrc",
            "hist": ".bash_history .zsh_history .sh_history .python_history .node_repl_history .psql_history "
                + ".mysql_history .sqlite_history .lesshst .viminfo .irb_history .rediscli_history .wget-hsts "
                + ".scala_history .lldb_history",
            "log": "nohup.out",
            "mail": "winmail.dat",
            "icon": "icon\r",
        ])
        for (names, id) in [("readme read.me", "read"),
                            ("changelog changes history authors contributors contributing todo thanks credits "
                                + "maintainers security code_of_conduct news", "info"),
                            ("license licence copying copyright notice unlicense patents", "lic"),
                            ("sha256sums sha1sums sha512sums sha384sums sha224sums md5sums b2sums checksums",
                             "sums")] {
            for name in names.split(separator: " ") {
                all[String(name)] = NameEntry(id: id, keepsTextExtension: true)
            }
        }
        let system = "hosts fstab crontab passwd group shadow sudoers services protocols networks shells exports "
            + "auto_master auto_home syslog.conf newsyslog.conf"
        for name in system.split(separator: " ") {
            all[String(name)] = NameEntry(id: "sys", yieldsToExecutable: true)
        }
        return all
    }()

    private static func entries(_ table: [String: String]) -> [String: NameEntry] {
        var out: [String: NameEntry] = [:]
        for (id, names) in table {
            for name in names.split(separator: " ") { out[String(name)] = NameEntry(id: id) }
        }
        return out
    }

    // MARK: Расширения

    /// Расширения по видам. Здесь — всё, что система числит не тем или не знает; прочее
    /// узнаётся у UTType. Одно расширение — один вид: двойники ловит тест.
    static let extensionsByKind: [FileKind: String] = [
        .image: "jpg jpeg jpe jfif png apng gif bmp dib tif tiff webp heic heif heics avif jxl jp2 j2k jpf jpx "
            + "tga dds pcx clip pxd pxm qoi pbm pgm "
            + "ppm pnm xbm xpm wbmp",
        .video: "mp4 m4v mov qt avi mkv webm wmv flv f4v mpg mpeg mpe m2v mts ogv 3gp 3g2 rm rmvb asf "
            + "divx xvid mxf dv hevc h264 h265 264 265 y4m swf ivf nut m1v mjpeg mjpg wtv dvr-ms tod",
        .audio: "mp3 m4a m4p aac wav wave aiff aif aifc ogg oga opus wma mka "
            + "caf ac3 eac3 dts spx au snd ra weba gsm voc mpc "
            + "rx2 mp2 mpa",
        .archive: "zip zipx "
            + "cab arj lzh lha ace sit sitx cpio shar ar pax xar br sz zpaq arc alz egg uue xxe b64 "
            + "cpgz pkz",
        .diskImage: "dmg iso img sparseimage sparsebundle toast nrg mds udf dsk hfs hfsx "
            + "dmgpart",
        .pdf: "pdf",
        .document: "rtf rtfd wpd wps abw lwp hwp hwpx wri "
            + "xps oxps ps gdoc",
        .spreadsheet: "csv tsv dif slk sylk gnumeric "
            + "gsheet wk1 wks et",
        .presentation: "gslides dps",
        .book: "djvu djv epub fb2 fb3 fbz mobi azw azw3 azw4 kf8 kfx cbz cbr cb7 cbt cba ibooks lit prc lrf tcr "
            + "pdg chm",
        .code: "scala sc groovy gvy "
            + "pl pm t pod6 raku lua r jl dart "
            + "coffee litcoffee ls elm ex erl hrl hs lhs ml mli fs fsi fsx clj cljs cljc edn lisp lsp el "
            + "scm ss rkt nim zig v vala d cr hx asm s nasm wat sol vy move ada adb ads pas pp dpr dpk "
            + "f f90 f95 f03 f08 for ftn cob cbl vb bas tcl awk "
            + "cu cuh vhdl verilog sv svh idr agda lean purs re rei res resi "
            + "gd gdscript hack hhi rc def odin mojo gleam roc carbon prisma xib storyboard "
            + "jsonnet libsonnet bicep q kql",
        .text: "txt text ascii utf8 ans",
        .font: "ttf otf ttc otc woff woff2 eot pfb pfm afm dfont fon fnt bdf pcf suit sfd glyphs vfb",
        .markup: "md markdown mdown mkd mkdn mdwn mdx rmd qmd rst adoc asciidoc org textile tex latex ltx "
            + "sty cls bib bst bbl typ wiki mediawiki creole rdoc dtx ins texi texinfo man",
        .web: "html htm xhtml shtml mhtml mht css scss sass less styl stylus vue svelte astro jsp jspx asp aspx "
            + "ascx cshtml vbhtml razor hbs handlebars mustache ejs pug jade twig liquid njk nunjucks erb haml "
            + "slim webmanifest htc",
        .data: "json jsonc json5 jsonl ndjson xml xsd xsl xslt dtd graphql gql proto thrift avsc bson cbor "
            + "msgpack rdf ttl owl n3 nt nq jsonld xaml xmi gexf graphml yang csl ris enl",
        .config: "ini cfg conf config cnf toml yaml yml env properties prefs plist xcconfig entitlements "
            + "mobileconfig reg inf service socket timer mount automount target hcl tf tfvars nix "
            + "pac xcsettings xcworkspacedata editorconfig dhall kdl ron cson "
            + "rules",
        .script: "sh bash zsh fish ksh csh tcsh dash command tool ps1 psm1 psd1 bat cmd btm vbs vbe wsf wsh "
            + "applescript scpt jxa ahk au3 shortcut nu xonsh elv",
        .executable: "exe com scr cpl xbe xex gadget",
        .binary: "dll so dylib a lib o ko sys drv efi bin elf out class pyc pyo pyd wasm node "
            + "beam dex odex oat vdex rlib nib car dat axf prx hex",
        .package: "pkg mpkg deb rpm apk apks aab xapk ipa msi msix msixbundle appx appxbundle appimage snap "
            + "flatpak flatpakref xpi crx vsix whl gem nupkg jar war ear aar jmod run unitypackage "
            + "mpack spk opk ipk tazpkg xbps pet",
        .database: "sqlite sqlite3 db db3 sdb s3db sqlitedb sql mdb accdb frm myd myi ibd dbf ndf mdf ldf "
            + "realm fdb gdb odb parquet feather arrow avro orc h5 hdf5 hdf he5 nc mat npy npz rdata rda rds "
            + "dta sas7bdat lmdb db-wal db-shm sqlite-wal sqlite-shm sqlite-journal db-journal "
            + "kexi fp7 fmp12 dbs",
        .build: "mk mak make cmake gradle sbt ninja bzl bazel podspec gemspec cabal csproj vbproj fsproj vcxproj "
            + "vcproj sln xcscheme pbxproj props targets nuspec lock lockb resolved nsi nsh gyp gypi pro pri qbs "
            + "dockerfile containerfile jenkinsfile justfile ebuild bb bbappend xcfilelist",
        .git: "patch diff rej gitignore gitattributes",
        .security: "pem crt cer der csr p12 pfx p7b p7c p7s p8 pk8 jks keystore bks asc sig pub ppk kdbx kdb "
            + "keychain keychain-db mobileprovision provisionprofile cert crl spc ovpn pkcs12 jwk "
            + "ca-bundle kbx",
        .encrypted: "gpg pgp aes enc age axx cpt crypt hc vault encrypted locked",
        .checksum: "md5 sha1 sha224 sha256 sha384 sha512 sha3 sfv sum crc crc32 md5sum sha1sum sha256sum "
            + "sha512sum b2 blake2 blake3 xxh par2 par",
        .design: "svg svgz eps "
            + "emf wmf fla psdc odg otg sda sxd epsf",
        .subtitle: "srt vtt webvtt ass ssa sub sbv ttml dfxp smi sami lrc usf idx sup scc",
        .playlist: "m3u m3u8 pls xspf wpl asx cue zpl b4s kpl",
        .mail: "eml emlx msg mbox mbx mbs oft pst ost tnef",
        .contact: "vcf vcard ldif",
        .calendar: "ics ical ifb vcs icalendar",
        .link: "webloc url inetloc fileloc lnk desktop website afploc ftploc mailloc",
        .download: "torrent crdownload part partial download opdownload aria2 !ut bc! nzb metalink meta4",
        .log: "log logs trace crash ips diag spin hang panic dmp mdmp hprof err stderr stdout etl evtx evt "
            + "pcap pcapng har history",
        .backup: "bak backup old orig tmp temp swp swo swn bk bkp autosave asv wbk xlk",
        .game: "nes sfc smc gb gbc gba n64 z64 v64 nds xci nsp gcm wbfs rvz wad pak rom sav chd gen smd sms gg "
            + "a26 a78 lnx ngp pce pck love mcworld mcpack mcaddon mca nbt cia pbp cso",
        .map: "gpx kml kmz geojson topojson shp shx osm mbtiles gpkg tcx igc qgs qgz loc",
        .virtualMachine: "vmdk vdi vhd vhdx qcow qcow2 qed ova ovf pvm vmx vmxf vmsd vmsn vmss vmem vbox "
            + "vbox-prev hdd hds box",
        .translation: "po pot mo strings stringsdict xliff xlf xcstrings resx resw arb tmx qm",
        .readme: "nfo diz 1st me",
        .license: "lic",
    ]

    /// Расширение → вид; собирается один раз.
    static let byExtension: [String: FileKind] = {
        var out: [String: FileKind] = [:]
        for (kind, list) in extensionsByKind {
            for ext in list.split(separator: " ") { out[String(ext)] = kind }
        }
        return out
    }()
}


extension FileKind {
    /// Чего нет в каталоге — у системы: она знает форматы картинок, звука и видео, которые
    /// появятся позже, чем этот список.
    static func systemKind(ofExtension ext: String) -> FileKind {
        guard let type = UTType(filenameExtension: ext), !type.isDynamic else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .presentation) { return .presentation }
        if type.conforms(to: .font) { return .font }
        if type.conforms(to: .html) { return .web }
        if type.conforms(to: .json) || type.conforms(to: .xml) { return .data }
        if type.conforms(to: .shellScript) { return .script }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .text) { return .text }
        return .other
    }
}
