# ==============================================================================
#  PMI.nim  — Parallel Motion Interpolate  (v1.3)
#
#  ТОЧКА ВХОДА ПРИЛОЖЕНИЯ. Здесь происходит:
#   1. Разбор аргументов командной строки (parseArgs).
#   2. Проба входного видео через FFmpeg (probeVideo) — узнаём длительность,
#      разрешение, FPS, число потоков в контейнере.
#   3. Планирование сегментов (planSegments) — видео режется на N кусков,
#      которые можно интерполировать параллельно, независимо друг от друга.
#   4. Запуск по одному потоку ОС на сегмент (worker.processSegment),
#      получение результатов через Channel.
#   5. Склейка успешных сегментов в один файл (concat.concatSegments).
#
#  ИЗМЕНЕНИЯ v1.3 (относительно v1.2, см. README):
#   • Добавлена константа PMI_VERSION и флаг -V/--version; версия печатается
#     также в баннере запуска и в тексте --help.
#   • Убран неиспользуемый import std/math (клампы приходят из system).
#   • См. README/CHANGELOG: два критических фикса компиляции в src/worker.nim
#     и src/concat.nim (let → var для указателей, которые освобождаются
#     через addr) — без них проект вообще не собирался.
#
#  ИЗМЕНЕНИЯ v4 (относительно v3, см. README):
#   • Стилевая правка исходного кода: везде префиксный синтаксис вызова
#     функций (len(A) вместо A.len и т.п.), однострочные/блочные
#     объявления const/let/var, сгруппированные import.
#   • Добавлен config.nims — теперь достаточно команды
#       nim c -d:release --threads:on PMI.nim
#     чтобы автоматически склонировать и собрать статический FFmpeg,
#     без обязательного использования Makefile (см. README).
# ==============================================================================

{.experimental: "parallel".}

import std/[strformat, strutils, parseopt, os,
            times, monotimes, sequtils, algorithm, terminal]
import src/[ffmpeg_api, worker, concat]

const PMI_VERSION* = "1.3"

# ------------------------------------------------------------------------------
# Определение TTY — цветной прогресс-бар с перерисовкой на месте (курсор
# вверх + перезапись строк) имеет смысл только в интерактивном терминале.
# Если stdout перенаправлен в файл/лог, ANSI-коды перемещения курсора там
# бессмысленны и только испортят лог — в этом случае используется старый
# построчный вывод [DONE]/[FAIL] без перерисовки.
#
# std/terminal не даёт единого кроссплатформенного isatty без оговорок,
# поэтому используем прямой FFI к C-библиотеке (portable: unistd.h на
# POSIX, io.h на Windows/mingw — актуально и для кросс-сборки под Windows,
# см. README).
when defined(windows):
  proc isattyImpl(fd: cint): cint {.importc: "_isatty", header: "<io.h>".}
else:
  proc isattyImpl(fd: cint): cint {.importc: "isatty", header: "<unistd.h>".}

let stdoutIsTty = isattyImpl(1.cint) != 0   # fd 1 = stdout

# ------------------------------------------------------------------------------
# Конфигурация приложения — заполняется из аргументов командной строки
# ------------------------------------------------------------------------------
type
  PMIConfig = object
    inputFile:   string
    outputFile:  string
    targetFps:   int
    miMode:      string
    mcMode:      string
    meMode:      string
    vsbmc:       int
    preset:      string
    crf:         int
    numWorkers:  int    # 0 = auto (по числу ядер CPU)
    tempDir:     string
    keepTemp:    bool
    verbose:     bool

proc defaultConfig(): PMIConfig =
  ## Значения по умолчанию — совпадают с теми, что описаны в README.
  PMIConfig(
    inputFile:   "input.mkv",
    outputFile:  "output.mkv",
    targetFps:   60,
    miMode:      "mci",
    mcMode:      "aobmc",
    meMode:      "bidir",
    vsbmc:       1,
    preset:      "slow",
    crf:         18,
    numWorkers:  0,
    tempDir:     "",
    keepTemp:    false,
    verbose:     false)

