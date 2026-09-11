#!/bin/bash
set -e
cd "$(dirname "$0")/.."

# The user-facing app bundle. The DISPLAY name is "Totum Commander"; the INTERNAL executable is
# still "TotumComXL" and the SwiftPM product "TotumComXLApp" — invisible codenames, kept so the
# build, the resource bundle name (<package>_<target>.bundle) and pkill by process name all keep
# working. Bundle identifier is also unchanged (see below).
APP="Totum Commander.app"
# debug for the everyday run; release.sh sets FCXL_CONFIG=release and FCXL_NO_LAUNCH=1.
CONFIG="${FCXL_CONFIG:-debug}"
APP_VERSION="1.1"
# One-time migration from the previous bundle name, so the skeleton (icon, entitlements) carries over.
[ -d "$APP" ] || { [ -d "TotumComXL.app" ] && mv "TotumComXL.app" "$APP"; } || true
# A fresh clone has no bundle yet: lay down the skeleton the steps below fill in.
if [ ! -f "$APP/Contents/Info.plist" ]; then
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TotumComXL</string>
    <key>CFBundleIdentifier</key><string>com.fcxl.filecommander</string>
    <key>CFBundleName</key><string>Totum Commander</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
fi

# Номер сборки поднимается ЗДЕСЬ, а не руками.
#
# Правило «увеличить APP_BUILD перед запуском» выполнялось заменой конкретного числа на
# следующее — и стоило номеру разойтись (слияние веток, откат), как замена переставала
# находить своё число и молча ничего не делала: sed возвращает 0 и в этом случае. Программа
# собиралась и запускалась со старым номером, а в отчётах стоял новый — расхождение,
# которое видно только по заголовку окна.
BUILD_FILE="app/TotumComXL/App/TotumComXLApp.swift"
NEW_BUILD=$(python3 - "$BUILD_FILE" <<'PYBUMP'
import io, re, sys
path = sys.argv[1]
text = io.open(path, encoding="utf-8").read()
match = re.search(r"let APP_BUILD: Int = (\d+)", text)
if not match:
    sys.exit("APP_BUILD не найден в " + path)
number = int(match.group(1)) + 1
io.open(path, "w", encoding="utf-8").write(
    text[:match.start(1)] + str(number) + text[match.end(1):])
print(number)
PYBUMP
)
echo "=== Build number $NEW_BUILD ==="

echo "=== Building ($CONFIG) ==="
swift build -c "$CONFIG"

# Папка со собранным — у самого SwiftPM, а не строкой в скрипте. Было вписано имя папки для
# Apple Silicon: на Intel-Mac она называется иначе, и сборка на таком копировала бы ничего —
# из того же семейства, что и личный сертификат ниже.
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "=== Updating bundle ==="
cp "$BIN/TotumComXLApp" "$APP/Contents/MacOS/TotumComXL"
# Copy resource bundle (includes HTML, localization files).
# MUST remove the old copy first: `cp -R src dst` with an EXISTING dst directory
# copies src INTO dst (nested bundle-in-bundle) and never refreshes dst's own
# files — the app's resource copy had been stale since April because of this.
rm -rf "$APP/Contents/Resources/TotumComXL_TotumComXLApp.bundle"
cp -R "$BIN/TotumComXL_TotumComXLApp.bundle" "$APP/Contents/Resources/TotumComXL_TotumComXLApp.bundle"
# Ensure Local Network permission keys exist (macOS 14/15 silently block
# Bonjour/NWBrowser without these — the app would see no network hosts).
# Idempotent: delete-then-add so re-runs don't fail. MUST run before codesign
# so the signature covers the updated Info.plist.
# App icon. Kept in the repo as a rendered .icns so a fresh clone builds a bundle that already
# looks right; scripts/make-icon.sh regenerates it from the SVG.
if [ -f design/icon/AppIcon.icns ]; then
    cp design/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
PLIST="$APP/Contents/Info.plist"
# Naming: display name is "Totum Commander"; binary/CFBundleExecutable stay "TotumComXL". Only
# CFBundleIdentifier (com.fcxl.filecommander) is kept unchanged on purpose, so saved
# settings, remote bookmarks and Keychain items keep working — the OS still sees the
# same app. CFBundleExecutable must match the renamed binary or the app won't launch.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable TotumComXL" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string TotumComXL" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName 'Totum Commander'" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string 'Totum Commander'" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'Totum Commander'" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'Totum Commander'" "$PLIST"

# Version and the floor: the code needs macOS 15, and a lower number here let the app crash on
# an older system instead of being refused politely.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $NEW_BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 15.0" "$PLIST"

# Localizations the OS should know about. Without them the bundle counted as English-only,
# and every SYSTEM menu — PDFKit's context menu, a text field's Cut/Copy/Paste — came up in
# English on a Russian Mac, whatever language the app's own strings spoke. Mixed
# localizations let the frameworks follow the system language even where the app has none.
/usr/libexec/PlistBuddy -c "Set :CFBundleDevelopmentRegion en" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :CFBundleLocalizations" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:0 string en" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:1 string ru" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleAllowMixedLocalizations true" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleAllowMixedLocalizations bool true" "$PLIST"
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/ru.lproj"

