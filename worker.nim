# ==============================================================================
#  worker.nim  — pipeline одного сегмента: seek→decode→filter→encode  (v3)
#
#  ИСПРАВЛЕНИЯ v3:
#   • Сегмент пишет ТОЛЬКО «чистые» кадры из окна [startSec, startSec+cleanDur).
#     Overlap (job.duration > job.cleanDuration) читается для контекста
#     minterpolate, но не записывается — иначе на стыках будет прыжок назад.
#   • PTS выходных кадров нормализован от 0 (в единицах 1/targetFps).
#     concat.nim потом прибавит правильный глобальный offset.
#   • Seek выполняется чуть раньше startSec (OVERLAP_PRE секунд) чтобы
#     minterpolate набрал контекст; эти кадры фильтруются и НЕ кодируются.
#   • Граница конца сегмента — строго cleanDur, без «+0.5» запаса.
#   • flushEncoder вызывается ровно один раз, после drainFilter.
# ==============================================================================

import std/[strformat, strutils, os, math]
import ffmpeg_api

# Сколько секунд декодируем ДО startSec, чтобы minterpolate получил контекст
const OVERLAP_PRE = 2.0

# ------------------------------------------------------------------------------
# Типы данных
# ------------------------------------------------------------------------------
type
  SegmentJob* = object
    jobId*:         int
    inputFile*:     string
    outputFile*:    string
    startTime*:     float       # секунды, начало «чистой» части
    cleanDuration*: float       # секунды, длина «чистой» (полезной) части
    overlapAfter*:  float       # секунды, сколько читать сверх cleanDuration
                                # для контекста minterpolate следующего сегмента
    videoIdx*:      int
    targetFps*:     int
    miMode*:        string
    mcMode*:        string
    meMode*:        string
    vsbmc*:         int
    preset*:        string
    crf*:           int
    threadSlices*:  int

  SegmentResult* = object
    jobId*:         int
    outputFile*:    string
    success*:       bool
    errorMsg*:      string
    frameCount*:    int64    # кадров декодировано
    outFrameCount*: int64    # кадров записано (после minterpolate)
    durationSec*:   float    # реальная длительность выхода

var resultChan*: Channel[SegmentResult]

# ------------------------------------------------------------------------------
# Внутренняя структура
# ------------------------------------------------------------------------------
type
  FilterGraph = object
    graph*:   ptr AVFilterGraph
    srcCtx*:  ptr AVFilterContext
    sinkCtx*: ptr AVFilterContext

  Pipeline = object
    inFmt*:     ptr AVFormatContext
    decCtx*:    ptr AVCodecContext
    vidIdx*:    cint
    inTB*:      AVRational

    fg*:        FilterGraph

    outFmt*:    ptr AVFormatContext
    encCtx*:    ptr AVCodecContext
    outVidIdx*: cint

# ------------------------------------------------------------------------------
# Строка фильтра
# ------------------------------------------------------------------------------
proc buildFilterDesc(job: SegmentJob; inPixFmt: cint): string =
  let minterp = fmt"minterpolate=fps={job.targetFps}:" &
                fmt"mi_mode={job.miMode}:" &
                fmt"mc_mode={job.mcMode}:" &
                fmt"me_mode={job.meMode}:" &
                fmt"vsbmc={job.vsbmc}:" &
                 "scd=fdiff"
  if inPixFmt == 0 or inPixFmt == 12:
    result = minterp
  else:
    result = "format=pix_fmts=yuv420p," & minterp

