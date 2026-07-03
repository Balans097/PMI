# ==============================================================================
#  config.nims — автосборка одной командой:
#
#      nim c -d:release --threads:on PMI.nim
#
#  Это NimScript-файл: компилятор Nim выполняет его КАК ОБЫЧНУЮ ПРОГРАММУ
#  (в собственной VM) ДО того, как начнёт компилировать PMI.nim. Здесь мы:
#
#    1. Проверяем, установлены ли уже статические .a библиотеки FFmpeg
#       в ffmpeg_build/lib. Если да — сразу переходим к шагу 4.
#    2. Если исходников FFmpeg рядом нет (../FFmpeg) — клонируем их
#       с GitHub-зеркала (мелкий shallow-clone стабильной ветки).
#    3. Собираем FFmpeg: configure (только нужные нам демуксеры, декодеры,
#       фильтры и x264-энкодер) → make → make install в ./ffmpeg_build.
#    4. Прописываем компилятору Nim пути к заголовкам (--passC:-I...)
#       и статическим библиотекам (--passL: <полный путь>.a), плюс
#       системные зависимости x264/zlib/bz2/lzma/pthread.
#
#  Идемпотентность: повторный `nim c` при уже собранном FFmpeg просто
#  пропускает шаги 2-3 (см. allLibsExist) — линковка настраивается заново
#  на каждый запуск, это дёшево.
#
#  Если FFmpeg лежит не в "../FFmpeg", можно передать свой путь через
#  переменную окружения:
#      PMI_FFMPEG_SRC=/путь/к/FFmpeg nim c -d:release --threads:on PMI.nim
# ==============================================================================

import std/[os, strformat, strutils]

# ------------------------------------------------------------------------------
# Пути. currentSourcePath() — путь к ЭТОМУ config.nims, он лежит рядом
# с PMI.nim, поэтому его родительская папка — корень проекта.
# ------------------------------------------------------------------------------
let
  projectDir = parentDir(currentSourcePath())
  parentOfProject = parentDir(projectDir)
  # Ветка FFmpeg по умолчанию; переопределяется через -d:pmiFFmpegBranch=...
  ffmpegBranch = "release/7.1"
  # Исходники FFmpeg: по умолчанию рядом с проектом, либо -d:pmiFFmpegSrc=...
  ffmpegSrc = if getEnv("PMI_FFMPEG_SRC") != "": getEnv("PMI_FFMPEG_SRC")
              else: parentOfProject / "FFmpeg"
  buildDir = projectDir / "ffmpeg_build"
  incDir   = buildDir / "include"
  libDir   = buildDir / "lib"

# Библиотеки в порядке зависимостей (см. README, «Детали линковки»):
# libavfilter → libavcodec → libavformat → libswscale → libswresample → libavutil
const ffmpegLibs = [
  "libavfilter.a",
  "libavcodec.a",
  "libavformat.a",
  "libswscale.a",
  "libswresample.a",
  "libavutil.a"
]

# ------------------------------------------------------------------------------
# allLibsExist — все ли шесть статических .a уже установлены
# ------------------------------------------------------------------------------
proc allLibsExist(dir: string): bool =
  result = true
  for libName in ffmpegLibs:
    if not fileExists(dir / libName):
      result = false

# ------------------------------------------------------------------------------
# cloneFFmpeg — shallow-clone GitHub-зеркала официального репозитория FFmpeg
# ------------------------------------------------------------------------------
proc cloneFFmpeg(dst, branch: string) =
  echo fmt"[config.nims] Клонируем FFmpeg ({branch}) → {dst}"
  exec fmt"git clone --branch {branch} --depth 1 https://github.com/FFmpeg/FFmpeg.git {dst}"

