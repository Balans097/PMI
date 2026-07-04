# ==============================================================================
#  config.nims — автосборка одной командой:
#
#      nim c -d:release --threads:on PMI.nim                      (Linux)
#      nim c -d:release --threads:on --os:windows PMI.nim         (Windows, кросс)
#
#  Это NimScript-файл: компилятор Nim выполняет его КАК ОБЫЧНУЮ ПРОГРАММУ
#  (в собственной VM) ДО того, как начнёт компилировать PMI.nim.
#
#  ⚠ ВАЖНАЯ ЛОВУШКА NimScript: при сборке с `--os:windows` компилятор
#  подставляет ЦЕЛЕВУЮ ОС во ВСЕ compile-time условия — в том числе внутри
#  std/os, которым пользуется сам config.nims. В частности:
#    • DirSep внутри оператора os."/" становится '\', а не '/';
#    • os.findExe() начинает искать "имя.exe" вместо "имя";
#    • hostOS в NimScript ВСЕГДА равен целевой ОС, а не физической машине,
#      на которой реально работает компилятор (т.е. проверка вида
#      "hostOS != windows" для отличия кросссборки от нативной — не
#      работает, она всегда false, если цель — Windows).
#  Но git/make/gcc/pkg-config, которые этот скрипт запускает через exec,
#  выполняются на РЕАЛЬНОЙ (Linux) машине сборки — им нужны обычные
#  Linux-пути через "/". Поэтому здесь НИГДЕ не используется оператор
#  os."/" и os.findExe() — все пути собираются вручную через bp(), а
#  поиск утилит идёт через findHostExe() (настоящий `which`). Без этого
#  "--os:windows" превращает "parentDir / "FFmpeg"" в буквальную строку
#  "...\FFmpeg" (один файл с обратным слэшем в имени, а не вложенная
#  папка) — именно это и произошло в первой версии этого файла.
#
#  ЧТО ДЕЛАЕТ СКРИПТ (кросскомпиляция под Windows, x86_64-w64-mingw32):
#    1. Проверяет/ставит тулчейн x86_64-w64-mingw32-gcc (dnf).
#    2. Сам собирает статическую libx264 этим кросстулчейном — Fedora не
#       поставляет готовый mingw64-x264 (патентный кодек), поэтому клонирует
#       исходники и собирает их с --host=x86_64-w64-mingw32.
#    3. Собирает статический FFmpeg с --enable-cross-compile
#       --target-os=mingw32 --cross-prefix=x86_64-w64-mingw32-.
#    4. Линкует PMI.nim собранным mingw-gcc, статически (без DLL), с
#       оконными системными библиотеками (ws2_32/secur32/bcrypt) вместо
#       POSIX-специфичных (-ldl и т.п.).
#
#  Linux- и Windows-сборки хранятся в РАЗНЫХ папках (ffmpeg_build /
#  ffmpeg_build_windows, исходники ../FFmpeg / ../FFmpeg-windows) — обе
#  остаются закешированы одновременно; переключение цели — это просто
#  наличие/отсутствие --os:windows.
#
#  PMI_FFMPEG_SRC=/путь/к/FFmpeg — как и раньше, переопределяет путь к
#  исходникам FFmpeg (действует для активной в данный момент цели).
# ==============================================================================




import std/[os, strformat, strutils]




# ------------------------------------------------------------------------------
# bp() — ЕДИНСТВЕННЫЙ способ строить пути в этом файле: всегда "/", всегда
# как на реальной машине сборки — независимо от --os:windows (см. врезку выше).
# ------------------------------------------------------------------------------

proc bp(parts: varargs[string]): string =
  join(parts, "/")

proc slashify(p: string): string =
  ## На случай, если currentSourcePath() вернёт путь уже "отформатированным"
  ## под целевую ОС — нормализуем один раз на входе и дальше уже никогда
  ## не используем os."/".
  p.replace('\\', '/')

proc findHostExe(name: string): string =
  ## os.findExe() под --os:windows искал бы "name.exe" — бесполезно для
  ## поиска инструментов сборки на текущей Linux-машине. Используем
  ## настоящий `which` хоста.
  let r = gorgeEx("which " & name & " 2>/dev/null")
  if r.exitCode == 0: strip(r.output) else: ""

proc detectJobs(): string =
  let nproc = gorgeEx("nproc")
  if nproc.exitCode == 0 and strip(nproc.output) != "":
    return strip(nproc.output)
  let sysctl = gorgeEx("sysctl -n hw.ncpu")
  if sysctl.exitCode == 0 and strip(sysctl.output) != "":
    return strip(sysctl.output)
  echo "[config.nims] [WARN] Не удалось определить число ядер, используем 4."
  return "4"