# ------------------------------------------------------------------------------
# Построение фильтрграфа
# ------------------------------------------------------------------------------
proc buildFilterGraph(fg: var FilterGraph;
                      decCtx: ptr AVCodecContext;
                      stream:  ptr AVStream;
                      job:     SegmentJob) =

  fg.graph = avfilter_graph_alloc()
  if fg.graph == nil:
    raise newException(IOError, "avfilter_graph_alloc failed")

  let bufFilt = avfilter_get_by_name("buffer")
  if bufFilt == nil:
    raise newException(IOError, "filter 'buffer' not found")

  let tb  = stream.time_base
  let fr  = getStreamFpsRat(stream)
  let parN = if decCtx.sample_aspect_ratio.den != 0:
               decCtx.sample_aspect_ratio.num else: 1
  let parD = if decCtx.sample_aspect_ratio.den != 0:
               decCtx.sample_aspect_ratio.den else: 1

  # Colorspace и range: берём из декодера; если не задан — дефолт bt709/tv
  # AVCOL_SPC_UNSPECIFIED=2, AVCOL_RANGE_UNSPECIFIED=0
  let cspInt   = if decCtx.colorspace.cint  != 2: decCtx.colorspace.cint  else: 1  # bt709
  let rangeInt = if decCtx.color_range.cint != 0: decCtx.color_range.cint else: 1  # tv

  let srcArgs = fmt"video_size={decCtx.width}x{decCtx.height}" &
                fmt":pix_fmt={decCtx.pix_fmt.cint}" &
                fmt":time_base={tb.num}/{tb.den}" &
                fmt":pixel_aspect={parN}/{parD}" &
                fmt":frame_rate={fr.num}/{fr.den}" &
                fmt":colorspace={cspInt}" &
                fmt":range={rangeInt}"

  ffCheck(
    avfilter_graph_create_filter(
      addr fg.srcCtx, bufFilt, "in",
      srcArgs.cstring, nil, fg.graph),
    "buffersrc create")

  let sinkFilt = avfilter_get_by_name("buffersink")
  if sinkFilt == nil:
    raise newException(IOError, "filter 'buffersink' not found")

  ffCheck(
    avfilter_graph_create_filter(
      addr fg.sinkCtx, sinkFilt, "out",
      nil, nil, fg.graph),
    "buffersink create")
  # pix_fmts задаётся через "format=pix_fmts=yuv420p" в строке фильтра —
  # av_opt_set на sinkCtx здесь неприменим (контекст уже инициализирован)

  let filterDesc = buildFilterDesc(job, decCtx.pix_fmt.cint)

  var inputs  = avfilter_inout_alloc()
  var outputs = avfilter_inout_alloc()
  if inputs == nil or outputs == nil:
    avfilter_inout_free(addr inputs)
    avfilter_inout_free(addr outputs)
    raise newException(IOError, "avfilter_inout_alloc failed")

  outputs.name       = av_strdup("in")
  outputs.filter_ctx = fg.srcCtx
  outputs.pad_idx    = 0.cint
  outputs.next       = nil

  inputs.name        = av_strdup("out")
  inputs.filter_ctx  = fg.sinkCtx
  inputs.pad_idx     = 0.cint
  inputs.next        = nil

  let ret = avfilter_graph_parse_ptr(
    fg.graph, filterDesc.cstring,
    addr inputs, addr outputs, nil)

  avfilter_inout_free(addr inputs)
  avfilter_inout_free(addr outputs)

  if ret < 0:
    raise newException(IOError,
      "avfilter_graph_parse_ptr: " & ffErrStr(ret) &
      "  filter: [" & filterDesc & "]")

  ffCheck(avfilter_graph_config(fg.graph, nil),
          "avfilter_graph_config")

proc freeFilterGraph(fg: var FilterGraph) =
  if fg.graph != nil:
    avfilter_graph_free(addr fg.graph)
    fg.graph   = nil
    fg.srcCtx  = nil
    fg.sinkCtx = nil

# ------------------------------------------------------------------------------
# Запись одного кадра из фильтра
# ------------------------------------------------------------------------------
proc writeFilteredFrame(p: var Pipeline;
                        filtFrame:     ptr AVFrame;
                        outFrameCount: var int64;
                        ptsCounter:    var int64) =
  ## Конвертирует PTS и кодирует один filtFrame.
  ## ptsCounter — строгий монотонный счётчик в единицах time_base энкодера.
  let outStream = p.outFmt.streams[p.outVidIdx]
  let tmpPkt    = av_packet_alloc()
  defer: av_packet_free(addr tmpPkt)

  # Используем строго монотонный счётчик (не PTS из filtFrame —
  # minterpolate может выдавать дробные/дублирующиеся значения на старте)
  filtFrame.pts = ptsCounter
  inc ptsCounter
  inc outFrameCount

  let sr = avcodec_send_frame(p.encCtx, filtFrame)
  if sr < 0 and sr != AVERROR_EOF:
    echo fmt"[WARN] encode send_frame: {ffErrStr(sr)}"
    return

  while true:
    let rp = avcodec_receive_packet(p.encCtx, tmpPkt)
    if rp == AVERROR_EAGAIN or rp == AVERROR_EOF: break
    if rp < 0:
      echo fmt"[WARN] encode receive_packet: {ffErrStr(rp)}"
      break
    tmpPkt.stream_index = p.outVidIdx
    av_packet_rescale_ts(tmpPkt, p.encCtx.time_base, outStream.time_base)
    tmpPkt.pos = -1
    ffCheckWarn(av_interleaved_write_frame(p.outFmt, tmpPkt), "write_frame")
    av_packet_unref(tmpPkt)

