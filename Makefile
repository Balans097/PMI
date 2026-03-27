# ==============================================================================
#  Makefile — PMI (Parallel Motion Interpolate)
#  Fedora Linux, статическая линковка FFmpeg
# ==============================================================================

MAKEFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
PROJECT_DIR   := $(patsubst %/,%,$(dir $(MAKEFILE_PATH)))

FFMPEG_SRC  := $(abspath $(PROJECT_DIR)/../FFmpeg)
BUILD_DIR   := $(PROJECT_DIR)/ffmpeg_build
SRC_DIR     := $(PROJECT_DIR)

INC  := $(BUILD_DIR)/include
LIB  := $(BUILD_DIR)/lib
JOBS := $(shell nproc)

NIM  := nim

PASSC := --passC:"-I$(INC)"

FFMPEG_LIBS := \
  $(LIB)/libavfilter.a \
  $(LIB)/libavcodec.a  \
  $(LIB)/libavformat.a \
  $(LIB)/libswscale.a  \
  $(LIB)/libswresample.a \
  $(LIB)/libavutil.a

FFMPEG_GROUP := \
  --passL:"-Wl,--start-group" \
  $(foreach lib,$(FFMPEG_LIBS),--passL:"$(lib)") \
  --passL:"-Wl,--end-group"

PASSL_FFMPEG := $(FFMPEG_GROUP)

PASSL_SYS := \
  --passL:"-lx264" \
  --passL:"-lz" \
  --passL:"-lbz2" \
  --passL:"-llzma" \
  --passL:"-lpthread" \
  --passL:"-lm" \
  --passL:"-ldl"

NIM_RELEASE := \
  -d:release \
  --opt:speed \
  --threads:on \
  --mm:orc \
  --experimental:parallel \
  $(PASSC) \
  $(PASSL_FFMPEG) \
  $(PASSL_SYS)

NIM_DEBUG := \
  -d:debug \
  --debuginfo:on \
  --linedir:on \
  --threads:on \
  --mm:orc \
  --experimental:parallel \
  $(PASSC) \
  $(PASSL_FFMPEG) \
  $(PASSL_SYS)

# ==============================================================================
.PHONY: all build-ffmpeg build debug clean clean-all help check-deps info

all: build

# ── Диагностика ───────────────────────────────────────────────────────────
info:
	@echo "PROJECT_DIR : $(PROJECT_DIR)"
	@echo "FFMPEG_SRC  : $(FFMPEG_SRC)"
	@echo "BUILD_DIR   : $(BUILD_DIR)"
	@echo "SRC_DIR     : $(SRC_DIR)"
	@echo "JOBS        : $(JOBS)"

