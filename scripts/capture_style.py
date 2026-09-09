#!/usr/bin/env python3
"""Снять текущее оформление автора в набор по умолчанию — DefaultStyle.plist.

Берёт настройки com.fcxl.filecommander, выбрасывает личное (пути, вкладки, окна,
подключения…) и системный мусор (NS*, com_apple_*), остальное кладёт ПОВЕРХ прежнего
набора: ключ, которого у автора нет, остаётся с прежним значением. Список личного —
тот же, что DefaultStyle.personalPrefixes в программе: вторая линия обороны там,
первая здесь. Маски курсора (DefaultCursorMask*.png) скрипт не трогает — их подменяют
руками, если менялись.

    python3 scripts/capture_style.py            # снять и записать
    python3 scripts/capture_style.py --dry-run  # только показать отличия
"""
import pathlib
import plistlib
import subprocess
import sys

PERSONAL = [
    "leftPanelPath", "rightPanelPath", "panelTabs_", "fcxl.remoteConnections",
    "fcxl.appLanguage", "appLanguage", "fcxl.updates.", "fcxl.windowLaunch",
    "fcxl.windowWasFullScreen", "showHiddenFiles", "fcxl.customCursorMaskPreviewRevision",
    "fcxl.bookmarks", "fcxl.workspaces", "NSWindow Frame",
    "fcxl.folderRules", "fcxl.fileAssociations", "fcxl.externalEditor",
    "fcxl.controlServerEnabled", "fcxl.recentNetworkDrives", "fcxl.networkHostsCache",
    "fcxl.vault.", "wifiPhones", "fKeyMode", "fcxl.settingsLastSection",
    "fcxl.selectionMaskRecent", "fcxl.quickLookPanelFrame", "fcxl.dropStack",
    "fcxl.uninstallAskClaude", "monitor.", "fcxl.multiRename.presets", "fcxl.searchExclude",
    "tunnel.", "fcxl.gallery", "mainWindow.",
]
SYSTEM = ["NS", "AV", "Apple", "WebKit", "com_apple_", "com.apple."]


def is_personal(key: str) -> bool:
    return key.endswith("Migrated") or any(key.startswith(p) for p in PERSONAL)


def is_system(key: str) -> bool:
    return any(key.startswith(p) for p in SYSTEM)


def short(value) -> str:
    text = repr(value)
    return text if len(text) <= 48 else text[:45] + "…"


def main() -> int:
    dry = "--dry-run" in sys.argv
    root = pathlib.Path(__file__).resolve().parent.parent
    plist_path = root / "app/TotumComXL/Resources/DefaultStyle.plist"
    raw = subprocess.run(["defaults", "export", "com.fcxl.filecommander", "-"],
                         capture_output=True, check=True).stdout
    current = plistlib.loads(raw)
    shipped = plistlib.load(open(plist_path, "rb"))

    merged = dict(shipped)
    changed, added = [], []
    for key, value in current.items():
        if is_personal(key) or is_system(key):
            continue
        if key not in shipped:
            added.append(key)
        elif shipped[key] != value:
            changed.append(key)
        merged[key] = value
    kept = [k for k in shipped if k not in current]

    for key in changed:
        print(f"  ~ {key}: {short(shipped[key])} -> {short(current[key])}")
    for key in added:
        print(f"  + {key}: {short(current[key])}")
    for key in kept:
        print(f"  = {key}: {short(shipped[key])} (у автора не задан, остаётся)")
    print(f"ключей: {len(merged)}; изменено {len(changed)}, добавлено {len(added)}, "
          f"оставлено {len(kept)}")
    if dry:
        return 0
    with open(plist_path, "wb") as out:
        plistlib.dump(merged, out, sort_keys=True)
    print(f"записано: {plist_path.relative_to(root)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