# ------------------------------------------------------------------------------
# Базовые пути
# ------------------------------------------------------------------------------
let
  thisFile        = slashify(currentSourcePath())
  projectDir      = thisFile[0 ..< thisFile.rfind('/')]        # .../PMI
  parentOfProject = projectDir[0 ..< projectDir.rfind('/')]    # .../FrameInterpolation
  ffmpegBranch    = "release/7.1"
  x264RepoUrl     = "https://code.videolan.org/videolan/x264.git"

# crossWindows = true ⇔ собираем PMI.exe (--os:windows) кросс-компилятором
# с этой же (Linux) машины. Раньше здесь была ещё проверка
# "and hostOS != windows" — она была НЕВЕРНОЙ (см. врезку в шапке файла)
# и заставляла скрипт молча собирать обычный нативный Linux FFmpeg вместо
# кросс-сборки. Убрана.
let crossWindows = defined(windows)

const mingwPrefix = "x86_64-w64-mingw32-"

let
  ffmpegSrc = if getEnv("PMI_FFMPEG_SRC") != "": getEnv("PMI_FFMPEG_SRC")
              elif crossWindows: bp(parentOfProject, "FFmpeg-windows")
              else: bp(parentOfProject, "FFmpeg")
  x264Src   = bp(parentOfProject, "x264-windows")               # только для Windows
  buildDir  = bp(projectDir, if crossWindows: "ffmpeg_build_windows" else: "ffmpeg_build")
  x264Build = bp(projectDir, "x264_build_windows")               # только для Windows
  incDir    = bp(buildDir, "include")
  libDir    = bp(buildDir, "lib")

const ffmpegLibs = [
  "libavfilter.a",
  "libavcodec.a",
  "libavformat.a",
  "libswscale.a",
  "libswresample.a",
  "libavutil.a"
]

proc allLibsExist(dir: string): bool =
  result = true
  for libName in ffmpegLibs:
    if not fileExists(bp(dir, libName)):
      result = false

proc cloneRepo(url, dst, branch: string) =
  echo fmt"[config.nims] Клонируем {url} ({branch}) → {dst}"
  exec "git clone --branch \"" & branch & "\" --depth 1 " &
       "\"" & url & "\" \"" & dst & "\""

# ------------------------------------------------------------------------------
# Windows: mingw-w64 тулчейн
# ------------------------------------------------------------------------------
proc ensureMingwToolchain(): string =
  result = findHostExe(mingwPrefix & "gcc")
  if result != "": return

  echo "[config.nims] mingw-w64 тулчейн не найден в PATH, пробуем dnf..."
  if findHostExe("dnf") != "":
    exec "sudo dnf install -y mingw64-gcc mingw64-gcc-c++ mingw64-binutils " &
         "mingw64-filesystem mingw64-crt mingw64-headers " &
         "mingw64-winpthreads-static nasm yasm git || true"
  else:
    echo "[config.nims] [WARN] dnf не найден — поставьте mingw-w64 тулчейн вручную."

  result = findHostExe(mingwPrefix & "gcc")
  if result == "":
    echo ""
    echo "[config.nims] [ERROR] " & mingwPrefix & "gcc так и не найден в PATH."
    echo "[config.nims]         Fedora:"
    echo "[config.nims]           sudo dnf install mingw64-gcc mingw64-gcc-c++ \\"
    echo "[config.nims]             mingw64-winpthreads-static mingw64-binutils"
    quit(1)

# ------------------------------------------------------------------------------
# Windows: статическая libx264, собранная кросс-тулчейном.
# ------------------------------------------------------------------------------
proc buildX264Windows(src, prefix: string) =
  if fileExists(bp(prefix, "lib", "libx264.a")):
    echo fmt"[config.nims] libx264.a (Windows) уже собрана в {prefix} — пропускаем."
    return

  discard ensureMingwToolchain()

  if not fileExists(bp(src, "configure")):
    cloneRepo(x264RepoUrl, src, "stable")

  let jobs = detectJobs()
  let savedDir = getCurrentDir()
  cd(src)
  echo "[config.nims] Кросс-сборка libx264 под Windows (mingw-w64)..."
  exec "./configure " &
       "--prefix=\"" & prefix & "\" " &
       "--host=x86_64-w64-mingw32 " &
       "--cross-prefix=" & mingwPrefix & " " &
       "--enable-static --enable-pic --disable-cli --bit-depth=all"
  exec fmt"make -j{jobs}"
  exec "make install"
  cd(savedDir)

