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
    if [ -f "$src" ]; then cp "$src" "$LIC/LICENSE-$name.txt"; else echo "    WARNING: no licence text for $name"; fi
done
cat > "$LIC/NOTICE.txt" <<EOF
Totum Commander $VERSION — GNU GPL v3 (LICENSE-Totum-Commander.txt).
Bundled: rclone (MIT), Ghostscript (AGPL v3), DjVuLibre (GPL v2+), ntfs-3g (GPL v2+),
libarchive (BSD), minizip-ng (zlib), libssh2 (BSD), OpenSSL (Apache 2.0), zstd, lz4, xz,
libjpeg-turbo, libb2. Source of the program: https://github.com/Toys-D/TotumCommander
EOF

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
