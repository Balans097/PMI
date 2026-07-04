# ==============================================================================
#  concat.nim  — склейка сегментов в финальный файл  (v1.3)
#
#  АРХИТЕКТУРА v3:
#   1. Видеосегменты склеиваются последовательно.
#      Каждый сегмент содержит PTS от 0; мы добавляем накопленный offset.
#      offset обновляется по реальному числу кадров сегмента (outFrameCount).
#   2. Аудио и субтитры копируются из исходника ВМЕСТЕ с видео через
#      av_interleaved_write_frame — это единственный способ гарантировать
#      правильный interleave и синхронизацию.
#      Аудио-пакеты пишутся сразу, как только их PTS попадает в текущее
#      временное окно видео.
#   3. PtsClock на каждый поток гарантирует монотонность DTS.
#
#  ИСПРАВЛЕНИЯ v1.3:
#   • vidPkt объявлялся через `let`, а defer брал его адрес (`addr vidPkt`)
#     для av_packet_free — как и в worker.nim, это ошибка компиляции
#     ("expression has no address"). Исправлено на `var`.
#   • Убран неиспользуемый import std/math.
#
#  ИСПРАВЛЕНИЯ v3 относительно v2:
#   • Аудио/субтитры больше НЕ копируются отдельным проходом в конце.
#     Это устраняло рассинхронизацию: видео удлиняется (minterpolate добавляет
#     кадры), а аудио оставалось с оригинальными PTS.
#   • concatSegments теперь открывает srcFile один раз и читает все потоки
#     параллельно с видео-сегментами, используя временны́е метки для
#     синхронного мультиплексирования.
#   • segDurations (seq[float]) передаётся в concat, чтобы знать точные
#     границы каждого сегмента в выходном времени.
# ==============================================================================

import std/[strformat, os]
import ffmpeg_api

# ------------------------------------------------------------------------------
# PTS-часы: гарантия монотонности DTS
# ------------------------------------------------------------------------------
type
  PtsClock = object
    lastDts:     int64
    initialized: bool

proc advance(clk: var PtsClock; pts, dts: int64): tuple[pts, dts: int64] =
  var
    outDts = dts
    outPts = pts

  if clk.initialized:
    if outDts <= clk.lastDts:
      outDts = clk.lastDts + 1
    if outPts != AV_NOPTS_VALUE and outPts < outDts:
      outPts = outDts
  else:
    clk.initialized = true

  clk.lastDts = outDts
  result = (outPts, outDts)

# ------------------------------------------------------------------------------
# Маппинг аудио/субтитров исходника → выходной файл
# ------------------------------------------------------------------------------
type
  StreamMap = object
    inIdx:  cint
    outIdx: cint
    inTB:   AVRational