# ------------------------------------------------------------------------------
# Информация о входном видео, полученная через avformat/avcodec probe
# ------------------------------------------------------------------------------
type
  VideoInfo = object
    duration:  float                # секунды
    fps:       float                # средний FPS видеопотока
    videoIdx:  int                  # индекс видеопотока внутри контейнера
    width:     int
    height:    int
    codec:     string               # имя декодера ("h264", "hevc", ...)
    nbStreams: int                  # всего потоков в контейнере (видео+аудио+субтитры)
    fmtCtx:    ptr AVFormatContext  # держим открытым до конца main() —
                                     # нужен concat.nim для копирования аудио/субтитров

proc probeVideo(path: string): VideoInfo =
  ## Открывает контейнер, находит "лучший" видеопоток (av_find_best_stream)
  ## и извлекает параметры, необходимые для планирования и кодирования.
  var fmtCtx: ptr AVFormatContext
  ffCheck(avformat_open_input(addr fmtCtx, path.cstring, nil, nil),
          "Не удалось открыть: " & path)
  ffCheck(avformat_find_stream_info(fmtCtx, nil),
          "Не удалось найти stream info")

  var decoder: ptr AVCodec
  let vidIdx = av_find_best_stream(
    fmtCtx, AVMEDIA_TYPE_VIDEO, -1.cint, -1.cint, cast[pointer](addr decoder), 0.cint)

  if vidIdx < 0:
    avformat_close_input(addr fmtCtx)
    raise newException(IOError, "Видеопоток не найден: " & path)

  let
    vStream = fmtCtx.streams[vidIdx]
    fps     = getStreamFps(vStream)
    # fmtCtx.duration (контейнерный уровень) часто отсутствует/ненадёжен
    # у TS/broadcast-подобных источников (см. отчёт, находка #12) — раньше
    # это приводило к duration=0.0 и жёсткому отказу "видео слишком
    # короткое" даже для полноценных многочасовых записей. Пробуем более
    # надёжные источники по очереди, прежде чем сдаться:
    #   1) fmtCtx.duration — обычно точнее всего, когда есть;
    #   2) stream.duration в единицах stream.time_base — доступен чаще,
    #      даже когда контейнер не знает общую длительность;
    #   3) stream.nb_frames / fps — грубая оценка по числу кадров.
    dur =
      if fmtCtx.duration > 0:
        fmtCtx.duration.float / AV_TIME_BASE.float
      elif vStream.duration > 0:
        vStream.duration.float * av_q2d(vStream.time_base)
      elif vStream.nb_frames > 0 and fps > 0.0:
        vStream.nb_frames.float / fps
      else:
        0.0

  result = VideoInfo(
    duration:  dur,
    fps:       fps,
    videoIdx:  vidIdx,
    width:     vStream.codecpar.width,
    height:    vStream.codecpar.height,
    codec:     if decoder != nil: $decoder.name else: "unknown",
    nbStreams: fmtCtx.nb_streams.int,
    fmtCtx:    fmtCtx)

proc closeVideoInfo(vi: var VideoInfo) =
  if vi.fmtCtx != nil:
    avformat_close_input(addr vi.fmtCtx)

# ------------------------------------------------------------------------------
# Планирование сегментов
# ------------------------------------------------------------------------------
type
  Segment = object
    idx:           int
    startSec:      float
    cleanDurSec:   float    # «чистая» длительность — ровно столько попадёт в выход
    overlapAfter:  float    # дополнительная зона чтения (для контекста minterp.)
    outFile:       string

const
  # minterpolate нужен контекст: читаем overlapAfter секунд за пределами сегмента
  OVERLAP_AFTER    = 2.0
  MIN_SEG_DURATION = 4.0   # минимальная «чистая» длительность сегмента

