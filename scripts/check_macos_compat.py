#!/usr/bin/env python3
"""Запустится ли собранная программа на macOS 15 (Sequoia) и всех следующих.

Две беды, которых не видно на машине сборки:

1. Повторный путь поиска библиотек (LC_RPATH). macOS 27 отказывается запускать такую
   программу ещё до первой строки — «duplicate LC_RPATH»; прежние системы это терпели, и
   выпуски 1.8.7 и раньше на macOS 27 не открывались вовсе.
2. Системная функция, которой нет в Sequoia. Пометку «собрано для macOS N» загрузчик не
   проверяет (проверено на macOS 27: программа и библиотека с пометкой 28.0 загружаются),
   зато падает на первой сильной ссылке на функцию, которой в системе нет. Так бывает, когда
   Homebrew на новой системе ставит библиотеки, собранные под неё, и они едут в выпуск.

Каждая сильная ссылка каждой части программы сверяется со списками функций в SDK macOS 15
(самом старом из найденных) и с тем, что дают библиотеки внутри самой программы. Слабые
ссылки — то, что код зовёт под проверкой версии, — пропускаются: на старой системе они
просто пусты.

    python3 scripts/check_macos_compat.py "Totum Commander.app"

SDK ищется в Command Line Tools (MacOSX15*.sdk); свой путь — FCXL_MACOS15_SDK.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
CLT_BIN = Path("/Library/Developer/CommandLineTools/usr/bin")


def tool(name):
    """Инструмент Xcode, а если Xcode недоступен (лицензия не принята) — Command Line Tools."""
    found = subprocess.run(["xcrun", "--find", name], capture_output=True, text=True)
    if found.returncode == 0 and found.stdout.strip():
        return found.stdout.strip()
    if (CLT_BIN / name).exists():
        return str(CLT_BIN / name)
    sys.exit(f"нет инструмента {name}: ни Xcode, ни Command Line Tools")


OTOOL, NM = tool("otool"), tool("nm")


def run(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def sequoia_sdk():
    if os.environ.get("FCXL_MACOS15_SDK"):
        return Path(os.environ["FCXL_MACOS15_SDK"])
    found = []
    for sdk in Path("/Library/Developer/CommandLineTools/SDKs").glob("MacOSX15*.sdk"):
        if sdk.is_symlink():
            continue
        m = re.match(r"MacOSX15(?:\.(\d+))?\.sdk", sdk.name)
        if m:
            found.append((int(m.group(1) or 0), sdk))
    return min(found)[1] if found else None


def macho_files(app):
    for root, _, files in os.walk(app):
        for name in files:
            path = Path(root) / name
            if path.is_symlink() or not path.is_file():
                continue
            try:
                with open(path, "rb") as f:
                    if f.read(4) in MAGICS:
                        yield path
            except OSError:
                pass


def load_commands(path):
    """Пути поиска, минимальная система и зависимости (путь, слабая ли)."""
    text = run(OTOOL, "-l", str(path))
    rpaths, deps, minos = [], [], None
    lines = text.splitlines()
    for i, line in enumerate(lines):
        cmd = line.strip()
        if cmd == "cmd LC_RPATH":
            for follow in lines[i + 1:i + 4]:
                if follow.strip().startswith("path "):
                    rpaths.append(follow.strip()[5:].rsplit(" (offset", 1)[0])
                    break
        elif cmd in ("cmd LC_LOAD_DYLIB", "cmd LC_LOAD_WEAK_DYLIB", "cmd LC_REEXPORT_DYLIB",
                     "cmd LC_LAZY_LOAD_DYLIB", "cmd LC_LOAD_UPWARD_DYLIB"):
            for follow in lines[i + 1:i + 4]:
                if follow.strip().startswith("name "):
                    deps.append((follow.strip()[5:].rsplit(" (offset", 1)[0], cmd == "cmd LC_LOAD_WEAK_DYLIB"))
                    break
        elif cmd == "cmd LC_BUILD_VERSION" and minos is None:
            for follow in lines[i + 1:i + 6]:
                if follow.strip().startswith("minos "):
                    minos = follow.strip().split()[1]
                    break
    return rpaths, deps, minos


class SDKSymbols:
    """Функции системных библиотек по спискам SDK (.tbd), с тем, что они передают дальше."""

    LIST = re.compile(r"(symbols|weak-symbols|thread-local-symbols|objc-classes|objc-eh-types|objc-ivars)"
                      r":\s*\[(.*?)\]", re.S)
    REEXPORTS = re.compile(r"reexported-libraries:(.*?)(?:\n\S|\Z)", re.S)

    def __init__(self, sdk):
        self.sdk = sdk
        self.cache = {}

    def tbd_path(self, install_name):
        base = re.sub(r"\.dylib$", "", install_name)
        return self.sdk / (base.lstrip("/") + ".tbd")

    def symbols(self, install_name, seen=None):
        """Набор функций библиотеки или None — её нет в этой системе вовсе."""
        if install_name in self.cache:
            return self.cache[install_name]
        seen = seen or set()
        if install_name in seen:
            return set()
        seen.add(install_name)
        path = self.tbd_path(install_name)
        if not path.exists():
            self.cache[install_name] = None
            return None
        text = path.read_text(errors="ignore")
        result = set()
        for kind, body in self.LIST.findall(text):
            for item in re.split(r"[,\s]+", body):
                item = item.strip().strip("'\"")
                if not item:
                    continue
                if kind == "objc-classes":
                    result.add("_OBJC_CLASS_$_" + item)
                    result.add("_OBJC_METACLASS_$_" + item)
                elif kind == "objc-eh-types":
                    result.add("_OBJC_EHTYPE_$_" + item)
                elif kind == "objc-ivars":
                    result.add("_OBJC_IVAR_$_" + item)
                else:
                    result.add(item)
        for block in self.REEXPORTS.findall(text):
            for lib in re.findall(r"'([^']+)'|(/[^\s,\]]+)", block):
                name = lib[0] or lib[1]
                if name.startswith("/"):
                    result |= self.symbols(name, seen) or set()
        self.cache[install_name] = result
        return result


def resolve_bundled(dep, binary, rpaths, app):
    """Файл внутри программы, на который указывает зависимость, или None — системная."""
    exe_dir = binary.parent
    candidates = []
    if dep.startswith("@executable_path/") or dep.startswith("@loader_path/"):
        rest = dep.split("/", 1)[1]
        candidates.append(exe_dir / rest)
    elif dep.startswith("@rpath/"):
        rest = dep[len("@rpath/"):]
        for rp in rpaths:
            base = rp.replace("@executable_path", str(exe_dir)).replace("@loader_path", str(exe_dir))
            candidates.append(Path(base) / rest)
    for c in candidates:
        c = Path(os.path.normpath(c))
        if c.exists() and str(c).startswith(str(app)):
            return c
    return None


def exported(path, cache={}):
    if path not in cache:
        cache[path] = set(line.split()[-1] for line in run(NM, "-gU", str(path)).splitlines() if line.strip())
    return cache[path]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    app = Path(sys.argv[1]).resolve()
    sdk = sequoia_sdk()
    if sdk is None or not sdk.exists():
        sys.exit("Нет SDK macOS 15 — не с чем сверить. Поставьте Command Line Tools с ним "
                 "или укажите путь в FCXL_MACOS15_SDK.")
    symbols = SDKSymbols(sdk)
    problems, checked = [], 0
    for binary in sorted(macho_files(app)):
        rel = binary.relative_to(app)
        rpaths, deps, minos = load_commands(binary)
        repeated = sorted({p for p in rpaths if rpaths.count(p) > 1})
        for p in repeated:
            problems.append(f"{rel}: путь поиска {p} записан {rpaths.count(p)} раза — macOS 27 не запустит")
        own_id = run(OTOOL, "-D", str(binary)).splitlines()[1:]
        available, missing_libs = set(), []
        for dep, weak in deps:
            if dep in own_id:
                continue
            bundled = resolve_bundled(dep, binary, rpaths, app)
            if bundled is not None:
                available |= exported(bundled)
                continue
            if dep.startswith("@"):
                problems.append(f"{rel}: зависимость {dep} не найдена внутри программы")
                continue
            lib = symbols.symbols(dep)
            if lib is None:
                if not weak:
                    missing_libs.append(dep)
                continue
            available |= lib
        for dep in missing_libs:
            problems.append(f"{rel}: библиотеки {dep} нет в macOS 15")
        missing = []
        for line in run(NM, "-m", "-u", str(binary)).splitlines():
            if "weak external" in line or "(dynamically looked up)" in line:
                continue
            parts = line.split()
            name = next((p for p in parts if p.startswith("_")), None)
            if name and name not in available:
                missing.append(name)
        if missing:
            shown = ", ".join(missing[:8]) + (f" и ещё {len(missing) - 8}" if len(missing) > 8 else "")
            problems.append(f"{rel}: нет в macOS 15 ({len(missing)}): {shown}")
        checked += 1
    if problems:
        print(f"Не запустится на macOS 15 и новее (сверено с {sdk.name}):")
        for p in problems:
            print("   ", p)
        sys.exit(1)
    print(f"    {checked} частей программы: путей поиска без повторов, все системные функции есть в {sdk.name}")


if __name__ == "__main__":
    main()