# ------------------------------------------------------------------------------
# Главная функция склейки
# ------------------------------------------------------------------------------
proc concatSegments*(segFiles:    seq[string];
                     segDurs:     seq[float];   # реальная dur каждого сегмента (сек)
                     srcFile:     string;
                     outputFile:  string;
                     srcFmtCtx:   ptr AVFormatContext;
                     videoIdx:    int;
                     targetFps:   int) =

  echo fmt"[CONCAT] Склейка {len(segFiles)} сегментов → {outputFile}"

  if len(segFiles) == 0:
    raise newException(IOError, "concat: нет сегментов")

  # ── Параметры видео из первого сегмента ───────────────────────────────
  var refFmt: ptr AVFormatContext
  ffCheck(
    avformat_open_input(addr refFmt, segFiles[0].cstring, nil, nil),
    "concat: open first segment")
  defer: avformat_close_input(addr refFmt)

  ffCheck(avformat_find_stream_info(refFmt, nil),
          "concat: find_stream_info first segment")

  var refVidIdx: cint = -1
  for i in 0..<refFmt.nb_streams.int:
    if isVideoStream(refFmt.streams[i]):
      refVidIdx = i.cint
      break
  if refVidIdx < 0:
    raise newException(IOError, "concat: видеопоток не найден в первом сегменте")

  let vidTB = refFmt.streams[refVidIdx].time_base   # time_base выходного видео

  # ── Создаём выходной контекст ──────────────────────────────────────────
  var outFmt: ptr AVFormatContext
  ffCheck(
    avformat_alloc_output_context2(
      addr outFmt, nil, nil, outputFile.cstring),
    "concat: alloc output context")
  defer:
    if outFmt != nil:
      if outFmt.pb != nil: discard avio_closep(addr outFmt.pb)
      avformat_free_context(outFmt)

  # ── Видеопоток ─────────────────────────────────────────────────────────
  let outVidStream = avformat_new_stream(outFmt, nil)
  if outVidStream == nil:
    raise newException(IOError, "concat: new video stream failed")
  let outVidIdx = outVidStream.index

  ffCheck(
    avcodec_parameters_copy(outVidStream.codecpar,
                             refFmt.streams[refVidIdx].codecpar),
    "concat: parameters_copy video")
  outVidStream.codecpar.codec_tag = 0.cuint
  outVidStream.time_base = vidTB
  discard av_dict_copy(addr outVidStream.metadata,
                        srcFmtCtx.streams[videoIdx].metadata, 0.cint)
  outVidStream.disposition = srcFmtCtx.streams[videoIdx].disposition

  # ── Аудио / субтитры из исходника ─────────────────────────────────────
  var maps: seq[StreamMap] = @[]

  for i in 0..<srcFmtCtx.nb_streams.int:
    if i == videoIdx: continue
    let inStream = srcFmtCtx.streams[i]
    let mtype = inStream.codecpar.codec_type
    if mtype != AVMEDIA_TYPE_AUDIO and mtype != AVMEDIA_TYPE_SUBTITLE:
      echo fmt"  [CONCAT] Пропускаем поток {i} (тип={mtype.cint})"
      continue

    let outStream = avformat_new_stream(outFmt, nil)
    if outStream == nil:
      echo fmt"  [WARN] concat: new stream failed for input {i}"
      continue

    ffCheck(avcodec_parameters_copy(outStream.codecpar, inStream.codecpar),
            fmt"concat: parameters_copy stream {i}")
    outStream.codecpar.codec_tag = 0.cuint
    outStream.time_base = inStream.time_base
    # Раньше копировались только параметры кодека — язык, title,
    # default/forced-флаги и прочие метаданные потока терялись (см. отчёт,
    # находка #17). av_dict_copy(..., 0) добавляет к уже имеющимся ключам;
    # outStream.metadata на новом потоке nil, так что это просто копия.
    discard av_dict_copy(addr outStream.metadata, inStream.metadata, 0.cint)
    outStream.disposition = inStream.disposition

    add(maps, StreamMap(
      inIdx:  i.cint,
      outIdx: outStream.index,
      inTB:   inStream.time_base))

    echo fmt"  [CONCAT] Поток {i} ({mtype.cint}) → вых.{outStream.index}"

  # ── Заголовок ─────────────────────────────────────────────────────────
  ffCheck(avio_open(addr outFmt.pb, outputFile.cstring, AVIO_FLAG_WRITE),
          "concat: avio_open: " & outputFile)
  ffCheck(avformat_write_header(outFmt, nil), "concat: write_header")

  # ── PtsClock для каждого выходного потока ─────────────────────────────
  var
    vidClk: PtsClock
    auxClocks = newSeq[PtsClock](len(maps))

  # ── Открываем исходник для аудио/субтитров ────────────────────────────
  # Аудио/субтитры читаем и мультиплексируем синхронно с видео.
  var srcFmt: ptr AVFormatContext
  let hasMaps = len(maps) > 0
  if hasMaps:
    if avformat_open_input(addr srcFmt, srcFile.cstring, nil, nil) < 0:
      echo "[WARN] concat: не удалось открыть исходник для аудио"
      srcFmt = nil
    elif avformat_find_stream_info(srcFmt, nil) < 0:
      echo "[WARN] concat: find_stream_info failed"
      avformat_close_input(addr srcFmt)
      srcFmt = nil

  defer:
    if srcFmt != nil:
      avformat_close_input(addr srcFmt)

  # ── Инкрементальный читатель аудио/субтитров ──────────────────────────
  #
  # РАНЬШЕ: перед каждым видео-сегментом код вычитывал и писал СРАЗУ весь
  # аудио/субтитровый диапазон этого сегмента (до 13+ минут — десятки
  # тысяч пакетов) одним проходом, и только потом переходил к видео-
  # пакетам того же сегмента. av_interleaved_write_frame формально не
  # терял данные, но matroska-мультиплексор получал на вход гигантский
  # чисто-аудио диапазон без единого видео-пакета рядом — на выходе
  # получались патологически организованные Cluster'ы, из-за которых
  # строгие плееры (VLC, GStreamer/GNOME) не проигрывали звук, хотя сам
  # аудиопоток был технически цел (перемукс через mkvtoolnix, который
  # перестраивает кластеры с нуля без перекодирования, файл чинил — это
  # и было диагностическим признаком, см. ffprobe: потоки идентичны).
  #
  # ТЕПЕРЬ: аудио/субтитры читаются и пишутся небольшими порциями, никогда
  # не уходя дальше AUDIO_LOOKAHEAD_SEC вперёд текущего видео-PTS — так
  # же, как обычный ffmpeg-мультиплексор чередует потоки при обычном
  # транскодировании.
  const AUDIO_LOOKAHEAD_SEC = 2.0

  var
    auxPkt:     ptr AVPacket = nil
    auxPending: bool = false
    auxMapIdx:  int = -1
    auxPktSec:  float = 0.0

  if hasMaps:
    auxPkt = av_packet_alloc()
  defer:
    if auxPkt != nil: av_packet_free(addr auxPkt)

  proc findMap(streamIdx: cint): int =
    for i, m in maps:
      if m.inIdx == streamIdx: return i
    -1

  proc readNextAux(): bool =
    ## Читает следующий пакет из ЗАМАПЛЕННОГО (аудио/суб) потока в auxPkt.
    ## Немаппленные потоки (вложения и т.п.) молча пропускаются.
    if srcFmt == nil: return false
    while true:
      let rd = av_read_frame(srcFmt, auxPkt)
      if rd < 0: return false
      let mi = findMap(auxPkt.stream_index)
      if mi >= 0:
        auxMapIdx = mi
        let rawPts = if auxPkt.pts != AV_NOPTS_VALUE: auxPkt.pts else: auxPkt.dts
        auxPktSec = if rawPts != AV_NOPTS_VALUE:
          av_q2d(maps[mi].inTB) * rawPts.float
        else: 0.0
        return true
      else:
        av_packet_unref(auxPkt)

  proc writeAuxPacket() =
    let m = maps[auxMapIdx]
    let outStream = outFmt.streams[m.outIdx]

    var outPts = if auxPkt.pts != AV_NOPTS_VALUE:
      av_rescale_q_rnd(auxPkt.pts, m.inTB, outStream.time_base,
                        AV_ROUND_NI_PASS)
    else: AV_NOPTS_VALUE

    var outDts = if auxPkt.dts != AV_NOPTS_VALUE:
      av_rescale_q_rnd(auxPkt.dts, m.inTB, outStream.time_base,
                        AV_ROUND_NI_PASS)
    else: AV_NOPTS_VALUE

    let outDur = if auxPkt.duration > 0:
      av_rescale_q(auxPkt.duration, m.inTB, outStream.time_base)
    else: 0'i64

    if outDts != AV_NOPTS_VALUE:
      let (mPts, mDts) = advance(auxClocks[auxMapIdx], outPts, outDts)
      auxPkt.pts = mPts
      auxPkt.dts = mDts
    else:
      auxPkt.pts = outPts
      auxPkt.dts = outDts

    auxPkt.stream_index = m.outIdx
    auxPkt.duration     = outDur
    auxPkt.pos          = -1

    ffCheckWarn(av_interleaved_write_frame(outFmt, auxPkt),
                fmt"concat: aux write (stream {m.inIdx})")

  proc flushAudioUpTo(limitSec: float) =
    ## Пишет все ожидающие аудио/суб-пакеты с временем <= limitSec.
    if not hasMaps or srcFmt == nil: return
    if not auxPending:
      auxPending = readNextAux()
    while auxPending and auxPktSec <= limitSec:
      writeAuxPacket()
      av_packet_unref(auxPkt)
      auxPending = readNextAux()

  # ── Обрабатываем сегменты последовательно ────────────────────────────
  var
    # vidPtsOffset — накопленный PTS в единицах vidTB, куда начинается
    # следующий сегмент.
    vidPtsOffset: int64 = 0
    # Для аудио: сколько секунд уже записано видео (для синхронизации)
    videoTimeSec: float = 0.0

  for segIdx, segFile in segFiles:
    echo fmt"  [CONCAT] сег.{segIdx}: {extractFilename(segFile)}  offset={vidPtsOffset}"

    if not fileExists(segFile):
      echo fmt"  [WARN] сегмент не найден: {segFile}"
      # Пропускаем, но обновляем offset по ожидаемой длительности
      if segIdx < len(segDurs):
        let nFrames = int64(segDurs[segIdx] * targetFps.float + 0.5)
        vidPtsOffset += av_rescale_q(nFrames, makeRat(1, targetFps), vidTB)
        videoTimeSec += segDurs[segIdx]
      continue

    var segFmt: ptr AVFormatContext
    ffCheck(
      avformat_open_input(addr segFmt, segFile.cstring, nil, nil),
      "concat: open " & segFile)
    defer: avformat_close_input(addr segFmt)

    ffCheck(avformat_find_stream_info(segFmt, nil),
            "concat: find_stream_info " & segFile)

    var segVidIdx: cint = -1
    for i in 0..<segFmt.nb_streams.int:
      if isVideoStream(segFmt.streams[i]):
        segVidIdx = i.cint
        break
    if segVidIdx < 0:
      echo fmt"  [WARN] нет видеопотока в: {segFile}"
      continue

    let inVidStream = segFmt.streams[segVidIdx]

    var vidPkt = av_packet_alloc()
    defer: av_packet_free(addr vidPkt)

    var
      firstSegPts: int64 = AV_NOPTS_VALUE
      segLastPts:  int64 = 0   # последний DTS+dur видео в выходных единицах

    let segDurSec = if segIdx < len(segDurs): segDurs[segIdx]
                    else: 0.0
    let segEndTimeSec = videoTimeSec + segDurSec

    # Читаем видео-пакеты сегмента. Перед КАЖДЫМ из них подтягиваем
    # аудио/субтитры до текущего видео-момента + небольшой лукахед — так
    # оба потока действительно чередуются в выходном файле, а не идут
    # залпами по многу минут одного типа подряд.
    while true:
      let rd = av_read_frame(segFmt, vidPkt)
      if rd == AVERROR_EOF: break
      if rd < 0:
        echo "[WARN] concat segment read: " & ffErrStr(rd)
        break

      if vidPkt.stream_index != segVidIdx:
        av_packet_unref(vidPkt)
        continue

      let rawPts = if vidPkt.pts != AV_NOPTS_VALUE: vidPkt.pts else: vidPkt.dts
      let rawDts = if vidPkt.dts != AV_NOPTS_VALUE: vidPkt.dts else: rawPts
      if rawPts == AV_NOPTS_VALUE:
        av_packet_unref(vidPkt)
        continue

      if firstSegPts == AV_NOPTS_VALUE:
        firstSegPts = rawPts

      # Нормализуем: вычитаем первый PTS сегмента (он = 0 после worker v3),
      # переводим в vidTB, добавляем глобальный offset
      let normPts = av_rescale_q(rawPts - firstSegPts,
                                  inVidStream.time_base, vidTB) + vidPtsOffset
      let normDts = av_rescale_q(rawDts - firstSegPts,
                                  inVidStream.time_base, vidTB) + vidPtsOffset

      let (outPts, outDts) = advance(vidClk, normPts, normDts)

      let outDur = if vidPkt.duration > 0:
        av_rescale_q(vidPkt.duration, inVidStream.time_base, vidTB)
      else: av_rescale_q(1'i64, makeRat(1, targetFps), vidTB)

      let curVideoSec = av_q2d(vidTB) * outDts.float
      flushAudioUpTo(curVideoSec + AUDIO_LOOKAHEAD_SEC)

      vidPkt.stream_index = outVidIdx
      vidPkt.pts      = outPts
      vidPkt.dts      = outDts
      vidPkt.duration = outDur
      vidPkt.pos      = -1

      ffCheckWarn(av_interleaved_write_frame(outFmt, vidPkt), "concat write_frame")

      segLastPts = outDts + outDur
      av_packet_unref(vidPkt)

    # Догоняем аудио/субтитры до конца этого сегмента — в норме это уже
    # небольшой хвост, основной объём ушёл вперемешку с видео выше.
    flushAudioUpTo(segEndTimeSec)

    # Обновляем глобальный offset и время видео
    vidPtsOffset = segLastPts
    videoTimeSec = segEndTimeSec

    echo fmt"  [CONCAT] сег.{segIdx} готов, следующий offset={vidPtsOffset}"

  # Хвост аудио/субтитров за пределами последнего видео-сегмента (если
  # исходник длиннее склеенного видео) — дочитываем всё до EOF, чтобы не
  # потерять концовку звука/субтитров.
  flushAudioUpTo(Inf)

  # ── Финальный трейлер ─────────────────────────────────────────────────
  ffCheck(av_write_trailer(outFmt), "concat: write_trailer")
  echo fmt"[CONCAT] Готово: {outputFile}"