/usr/libexec/PlistBuddy -c "Delete :FCXLGitBranch" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :NSLocalNetworkUsageDescription" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string 'Totum Commander ищет компьютеры в локальной сети для подключения к общим папкам.'" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :NSBonjourServices" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSBonjourServices array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSBonjourServices:0 string _smb._tcp" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSBonjourServices:1 string _afpovertcp._tcp" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSBonjourServices:2 string _sftp-ssh._tcp" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSBonjourServices:3 string _ftp._tcp" "$PLIST"

# Bundle every non-system dylib INTO the .app so it runs on a Mac WITHOUT Homebrew.
# Without this the binary hard-references /opt/homebrew/... (mupdf, libssh2 + ~26
# transitive deps) and dyld aborts the app at launch on any clean machine — it only
# ever worked here because this is a dev box. dylibbundler copies the whole dependency
# tree into Contents/Frameworks and rewrites the load commands to @executable_path.
# MUST run BEFORE codesign: it rewrites the binary and would invalidate a prior signature.
# The MCP bridge, shipped inside the bundle so registering it with Claude is one path and
# nothing to install. It only talks to the commander's control socket, which stays off until
# the user turns it on in Settings.
echo "=== Embedding MCP bridge ==="
swift build -c "$CONFIG" --product FCXLMCPServer
mkdir -p "$APP/Contents/Helpers"
cp "$BIN/FCXLMCPServer" "$APP/Contents/Helpers/fcxl-mcp"
chmod +x "$APP/Contents/Helpers/fcxl-mcp"

# rclone — им работают облака: Google Drive, Dropbox, OneDrive и ещё десятки. Едет внутри
# бандла, чтобы человек НИЧЕГО не ставил руками и не открывал Терминал: он выбирает службу
# в нашем окне, разрешает доступ в браузере — и всё. Лицензия MIT, текст рядом.
echo "=== Embedding rclone ==="
"$(dirname "$0")/fetch-rclone.sh"
cp third_party/rclone/rclone "$APP/Contents/Helpers/rclone"
chmod +x "$APP/Contents/Helpers/rclone"
cp third_party/rclone/LICENSE-rclone.txt "$APP/Contents/Resources/LICENSE-rclone.txt"

# Standalone DjVu reader, shipped INSIDE our bundle so the commander can launch it as a
# separate program and the user still installs nothing. macOS has no DjVu support at all.
echo "=== Embedding DjVu viewer ==="
swift build -c "$CONFIG" --product FCXLDjVuViewer
VIEWER_APP="$APP/Contents/Library/FCXL DjVu Viewer.app"
mkdir -p "$VIEWER_APP/Contents/MacOS"
cp "$BIN/FCXLDjVuViewer" "$VIEWER_APP/Contents/MacOS/FCXLDjVuViewer"
cat > "$VIEWER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FCXLDjVuViewer</string>
    <key>CFBundleIdentifier</key><string>com.fcxl.djvuviewer</string>
    <key>CFBundleName</key><string>FCXL DjVu Viewer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>DjVu Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key><array><string>com.lizardtech.djvu</string></array>
            <key>CFBundleTypeExtensions</key><array><string>djvu</string><string>djv</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ghostscript, shipped INSIDE the bundle so EPS/PS preview works with nothing installed.
# macOS dropped its own PostScript rasteriser in 10.15, so there is no system fallback.
# We ship the BINARY (not the library) and run it as a child process: PostScript is a full
# programming language, so a malformed file can loop forever — a child can be killed on a
# timeout, an in-process interpreter could not. Resource/ carries the init files and the
# base-35 fonts; without it the interpreter refuses to start.
echo "=== Embedding Ghostscript ==="
GS_BIN="$(command -v gs || true)"
if [ -n "$GS_BIN" ]; then
    GS_PREFIX="$(cd "$(dirname "$GS_BIN")/.." && pwd)"
    GS_DEST="$APP/Contents/Library/Ghostscript"
    GS_RES_SRC="$(/bin/ls -d "$GS_PREFIX"/share/ghostscript/*/Resource 2>/dev/null | head -1)"
    [ -d "$GS_RES_SRC" ] || GS_RES_SRC="$GS_PREFIX/share/ghostscript/Resource"
    if [ -d "$GS_RES_SRC" ]; then
        rm -rf "$GS_DEST"
        mkdir -p "$GS_DEST/bin" "$GS_DEST/share/ghostscript"
        cp "$GS_BIN" "$GS_DEST/bin/gs"
        cp -R "$GS_RES_SRC" "$GS_DEST/share/ghostscript/Resource"
        # Цветовые профили. Замер на нашей отрисовке (png16m) разницы не дал: CMYK выходит
        # побайтово одинаково с ними и без них. Но лежат они 256 КБ, а файлу, который
        # ССЫЛАЕТСЯ на профиль, без них рисовать нечем — кладём, раз есть.
        GS_ICC_SRC="$(/bin/ls -d "$GS_PREFIX"/share/ghostscript/*/iccprofiles 2>/dev/null | head -1)"
        [ -d "$GS_ICC_SRC" ] || GS_ICC_SRC="$GS_PREFIX/share/ghostscript/iccprofiles"
        if [ -d "$GS_ICC_SRC" ]; then
            cp -R "$GS_ICC_SRC" "$GS_DEST/share/ghostscript/iccprofiles"
        else
            echo "    (no iccprofiles beside Ghostscript — a colour-managed EPS falls back)"
        fi
        dylibbundler -od -b \
            -x "$GS_DEST/bin/gs" \
            -d "$GS_DEST/lib" \
            -p @executable_path/../lib
        echo "    Ghostscript embedded ($(du -sh "$GS_DEST" | cut -f1))"
    else
        echo "    WARNING: Ghostscript Resource dir not found — EPS preview will not work"
    fi