# ------------------------------------------------------------------------------
# buildFFmpeg — configure + make + make install
#
# Флаги --enable-* минимальны: собираем только то, что реально использует
# PMI (see worker.nim/concat.nim): матрёшка контейнеров mkv/mp4/mov/avi/ts,
# декодеры популярных видео/аудио/субтитровых кодеков, x264-энкодер и
# фильтры minterpolate/buffer/buffersink/format.
# ------------------------------------------------------------------------------
proc buildFFmpeg(src, prefix: string) =
  let jobs = strip(gorge("nproc"))

  echo "[config.nims] Проверяем системные зависимости (dnf)..."
  # "|| true" — не прерывать сборку, если пакеты уже установлены
  # или dnf недоступен (например, сборка идёт не на Fedora).
  exec "sudo dnf install -y nasm yasm gcc gcc-c++ make pkg-config " &
       "x264-devel zlib-devel bzip2-devel xz-devel || true"

  let configureFlags = [
    fmt"--prefix={prefix}",
    "--enable-static", "--disable-shared", "--enable-pic",
    "--enable-gpl", "--enable-version3", "--enable-libx264",
    "--disable-programs", "--disable-doc", "--disable-debug",
    "--disable-autodetect",
    "--enable-protocol=file",
    "--enable-demuxer=matroska,mov,mpegts,avi,flv,concat",
    "--enable-muxer=matroska,mp4,mov,avi,segment",
    "--enable-decoder=h264,hevc,mpeg4,mpeg2video,vp9,vp8,av1,aac,ac3,mp3," &
      "eac3,dts,opus,vorbis,flac,truehd,ass,ssa,srt,subrip,dvd_subtitle," &
      "hdmv_pgs_subtitle",
    "--enable-encoder=libx264",
    "--enable-parser=h264,hevc,aac,ac3,mpegaudio,vp9,av1,mpeg4video",
    "--enable-filter=minterpolate,buffer,buffersink,scale,format,fps,setpts,fifo",
    "--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata",
    "--extra-cflags=\"-O3 -march=native -fPIC\"",
    "--extra-ldflags=\"-static-libgcc\"",
    "--pkg-config-flags=\"--static\""
  ]

  let savedDir = getCurrentDir()
  cd(src)

  echo "[config.nims] ./configure ..."
  exec "./configure " & join(configureFlags, " ")

  echo fmt"[config.nims] make -j{jobs} ..."
  exec fmt"make -j{jobs}"

  echo "[config.nims] make install ..."
  exec "make install"

  cd(savedDir)

# ------------------------------------------------------------------------------
# Оркестрация шагов 1-3
# ------------------------------------------------------------------------------
if allLibsExist(libDir):
  echo fmt"[config.nims] Готовые библиотеки FFmpeg найдены в {libDir} — пропускаем сборку."
else:
  echo "[config.nims] Статические библиотеки FFmpeg не найдены, начинаем сборку."

  let haveSrc = fileExists(ffmpegSrc / "configure")
  if not haveSrc:
    cloneFFmpeg(ffmpegSrc, ffmpegBranch)

  buildFFmpeg(ffmpegSrc, buildDir)

  if not allLibsExist(libDir):
    echo "[config.nims] [ERROR] Сборка FFmpeg завершилась, но .a не найдены."
    echo fmt"[config.nims]         Ожидались файлы в {libDir}"
    quit(1)

# ------------------------------------------------------------------------------
# Шаг 4 — флаги компилятора/линковщика Nim
# ------------------------------------------------------------------------------
switch("passC", fmt"-I{incDir}")

# GNU ld читает .a слева направо: зависящая библиотека должна стоять
# левее той, от которой она зависит. --start-group/--end-group снимает
# это ограничение (позволяет ld повторно просматривать группу, пока
# все символы не разрешатся), поэтому порядок внутри группы не критичен.
switch("passL", "-Wl,--start-group")
for libName in ffmpegLibs:
  switch("passL", libDir / libName)
switch("passL", "-Wl,--end-group")

switch("passL", "-lx264")
switch("passL", "-lz")
switch("passL", "-lbz2")
switch("passL", "-llzma")
switch("passL", "-lpthread")
switch("passL", "-lm")
switch("passL", "-ldl")

# Дефолты, гарантирующие корректную сборку даже если пользователь наберёт
# ровно "nim c -d:release --threads:on PMI.nim" без доп. флагов:
switch("mm", "orc")             # современный, потокобезопасный сборщик мусора
switch("threads", "on")         # на случай, если забыт в командной строке
switch("experimental", "parallel")