proc planSegments(vi:       VideoInfo;
                  numSeg:   int;
                  tempDir:  string;
                  baseName: string): seq[Segment] =
  ## Делит видео на numSeg (или меньше — если видео слишком короткое)
  ## непересекающихся «чистых» кусков [start, start+cleanDur). Overlap
  ## задаётся отдельно (overlapAfter) — это зона ЧТЕНИЯ сверх сегмента,
  ## нужная minterpolate для сглаживания на стыках; в выходной файл
  ## сегмента она не попадает (см. worker.nim: drainFilter).
  let
    totalDur  = vi.duration
    actualSeg = min(numSeg, max(1, int(totalDur / MIN_SEG_DURATION)))
    segDur    = totalDur / actualSeg.float

  if actualSeg < numSeg:
    echo fmt"[INFO] Сокращаем до {actualSeg} сегментов " &
         fmt"(видео {totalDur:.1f}с, мин. {MIN_SEG_DURATION}с/сегм.)"

  for i in 0..<actualSeg:
    let
      startSec    = i.float * segDur
      cleanDurSec = if i < actualSeg - 1: segDur
                    else: totalDur - startSec   # последний сегмент — до конца
      # Последний сегмент не нуждается в overlap после себя
      overlapAfter = if i < actualSeg - 1: OVERLAP_AFTER else: 0.0

    add(result, Segment(
      idx:          i,
      startSec:     startSec,
      cleanDurSec:  cleanDurSec,
      overlapAfter: overlapAfter,
      outFile:      tempDir / fmt"{baseName}_seg{i:04d}.mkv"))

# ------------------------------------------------------------------------------
# Утилиты вывода
# ------------------------------------------------------------------------------
proc bar(done, total: int; width = 40): string =
  ## Текстовый прогресс-бар вида [████░░░░].
  let f = if total > 0: (done * width) div total else: 0
  "[" & repeat("█", f) & repeat("░", width - f) & "]"

proc renderSegLine(jobId: int; curFrames, totalFrames: int64;
                   state: string;  # "run" | "done" | "fail"
                   errMsg: string; width = 28): string =
  ## Одна строка живого прогресса сегмента: цветной бар + % + кадры.
  ## state="run"  → голубой, ещё считает
  ## state="done" → зелёный, ✓
  ## state="fail" → красный, ✗ + текст ошибки
  let
    # segTotalFrames — это оценка ДО запуска (длительность×fps×множитель),
    # а curFrames для завершённого сегмента — реальное число кадров на
    # выходе энкодера. Небольшое расхождение (округление minterpolate,
    # обрезка на границе overlap) — это норма, а не ошибка обработки.
    # Без этой развязки успешно завершённый сегмент мог навсегда
    # показывать "99.9%" и недорисованный бар, хотя файл полностью готов.
    pct = if state == "done": 100.0
          elif totalFrames > 0: clamp(curFrames.float / totalFrames.float * 100.0, 0.0, 100.0)
          else: 0.0
    filled = if state == "done": width
             else: clamp(int(pct / 100.0 * width.float), 0, width)
    barStr = "[" & repeat("█", filled) & repeat("░", width - filled) & "]"
    color  = case state
             of "done": fgGreen
             of "fail": fgRed
             else:      fgCyan
    mark   = case state
             of "done": "✓"
             of "fail": "✗"
             else:      "…"
    code   = ansiForegroundColorCode(color, bright = true)

  result = fmt"{code}Сег.{jobId:02d} {mark} {barStr}{ansiResetCode}" &
           fmt" {pct:5.1f}%  {curFrames:>6}/{totalFrames:<6} кадров"
  if state == "fail":
    let e = if len(errMsg) > 60: errMsg[0..<60] & "…" else: errMsg
    result &= fmt"{ansiForegroundColorCode(fgRed)}  — {e}{ansiResetCode}"

proc fmtTime(sec: float): string =
  ## Форматирует секунды в ЧЧ:ММ:СС.
  let s = max(0, sec.int)
  fmt"{s div 3600:02d}:{(s mod 3600) div 60:02d}:{s mod 60:02d}"

proc printBanner(cfg: PMIConfig; vi: VideoInfo; nw: int; durationUnknown: bool) =
  echo repeat("═", 64)
  echo fmt"  PMI — Parallel Motion Interpolate  (v{PMI_VERSION})"
  echo repeat("═", 64)
  echo fmt"  Вход:        {cfg.inputFile}"
  echo fmt"  Выход:       {cfg.outputFile}"
  let durStr = if durationUnknown: "неизвестна" else: fmtTime(vi.duration)
  echo fmt"  Видео:       {vi.width}×{vi.height}  {vi.fps:.3f} fps  {durStr}"
  echo fmt"  Кодек вх.:   {vi.codec}  потоков всего: {vi.nbStreams}"
  echo fmt"  Целевой FPS: {cfg.targetFps}"
  echo fmt"  mi_mode={cfg.miMode}  mc={cfg.mcMode}  me={cfg.meMode}  vsbmc={cfg.vsbmc}"
  echo fmt"  x264: CRF={cfg.crf}  preset={cfg.preset}"
  echo fmt"  Потоков:     {nw}  (av_cpu_count={av_cpu_count()})"
  echo repeat("═", 64)

