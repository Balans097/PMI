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
    # Colorspace/range, выбранные ОДИН раз при построении фильтрграфа
    # (buildFilterGraph) и переиспользуемые везде далее: их же мы
    # прописываем в каждый decFrame перед отправкой в buffersrc (чтобы
    # реальные кадры совпадали с тем, что было заявлено buffersrc при
    # создании), и в encCtx — чтобы выходной файл был размечен тем же
    # значением, а не «unspecified» из декодера.
    outCsp*:    AVColorSpace
    outRange*:  AVColorRange

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
proc buildFilterGraph(p: var Pipeline;
                      decCtx: ptr AVCodecContext;
                      stream:  ptr AVStream;
                      job:     SegmentJob) =

  p.fg.graph = avfilter_graph_alloc()
  if p.fg.graph == nil:
    raise newException(IOError, "avfilter_graph_alloc failed")

  let bufFilt = avfilter_get_by_name("buffer")
  if bufFilt == nil:
    raise newException(IOError, "filter 'buffer' not found")

  let
    tb   = stream.time_base
    fr   = getStreamFpsRat(stream)
    # pixel_aspect (SAR) — если декодер его не сообщил, считаем 1/1
    parN = if decCtx.sample_aspect_ratio.den != 0: decCtx.sample_aspect_ratio.num else: 1
    parD = if decCtx.sample_aspect_ratio.den != 0: decCtx.sample_aspect_ratio.den else: 1
    # Colorspace и range: на этом этапе декодер ещё НИЧЕГО не декодировал
    # (buildFilterGraph вызывается сразу после avcodec_open2), поэтому
    # decCtx.colorspace/color_range почти всегда "unspecified" — реальные
    # значения появляются только в decFrame.colorspace/color_range уже
    # ПОСЛЕ декодирования первого кадра (парсятся из VUI/SEI H.264).
    #
    # Но `stream.codecpar` (AVCodecParameters) заполняется демуксером из
    # контейнера/SPS ДО открытия декодера и часто уже содержит корректные
    # color_space/color_range/primaries/trc — используем их как основной
    # источник. Раньше здесь всегда жёстко стояло bt709/tv, что молча
    # переразмечало SD BT.601, full-range, HDR/BT.2020 и другие
    # non-BT.709 источники в BT.709 (см. отчёт, находка #10). BT.709/tv
    # остаётся дефолтом только когда codecpar сам ничего не знает
    # (typично для web-рипов без явной цветовой разметки).
    csp   = stream.codecpar.color_space
    rng   = stream.codecpar.color_range
    cspInt   = if csp.cint != AVCOL_SPC_UNSPECIFIED: csp.cint else: 1.cint    # 1 = BT709
    rangeInt = if rng.cint != AVCOL_RANGE_UNSPECIFIED: rng.cint else: 1.cint  # 1 = MPEG (tv)

  p.outCsp   = AVColorSpace(cspInt)
  p.outRange = AVColorRange(rangeInt)

  let srcArgs = fmt"video_size={decCtx.width}x{decCtx.height}" &
                fmt":pix_fmt={decCtx.pix_fmt.cint}" &
                fmt":time_base={tb.num}/{tb.den}" &
                fmt":pixel_aspect={parN}/{parD}" &
                fmt":frame_rate={fr.num}/{fr.den}" &
                fmt":colorspace={cspInt}" &
                fmt":range={rangeInt}"

  ffCheck(
    avfilter_graph_create_filter(
      addr p.fg.srcCtx, bufFilt, "in",
      srcArgs.cstring, nil, p.fg.graph),
    "buffersrc create")

  let sinkFilt = avfilter_get_by_name("buffersink")
  if sinkFilt == nil:
    raise newException(IOError, "filter 'buffersink' not found")

  ffCheck(
    avfilter_graph_create_filter(
      addr p.fg.sinkCtx, sinkFilt, "out",
      nil, nil, p.fg.graph),
    "buffersink create")
  # pix_fmts задаётся через "format=pix_fmts=yuv420p" в строке фильтра —
  # av_opt_set на sinkCtx здесь неприменим (контекст уже инициализирован)

  let filterDesc = buildFilterDesc(job, decCtx.pix_fmt.cint)

  var
    inputs  = avfilter_inout_alloc()
    outputs = avfilter_inout_alloc()
  if inputs == nil or outputs == nil:
    avfilter_inout_free(addr inputs)
    avfilter_inout_free(addr outputs)
    raise newException(IOError, "avfilter_inout_alloc failed")

  outputs.name       = av_strdup("in")
  outputs.filter_ctx = p.fg.srcCtx
  outputs.pad_idx    = 0.cint
  outputs.next       = nil

  inputs.name        = av_strdup("out")
  inputs.filter_ctx  = p.fg.sinkCtx
  inputs.pad_idx     = 0.cint
  inputs.next        = nil

  let ret = avfilter_graph_parse_ptr(
    p.fg.graph, filterDesc.cstring,
    addr inputs, addr outputs, nil)

  avfilter_inout_free(addr inputs)
  avfilter_inout_free(addr outputs)

  if ret < 0:
    raise newException(IOError,
      "avfilter_graph_parse_ptr: " & ffErrStr(ret) &
      "  filter: [" & filterDesc & "]")

  ffCheck(avfilter_graph_config(p.fg.graph, nil),
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
                        tmpPkt:        ptr AVPacket;
                        outFrameCount: var int64;
                        ptsCounter:    var int64) =
  ## Конвертирует PTS и кодирует один filtFrame.
  ## ptsCounter — строгий монотонный счётчик в единицах time_base энкодера.
  ## tmpPkt переиспользуется вызывающей стороной (см. processSegment) —
  ## раньше `av_packet_alloc()`/`av_packet_free()` вызывались на каждый
  ## кадр, что на 60/120 fps выходе даёт аллокацию в куче на каждый кадр
  ## (Performance Findings #1). Теперь пакет живёт на весь пайплайн
  ## сегмента, здесь только `av_packet_unref`.
  let outStream = p.outFmt.streams[p.outVidIdx]

  # Используем строго монотонный счётчик (не PTS из filtFrame —
  # minterpolate может выдавать дробные/дублирующиеся значения на старте)
  filtFrame.pts = ptsCounter
  inc ptsCounter
  inc outFrameCount

  # frame.pict_type наследуется от исходного декодированного кадра
  # (в источнике есть B-кадры) и пробрасывается фильтром как есть. Если не
  # сбросить его, libx264-обёртка трактует ненулевой pict_type как явное
  # указание типа кадра и на границе GOP/сегмента ругается
  # "specified frame type ... not compatible with keyframe interval",
  # принудительно меняя тип сама. Явно отдаём решение x264.
  filtFrame.pict_type = AV_PICTURE_TYPE_NONE

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
                 tmpPkt:       ptr AVPacket;
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

    writeFilteredFrame(p, filtFrame, tmpPkt, outFrameCount, ptsCounter)
    av_frame_unref(filtFrame)

