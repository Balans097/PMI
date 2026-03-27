# ==============================================================================
#  PMI.nim  — Parallel Motion Interpolate  (v3)
#
#  ИЗМЕНЕНИЯ v3:
#   • planSegments: сегменты планируются как [start, start+cleanDur) без overlap,
#     overlap задаётся отдельным полем overlapAfter для контекста minterpolate.
#   • SegmentJob содержит cleanDuration + overlapAfter вместо одного duration.
#   • concatSegments принимает segDurs (реальные длительности из результатов)
#     и targetFps для правильного рассчёта PTS.
#   • Прогресс: выводим реальную durationSec из результата.
# ==============================================================================

{.experimental: "parallel".}

import std/[strformat, strutils, parseopt, os, math,
            times, monotimes, sequtils, algorithm]
import ffmpeg_api
import worker
import concat

# ------------------------------------------------------------------------------
# Конфигурация
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
    numWorkers:  int    # 0 = auto
    tempDir:     string
    keepTemp:    bool
    verbose:     bool

proc defaultConfig(): PMIConfig =
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
# Информация о видео
# ------------------------------------------------------------------------------
type
  VideoInfo = object
    duration:  float
    fps:       float
    videoIdx:  int
    width:     int
    height:    int
    codec:     string
    nbStreams: int
    fmtCtx:    ptr AVFormatContext