# ------------------------------------------------------------------------------
# Парсинг аргументов
# ------------------------------------------------------------------------------
proc parseArgs(): PMIConfig =
  result = defaultConfig()
  var
    p         = initOptParser(commandLineParams())
    inputSet  = false
    outputSet = false

  proc optVal(p: var OptParser): string =
    ## p.val возвращает пустую строку для "-j 4" / "--fps 60" (значение через
    ## пробел, не через '='). В этом случае вручную забираем следующий токен,
    ## как это уже делалось только для -i/-o. Без этого числовые/строковые
    ## опции через пробел молча остаются со значением по умолчанию, а сам
    ## токен-значение потом ошибочно трактуется как позиционный аргумент.
    if p.val != "":
      return p.val
    next(p)
    if p.kind == cmdArgument:
      return p.key
    return ""

  while true:
    next(p)
    case p.kind
    of cmdEnd: break
    of cmdArgument:
      # Позиционный аргумент: первый необработанный — входной файл
      if not inputSet:
        result.inputFile = p.key
        inputSet = true
    of cmdShortOption, cmdLongOption:
      case p.key
      of "i", "input":
        let v = optVal(p)
        if v != "":
          result.inputFile = v
          inputSet = true
      of "o", "output":
        let v = optVal(p)
        if v != "":
          result.outputFile = v
          outputSet = true
      of "fps":
        let v = optVal(p)
        try: result.targetFps = parseInt(v)
        except: echo "[WARN] Неверный fps: " & v
      of "j", "jobs":
        let v = optVal(p)
        try: result.numWorkers = parseInt(v)
        except: echo "[WARN] Неверное число jobs: " & v
      of "preset":       result.preset    = optVal(p)
      of "crf":
        let v = optVal(p)
        try: result.crf = parseInt(v)
        except: echo "[WARN] Неверный crf: " & v
      of "mi-mode":      result.miMode    = optVal(p)
      of "mc-mode":      result.mcMode    = optVal(p)
      of "me-mode":      result.meMode    = optVal(p)
      of "vsbmc":
        let v = optVal(p)
        try: result.vsbmc = parseInt(v)
        except: echo "[WARN] Неверный vsbmc: " & v
      of "temp-dir":     result.tempDir   = optVal(p)
      of "keep-temp":    result.keepTemp  = true
      of "v", "verbose": result.verbose   = true
      of "h", "help":
        echo fmt"""
PMI — Parallel Motion Interpolate  (v{PMI_VERSION})
Повышение FPS через minterpolate + x264, параллельно по N ядрам.

  PMI [опции] [входной файл]
  PMI -i film.mkv -o film_60fps.mkv --fps=60

ОСНОВНЫЕ:
  -i, --input=FILE     Входной файл (mkv, mp4, avi, ts, ...)
  -o, --output=FILE    Выходной файл (default: output.mkv)
  --fps=N              Целевой FPS: 60, 90, 120 (default: 60)
  -j, --jobs=N         Потоков (default: auto=CPU)

ИНТЕРПОЛЯЦИЯ:
  --mi-mode=MODE       mci|blend|dup (default: mci)
  --mc-mode=MODE       aobmc|obmc (default: aobmc)
  --me-mode=MODE       bidir|bilat (default: bidir)
  --vsbmc=0|1          Variable-size block MC (default: 1)

КОДИРОВАНИЕ:
  --preset=NAME        ultrafast|fast|medium|slow|veryslow (default: slow)
  --crf=N              0-51 (default: 18)

ПРОЧЕЕ:
  --temp-dir=DIR       Папка сегментов (default: .pmi_tmp_*)
  --keep-temp          Не удалять сегменты
  -v, --verbose        AV_LOG_INFO
  -h, --help            Эта справка
  -V, --version         Показать версию
"""
        quit(0)
      of "V", "version":
        echo fmt"PMI (Parallel Motion Interpolate) v{PMI_VERSION}"
        quit(0)
      else:
        echo fmt"[WARN] Неизвестная опция: --{p.key}"

