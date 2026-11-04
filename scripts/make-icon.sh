#!/bin/bash
# Собирает AppIcon.icns из одного SVG и ставит его в бандл.
#
#   scripts/make-icon.sh Logo/totum-icon-template-1024.svg
#
# Отрисовка идёт через make-iconset.swift (AppKit умеет SVG сам), а НЕ через qlmanage:
# тот подкладывает под превью белый фон, и прозрачная иконка получалась в белом квадрате.
# Каждый размер рисуется прямо из вектора, поэтому мелкие не мылятся уменьшением.
set -e
cd "$(dirname "$0")/.."

SVG="${1:-$(cat design/icon/SOURCE 2>/dev/null)}"
[ -n "$SVG" ] && [ -f "$SVG" ] || {
    echo "Нет файла: ${SVG:-<не задан>}"
    echo "Использование: scripts/make-icon.sh path/to/icon.svg"
    exit 1
}

OUT="design/icon/build"
rm -rf "$OUT"
mkdir -p "$OUT"

# Второй файл — для 16 и 32 pt. Там надпись всё равно нечитаема, поэтому используется знак
# без неё и во весь квадрат. Нет файла — все размеры берутся из основного, как раньше.
SMALL="Logo/totum-icon-mark.svg"
if [ -f "$SMALL" ]; then
    swift scripts/make-iconset.swift "$SVG" "$OUT/AppIcon.iconset" "$SMALL"
else
    swift scripts/make-iconset.swift "$SVG" "$OUT/AppIcon.iconset"
fi
iconutil -c icns "$OUT/AppIcon.iconset" -o design/icon/AppIcon.icns

# Запоминаем, из чего собрана текущая иконка — рядом с ней, чтобы через месяц не гадать.
# Сам SVG не копируем: он уже лежит в репозитории, а вторая копия неминуемо разошлась бы с первой.
echo "$SVG" > design/icon/SOURCE

APP="Totum Commander.app"
if [ -d "$APP" ]; then
    cp design/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    touch "$APP"
    echo "Иконка установлена: $APP"
fi
echo "Готово: design/icon/AppIcon.icns из $SVG"