proc flushEncoder(p: var Pipeline; tmpPkt: ptr AVPacket;
                  outFrameCount: var int64; ptsCounter: var int64) =
  let outStream = p.outFmt.streams[p.outVidIdx]

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
                                   low(int64), seekTs, seekTs,
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
    buildFilterGraph(p, p.decCtx, inStream, job)

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
    p.encCtx.colorspace      = p.outCsp
    p.encCtx.color_range     = p.outRange
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

    let
      pkt       = av_packet_alloc()
      decFrame  = av_frame_alloc()
      filtFrame = av_frame_alloc()
      tmpPkt    = av_packet_alloc()   # переиспользуется всеми encode-вызовами сегмента
    if pkt == nil or decFrame == nil or filtFrame == nil or tmpPkt == nil:
      raise newException(IOError, "av_alloc failed")
    defer:
      av_packet_free(addr pkt)
      av_frame_free(addr decFrame)
      av_frame_free(addr filtFrame)
      av_packet_free(addr tmpPkt)

    var
      frameCount:    int64 = 0  # кадров декодировано
      outFrameCount: int64 = 0  # кадров записано (после minterpolate)
      ptsCounter:    int64 = 0  # монотонный счётчик выходных кадров (от 0)
      done = false

    while not done:
      let rd = av_read_frame(p.inFmt, pkt)
      if rd == AVERROR_EOF: break
      if rd < 0:
        echo fmt"[WARN] seg{job.jobId}: read_frame: {ffErrStr(rd)}"
        break

      if pkt.stream_index != p.vidIdx:
        av_packet_unref(pkt)
        continue

      # Раньше здесь была ранняя остановка чтения по pkt.pts > readEndSec:
      # PTS ПАКЕТА (в отличие от PTS декодированного КАДРА) не гарантированно
      # монотонен при переупорядочивании из-за B-кадров — считывая пакеты в
      # порядке декодирования (DTS), можно наткнуться на пакет с "далёким"
      # PTS ещё до того, как дочитаны все пакеты, чьи кадры на самом деле
      # попадают в окно сегмента. Останов по времени сделан ниже — по
      # best_effort_timestamp уже ДЕКОДИРОВАННОГО кадра (см. frameSec).

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

        # best_effort_timestamp — единственный надёжный PTS декодированного
        # кадра (учитывает переупорядочивание B-кадров и умеет достраивать
        # значение из DTS, если PTS у потока отсутствует/разрежен). Раньше
        # эта величина использовалась только для проверки границ сегмента
        # выше, а сам decFrame.pts, отправляемый в buffersrc, не менялся —
        # т.е. фильтр мог получать неверный/исходный (или NOPTS) PTS кадра.
        # На источниках с пропущенными/нестандартными PTS это ломало
        # тайминг интерполяции minterpolate. Проставляем нормализованное
        # значение явно перед отправкой в фильтрграф.
        if fts != AV_NOPTS_VALUE:
          decFrame.pts = fts

        # Принудительно тегируем кадр тем же csp/range, что заявлен
        # buffersrc при создании фильтрграфа (p.outCsp/p.outRange) —
        # иначе libavfilter ругается "Changing video frame properties
        # on the fly is not supported by all filters", т.к. реальный
        # decFrame почти всегда несёт colorspace=unspecified.
        decFrame.colorspace  = p.outCsp
        decFrame.color_range = p.outRange

        let fr = av_buffersrc_add_frame_flags(
          p.fg.srcCtx, decFrame, AV_BUFFERSRC_FLAG_KEEP_REF)
        av_frame_unref(decFrame)
        if fr < 0:
          echo fmt"[WARN] seg{job.jobId}: buffersrc: {ffErrStr(fr)}"
          continue

        # drainFilter пишет только кадры в [startTime, writeEndSec]
        drainFilter(p, filtFrame, tmpPkt, outFrameCount, ptsCounter,
                    job.startTime, writeEndSec)

    # ── 7. Flush: три фазы ───────────────────────────────────────────────

    # Фаза 1: flush декодера → buffersrc
    if avcodec_send_packet(p.decCtx, nil) >= 0:
      while true:
        let rr = avcodec_receive_frame(p.decCtx, decFrame)
        if rr == AVERROR_EAGAIN or rr == AVERROR_EOF: break
        if rr < 0: break
        inc frameCount
        decFrame.colorspace  = p.outCsp
        decFrame.color_range = p.outRange
        let fr = av_buffersrc_add_frame_flags(
          p.fg.srcCtx, decFrame, AV_BUFFERSRC_FLAG_KEEP_REF)
        av_frame_unref(decFrame)
        if fr >= 0:
          drainFilter(p, filtFrame, tmpPkt, outFrameCount, ptsCounter,
                      job.startTime, writeEndSec)

    # Фаза 2: flush фильтра
    discard av_buffersrc_add_frame_flags(p.fg.srcCtx, nil, 0)
    drainFilter(p, filtFrame, tmpPkt, outFrameCount, ptsCounter,
                job.startTime, writeEndSec)

    # Фаза 3: flush энкодера
    flushEncoder(p, tmpPkt, outFrameCount, ptsCounter)

    ffCheck(av_write_trailer(p.outFmt), "av_write_trailer")

    # Реальная длительность сегмента по числу выходных кадров
    result.success        = true
    result.frameCount     = frameCount
    result.outFrameCount  = outFrameCount
    result.durationSec    = outFrameCount.float / job.targetFps.float

    echo fmt"[SEG {job.jobId:02d}] dec={frameCount} enc={outFrameCount}" &
         fmt" dur={result.durationSec:.3f}s → {extractFilename(job.outputFile)}"

  except CatchableError as e:
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
  # processSegment теперь сама ловит CatchableError (см. ниже) и всегда
  # возвращает SegmentResult. Но send() и вообще код вокруг вызова —
  # это код workerThread, а не processSegment: если бы здесь возникло
  # необработанное исключение до send(resultChan, res), main() навсегда
  # завис бы в recv, ожидая результат для этого jobId (полный deadlock
  # главного потока вместо сообщения об ошибке). Ловим здесь всё как
  # последний рубеж защиты.
  try:
    let res = processSegment(job)
    send(resultChan, res)
  except CatchableError as e:
    send(resultChan, SegmentResult(
      jobId:      job.jobId,
      outputFile: job.outputFile,
      success:    false,
      errorMsg:   "необработанное исключение: " & e.msg))