proc probeVideo(path: string): VideoInfo =
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

  let vStream = fmtCtx.streams[vidIdx]
  let dur = if fmtCtx.duration > 0:
    fmtCtx.duration.float / AV_TIME_BASE.float
  else: 0.0

  result = VideoInfo(
    duration:  dur,
    fps:       getStreamFps(vStream),
    videoIdx:  vidIdx,
    width:     vStream.codecpar.width,
    height:    vStream.codecpar.height,
    codec:     if decoder != nil: $decoder.name else: "unknown",
    nbStreams:  fmtCtx.nb_streams.int,
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

# minterpolate нужен контекст: читаем overlapAfter секунд за пределами сегмента
const OVERLAP_AFTER  = 2.0
const MIN_SEG_DURATION = 4.0   # минимальная «чистая» длительность сегмента

proc planSegments(vi:       VideoInfo;
                  numSeg:   int;
                  tempDir:  string;
                  baseName: string): seq[Segment] =

  let totalDur  = vi.duration
  let actualSeg = min(numSeg, max(1, int(totalDur / MIN_SEG_DURATION)))
  let segDur    = totalDur / actualSeg.float

  if actualSeg < numSeg:
    echo fmt"[INFO] Сокращаем до {actualSeg} сегментов " &
         fmt"(видео {totalDur:.1f}с, мин. {MIN_SEG_DURATION}с/сегм.)"

  for i in 0..<actualSeg:
    let startSec    = i.float * segDur
    let cleanDurSec = if i < actualSeg - 1: segDur
                      else: totalDur - startSec   # последний сегмент — до конца
    # Последний сегмент не нуждается в overlap после себя
    let overlapAfter = if i < actualSeg - 1: OVERLAP_AFTER else: 0.0

    result.add(Segment(
      idx:          i,
      startSec:     startSec,
      cleanDurSec:  cleanDurSec,
      overlapAfter: overlapAfter,
      outFile:      tempDir / fmt"{baseName}_seg{i:04d}.mkv"))

# ------------------------------------------------------------------------------
# Утилиты вывода
# ------------------------------------------------------------------------------
proc bar(done, total: int; width = 40): string =
  let f = if total > 0: (done * width) div total else: 0
  "[" & "█".repeat(f) & "░".repeat(width - f) & "]"

proc fmtTime(sec: float): string =
  let s = max(0, sec.int)
  fmt"{s div 3600:02d}:{(s mod 3600) div 60:02d}:{s mod 60:02d}"

proc printBanner(cfg: PMIConfig; vi: VideoInfo; nw: int) =
  echo "═".repeat(64)
  echo "  PMI — Parallel Motion Interpolate"
  echo "═".repeat(64)
  echo fmt"  Вход:        {cfg.inputFile}"
  echo fmt"  Выход:       {cfg.outputFile}"
  echo fmt"  Видео:       {vi.width}×{vi.height}  {vi.fps:.3f} fps  {fmtTime(vi.duration)}"
  echo fmt"  Кодек вх.:   {vi.codec}  потоков всего: {vi.nbStreams}"
  echo fmt"  Целевой FPS: {cfg.targetFps}"
  echo fmt"  mi_mode={cfg.miMode}  mc={cfg.mcMode}  me={cfg.meMode}  vsbmc={cfg.vsbmc}"
  echo fmt"  x264: CRF={cfg.crf}  preset={cfg.preset}"
  echo fmt"  Потоков:     {nw}  (av_cpu_count={av_cpu_count()})"
  echo "═".repeat(64)

# ------------------------------------------------------------------------------
# Парсинг аргументов
# ------------------------------------------------------------------------------
proc parseArgs(): PMIConfig =
  result = defaultConfig()
  var p = initOptParser(commandLineParams())
  var inputSet  = false
  var outputSet = false
  while true:
    p.next()
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
        let v = p.val
        if v != "":
          result.inputFile = v
          inputSet = true
        else:
          # "-i filename" через пробел — следующий токен
          p.next()
          if p.kind == cmdArgument:
            result.inputFile = p.key
            inputSet = true
      of "o", "output":
        let v = p.val
        if v != "":
          result.outputFile = v
          outputSet = true
        else:
          p.next()
          if p.kind == cmdArgument:
            result.outputFile = p.key
            outputSet = true
      of "fps":
        try: result.targetFps = parseInt(p.val)
        except: echo "[WARN] Неверный fps: " & p.val
      of "j", "jobs":
        try: result.numWorkers = parseInt(p.val)
        except: echo "[WARN] Неверное число jobs: " & p.val
      of "preset":       result.preset    = p.val
      of "crf":
        try: result.crf = parseInt(p.val)
        except: discard
      of "mi-mode":      result.miMode    = p.val
      of "mc-mode":      result.mcMode    = p.val
      of "me-mode":      result.meMode    = p.val
      of "vsbmc":
        try: result.vsbmc = parseInt(p.val)
        except: discard
      of "temp-dir":     result.tempDir   = p.val
      of "keep-temp":    result.keepTemp  = true
      of "v", "verbose": result.verbose   = true
      of "h", "help":
        echo """
PMI — Parallel Motion Interpolate
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
  -h, --help           Эта справка
"""
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

  if cfg.targetFps < 1 or cfg.targetFps > 240:
    echo fmt"[ERROR] Неверный fps={cfg.targetFps}"
    quit(1)

  av_log_set_level(if cfg.verbose: AV_LOG_INFO else: AV_LOG_WARNING)

  let cpuCount   = av_cpu_count().int
  let numWorkers = if cfg.numWorkers > 0: cfg.numWorkers
                   else: max(1, cpuCount)

  var vi = probeVideo(cfg.inputFile)
  defer: closeVideoInfo(vi)

  if vi.duration < MIN_SEG_DURATION:
    echo fmt"[ERROR] Видео слишком короткое ({vi.duration:.1f}с)"
    quit(1)

  if vi.fps >= cfg.targetFps.float - 0.5:
    echo fmt"[WARN] Входной FPS ({vi.fps:.2f}) >= целевого ({cfg.targetFps})"

  printBanner(cfg, vi, numWorkers)

  let outDir  = cfg.outputFile.parentDir
  let outBase = cfg.outputFile.splitFile.name
  let tempDir = if cfg.tempDir != "": cfg.tempDir
                else: (if outDir == "": "." else: outDir) / fmt".pmi_tmp_{outBase}"

  createDir(tempDir)
  defer:
    if not cfg.keepTemp and dirExists(tempDir):
      removeDir(tempDir)

  let segments   = planSegments(vi, numWorkers, tempDir, outBase)
  let actualSegs = segments.len

  echo fmt"[INFO] Длительность: {fmtTime(vi.duration)}"
  echo fmt"[INFO] Сегментов:    {actualSegs}  " &
       fmt"(≈{fmtTime(vi.duration / actualSegs.float)} каждый)"
  echo ""

  resultChan.open(actualSegs)
  defer: resultChan.close()

  let slicesPerWorker = max(1, cpuCount div max(1, actualSegs))
  var threads = newSeq[Thread[SegmentJob]](actualSegs)
  let wallStart = getMonoTime()

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
         fmt" clean={fmtTime(seg.cleanDurSec)} → {seg.outFile.extractFilename}"

  echo ""

  var results   = newSeq[SegmentResult](actualSegs)
  var doneCount = 0
  var errors:   seq[string] = @[]

  while doneCount < actualSegs:
    let res = resultChan.recv()
    results[res.jobId] = res
    inc doneCount

    let elapsed = (getMonoTime() - wallStart).inSeconds.float
    let eta = if doneCount < actualSegs:
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
      errors.add(fmt"Segment {res.jobId}: {res.errorMsg}")

  for i in 0..<actualSegs: joinThread(threads[i])

  let wallElapsed = (getMonoTime() - wallStart).inSeconds.float
  echo ""
  echo fmt"[INFO] Потоки завершены за {fmtTime(wallElapsed)}"

  if errors.len > 0:
    echo fmt"[ERROR] {errors.len}/{actualSegs} сегментов провалились"
    for e in errors: echo fmt"  • {e}"
    if errors.len == actualSegs:
      echo "[ERROR] Все сегменты провалились."
      quit(1)
    echo "[WARN] Склеиваем успешные сегменты..."

  echo ""
  echo "[CONCAT] Начинаем склейку..."

  let sortedResults = results.sortedByIt(it.jobId)

  let segFiles = sortedResults
    .filterIt(it.success and fileExists(it.outputFile))
    .mapIt(it.outputFile)

  # Реальные длительности успешных сегментов (в секундах)
  let segDurs = sortedResults
    .filterIt(it.success and fileExists(it.outputFile))
    .mapIt(it.durationSec)

  if segFiles.len == 0:
    echo "[ERROR] Нет успешных сегментов."
    quit(1)

  concat.concatSegments(
    segFiles   = segFiles,
    segDurs    = segDurs,
    srcFile    = cfg.inputFile,
    outputFile = cfg.outputFile,
    srcFmtCtx  = vi.fmtCtx,
    videoIdx   = vi.videoIdx,
    targetFps  = cfg.targetFps)

  let totalWall = (getMonoTime() - wallStart).inSeconds.float
  let outSize   = if fileExists(cfg.outputFile):
    getFileSize(cfg.outputFile) div (1024*1024) else: 0i64

  let inFrames  = results.filterIt(it.success).mapIt(it.frameCount).foldl(a+b, 0i64)
  let outFrames = results.filterIt(it.success).mapIt(it.outFrameCount).foldl(a+b, 0i64)

  echo ""
  echo "═".repeat(64)
  echo "  PMI — Готово!"
  echo "═".repeat(64)
  echo fmt"  Выходной файл:  {cfg.outputFile}  ({outSize} МБ)"
  echo fmt"  Общее время:    {fmtTime(totalWall)}"
  echo fmt"  Ускорение:      ×{vi.duration / max(1.0, totalWall):.2f} к реальному"
  echo fmt"  Кадров вход:    {inFrames}"
  echo fmt"  Кадров выход:   {outFrames}"
  if inFrames > 0:
    echo fmt"  Мультипликатор: ×{outFrames.float / inFrames.float:.2f}"
  echo "═".repeat(64)

when isMainModule:
  main()
