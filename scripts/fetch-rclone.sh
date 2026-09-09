#!/bin/bash
# Достать rclone — чужую программу, через которую работают облака.
#
# Она кладётся ВНУТРЬ нашей программы, чтобы человек ничего не ставил руками: Google Drive
# он подключает из нашего окна, а не из Терминала. Лицензия rclone — MIT, встраивать можно.
#
# В хранилище исходников бинарник не кладём: семьдесят мегабайт на каждое обновление
# раздули бы историю. Вместо этого он скачивается сюда один раз и лежит в third_party,
# которая не отслеживается.
#
# Выпуск и контрольная сумма прибиты гвоздями. Скачивать «последнюю версию» значит однажды
# собрать программу с тем, чего никто не проверял, а сверка суммы — единственное, что
# отличает официальный выпуск от подсунутого по дороге.
set -euo pipefail

VERSION="v1.75.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/rclone"
BINARY="$DEST/rclone"

case "$(uname -m)" in
    arm64)  ARCH="arm64";  SUM="35e8f2a666ce789b29111db0dd843ddabc0d59c6b609d07bcaae5d1a07cba6f8" ;;
    x86_64) ARCH="amd64";  SUM="19edbb8e5e73096eb66e92a42abbc5c34bfa8981ea3986a53872c7eef85a22f4" ;;
    *) echo "Неизвестная архитектура: $(uname -m)" >&2; exit 1 ;;
esac

NAME="rclone-$VERSION-osx-$ARCH"
URL="https://github.com/rclone/rclone/releases/download/$VERSION/$NAME.zip"

# Уже лежит и той же версии — ничего не делаем: сборка не должна ходить в сеть каждый раз.
if [ -x "$BINARY" ] && "$BINARY" version 2>/dev/null | head -1 | grep -q "$VERSION"; then
    echo "rclone $VERSION уже на месте"
    exit 0
fi

mkdir -p "$DEST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Скачиваю rclone $VERSION ($ARCH)…"
curl -sSL --fail -o "$WORK/rclone.zip" "$URL"

echo "Сверяю контрольную сумму…"
GOT="$(shasum -a 256 "$WORK/rclone.zip" | awk '{print $1}')"
if [ "$GOT" != "$SUM" ]; then
    echo "Контрольная сумма не сошлась." >&2
    echo "  ожидалась: $SUM" >&2
    echo "  получена:  $GOT" >&2
    exit 1
fi

unzip -q -o "$WORK/rclone.zip" -d "$WORK"
mv "$WORK/$NAME/rclone" "$BINARY"
chmod +x "$BINARY"
# Заодно лицензия: MIT требует, чтобы её текст ехал вместе с программой. В архиве
# выпуска её нет, поэтому берём из самого хранилища исходников, с той же метки.
curl -sSL --fail -o "$DEST/LICENSE-rclone.txt" \
    "https://raw.githubusercontent.com/rclone/rclone/$VERSION/COPYING"

echo "Готово: $BINARY"
"$BINARY" version | head -1