# ------------------------------------------------------------------------------
# Drain фильтра → кодировать; пропускать кадры до writeFromSec
# ------------------------------------------------------------------------------
proc drainFilter(p:            var Pipeline;
                 filtFrame:    ptr AVFrame;
                 outFrameCount: var int64;
                 ptsCounter:   var int64;
                 writeFromSec:  float;    # кадры с меньшим PTS не пишем
                 endSec:        float) =  # кадры с большим PTS не пишем
  let sinkTB = av_buffersink_get_time_base(p.fg.sinkCtx)

  while true:
    let gr = av_buffersink_get_frame(p.fg.sinkCtx, filtFrame)
    if gr == AVERROR_EAGAIN or gr == AVERROR_EOF: break
    if gr < 0:
      echo fmt"[WARN] buffersink_get_frame: {ffErrStr(gr)}"
      break

    # Определяем позицию кадра в исходном времени
    let frameSec = if filtFrame.pts != AV_NOPTS_VALUE:
      av_q2d(sinkTB) * filtFrame.pts.float
    else: -1.0

    # Кадры до startSec — контекст для minterpolate, не пишем
    if frameSec >= 0.0 and frameSec < writeFromSec - 0.001:
      av_frame_unref(filtFrame)
      continue

    # Кадры после cleanDur — overlap, не пишем
    if frameSec >= 0.0 and frameSec > endSec + 0.001:
      av_frame_unref(filtFrame)
      break

    writeFilteredFrame(p, filtFrame, outFrameCount, ptsCounter)
    av_frame_unref(filtFrame)

proc flushEncoder(p: var Pipeline; outFrameCount: var int64; ptsCounter: var int64) =
  let outStream = p.outFmt.streams[p.outVidIdx]
  let tmpPkt    = av_packet_alloc()
  defer: av_packet_free(addr tmpPkt)

  let sr = avcodec_send_frame(p.encCtx, nil)
  if sr < 0 and sr != AVERROR_EOF:
    echo fmt"[WARN] flushEncoder send_frame(nil): {ffErrStr(sr)}"

  while true:
    let rp = avcodec_receive_packet(p.encCtx, tmpPkt)
    if rp == AVERROR_EAGAIN or rp == AVERROR_EOF: break
    if rp < 0:
      echo fmt"[WARN] flushEncoder receive_packet: {ffErrStr(rp)}"
      break
    tmpPkt.stream_index = p.outVidIdx
    av_packet_rescale_ts(tmpPkt, p.encCtx.time_base, outStream.time_base)
    tmpPkt.pos = -1
    ffCheckWarn(av_interleaved_write_frame(p.outFmt, tmpPkt), "flush write")
    av_packet_unref(tmpPkt)

