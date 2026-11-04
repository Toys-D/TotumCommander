#!/bin/bash
# Собрать маленький ffmpeg — переводчик звука, которого macOS не знает.
#
# Системный проигрыватель (AVPlayer) не играет WMA, APE, RealAudio и DTS. Просмотрщик отдаёт
# такой файл этому ffmpeg, тот переводит его во FLAC (без потерь, macOS его играет), и дальше
# всё как с MP3. Собирается ТОЛЬКО звук: нужные разборщики и декодеры, кодировщик FLAC и
# преобразование выборок — пара мегабайт вместо сорока у полного ffmpeg. Лицензия LGPL 2.1
# (сборка без --enable-gpl), с нашей GPL-3 совместима; её текст едет вместе с программой.
#
# В хранилище исходников бинарник не кладём, как и rclone: он собирается сюда один раз и лежит
# в third_party, которая не отслеживается. Версия и контрольная сумма архива прибиты гвоздями;
# сумма та же, что у Homebrew для этого выпуска (gpg для проверки подписи на машине нет).
#
#     scripts/fetch-ffmpeg.sh                         # скачать, сверить, собрать
#     FFMPEG_TARBALL=путь/к/архиву scripts/fetch-ffmpeg.sh   # архив уже скачан
set -euo pipefail

VERSION="9.0.2"
SUM="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/ffmpeg"
BINARY="$DEST/ffmpeg"
URL="https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"

# Уже собран той же версии — ничего не делаем: сборка не должна ходить в сеть каждый раз.
if [ -x "$BINARY" ] && "$BINARY" -hide_banner -version 2>/dev/null | head -1 | grep -q "version $VERSION"; then
    echo "ffmpeg $VERSION уже на месте"
    exit 0
fi

mkdir -p "$DEST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TARBALL="${FFMPEG_TARBALL:-$WORK/ffmpeg.tar.xz}"
if [ -z "${FFMPEG_TARBALL:-}" ]; then
    echo "Скачиваю ffmpeg $VERSION…"
    curl -sSL --fail -o "$TARBALL" "$URL"
fi

echo "Сверяю контрольную сумму…"
GOT="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$GOT" != "$SUM" ]; then
    echo "Контрольная сумма не сошлась." >&2
    echo "  ожидалась: $SUM" >&2
    echo "  получена:  $GOT" >&2
    exit 1
fi

tar -xf "$TARBALL" -C "$WORK"
SRC="$WORK/ffmpeg-$VERSION"

# Что умеет этот ffmpeg — и только это:
#   разборщики:  asf (WMA), ape, rm (RealAudio), dts/dtshd, voc;
#   декодеры:    все WMA, APE, RealAudio (cook, sipr, atrac3, ralf, 14.4, 28.8), DTS, PCM и ADPCM;
#   на выходе:   FLAC — кодировщик, упаковщик и преобразование выборок (aresample/aformat).
echo "Собираю ffmpeg $VERSION (только звук)…"
(
    cd "$SRC"
    ./configure \
        --cc=clang --arch=arm64 --target-os=darwin \
        --extra-cflags="-mmacosx-version-min=15.0" --extra-ldflags="-mmacosx-version-min=15.0" \
        --disable-everything --disable-autodetect --disable-doc --disable-debug \
        --disable-network --disable-ffplay --disable-ffprobe --disable-avdevice \
        --disable-swscale --enable-small \
        --enable-static --disable-shared \
        --enable-ffmpeg --enable-avformat --enable-avcodec --enable-avfilter --enable-swresample \
        --enable-protocol=file,pipe \
        --enable-demuxer=asf,ape,rm,dts,dtshd,voc \
        --enable-decoder=wmav1,wmav2,wmapro,wmalossless,wmavoice,ape,cook,sipr,atrac3,ralf,ra_144,ra_288,dca \
        --enable-decoder='pcm_*' --enable-decoder='adpcm_*' \
        --enable-parser=dca \
        --enable-encoder=flac --enable-muxer=flac \
        --enable-filter=abuffer,abuffersink,aformat,anull,aresample \
        > "$WORK/configure.log" 2>&1 || { tail -30 "$WORK/configure.log" >&2; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" ffmpeg > "$WORK/make.log" 2>&1 || { tail -30 "$WORK/make.log" >&2; exit 1; }
)

cp "$SRC/ffmpeg" "$BINARY"
strip -x "$BINARY"
chmod +x "$BINARY"
cp "$SRC/COPYING.LGPLv2.1" "$DEST/LICENSE-ffmpeg.txt"

echo "Готово: $BINARY ($(du -h "$BINARY" | awk '{print $1}'))"
"$BINARY" -hide_banner -version | head -1
