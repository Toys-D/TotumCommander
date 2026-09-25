#!/usr/bin/env python3
"""Индекс поиска по настройкам: какие подписи (ключи строк) живут в каком разделе.

Берёт все L("ключ") из файлов разделов, отбрасывает подсказки, кнопки и тексты диалогов,
запоминает ближайший заголовок группы. Результат — SettingsSearchIndex.swift. Запускать
после добавления настройки; тест SettingsSearchTests падает, если индекс отстал.
"""
import re, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SECTIONS = ROOT / "app/TotumComXL/Views/Settings/Sections"
OUT = ROOT / "app/TotumComXL/Views/Settings/SettingsSearchIndex.swift"
FILES = [("general", "SettingsGeneralView"), ("keys", "SettingsKeysView"),
         ("terminal", "SettingsTerminalView"), ("list", "SettingsListView"),
         ("colors", "SettingsColorsView"), ("fileColors", "SettingsFileColorsView"),
         ("cursor", "SettingsCursorView"), ("folders", "SettingsFoldersView"),
         ("font", "SettingsFontView"), ("tabs", "SettingsTabsView"),
         ("divider", "SettingsDividerView"), ("contextMenu", "SettingsContextMenuView"),
         ("networkNTFS", "SettingsNetworkNTFSView"), ("about", "SettingsAboutView")]
# Та же строка, что SettingsSearch.excludedKeyPattern — тест сверяет оба.
EXCLUDED = re.compile(r"(?i)(hint|message|restart|failed|placeholder|browse|\.now$|\.later$|^unit\.|^button\.|^common\.|^dialog|\.title$|\.ok$|\.cancel$|\.remove$|\.add$|\.delete$|\.reset|\.help$|\.verdict|\.summary|\.stage\.|\.error\.|\.obstacle\.|\.page$|\.install$|\.link$|\.example|\.none$|\.tooltip$)")
GROUP = re.compile(r"\.section\.")

def extract(src):
    rows, group, seen = [], None, set()
    for key in re.findall(r'\bL\("([^"]+)"', src):
        if GROUP.search(key):
            group = key
            continue
        # Ключ, собираемый на лету (`L("x.\($0)")`), в индекс не попадает: подписи вариантов.
        if key in seen or "\\(" in key or EXCLUDED.search(key):
            continue
        seen.add(key)
        rows.append((key, group))
    return rows

lines = ["// Сгенерировано scripts/gen_settings_index.py — не править руками.",
         "// Подписи настроек по разделам для поиска; группа — ближайший заголовок в файле.",
         "",
         "enum SettingsSearchIndex {",
         "    static let entries: [SettingsSection: [(key: String, group: String?)]] = ["]
for case, name in FILES:
    rows = extract((SECTIONS / f"{name}.swift").read_text(encoding="utf-8"))
    lines.append(f"        .{case}: [")
    for key, group in rows:
        g = f'"{group}"' if group else "nil"
        lines.append(f'            ("{key}", {g}),')
    lines.append("        ],")
lines += ["    ]", "}", ""]
OUT.write_text("\n".join(lines), encoding="utf-8")
print(f"{OUT.name}: {sum(len(extract((SECTIONS / f'{n}.swift').read_text(encoding='utf-8'))) for _, n in FILES)} подписей")