# ------------------------------------------------------------------------------
# Главная функция сегмента
# ------------------------------------------------------------------------------
proc processSegment*(job: SegmentJob): SegmentResult =
  result = SegmentResult(
    jobId:      job.jobId,
    outputFile: job.outputFile,
    success:    false)

  var p: Pipeline

  try:
    # ── 1. Открытие входного файла ───────────────────────────────────────
    ffCheck(
      avformat_open_input(addr p.inFmt, job.inputFile.cstring, nil, nil),
      "avformat_open_input: " & job.inputFile)
    ffCheck(
      avformat_find_stream_info(p.inFmt, nil),
      "avformat_find_stream_info")

    # ── 2. Seek ──────────────────────────────────────────────────────────
    # Seek чуть раньше startTime, чтобы minterpolate набрал контекст
    let seekSec = max(0.0, job.startTime - OVERLAP_PRE)
    if seekSec > 0.05:
      let seekTs = int64(seekSec * AV_TIME_BASE.float)
      let sr = avformat_seek_file(p.inFmt, -1,
                                   int64.low, seekTs, seekTs,
                                   AVSEEK_FLAG_BACKWARD)
      if sr < 0:
        echo fmt"[WARN] seg{job.jobId}: seek: {ffErrStr(sr)}"

    # ── 3. Декодер ───────────────────────────────────────────────────────
    p.vidIdx = job.videoIdx.cint
    let inStream = p.inFmt.streams[p.vidIdx]
    p.inTB = inStream.time_base

    let codec = avcodec_find_decoder(inStream.codecpar.codec_id)
    if codec == nil:
      raise newException(IOError, "decoder not found")

    p.decCtx = avcodec_alloc_context3(codec)
    if p.decCtx == nil:
      raise newException(IOError, "avcodec_alloc_context3 failed")

    ffCheck(avcodec_parameters_to_context(p.decCtx, inStream.codecpar),
            "parameters_to_context")

    p.decCtx.thread_count = job.threadSlices.cint
    p.decCtx.thread_type  = (FF_THREAD_FRAME or FF_THREAD_SLICE).cint

    ffCheck(avcodec_open2(p.decCtx, codec, nil), "avcodec_open2 decoder")

    # ── 4. Фильтрграф ────────────────────────────────────────────────────
    buildFilterGraph(p.fg, p.decCtx, inStream, job)

    # ── 5. Выходной файл и энкодер ───────────────────────────────────────
    ffCheck(
      avformat_alloc_output_context2(
        addr p.outFmt, nil, nil, job.outputFile.cstring),
      "avformat_alloc_output_context2")

    let encoder = avcodec_find_encoder_by_name("libx264")
    if encoder == nil:
      raise newException(IOError, "libx264 not found")

    let outVidStream = avformat_new_stream(p.outFmt, nil)
    if outVidStream == nil:
      raise newException(IOError, "avformat_new_stream failed")
    p.outVidIdx = outVidStream.index

    p.encCtx = avcodec_alloc_context3(encoder)
    if p.encCtx == nil:
      raise newException(IOError, "avcodec_alloc_context3 encoder failed")

    p.encCtx.width        = p.decCtx.width
    p.encCtx.height       = p.decCtx.height
    p.encCtx.pix_fmt      = AV_PIX_FMT_YUV420P
    p.encCtx.time_base    = makeRat(1, job.targetFps)
    p.encCtx.framerate    = makeRat(job.targetFps, 1)
    p.encCtx.gop_size     = job.targetFps.cint
    p.encCtx.max_b_frames = 2.cint
    p.encCtx.thread_count = job.threadSlices.cint
    p.encCtx.thread_type  = (FF_THREAD_FRAME or FF_THREAD_SLICE).cint
    p.encCtx.colorspace      = p.decCtx.colorspace
    p.encCtx.color_range     = p.decCtx.color_range
    p.encCtx.color_primaries = p.decCtx.color_primaries
    p.encCtx.color_trc       = p.decCtx.color_trc
    p.encCtx.sample_aspect_ratio = p.decCtx.sample_aspect_ratio

    if p.outFmt.oformat != nil and
       (p.outFmt.oformat.flags and AVFMT_GLOBALHEADER) != 0:
      p.encCtx.flags = p.encCtx.flags or AV_CODEC_FLAG_GLOBAL_HEADER

    var encOpts: ptr AVDictionary = nil
    discard av_dict_set(addr encOpts, "crf", ($job.crf).cstring, 0)
    discard av_dict_set(addr encOpts, "preset", job.preset.cstring, 0)
    # zerolatency: убирает lookahead → каждый сегмент независим
    # discard av_dict_set(addr encOpts, "tune", cstring("zerolatency"), 0)
    discard av_dict_set(addr encOpts, "tune", cstring("film"), 0)

    ffCheck(avcodec_open2(p.encCtx, encoder, addr encOpts),
            "avcodec_open2 x264")
    av_dict_free(addr encOpts)

    ffCheck(avcodec_parameters_from_context(outVidStream.codecpar, p.encCtx),
            "parameters_from_context")
    outVidStream.time_base = p.encCtx.time_base

    ffCheck(avio_open(addr p.outFmt.pb, job.outputFile.cstring, AVIO_FLAG_WRITE),
            "avio_open: " & job.outputFile)
    ffCheck(avformat_write_header(p.outFmt, nil), "avformat_write_header")

    # ── 6. Главный цикл ──────────────────────────────────────────────────
    # Читаем до startSec + cleanDuration + overlapAfter (для контекста minterpolate)
    let readEndSec  = job.startTime + job.cleanDuration + job.overlapAfter
    # Пишем только кадры в [startSec, startSec + cleanDuration)
    let writeEndSec = job.startTime + job.cleanDuration

    let pkt       = av_packet_alloc()
    let decFrame  = av_frame_alloc()
    let filtFrame = av_frame_alloc()
    if pkt == nil or decFrame == nil or filtFrame == nil:
      raise newException(IOError, "av_alloc failed")
    defer:
      av_packet_free(addr pkt)
      av_frame_free(addr decFrame)
      av_frame_free(addr filtFrame)

    var frameCount:    int64 = 0
    var outFrameCount: int64 = 0
    var ptsCounter:    int64 = 0  # монотонный счётчик выходных кадров (от 0)
    var done = false

    while not done:
      let rd = av_read_frame(p.inFmt, pkt)
      if rd == AVERROR_EOF: break
      if rd < 0:
        echo fmt"[WARN] seg{job.jobId}: read_frame: {ffErrStr(rd)}"
        break

      if pkt.stream_index != p.vidIdx:
        av_packet_unref(pkt)
        continue

      # Проверяем не вышли ли за конец зоны чтения
      if pkt.pts != AV_NOPTS_VALUE:
        let pktSec = av_q2d(p.inTB) * pkt.pts.float
        if pktSec > readEndSec + 0.5:
          av_packet_unref(pkt)
          done = true
          break

      let dr = avcodec_send_packet(p.decCtx, pkt)
      av_packet_unref(pkt)
      if dr < 0 and dr != AVERROR_EAGAIN: continue

      while true:
        let rr = avcodec_receive_frame(p.decCtx, decFrame)
        if rr == AVERROR_EAGAIN or rr == AVERROR_EOF: break
        if rr < 0: break

        let fts = decFrame.best_effort_timestamp
        if fts != AV_NOPTS_VALUE:
          let frameSec = av_q2d(p.inTB) * fts.float
          # Пропускаем кадры до зоны чтения (до seekSec)
          if frameSec < seekSec - 0.02:
            av_frame_unref(decFrame)
            continue
          # Прекращаем читать за концом зоны чтения
          if frameSec > readEndSec + 0.2:
            av_frame_unref(decFrame)
            done = true
            break

        inc frameCount

        let fr = av_buffersrc_add_frame_flags(
          p.fg.srcCtx, decFrame, AV_BUFFERSRC_FLAG_KEEP_REF)
        av_frame_unref(decFrame)
        if fr < 0:
          echo fmt"[WARN] seg{job.jobId}: buffersrc: {ffErrStr(fr)}"
          continue

        # drainFilter пишет только кадры в [startTime, writeEndSec]
        drainFilter(p, filtFrame, outFrameCount, ptsCounter,
                    job.startTime, writeEndSec)

    # ── 7. Flush: три фазы ───────────────────────────────────────────────

    # Фаза 1: flush декодера → buffersrc
    if avcodec_send_packet(p.decCtx, nil) >= 0:
      while true:
        let rr = avcodec_receive_frame(p.decCtx, decFrame)
        if rr == AVERROR_EAGAIN or rr == AVERROR_EOF: break
        if rr < 0: break
        inc frameCount
        let fr = av_buffersrc_add_frame_flags(
          p.fg.srcCtx, decFrame, AV_BUFFERSRC_FLAG_KEEP_REF)
        av_frame_unref(decFrame)
        if fr >= 0:
          drainFilter(p, filtFrame, outFrameCount, ptsCounter,
                      job.startTime, writeEndSec)

    # Фаза 2: flush фильтра
    discard av_buffersrc_add_frame_flags(p.fg.srcCtx, nil, 0)
    drainFilter(p, filtFrame, outFrameCount, ptsCounter,
                job.startTime, writeEndSec)

    # Фаза 3: flush энкодера
    flushEncoder(p, outFrameCount, ptsCounter)

    ffCheck(av_write_trailer(p.outFmt), "av_write_trailer")

    # Реальная длительность сегмента по числу выходных кадров
    result.success        = true
    result.frameCount     = frameCount
    result.outFrameCount  = outFrameCount
    result.durationSec    = outFrameCount.float / job.targetFps.float

    echo fmt"[SEG {job.jobId:02d}] dec={frameCount} enc={outFrameCount}" &
         fmt" dur={result.durationSec:.3f}s → {job.outputFile.extractFilename}"

  except IOError as e:
    result.success  = false
    result.errorMsg = e.msg
    echo fmt"[ERROR] seg{job.jobId}: {e.msg}"

  finally:
    freeFilterGraph(p.fg)
    if p.encCtx != nil: avcodec_free_context(addr p.encCtx)
    if p.decCtx != nil: avcodec_free_context(addr p.decCtx)
    if p.outFmt != nil:
      if p.outFmt.pb != nil: discard avio_closep(addr p.outFmt.pb)
      avformat_free_context(p.outFmt)
      p.outFmt = nil
    if p.inFmt != nil:
      avformat_close_input(addr p.inFmt)

# ------------------------------------------------------------------------------
# Точка входа потока
# ------------------------------------------------------------------------------
proc workerThread*(job: SegmentJob) {.thread.} =
  let res = processSegment(job)
  resultChan.send(res)
