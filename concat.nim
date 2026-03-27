# ==============================================================================
#  concat.nim  — склейка сегментов в финальный файл  (v3)
#
#  АРХИТЕКТУРА v3:
#   1. Видео-сегменты склеиваются последовательно.
#      Каждый сегмент содержит PTS от 0; мы добавляем накопленный offset.
#      offset обновляется по реальному числу кадров сегмента (outFrameCount).
#   2. Аудио и субтитры копируются из исходника ВМЕСТЕ с видео через
#      av_interleaved_write_frame — это единственный способ гарантировать
#      правильный interleave и синхронизацию.
#      Аудио-пакеты пишутся сразу, как только их PTS попадает в текущее
#      временное окно видео.
#   3. PtsClock на каждый поток гарантирует монотонность DTS.
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

import std/[strformat, os, math]
import ffmpeg_api

# ------------------------------------------------------------------------------
# PTS-часы: гарантия монотонности DTS
# ------------------------------------------------------------------------------
type
  PtsClock = object
    lastDts:     int64
    initialized: bool

proc advance(clk: var PtsClock; pts, dts: int64): tuple[pts, dts: int64] =
  var outDts = dts
  var outPts = pts

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

  echo fmt"[CONCAT] Склейка {segFiles.len} сегментов → {outputFile}"

  if segFiles.len == 0:
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
    if refFmt.streams[i].isVideoStream():
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

    maps.add(StreamMap(
      inIdx:  i.cint,
      outIdx: outStream.index,
      inTB:   inStream.time_base))

    echo fmt"  [CONCAT] Поток {i} ({mtype.cint}) → вых.{outStream.index}"

  # ── Заголовок ─────────────────────────────────────────────────────────
  ffCheck(avio_open(addr outFmt.pb, outputFile.cstring, AVIO_FLAG_WRITE),
          "concat: avio_open: " & outputFile)
  ffCheck(avformat_write_header(outFmt, nil), "concat: write_header")

  # ── PtsClock для каждого выходного потока ─────────────────────────────
  var vidClk: PtsClock
  var auxClocks = newSeq[PtsClock](maps.len)

  # ── Открываем исходник для аудио/субтитров ────────────────────────────
  # Аудио/субтитры читаем и мультиплексируем синхронно с видео.
  var srcFmt: ptr AVFormatContext
  let hasMaps = maps.len > 0
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

  # ── Обрабатываем сегменты последовательно ────────────────────────────
  # vidPtsOffset — накопленный PTS в единицах vidTB, куда начинается
  # следующий сегмент.
  var vidPtsOffset: int64 = 0

  # Для аудио: сколько секунд уже записано видео (для синхронизации)
  var videoTimeSec: float = 0.0

  for segIdx, segFile in segFiles:
    echo fmt"  [CONCAT] сег.{segIdx}: {segFile.extractFilename}  offset={vidPtsOffset}"

    if not fileExists(segFile):
      echo fmt"  [WARN] сегмент не найден: {segFile}"
      # Пропускаем, но обновляем offset по ожидаемой длительности
      if segIdx < segDurs.len:
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
      if segFmt.streams[i].isVideoStream():
        segVidIdx = i.cint
        break
    if segVidIdx < 0:
      echo fmt"  [WARN] нет видеопотока в: {segFile}"
      continue

    let inVidStream  = segFmt.streams[segVidIdx]
    let outVidStream2 = outFmt.streams[outVidIdx]

    let vidPkt = av_packet_alloc()
    defer: av_packet_free(addr vidPkt)

    # Перед чтением сегмента — пишем все аудио-пакеты, чьи PTS < videoTimeSec,
    # чтобы они не отставали от видео.
    # Затем читаем видео-пакеты сегмента и перемежаем с аудио.

    var firstSegPts: int64 = AV_NOPTS_VALUE
    var segLastPts:  int64 = 0   # последний DTS+dur видео в выходных единицах

    # Буфер аудио: сначала читаем весь сегмент, параллельно пишем аудио
    # вплоть до текущей позиции видео.

    # Сколько секунд займёт этот сегмент в выходе
    let segDurSec = if segIdx < segDurs.len: segDurs[segIdx]
                    else: 0.0

    let segEndTimeSec = videoTimeSec + segDurSec

    # Пишем аудио-пакеты из [videoTimeSec, segEndTimeSec)
    if srcFmt != nil and hasMaps:
      # Читаем и пишем аудио до конца этого видео-сегмента
      let auxPkt = av_packet_alloc()
      defer: av_packet_free(addr auxPkt)

      # av_read_frame продолжается с последнего места (файл не перематываем)
      var audioWritten = false
      block audioBlock:
        while true:
          let rd = av_read_frame(srcFmt, auxPkt)
          if rd == AVERROR_EOF: break
          if rd < 0: break

          var hit = false
          for i, m in maps:
            if auxPkt.stream_index == m.inIdx:
              let outStream = outFmt.streams[m.outIdx]

              let rawPts = if auxPkt.pts != AV_NOPTS_VALUE: auxPkt.pts
                           else: auxPkt.dts
              if rawPts == AV_NOPTS_VALUE:
                av_packet_unref(auxPkt)
                hit = true
                break

              let pktSec = av_q2d(m.inTB) * rawPts.float

              # Если аудио-пакет ушёл за конец этого сегмента — возвращаем
              # управление (следующий сегмент дочитает)
              # Для этого используем av_seek_frame - не подходит,
              # поэтому просто пишем пока не превысим segEndTimeSec
              if pktSec > segEndTimeSec + 0.1:
                # Слишком далеко вперёд — запишем на следующей итерации
                # Перемотать нельзя, поэтому пишем сейчас
                discard  # fall through — всё равно пишем

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
                let (mPts, mDts) = auxClocks[i].advance(outPts, outDts)
                auxPkt.pts = mPts
                auxPkt.dts = mDts
              else:
                auxPkt.pts = outPts
                auxPkt.dts = outDts

              auxPkt.stream_index = m.outIdx
              auxPkt.duration     = outDur
              auxPkt.pos          = -1

              discard av_interleaved_write_frame(outFmt, auxPkt)
              audioWritten = true
              hit = true

              # Если пакет вышел за конец текущего сегмента — хватит
              if pktSec > segEndTimeSec + 0.1:
                break audioBlock
              break

          if not hit:
            av_packet_unref(auxPkt)

    # Читаем видео-пакеты сегмента
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

      let (outPts, outDts) = vidClk.advance(normPts, normDts)

      let outDur = if vidPkt.duration > 0:
        av_rescale_q(vidPkt.duration, inVidStream.time_base, vidTB)
      else: av_rescale_q(1'i64, makeRat(1, targetFps), vidTB)

      vidPkt.stream_index = outVidIdx
      vidPkt.pts      = outPts
      vidPkt.dts      = outDts
      vidPkt.duration = outDur
      vidPkt.pos      = -1

      ffCheckWarn(av_interleaved_write_frame(outFmt, vidPkt), "concat write_frame")

      segLastPts = outDts + outDur
      av_packet_unref(vidPkt)

    # Обновляем глобальный offset и время видео
    vidPtsOffset = segLastPts
    videoTimeSec = segEndTimeSec

    echo fmt"  [CONCAT] сег.{segIdx} готов, следующий offset={vidPtsOffset}"

  # ── Финальный трейлер ─────────────────────────────────────────────────
  ffCheck(av_write_trailer(outFmt), "concat: write_trailer")
  echo fmt"[CONCAT] Готово: {outputFile}"