# ── Шаг 1: собрать FFmpeg (всё inline, без внешнего скрипта) ──────────────
build-ffmpeg:
	@echo "════════════════════════════════════════════════════════════"
	@echo "  FFmpeg Static Build для PMI (Fedora)"
	@echo "════════════════════════════════════════════════════════════"
	@echo "  FFmpeg src : $(FFMPEG_SRC)"
	@echo "  Build dir  : $(BUILD_DIR)"
	@echo "  CPU cores  : $(JOBS)"
	@echo "════════════════════════════════════════════════════════════"
	@test -f "$(FFMPEG_SRC)/configure" || \
	  (echo "" && \
	   echo "[ERROR] Не найден $(FFMPEG_SRC)/configure" && \
	   echo "" && \
	   echo "  Ожидается структура:" && \
	   echo "    <parent>/" && \
	   echo "      FFmpeg/   ← исходники FFmpeg" && \
	   echo "      PMI/      ← этот проект" && \
	   echo "" && \
	   echo "  Текущий PROJECT_DIR: $(PROJECT_DIR)" && \
	   echo "  Ищем FFmpeg в     : $(FFMPEG_SRC)" && \
	   exit 1)
	@echo ""
	@echo "[DEPS] Устанавливаем зависимости через dnf..."
	sudo dnf install -y nasm yasm gcc gcc-c++ make pkg-config \
	  x264-devel zlib-devel bzip2-devel xz-devel || true
	@echo ""
	@echo "[CONFIGURE] Конфигурируем FFmpeg..."
	mkdir -p "$(BUILD_DIR)"
	cd "$(FFMPEG_SRC)" && ./configure \
	  --prefix="$(BUILD_DIR)" \
	  --enable-static \
	  --disable-shared \
	  --enable-pic \
	  --enable-gpl \
	  --enable-version3 \
	  --enable-libx264 \
	  --disable-programs \
	  --disable-doc \
	  --disable-debug \
	  --disable-autodetect \
	  --enable-protocol=file \
	  --enable-demuxer=matroska \
	  --enable-demuxer=mov \
	  --enable-demuxer=mpegts \
	  --enable-demuxer=avi \
	  --enable-demuxer=flv \
	  --enable-demuxer=concat \
	  --enable-muxer=matroska \
	  --enable-muxer=mp4 \
	  --enable-muxer=mov \
	  --enable-muxer=avi \
	  --enable-muxer=segment \
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
	  --enable-encoder=libx264 \
	  --enable-parser=h264 \
	  --enable-parser=hevc \
	  --enable-parser=aac \
	  --enable-parser=ac3 \
	  --enable-parser=mpegaudio \
	  --enable-parser=vp9 \
	  --enable-parser=av1 \
	  --enable-parser=mpeg4video \
	  --enable-filter=minterpolate \
	  --enable-filter=buffer \
	  --enable-filter=buffersink \
	  --enable-filter=scale \
	  --enable-filter=format \
	  --enable-filter=fps \
	  --enable-filter=setpts \
	  --enable-filter=fifo \
	  --enable-bsf=h264_mp4toannexb \
	  --enable-bsf=hevc_mp4toannexb \
	  --enable-bsf=aac_adtstoasc \
	  --enable-bsf=extract_extradata \
	  --extra-cflags="-O3 -march=native -fPIC" \
	  --extra-ldflags="-static-libgcc" \
	  --pkg-config-flags="--static"
	@echo ""
	@echo "[BUILD] make -j$(JOBS) ..."
	cd "$(FFMPEG_SRC)" && make -j$(JOBS)
	@echo ""
	@echo "[INSTALL] → $(BUILD_DIR)"
	cd "$(FFMPEG_SRC)" && make install
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  FFmpeg собран. Следующий шаг: make build"
	@echo "════════════════════════════════════════════════════════════"
	@ls -lh "$(LIB)"/*.a 2>/dev/null | awk '{printf "  %s  %s\n", $$5, $$9}' || true

# ── Шаг 2: скомпилировать PMI ─────────────────────────────────────────────
build: $(LIB)/libavcodec.a
	@echo ">>> Компиляция PMI (release)..."
	cd "$(SRC_DIR)" && $(NIM) c \
	  $(NIM_RELEASE) \
	  -o:"$(PROJECT_DIR)/PMI" \
	  PMI.nim
	@echo ""
	@echo "✓ Готово: $(PROJECT_DIR)/PMI"
	@echo "  Запуск: ./PMI --help"

$(LIB)/libavcodec.a:
	@echo ""
	@echo "[ERROR] Библиотеки FFmpeg не найдены в $(LIB)/"
	@echo "        Сначала выполните: make build-ffmpeg"
	@echo ""
	@exit 1

# ── Отладочная сборка ─────────────────────────────────────────────────────
debug: $(LIB)/libavcodec.a
	@echo ">>> Компиляция PMI (debug)..."
	cd "$(SRC_DIR)" && $(NIM) c \
	  $(NIM_DEBUG) \
	  -o:"$(PROJECT_DIR)/PMI_debug" \
	  PMI.nim
	@echo "✓ Debug: $(PROJECT_DIR)/PMI_debug"

# ── Проверка зависимостей ─────────────────────────────────────────────────
check-deps:
	@echo "=== Проверка зависимостей ==="
	@command -v nim     >/dev/null && echo "✓ nim    $$(nim --version | head -1)" \
	  || echo "✗ nim    НЕ НАЙДЕН  →  sudo dnf install nim"
	@command -v gcc     >/dev/null && echo "✓ gcc    $$(gcc --version | head -1)" \
	  || echo "✗ gcc    НЕ НАЙДЕН  →  sudo dnf install gcc"
	@command -v nasm    >/dev/null && echo "✓ nasm   $$(nasm --version)" \
	  || echo "✗ nasm   НЕ НАЙДЕН  →  sudo dnf install nasm"
	@pkg-config --exists x264 2>/dev/null \
	  && echo "✓ x264   $$(pkg-config --modversion x264)" \
	  || echo "✗ x264   НЕ НАЙДЕН  →  sudo dnf install x264-devel"
	@pkg-config --exists zlib 2>/dev/null \
	  && echo "✓ zlib   OK" \
	  || echo "✗ zlib   НЕ НАЙДЕН  →  sudo dnf install zlib-devel"
	@test -f "$(FFMPEG_SRC)/configure" \
	  && echo "✓ FFmpeg src: $(FFMPEG_SRC)" \
	  || echo "✗ FFmpeg src НЕ НАЙДЕН: $(FFMPEG_SRC)"
	@test -f "$(LIB)/libavcodec.a" \
	  && echo "✓ FFmpeg .a библиотеки OK" \
	  || echo "✗ FFmpeg НЕ СОБРАН  →  make build-ffmpeg"

# ── Очистка ───────────────────────────────────────────────────────────────
clean:
	rm -f "$(PROJECT_DIR)/PMI" "$(PROJECT_DIR)/PMI_debug"
	rm -rf "$(SRC_DIR)/nimcache"

clean-all: clean
	rm -rf "$(BUILD_DIR)"
	@echo "Удалены: $(BUILD_DIR)"

# ── Помощь ───────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "PMI — Parallel Motion Interpolate"
	@echo ""
	@echo "  make check-deps    — проверить зависимости"
	@echo "  make build-ffmpeg  — собрать статические библиотеки FFmpeg"
	@echo "  make build         — скомпилировать PMI"
	@echo "  make debug         — скомпилировать с отладкой"
	@echo "  make info          — показать вычисленные пути"
	@echo "  make clean         — удалить бинарники"
	@echo "  make clean-all     — удалить бинарники + ffmpeg_build/"
	@echo ""
	@echo "  Полная сборка:"
	@echo "    make build-ffmpeg && make build"
	@echo ""
