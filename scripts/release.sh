#!/bin/bash
# Release build of Totum Commander: the same bundle launch.sh assembles, built with
# optimisation, cleaned of what only the developer needs, signed ad hoc, and put into a DMG
# with an Applications shortcut. Everything lands in dist/.
#
# No Apple Developer ID: the app is signed ad hoc, so the first launch on another Mac needs
# a right-click ▸ Open (or Privacy & Security ▸ Open Anyway on macOS 15). Said in README.
set -e
cd "$(dirname "$0")/.."

APP="Totum Commander.app"
DIST="dist"
STAGE="$DIST/stage"

echo "=== Release build ==="
FCXL_CONFIG=release FCXL_NO_LAUNCH=1 ./scripts/launch.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$DIST/Totum-Commander-$VERSION.dmg"

echo "=== Staging $VERSION (build $BUILD) ==="
rm -rf "$DIST"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$APP"
OUT="$STAGE/$APP"

# What only the developer needs.
find "$OUT" -name '.DS_Store' -delete
rm -f "$OUT/Contents/Resources/TotumComXL_TotumComXLApp.bundle/cloud-icons-source.txt"

# Licences of everything shipped inside — the GPL parts (Ghostscript, DjVuLibre, ntfs-3g)
# make the app GPL, and every recipient is owed the terms and the source (README says where).
LIC="$OUT/Contents/Resources/Licenses"
mkdir -p "$LIC"
cp LICENSE "$LIC/LICENSE-Totum-Commander.txt"
cp third_party/minizip-ng/LICENSE "$LIC/LICENSE-minizip-ng.txt" 2>/dev/null || true
mv "$OUT/Contents/Resources/LICENSE-rclone.txt" "$LIC/LICENSE-rclone.txt" 2>/dev/null || true
for pair in ghostscript:LICENSE djvulibre:COPYING libarchive:COPYING libssh2:COPYING \
            openssl@3:LICENSE.txt zstd:COPYING lz4:LICENSE xz:COPYING jpeg-turbo:LICENSE.md libb2:COPYING; do
    name="${pair%%:*}"; file="${pair##*:}"
    src="/opt/homebrew/opt/$name/$file"
    if [ -f "$src" ]; then
        cp "$src" "$LIC/LICENSE-$name.txt"
    else
        # Раньше здесь было предупреждение, и выпуск шёл дальше. Внутри лежат Ghostscript
        # (AGPL v3), DjVuLibre и ntfs-3g (GPL v2+): отдать их без текста лицензии нельзя,
        # а предупреждение в потоке сборки никто не читает.
        echo "    NO LICENCE TEXT for $name ($src)"; MISSING_LIC=1
    fi
done
[ "${MISSING_LIC:-0}" = 0 ] || { echo "Bundled GPL parts without their licence text — not shipping"; exit 1; }
cat > "$LIC/NOTICE.txt" <<EOF
Totum Commander $VERSION — GNU GPL v3 (LICENSE-Totum-Commander.txt).
Bundled: rclone (MIT), Ghostscript (AGPL v3), DjVuLibre (GPL v2+), ntfs-3g (GPL v2+),
libarchive (BSD), minizip-ng (zlib), libssh2 (BSD), OpenSSL (Apache 2.0), zstd, lz4, xz,
libjpeg-turbo, libb2. Source of the program: https://github.com/Toys-D/TotumCommander
EOF

# Ghostscript встраивается только если он есть на машине сборки (launch.sh), а его нет —
# значит у всех получателей мёртвый просмотр EPS и PostScript. Раньше об этом говорило
# предупреждение посреди сборки, и выпуск шёл дальше.
echo "=== Checking Ghostscript is embedded ==="
if [ ! -x "$OUT/Contents/Library/Ghostscript/bin/gs" ]; then
    echo "No Ghostscript inside the bundle — EPS and PostScript preview would be dead"
    echo "Install it first: brew install ghostscript"
    exit 1
fi

echo "=== Checking for paths that exist only on this Mac ==="
BAD=0
while IFS= read -r -d '' bin; do
    if file "$bin" | grep -q 'Mach-O'; then
        if otool -L "$bin" 2>/dev/null | grep -q '/opt/homebrew\|/usr/local'; then
            echo "    $bin links a Homebrew library"; BAD=1
        fi
    fi
done < <(find "$OUT" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)
[ "$BAD" = 0 ] || { echo "Homebrew paths inside the bundle — it would not run elsewhere"; exit 1; }

# The crash that taught this: SwiftPM writes Bundle.module out of exactly two paths — the
# bundle NEXT TO the .app and an ABSOLUTE path inside the build directory of the machine that
# compiled it. Neither is where a macOS app keeps its resources, so on the author's Mac the
# build directory quietly saved every launch, and on the first other Mac the app died in its
# very first line — no window, just "quit unexpectedly". The app now looks in
# Contents/Resources itself (see AppResources) and this asks it, before the DMG exists.
echo "=== Checking the app finds its own resources ==="
if ! "$OUT/Contents/MacOS/TotumComXL" --fcxl-resource-check; then
    echo "The app cannot see its resources inside itself — it would not start on another Mac"
    exit 1
fi

echo "=== Signing ad hoc ==="
codesign --force --deep --sign - "$OUT"
codesign --verify --deep --strict "$OUT"

echo "=== DMG ==="
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Totum Commander" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)

echo "=== Done ==="
du -sh "$DMG" | cut -f1 | xargs -I{} echo "    $DMG ({})"
cat "$DIST/SHA256SUMS.txt"