# ------------------------------------------------------------------------------
# buildFFmpeg — configure + make + make install.
# ------------------------------------------------------------------------------
proc buildFFmpeg(src, prefix: string; windows: bool; x264Prefix: string) =
  let jobs = detectJobs()

  if windows:
    discard ensureMingwToolchain()
    buildX264Windows(x264Src, x264Prefix)
    # Направляем pkg-config ИСКЛЮЧИТЕЛЬНО на .pc свежесобранной Windows-
    # libx264, иначе ./configure на Fedora найдёт системную (ELF) x264-devel
    # и линковка PMI упадёт с несовместимым форматом объектов.
    putEnv("PKG_CONFIG_LIBDIR", bp(x264Prefix, "lib", "pkgconfig"))
    putEnv("PKG_CONFIG_PATH", "")
  else:
    echo "[config.nims] Проверяем системные зависимости (dnf)..."
    if findHostExe("dnf") == "":
      echo "[config.nims] [WARN] dnf не найден (не Fedora/RHEL?) — пропускаем " &
           "автоустановку системных пакетов."
    else:
      exec "sudo dnf install -y nasm yasm gcc gcc-c++ make pkg-config " &
           "x264-devel zlib-devel bzip2-devel xz-devel || true"

  var configureFlags = @[
    "--prefix=\"" & prefix & "\"",
    "--enable-static", "--disable-shared",
    "--enable-gpl", "--enable-version3", "--enable-libx264",
    "--disable-programs", "--disable-doc", "--disable-debug",
    "--disable-autodetect",
    "--disable-postproc",
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
    "--pkg-config-flags=\"--static\""
  ]

  if windows:
    add(configureFlags, [
      "--enable-cross-compile",
      "--arch=x86_64",
      "--target-os=mingw32",
      "--cross-prefix=" & mingwPrefix,
      "--extra-cflags=\"-O3 -I" & bp(x264Prefix, "include") & "\"",
      "--extra-ldflags=\"-static -L" & bp(x264Prefix, "lib") & "\""
    ])
  else:
    add(configureFlags, [
      "--enable-pic",
      "--extra-cflags=\"-O3 -march=native -fPIC\"",
      "--extra-ldflags=\"-static-libgcc\""
    ])

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
  if crossWindows:
    echo "[config.nims] Целевая ОС: Windows (кросс-компиляция mingw-w64)."

  if not fileExists(bp(ffmpegSrc, "configure")):
    cloneRepo("https://github.com/FFmpeg/FFmpeg.git", ffmpegSrc, ffmpegBranch)

  buildFFmpeg(ffmpegSrc, buildDir, crossWindows, x264Build)

  if not allLibsExist(libDir):
    echo "[config.nims] [ERROR] Сборка FFmpeg завершилась, но .a не найдены."
    echo fmt"[config.nims]         Ожидались файлы в {libDir}"
    quit(1)

# ------------------------------------------------------------------------------
# Шаг 4 — флаги компилятора/линковщика Nim
# ------------------------------------------------------------------------------
switch("passC", fmt"-I{incDir}")

if crossWindows:
  let mingwGcc = ensureMingwToolchain()
  switch("gcc.exe", mingwGcc)
  switch("gcc.linkerexe", mingwGcc)

switch("passL", "-Wl,--start-group")
for libName in ffmpegLibs:
  switch("passL", bp(libDir, libName))
if fileExists(bp(libDir, "libpostproc.a")):
  switch("passL", bp(libDir, "libpostproc.a"))
switch("passL", "-Wl,--end-group")

if crossWindows:
  switch("passL", bp(x264Build, "lib", "libx264.a"))
  switch("passL", "-lz")
  switch("passL", "-lbz2")
  switch("passL", "-llzma")
  switch("passL", "-lm")
  switch("passL", "-lws2_32")
  switch("passL", "-lsecur32")
  switch("passL", "-lbcrypt")
  switch("passL", "-lwinpthread")
  switch("passL", "-static")
else:
  switch("passL", "-lx264")
  switch("passL", "-lz")
  switch("passL", "-lbz2")
  switch("passL", "-llzma")
  switch("passL", "-lpthread")
  switch("passL", "-lm")
  switch("passL", "-ldl")

switch("mm", "orc")
switch("threads", "on")
switch("experimental", "parallel")