else
    echo "    WARNING: gs not installed (brew install ghostscript) — EPS preview will not work"
fi

echo "=== Bundling libraries ==="
dylibbundler -od -b \
    -x "$APP/Contents/MacOS/TotumComXL" \
    -d "$APP/Contents/Frameworks" \
    -p @executable_path/../Frameworks

# The embedded viewer gets its OWN Frameworks folder. Sharing the commander's would save a
# few MB but cannot work: @executable_path resolves against whichever executable is running,
# so one shared libdjvulibre cannot reference its neighbours correctly for two executables
# at different bundle depths — pointing it at the viewer (4 levels up) made the commander
# look outside the bundle and abort at launch with "Library not loaded".
dylibbundler -od -b \
    -x "$VIEWER_APP/Contents/MacOS/FCXLDjVuViewer" \
    -d "$VIEWER_APP/Contents/Frameworks" \
    -p @executable_path/../Frameworks

# Signing. A STABLE identity is a convenience for the developer: macOS then remembers the
# permissions and firewall rules it granted, instead of asking again after every build.
#
# It used to be one unconditional line with the author's own certificate — under `set -e`.
# That certificate exists in no other keychain, so on any other Mac the build died exactly
# here, and release.sh (which runs this script) died with it: nobody but the author could
# build the program from this repository at all. Now the identity is CHOSEN: the one asked
# for, the author's if this machine really has it, ad hoc otherwise — and a refusal of the
# stable identity falls back instead of ending the build.
SIGN_ID="${FCXL_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    PREFERRED="Apple Development: toysappleid@gmail.com (3P8J62VT66)"
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$PREFERRED"; then
        SIGN_ID="$PREFERRED"
    else
        SIGN_ID="-"
    fi
fi
if ! codesign --force --deep --sign "$SIGN_ID" "$APP"; then
    echo "    signing with '$SIGN_ID' failed — falling back to ad hoc"
    codesign --force --deep --sign - "$APP"
fi

if [ -n "${FCXL_NO_LAUNCH:-}" ]; then
    echo "=== Built, not launched ==="
    exit 0
fi
echo "=== Launching ==="
# --fresh: the program as a NEW USER sees it. A second bundle with its own bundle identifier
# and therefore its own, always-empty settings: the developer's tabs, paths and colours stay
# untouched, both copies can stand side by side, and "first launch" can be looked at any time.
if [ "${1:-}" = "--fresh" ]; then
    FRESH="Totum Commander (новый).app"
    echo "=== Fresh copy: $FRESH ==="
    rsync -a --delete "$APP/" "$FRESH/"
    FP="$FRESH/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.fcxl.filecommander.fresh" "$FP"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName 'Totum Commander (новый)'" "$FP"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'Totum Commander (новый)'" "$FP"
    codesign --force --deep --sign - "$FRESH" 2>/dev/null
    # Every launch is a first launch.
    defaults delete com.fcxl.filecommander.fresh 2>/dev/null || true
    # Скобки в имени — это ГРУППА для регулярного выражения pkill, а не сами скобки: старая
    # копия не убивалась, `open` просто выводил её вперёд, и «новый пользователь» смотрел на
    # позавчерашнюю сборку. Экранируем.
    pkill -f "Totum Commander \\(новый\\)\\.app/Contents/MacOS/TotumComXL" 2>/dev/null || true
    sleep 0.3
    open "$FRESH"
    echo "=== Done (fresh) ==="
    exit 0
fi
# Kill all running app instances (both installed bundle and .build app wrapper)
# By path, not by name: the fresh copy (--fresh) shares the executable name and must live on.
pkill -f "$APP/Contents/MacOS/TotumComXL" 2>/dev/null || true
pkill -f "TotumComXLApp.app/Contents/MacOS/TotumComXL" 2>/dev/null || true
sleep 0.3
# Brought to the front, so it has keyboard focus and is usable at once. This does NOT drag the
# user to another desktop any more: the main window carries .moveToActiveSpace, so activating
# brings the window to whichever desktop is in front instead of switching to the window.
# --background launches without taking focus at all.
if [ "${1:-}" = "--background" ]; then
    open -g "$APP"
else
    open "$APP"
fi
echo "=== Done ==="
