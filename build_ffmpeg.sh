#!/usr/bin/env bash
# ==============================================================================
#  scripts/build_ffmpeg.sh
#  Сборка статических библиотек FFmpeg на Fedora Linux
#
#  Аргументы (передаёт Makefile):
#    $1 — путь к исходникам FFmpeg  (обязателен)
#    $2 — путь к build-директории   (обязателен)
#
#  Можно запустить и вручную:
#    ./scripts/build_ffmpeg.sh /путь/к/FFmpeg /путь/к/PMI/ffmpeg_build
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Пути
# ------------------------------------------------------------------------------
FFMPEG_SRC="${1:-}"
BUILD_DIR="${2:-}"

# Если аргументы не переданы — пытаемся угадать по расположению скрипта
if [ -z "$FFMPEG_SRC" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PMI_DIR="$(dirname "$SCRIPT_DIR")"
  FFMPEG_SRC="$(dirname "$PMI_DIR")/FFmpeg"
fi

if [ -z "$BUILD_DIR" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PMI_DIR="$(dirname "$SCRIPT_DIR")"
  BUILD_DIR="$PMI_DIR/ffmpeg_build"
fi

FFMPEG_SRC="$(realpath "$FFMPEG_SRC")"
BUILD_DIR="$(realpath -m "$BUILD_DIR")"   # -m: не требует существования
JOBS=$(nproc)

echo "════════════════════════════════════════════════════════════"
echo "  FFmpeg Static Build для PMI (Fedora)"
echo "════════════════════════════════════════════════════════════"
echo "  FFmpeg src : $FFMPEG_SRC"
echo "  Build dir  : $BUILD_DIR"
echo "  CPU cores  : $JOBS"
echo "════════════════════════════════════════════════════════════"

# ------------------------------------------------------------------------------
# Проверка исходников
# ------------------------------------------------------------------------------
if [ ! -f "$FFMPEG_SRC/configure" ]; then
  echo ""
  echo "[ERROR] Не найден: $FFMPEG_SRC/configure"
  echo ""
  echo "  Ожидаемая структура:"
  echo "    <родитель>/"
  echo "      FFmpeg/    ← исходники FFmpeg (с файлом configure)"
  echo "      PMI/       ← этот проект"
  echo ""
  echo "  Или передайте путь явно:"
  echo "    $0 /полный/путь/к/FFmpeg /полный/путь/к/ffmpeg_build"
  exit 1
fi

# ------------------------------------------------------------------------------
# Установка зависимостей (Fedora / RHEL / CentOS Stream)
# ------------------------------------------------------------------------------
echo ""
echo "[DEPS] Проверяем зависимости..."

if command -v dnf &>/dev/null; then
  echo "[DEPS] Устанавливаем через dnf..."
  sudo dnf install -y \
    nasm yasm gcc gcc-c++ make pkg-config \
    x264-devel zlib-devel bzip2-devel xz-devel \
    || true
  echo "[DEPS] OK"
else
  echo "[WARN] dnf не найден — проверьте зависимости вручную"
fi

# ------------------------------------------------------------------------------
# Конфигурация FFmpeg
# ------------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

cd "$FFMPEG_SRC"

echo ""
echo "[CONFIGURE] Конфигурируем FFmpeg..."
echo "  prefix: $BUILD_DIR"

./configure \
  --prefix="$BUILD_DIR" \
  \
  --enable-static \
  --disable-shared \
  --enable-pic \
  \
  --enable-gpl \
  --enable-version3 \
  \
  --enable-libx264 \
  \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --disable-autodetect \
  \
  --enable-protocol=file \
  \
  --enable-demuxer=matroska \
  --enable-demuxer=mov \
  --enable-demuxer=mpegts \
  --enable-demuxer=avi \
  --enable-demuxer=flv \
  --enable-demuxer=concat \
  \
  --enable-muxer=matroska \
  --enable-muxer=mp4 \
  --enable-muxer=mov \
  --enable-muxer=avi \
  --enable-muxer=segment \
  \
  --enable-decoder=h264 \
  --enable-decoder=hevc \
  --enable-decoder=mpeg4 \
  --enable-decoder=mpeg2video \
  --enable-decoder=vp9 \
  --enable-decoder=vp8 \
  --enable-decoder=av1 \
  --enable-decoder=aac \
  --enable-decoder=ac3 \
  --enable-decoder=mp3 \
  --enable-decoder=eac3 \
  --enable-decoder=dts \
  --enable-decoder=opus \
  --enable-decoder=vorbis \
  --enable-decoder=flac \
  --enable-decoder=truehd \
  --enable-decoder=ass \
  --enable-decoder=ssa \
  --enable-decoder=srt \
  --enable-decoder=subrip \
  --enable-decoder=dvd_subtitle \
  --enable-decoder=hdmv_pgs_subtitle \
  \
  --enable-encoder=libx264 \
  \
  --enable-parser=h264 \
  --enable-parser=hevc \
  --enable-parser=aac \
  --enable-parser=ac3 \
  --enable-parser=mpegaudio \
  --enable-parser=vp9 \
  --enable-parser=av1 \
  --enable-parser=mpeg4video \
  \
  --enable-filter=minterpolate \
  --enable-filter=buffer \
  --enable-filter=buffersink \
  --enable-filter=scale \
  --enable-filter=format \
  --enable-filter=fps \
  --enable-filter=setpts \
  --enable-filter=fifo \
  \
  --enable-bsf=h264_mp4toannexb \
  --enable-bsf=hevc_mp4toannexb \
  --enable-bsf=aac_adtstoasc \
  --enable-bsf=extract_extradata \
  \
  --extra-cflags="-O3 -march=native -fPIC" \
  --extra-ldflags="-static-libgcc" \
  --pkg-config-flags="--static"

# ------------------------------------------------------------------------------
# Сборка и установка
# ------------------------------------------------------------------------------
echo ""
echo "[BUILD] make -j${JOBS} (это займёт несколько минут)..."
make -j"$JOBS"

echo ""
echo "[INSTALL] Устанавливаем в $BUILD_DIR ..."
make install

# ------------------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Сборка FFmpeg завершена!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Библиотеки:"
ls -lh "$BUILD_DIR/lib/"*.a 2>/dev/null \
  | awk '{printf "    %-12s %s\n", $5, $9}' || true
echo ""
echo "  Следующий шаг:"
echo "    make build"
echo "════════════════════════════════════════════════════════════"