# ------------------------------------------------------------------------------
# Точка входа
# ------------------------------------------------------------------------------
proc main() =
  let cfg = parseArgs()

  if not fileExists(cfg.inputFile):
    echo fmt"[ERROR] Файл не найден: {cfg.inputFile}"
    quit(1)

  # Защита от перезаписи входного файла: сравниваем абсолютные,
  # нормализованные пути (не просто строковое равенство "input.mkv" ==
  # "./input.mkv", которое пропустило бы очевидный кейс).
  if absolutePath(cfg.inputFile) == absolutePath(cfg.outputFile):
    echo fmt"[ERROR] Входной и выходной файл совпадают: {cfg.inputFile}"
    quit(1)

  if cfg.targetFps < 1 or cfg.targetFps > 240:
    echo fmt"[ERROR] Неверный fps={cfg.targetFps}"
    quit(1)

  if cfg.crf < 0 or cfg.crf > 51:
    echo fmt"[ERROR] Неверный crf={cfg.crf} (допустимо 0..51)"
    quit(1)

  if cfg.vsbmc notin [0, 1]:
    echo fmt"[ERROR] Неверный vsbmc={cfg.vsbmc} (допустимо 0 или 1)"
    quit(1)

  const validMiModes  = ["mci", "blend", "dup"]
  const validMcModes  = ["aobmc", "obmc"]
  const validMeModes  = ["bidir", "bilat"]
  const validPresets  = ["ultrafast", "superfast", "veryfast", "faster",
                          "fast", "medium", "slow", "slower", "veryslow", "placebo"]

  if cfg.miMode notin validMiModes:
    echo fmt"[ERROR] Неверный --mi-mode={cfg.miMode} (допустимо: {validMiModes})"
    quit(1)
  if cfg.mcMode notin validMcModes:
    echo fmt"[ERROR] Неверный --mc-mode={cfg.mcMode} (допустимо: {validMcModes})"
    quit(1)
  if cfg.meMode notin validMeModes:
    echo fmt"[ERROR] Неверный --me-mode={cfg.meMode} (допустимо: {validMeModes})"
    quit(1)
  if cfg.preset notin validPresets:
    echo fmt"[ERROR] Неверный --preset={cfg.preset} (допустимо: {validPresets})"
    quit(1)

  # Верхняя граница --jobs: без неё пользователь может случайно запросить
  # сотни ОС-потоков (по одному воркеру на сегмент + внутренние потоки
  # декодера/энкодера в каждом), что скорее навредит производительности,
  # чем поможет (см. README/отчёт, "Performance Findings" #7).
  const MAX_JOBS = 64
  if cfg.numWorkers < 0 or cfg.numWorkers > MAX_JOBS:
    echo fmt"[ERROR] Неверный --jobs={cfg.numWorkers} (допустимо 1..{MAX_JOBS}, 0=авто)"
    quit(1)

  # libav сам пишет свои сообщения прямо в stderr, в обход построчной
  # перерисовки прогресс-бара: redraw() (см. ниже) умеет поднимать курсор
  # ТОЛЬКО на то число строк, которое сама PMI напечатала через echo
  # (cursorUp(stdout, actualSegs)). Любая WARNING-строка от libav — типично
  # "Could not find codec parameters for stream N (Attachment: none)" при
  # открытии контейнера каждым из воркеров (безобидно, см. отчёт находка
  # #6) — физически появляется в терминале между перерисовками и сдвигает
  # весь последующий вывод на одну строку вниз. PMI об этом сдвиге не
  # знает, поэтому следующий cursorUp() поднимается уже не туда — бар
  # необратимо "съезжает" вниз на каждое такое предупреждение (именно это
  # наблюдалось на практике, см. скриншот в обсуждении).
  #
  # В live-TTY режиме поэтому глушим WARNING полностью — ERROR всё равно
  # почти всегда приводит к немедленному исключению через ffCheck и
  # остановке процесса, так что проглатывать WARNING здесь не опасно.
  # Вне TTY (вывод в файл/pipe) перерисовки нет — сдвигать нечего, там
  # поведение прежнее.
  av_log_set_level(
    if stdoutIsTty: AV_LOG_ERROR
    elif cfg.verbose: AV_LOG_INFO
    else: AV_LOG_WARNING)

  if cfg.verbose and stdoutIsTty:
    echo "[INFO] --verbose с live-прогрессом в терминале не совместим " &
         "(WARNING-строки libav ломают перерисовку бара выше) — " &
         "подробный лог libav отключён на время этого запуска. Для " &
         "полного лога перенаправьте вывод в файл: PMI ... > pmi.log 2>&1"

  let
    cpuCount   = av_cpu_count().int
    numWorkers = if cfg.numWorkers > 0: cfg.numWorkers else: max(1, cpuCount)

  var vi = probeVideo(cfg.inputFile)
  defer: closeVideoInfo(vi)

  # Раньше duration==0.0 (контейнер/поток не сообщают длительность — типично
  # для TS/broadcast-источников) неотличимо трактовалось как "видео короче
  # 4 секунд" и приводило к жёсткому отказу, хотя README документирует
  # поддержку именно таких TS-источников (см. отчёт, находка #12).
  #
  # Явный "неизвестно" (0.0) больше не считается "слишком коротким". Но
  # многосегментное планирование по большой оценке-заглушке было бы опасно:
  # все сегменты, кроме первого, стартовали бы far beyond реального EOF,
  # их воркеры ничего не декодировали бы и завершались с ошибкой — а после
  # фикса находки #3 (полный отказ при любом упавшем сегменте, см. main())
  # это привело бы к отказу всего прогона. Поэтому при неизвестной
  # длительности принудительно используем один сегмент (без параллелизма):
  # единственный воркер честно читает файл до настоящего EOF.
  var unknownDuration = false
  const UNKNOWN_DURATION_FALLBACK = 24.0 * 3600.0  # только для планирования
  if vi.duration <= 0.0:
    echo "[WARN] Не удалось определить длительность видео " &
         "(контейнер/поток её не сообщают) — сегментация отключена " &
         "(--jobs игнорируется), файл будет обработан одним потоком."
    vi.duration = UNKNOWN_DURATION_FALLBACK
    unknownDuration = true
  elif vi.duration < MIN_SEG_DURATION:
    echo fmt"[ERROR] Видео слишком короткое ({vi.duration:.1f}с)"
    quit(1)

  if vi.fps >= cfg.targetFps.float - 0.5:
    echo fmt"[WARN] Входной FPS ({vi.fps:.2f}) >= целевого ({cfg.targetFps})"

  let effectiveWorkers = if unknownDuration: 1 else: numWorkers
  printBanner(cfg, vi, effectiveWorkers, unknownDuration)

  let
    outDir  = parentDir(cfg.outputFile)
    outBase = splitFile(cfg.outputFile).name
    tempDir = if cfg.tempDir != "": cfg.tempDir
              else: (if outDir == "": "." else: outDir) / fmt".pmi_tmp_{outBase}"

  # Удаляем temp-dir на выходе ТОЛЬКО если он не существовал до этого запуска
  # и мы сами его создали — иначе `--temp-dir=/tmp` (или любой другой уже
  # существующий/общий каталог) мог бы быть рекурсивно удалён целиком со
  # всем посторонним содержимым. Если каталог уже существовал, PMI никогда
  # не удаляет его сам, вне зависимости от --keep-temp.
  let tempDirPreexisted = dirExists(tempDir)
  createDir(tempDir)
  defer:
    if not tempDirPreexisted and not cfg.keepTemp and dirExists(tempDir):
      removeDir(tempDir)

  let
    segments   = planSegments(vi, effectiveWorkers, tempDir, outBase)
    actualSegs = len(segments)

  echo fmt"[INFO] Длительность: " &
       (if unknownDuration: "неизвестна (TS/broadcast?)" else: fmtTime(vi.duration))
  if actualSegs > 1:
    echo fmt"[INFO] Сегментов:    {actualSegs}  " &
         fmt"(≈{fmtTime(vi.duration / actualSegs.float)} каждый)"
  else:
    echo fmt"[INFO] Сегментов:    {actualSegs} (без сегментации)"
  echo ""

  open(resultChan, actualSegs)
  defer: close(resultChan)

  let slicesPerWorker = max(1, cpuCount div max(1, actualSegs))
  var threads = newSeq[Thread[SegmentJob]](actualSegs)
  let wallStart = getMonoTime()

  # Ожидаемое число выходных кадров на сегмент (для % и живого бара) —
  # оценка по cleanDurSec*targetFps; фактическое outFrameCount может чуть
  # отличаться (округления PTS у minterpolate), поэтому бар допускает
  # переполнение за 100% и просто зажимается clamp'ом в renderSegLine.
  let segTotalFrames = mapIt(segments,
    max(1'i64, int64(it.cleanDurSec * cfg.targetFps.float + 0.5)))

  worker.initProgress(actualSegs)
  defer: worker.freeProgress()

  for i, seg in segments:
    let job = SegmentJob(
      jobId:         i,
      inputFile:     cfg.inputFile,
      outputFile:    seg.outFile,
      startTime:     seg.startSec,
      cleanDuration: seg.cleanDurSec,
      overlapAfter:  seg.overlapAfter,
      videoIdx:      vi.videoIdx,
      targetFps:     cfg.targetFps,
      miMode:        cfg.miMode,
      mcMode:        cfg.mcMode,
      meMode:        cfg.meMode,
      vsbmc:         cfg.vsbmc,
      preset:        cfg.preset,
      crf:           cfg.crf,
      threadSlices:  slicesPerWorker)

    createThread(threads[i], workerThread, job)
    echo fmt"[LAUNCH] Поток {i:2d} | start={fmtTime(seg.startSec)}" &
         fmt" clean={fmtTime(seg.cleanDurSec)} → {extractFilename(seg.outFile)}"

  echo ""

  var
    results   = newSeq[SegmentResult](actualSegs)
    doneMask  = newSeq[bool](actualSegs)
    doneCount = 0
    errors:   seq[string] = @[]

  if stdoutIsTty:
    # ── Живой цветной прогресс: перерисовка actualSegs строк в терминале ──
    var states  = newSeq[string](actualSegs)
    for i in 0..<actualSegs: states[i] = "run"

    proc redraw(firstDraw: bool) =
      if not firstDraw: cursorUp(stdout, actualSegs)
      for i in 0..<actualSegs:
        # Явный \r перед eraseLine: cursorUp() двигает курсор только ВВЕРХ,
        # колонку не трогает. Если предыдущая печать оставила курсор не в
        # колонке 0 (например, из-за терминала/PTY, где перевод строки не
        # гарантированно возвращает каретку в начало), erase+echo пишут
        # поверх старой строки со сдвигом, а не заменяют её — визуально это
        # выглядит как "размножение" строки прогресса вместо перерисовки на
        # месте (наблюдалось на практике). \r убирает эту зависимость от
        # поведения терминала.
        stdout.write("\r")
        eraseLine(stdout)
        let cur = if doneMask[i]: results[i].outFrameCount
                  else: worker.getProgress(i)
        let err = if doneMask[i] and not results[i].success: results[i].errorMsg
                  else: ""
        echo renderSegLine(i, cur, segTotalFrames[i], states[i], err)

    hideCursor(stdout)
    redraw(firstDraw = true)

    while doneCount < actualSegs:
      # Неблокирующе забираем завершённые сегменты, не мешая перерисовке.
      var gotAny = false
      while true:
        let (avail, res) = tryRecv(resultChan)
        if not avail: break
        gotAny = true
        results[res.jobId]  = res
        doneMask[res.jobId] = true
        states[res.jobId]   = if res.success: "done" else: "fail"
        inc doneCount
        if not res.success:
          add(errors, fmt"Segment {res.jobId}: {res.errorMsg}")

      redraw(firstDraw = false)
      if doneCount < actualSegs:
        sleep(if gotAny: 0 else: 200)  # без задержки сразу после события

    showCursor(stdout)
    echo ""
  else:
    # Не терминал (лог/pipe) — построчный вывод без перемещения курсора,
    # чтобы не засорять лог ANSI-кодами.
    while doneCount < actualSegs:
      let res = recv(resultChan)
      results[res.jobId] = res
      doneMask[res.jobId] = true
      inc doneCount

      let
        elapsed = inSeconds(getMonoTime() - wallStart).float
        eta = if doneCount < actualSegs:
          elapsed / doneCount.float * (actualSegs - doneCount).float
        else: 0.0

      if res.success:
        let sz = if fileExists(res.outputFile):
          getFileSize(res.outputFile) div (1024*1024) else: 0i64
        echo fmt"[DONE {doneCount:2d}/{actualSegs}] Сег.{res.jobId:02d}" &
             fmt" | dec={res.frameCount} enc={res.outFrameCount}" &
             fmt" dur={res.durationSec:.2f}s" &
             fmt" | {sz} МБ | ETA {fmtTime(eta)}  {bar(doneCount, actualSegs)}"
      else:
        echo fmt"[FAIL  {doneCount:2d}/{actualSegs}] Сег.{res.jobId:02d}: {res.errorMsg}"
        add(errors, fmt"Segment {res.jobId}: {res.errorMsg}")

  for i in 0..<actualSegs: joinThread(threads[i])

  let wallElapsed = inSeconds(getMonoTime() - wallStart).float
  echo ""
  echo fmt"[INFO] Потоки завершены за {fmtTime(wallElapsed)}"

  if len(errors) > 0:
    echo fmt"[ERROR] {len(errors)}/{actualSegs} сегментов провалились"
    for e in errors: echo fmt"  • {e}"
    # Раньше PMI склеивал оставшиеся успешные сегменты даже при частичном
    # провале. Это приводило к тихой потере кусков видео: индексы и
    # временные разрывы неудавшихся сегментов нигде не сохраняются, и
    # concatSegments не может ни вставить видимый пропуск, ни хотя бы
    # предупредить — на выходе получался повреждённый/рассинхронизированный
    # файл, который выглядел как обычный успешный результат (см. отчёт,
    # находки #3 и #20). Пока склейка не умеет честно обрабатывать частичный
    # результат (сохранять индексы сегментов, вставлять явные пропуски),
    # безопаснее полностью остановиться.
    echo "[ERROR] Склейка отменена: без всех сегментов результат будет " &
         "повреждён/рассинхронизирован. Запустите заново или используйте " &
         "--keep-temp, чтобы разобрать причину сбоя вручную."
    quit(1)

  echo ""
  echo "[CONCAT] Начинаем склейку..."

  let sortedResults = sortedByIt(results, it.jobId)

  # Реальные длительности успешных сегментов (в секундах) — идут парой
  # с segFiles: индекс i в обоих seq соответствует одному и тому же сегменту.
  let
    segFiles = mapIt(
      filterIt(sortedResults, it.success and fileExists(it.outputFile)),
      it.outputFile)
    segDurs = mapIt(
      filterIt(sortedResults, it.success and fileExists(it.outputFile)),
      it.durationSec)

  if len(segFiles) == 0:
    echo "[ERROR] Нет успешных сегментов."
    quit(1)

  concatSegments(
    segFiles   = segFiles,
    segDurs    = segDurs,
    srcFile    = cfg.inputFile,
    outputFile = cfg.outputFile,
    srcFmtCtx  = vi.fmtCtx,
    videoIdx   = vi.videoIdx,
    targetFps  = cfg.targetFps)

  let totalWall = inSeconds(getMonoTime() - wallStart).float
  let outSize   = if fileExists(cfg.outputFile):
    getFileSize(cfg.outputFile) div (1024*1024) else: 0i64

  let
    inFrames  = foldl(mapIt(filterIt(results, it.success), it.frameCount), a + b, 0i64)
    outFrames = foldl(mapIt(filterIt(results, it.success), it.outFrameCount), a + b, 0i64)

  echo ""
  echo repeat("═", 64)
  echo "  PMI — Готово!"
  echo repeat("═", 64)
  echo fmt"  Выходной файл:  {cfg.outputFile}  ({outSize} МБ)"
  echo fmt"  Общее время:    {fmtTime(totalWall)}"
  if not unknownDuration:
    echo fmt"  Ускорение:      ×{vi.duration / max(1.0, totalWall):.2f} к реальному"
  echo fmt"  Кадров вход:    {inFrames}"
  echo fmt"  Кадров выход:   {outFrames}"
  if inFrames > 0:
    echo fmt"  Мультипликатор: ×{outFrames.float / inFrames.float:.2f}"
  echo repeat("═", 64)

when isMainModule:
  main()
