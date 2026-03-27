# ==============================================================================
#  ffmpeg_api.nim  — Nim-обёртка над FFmpeg C API  (v2)
#
#  Линковка задаётся через Makefile (--passL с полными путями к .a).
#  Для сборки напрямую через "nim c ..." раскомментируйте блок ниже.
#
#  ИЗМЕНЕНИЯ v2:
#   • av_opt_set / av_opt_set_int  (нужны для pix_fmts на buffersink)
#   • av_packet_rescale_ts         (упрощает flush в worker)
#   • avcodec_find_encoder по ID   (дополнение к _by_name)
#   • AVOutputFormat.flags         (для проверки AVFMT_GLOBALHEADER)
#   • AV_CODEC_FLAG_GLOBAL_HEADER  (именованная константа, не магическое число)
#   • AVSEEK_FLAG_* константы
#   • AVCodecContext.delay
#   • av_strdup, av_frame_get_buffer, av_frame_make_writable
#   • av_buffersink_set_frame_size
#   • ffCheckWarn                  (нефатальная проверка кода ошибки)
#   • getStreamFps / getStreamFpsRat / isVideoStream / isAudioStream / isSubtitleStream
# ==============================================================================

# ------------------------------------------------------------------------------
# Раскомментируйте для ручной сборки без Makefile:
# {.passL: "../ffmpeg_build/lib/libavfilter.a".}
# {.passL: "../ffmpeg_build/lib/libavcodec.a".}
# {.passL: "../ffmpeg_build/lib/libavformat.a".}
# {.passL: "../ffmpeg_build/lib/libswscale.a".}
# {.passL: "../ffmpeg_build/lib/libswresample.a".}
# {.passL: "../ffmpeg_build/lib/libavutil.a".}
# {.passL: "-lx264 -lz -lbz2 -llzma -lpthread -lm -ldl".}
# ------------------------------------------------------------------------------

type
  AVMediaType* = distinct cint
  AVPixelFormat* = distinct cint
  AVSampleFormat* = distinct cint
  AVCodecID* = distinct cint
  AVColorSpace* = distinct cint
  AVColorRange* = distinct cint
  AVColorPrimaries* = distinct cint
  AVColorTransferCharacteristic* = distinct cint


# distinct не наследует == — объявляем сразу после type, до любого использования
proc `==`*(a, b: AVMediaType):  bool {.borrow.}
proc `==`*(a, b: AVPixelFormat): bool {.borrow.}
proc `==`*(a, b: AVSampleFormat): bool {.borrow.}
proc `==`*(a, b: AVCodecID):    bool {.borrow.}
proc `==`*(a, b: AVColorSpace): bool {.borrow.}
proc `==`*(a, b: AVColorRange): bool {.borrow.}
proc `==`*(a, b: AVColorPrimaries): bool {.borrow.}
proc `==`*(a, b: AVColorTransferCharacteristic): bool {.borrow.}
proc `$`*(v: AVMediaType):   string = $cint(v)
proc `$`*(v: AVPixelFormat): string = $cint(v)
proc `$`*(v: AVCodecID):     string = $cint(v)
const
  AVMEDIA_TYPE_VIDEO*    = AVMediaType(0)
  AVMEDIA_TYPE_AUDIO*    = AVMediaType(1)
  AVMEDIA_TYPE_SUBTITLE* = AVMediaType(3)
  AVMEDIA_TYPE_UNKNOWN*  = AVMediaType(-1)

  AV_PIX_FMT_NONE*      = AVPixelFormat(-1)
  AV_PIX_FMT_YUV420P*   = AVPixelFormat(0)
  AV_PIX_FMT_YUV422P*   = AVPixelFormat(4)
  AV_PIX_FMT_YUV444P*   = AVPixelFormat(5)
  AV_PIX_FMT_YUV420P10* = AVPixelFormat(63)

  AV_NOPTS_VALUE* = cast[int64](0x8000000000000000'u64)
  AV_TIME_BASE*   = 1_000_000

  AVERROR_EAGAIN* = -11
  AVERROR_EOF*    = -541478725
  AVERROR_EINVAL* = -22
  AVERROR_ENOMEM* = -12

  AV_LOG_QUIET*   = -8
  AV_LOG_PANIC*   =  0
  AV_LOG_FATAL*   =  8
  AV_LOG_ERROR*   = 16
  AV_LOG_WARNING* = 24
  AV_LOG_INFO*    = 32
  AV_LOG_VERBOSE* = 40
  AV_LOG_DEBUG*   = 48

  AVIO_FLAG_WRITE* = 2
  AVIO_FLAG_READ*  = 1

  AV_BUFFERSRC_FLAG_KEEP_REF* = 8
  AV_BUFFERSRC_FLAG_PUSH*     = 4

  AV_ROUND_NEAR_INF*    = 5
  AV_ROUND_PASS_MINMAX* = 8192
  AV_ROUND_NI_PASS*     = AV_ROUND_NEAR_INF or AV_ROUND_PASS_MINMAX

  FF_COMPLIANCE_NORMAL*    = 0
  AV_OPT_SEARCH_CHILDREN* = 1

  AV_CODEC_FLAG_GLOBAL_HEADER* = 1 shl 22
  AVFMT_GLOBALHEADER*          = 0x0040

  FF_THREAD_FRAME* = 1
  FF_THREAD_SLICE* = 2

  AVSEEK_FLAG_BACKWARD* = 1
  AVSEEK_FLAG_BYTE*     = 2
  AVSEEK_FLAG_ANY*      = 4
  AVSEEK_FLAG_FRAME*    = 8

# --- AVRational ---------------------------------------------------------------
type
  AVRational* {.importc: "AVRational",
                header: "<libavutil/rational.h>".} = object
    num*: cint
    den*: cint

proc av_q2d*(q: AVRational): cdouble
  {.importc: "av_q2d", header: "<libavutil/rational.h>".}
proc av_inv_q*(q: AVRational): AVRational
  {.importc: "av_inv_q", header: "<libavutil/rational.h>".}
proc av_mul_q*(b, c: AVRational): AVRational
  {.importc: "av_mul_q", header: "<libavutil/rational.h>".}
proc av_cmp_q*(a, b: AVRational): cint
  {.importc: "av_cmp_q", header: "<libavutil/rational.h>".}
proc av_reduce*(dst_num, dst_den: ptr cint; num, den: int64; max: int64): cint
  {.importc: "av_reduce", header: "<libavutil/rational.h>".}

proc makeRat*(num, den: int): AVRational {.inline.} =
  AVRational(num: num.cint, den: den.cint)

# --- Математика / время -------------------------------------------------------
proc av_rescale_q*(a: int64; bq, cq: AVRational): int64
  {.importc: "av_rescale_q", header: "<libavutil/mathematics.h>".}
proc av_rescale_q_rnd*(a: int64; bq, cq: AVRational; rnd: cint): int64
  {.importc: "av_rescale_q_rnd", header: "<libavutil/mathematics.h>".}
proc av_rescale*(a, b, c: int64): int64
  {.importc: "av_rescale", header: "<libavutil/mathematics.h>".}
proc av_rescale_rnd*(a, b, c: int64; rnd: cint): int64
  {.importc: "av_rescale_rnd", header: "<libavutil/mathematics.h>".}
proc av_compare_ts*(ts_a: int64; tb_a: AVRational;
                    ts_b: int64; tb_b: AVRational): cint
  {.importc: "av_compare_ts", header: "<libavutil/mathematics.h>".}

# --- CPU ----------------------------------------------------------------------
proc av_cpu_count*(): cint
  {.importc: "av_cpu_count", header: "<libavutil/cpu.h>".}

# --- Логирование --------------------------------------------------------------
proc av_log_set_level*(level: cint)
  {.importc: "av_log_set_level", header: "<libavutil/log.h>".}
proc av_log_get_level*(): cint
  {.importc: "av_log_get_level", header: "<libavutil/log.h>".}
proc av_log_set_flags*(arg: cint)
  {.importc: "av_log_set_flags", header: "<libavutil/log.h>".}

# --- AVDictionary -------------------------------------------------------------
type
  AVDictionary* {.importc: "AVDictionary",
                  header: "<libavutil/dict.h>".} = object

proc av_dict_set*(pm: ptr ptr AVDictionary; key, value: cstring;
                  flags: cint): cint
  {.importc: "av_dict_set", header: "<libavutil/dict.h>".}
proc av_dict_set_int*(pm: ptr ptr AVDictionary; key: cstring;
                      value: int64; flags: cint): cint
  {.importc: "av_dict_set_int", header: "<libavutil/dict.h>".}
proc av_dict_free*(m: ptr ptr AVDictionary)
  {.importc: "av_dict_free", header: "<libavutil/dict.h>".}
proc av_dict_copy*(dst: ptr ptr AVDictionary; src: ptr AVDictionary;
                   flags: cint): cint
  {.importc: "av_dict_copy", header: "<libavutil/dict.h>".}

# --- AVOptions ----------------------------------------------------------------
proc av_opt_set*(obj: pointer; name, val: cstring; search_flags: cint): cint
  {.importc: "av_opt_set", header: "<libavutil/opt.h>".}
proc av_opt_set_int*(obj: pointer; name: cstring; val: int64;
                     search_flags: cint): cint
  {.importc: "av_opt_set_int", header: "<libavutil/opt.h>".}
proc av_opt_set_bin*(obj: pointer; name: cstring; val: ptr uint8;
                     size: cint; search_flags: cint): cint
  {.importc: "av_opt_set_bin", header: "<libavutil/opt.h>".}

# --- AVFrame ------------------------------------------------------------------
type
  AVFrame* {.importc: "AVFrame",
             header: "<libavutil/frame.h>".} = object
    data*:       array[8, ptr uint8]
    linesize*:   array[8, cint]
    extended_data*: ptr ptr uint8
    width*:      cint
    height*:     cint
    nb_samples*: cint
    format*:     cint
    key_frame*:  cint
    pict_type*:  cint
    sample_aspect_ratio*: AVRational
    pts*:        int64
    pkt_dts*:    int64
    best_effort_timestamp*: int64
    pkt_duration*: int64
    time_base*:  AVRational
    sample_rate*: cint
    color_space*: AVColorSpace
    color_range*: AVColorRange
    color_primaries*: AVColorPrimaries
    color_trc*:  AVColorTransferCharacteristic

proc av_frame_alloc*(): ptr AVFrame
  {.importc: "av_frame_alloc", header: "<libavutil/frame.h>".}
proc av_frame_free*(frame: ptr ptr AVFrame)
  {.importc: "av_frame_free", header: "<libavutil/frame.h>".}
proc av_frame_unref*(frame: ptr AVFrame)
  {.importc: "av_frame_unref", header: "<libavutil/frame.h>".}
proc av_frame_clone*(src: ptr AVFrame): ptr AVFrame
  {.importc: "av_frame_clone", header: "<libavutil/frame.h>".}
proc av_frame_copy_props*(dst, src: ptr AVFrame): cint
  {.importc: "av_frame_copy_props", header: "<libavutil/frame.h>".}
proc av_frame_get_buffer*(frame: ptr AVFrame; align: cint): cint
  {.importc: "av_frame_get_buffer", header: "<libavutil/frame.h>".}
proc av_frame_make_writable*(frame: ptr AVFrame): cint
  {.importc: "av_frame_make_writable", header: "<libavutil/frame.h>".}

# --- AVPacket -----------------------------------------------------------------
type
  AVPacket* {.importc: "AVPacket",
              header: "<libavcodec/packet.h>".} = object
    pts*:          int64
    dts*:          int64
    data*:         ptr uint8
    size*:         cint
    stream_index*: cint
    flags*:        cint
    duration*:     int64
    pos*:          int64

proc av_packet_alloc*(): ptr AVPacket
  {.importc: "av_packet_alloc", header: "<libavcodec/packet.h>".}
proc av_packet_free*(pkt: ptr ptr AVPacket)
  {.importc: "av_packet_free", header: "<libavcodec/packet.h>".}
proc av_packet_unref*(pkt: ptr AVPacket)
  {.importc: "av_packet_unref", header: "<libavcodec/packet.h>".}
proc av_packet_clone*(src: ptr AVPacket): ptr AVPacket
  {.importc: "av_packet_clone", header: "<libavcodec/packet.h>".}
proc av_packet_rescale_ts*(pkt: ptr AVPacket; src_tb, dst_tb: AVRational)
  {.importc: "av_packet_rescale_ts", header: "<libavcodec/packet.h>".}

# --- AVCodecParameters --------------------------------------------------------
type
  AVCodecParameters* {.importc: "AVCodecParameters",
                       header: "<libavcodec/codec_par.h>".} = object
    codec_type*:    AVMediaType
    codec_id*:      AVCodecID
    codec_tag*:     cuint
    extradata*:     ptr uint8
    extradata_size*: cint
    format*:        cint
    bit_rate*:      int64
    bits_per_coded_sample*: cint
    bits_per_raw_sample*:   cint
    profile*:       cint
    level*:         cint
    width*:         cint
    height*:        cint
    sample_aspect_ratio*: AVRational
    field_order*:   cint
    color_range*:   AVColorRange
    color_primaries*: AVColorPrimaries
    color_trc*:     AVColorTransferCharacteristic
    color_space*:   AVColorSpace
    sample_rate*:   cint
    frame_size*:    cint
    # AVChannelLayout — непрозрачный, только копируем целиком
    ch_layout_opaque*: array[40, uint8]

proc avcodec_parameters_alloc*(): ptr AVCodecParameters
  {.importc: "avcodec_parameters_alloc", header: "<libavcodec/avcodec.h>".}
proc avcodec_parameters_free*(par: ptr ptr AVCodecParameters)
  {.importc: "avcodec_parameters_free", header: "<libavcodec/avcodec.h>".}
proc avcodec_parameters_copy*(dst, src: ptr AVCodecParameters): cint
  {.importc: "avcodec_parameters_copy", header: "<libavcodec/avcodec.h>".}
proc avcodec_parameters_to_context*(ctx: pointer;
                                     par: ptr AVCodecParameters): cint
  {.importc: "avcodec_parameters_to_context",
    header: "<libavcodec/avcodec.h>".}
proc avcodec_parameters_from_context*(par: ptr AVCodecParameters;
                                       ctx: pointer): cint
  {.importc: "avcodec_parameters_from_context",
    header: "<libavcodec/avcodec.h>".}

# --- AVCodec / AVCodecContext -------------------------------------------------
type
  AVCodec* {.importc: "AVCodec",
             header: "<libavcodec/codec.h>".} = object
    name*:      cstring
    long_name*: cstring
    `type`*:    AVMediaType
    id*:        AVCodecID

  AVCodecContext* {.importc: "AVCodecContext",
                    header: "<libavcodec/avcodec.h>".} = object
    codec*:           ptr AVCodec
    codec_id*:        AVCodecID
    codec_type*:      AVMediaType
    bit_rate*:        int64
    width*:           cint
    height*:          cint
    sample_aspect_ratio*: AVRational
    pix_fmt*:         AVPixelFormat
    framerate*:       AVRational
    time_base*:       AVRational
    gop_size*:        cint
    max_b_frames*:    cint
    thread_count*:    cint
    thread_type*:     cint
    flags*:           cint
    flags2*:          cint
    extradata*:       ptr uint8
    extradata_size*:  cint
    profile*:         cint
    level*:           cint
    sample_rate*:     cint
    sample_fmt*:      AVSampleFormat
    colorspace*:     AVColorSpace
    color_range*:     AVColorRange
    color_primaries*: AVColorPrimaries
    color_trc*:       AVColorTransferCharacteristic
    strict_std_compliance*: cint
    delay*:           cint

proc avcodec_find_decoder*(id: AVCodecID): ptr AVCodec
  {.importc: "avcodec_find_decoder", header: "<libavcodec/avcodec.h>".}
proc avcodec_find_decoder_by_name*(name: cstring): ptr AVCodec
  {.importc: "avcodec_find_decoder_by_name", header: "<libavcodec/avcodec.h>".}
proc avcodec_find_encoder*(id: AVCodecID): ptr AVCodec
  {.importc: "avcodec_find_encoder", header: "<libavcodec/avcodec.h>".}
proc avcodec_find_encoder_by_name*(name: cstring): ptr AVCodec
  {.importc: "avcodec_find_encoder_by_name", header: "<libavcodec/avcodec.h>".}
proc avcodec_alloc_context3*(codec: ptr AVCodec): ptr AVCodecContext
  {.importc: "avcodec_alloc_context3", header: "<libavcodec/avcodec.h>".}
proc avcodec_free_context*(avctx: ptr ptr AVCodecContext)
  {.importc: "avcodec_free_context", header: "<libavcodec/avcodec.h>".}
proc avcodec_open2*(avctx: ptr AVCodecContext; codec: ptr AVCodec;
                    options: ptr ptr AVDictionary): cint
  {.importc: "avcodec_open2", header: "<libavcodec/avcodec.h>".}
proc avcodec_send_packet*(avctx: ptr AVCodecContext;
                           avpkt: ptr AVPacket): cint
  {.importc: "avcodec_send_packet", header: "<libavcodec/avcodec.h>".}
proc avcodec_receive_frame*(avctx: ptr AVCodecContext;
                             frame: ptr AVFrame): cint
  {.importc: "avcodec_receive_frame", header: "<libavcodec/avcodec.h>".}
proc avcodec_send_frame*(avctx: ptr AVCodecContext;
                          frame: ptr AVFrame): cint
  {.importc: "avcodec_send_frame", header: "<libavcodec/avcodec.h>".}
proc avcodec_receive_packet*(avctx: ptr AVCodecContext;
                              avpkt: ptr AVPacket): cint
  {.importc: "avcodec_receive_packet", header: "<libavcodec/avcodec.h>".}
proc avcodec_flush_buffers*(avctx: ptr AVCodecContext)
  {.importc: "avcodec_flush_buffers", header: "<libavcodec/avcodec.h>".}

# --- AVStream / AVFormatContext -----------------------------------------------
type
  AVIOContext* {.importc: "AVIOContext",
                 header: "<libavformat/avio.h>".} = object

  AVInputFormat* {.importc: "AVInputFormat",
                   header: "<libavformat/avformat.h>".} = object
    name*: cstring

  AVOutputFormat* {.importc: "AVOutputFormat",
                    header: "<libavformat/avformat.h>".} = object
    name*:       cstring
    long_name*:  cstring
    mime_type*:  cstring
    extensions*: cstring
    flags*:      cint     # содержит AVFMT_GLOBALHEADER

  AVStream* {.importc: "AVStream",
              header: "<libavformat/avformat.h>".} = object
    index*:          cint
    id*:             cint
    codecpar*:       ptr AVCodecParameters
    time_base*:      AVRational
    start_time*:     int64
    duration*:       int64
    nb_frames*:      int64
    disposition*:    cint
    r_frame_rate*:   AVRational
    avg_frame_rate*: AVRational
    metadata*:       ptr AVDictionary

  AVFormatContext* {.importc: "AVFormatContext",
                     header: "<libavformat/avformat.h>".} = object
    iformat*:    ptr AVInputFormat
    oformat*:    ptr AVOutputFormat
    pb*:         ptr AVIOContext
    nb_streams*: cuint
    streams*:    ptr UncheckedArray[ptr AVStream]
    url*:        cstring
    start_time*: int64
    duration*:   int64
    bit_rate*:   int64
    metadata*:   ptr AVDictionary
    flags*:      cint

proc avformat_open_input*(ps: ptr ptr AVFormatContext; url: cstring;
                           fmt: ptr AVInputFormat;
                           options: ptr ptr AVDictionary): cint
  {.importc: "avformat_open_input", header: "<libavformat/avformat.h>".}
proc avformat_find_stream_info*(ic: ptr AVFormatContext;
                                 options: ptr ptr AVDictionary): cint
  {.importc: "avformat_find_stream_info",
    header: "<libavformat/avformat.h>".}
proc avformat_close_input*(s: ptr ptr AVFormatContext)
  {.importc: "avformat_close_input", header: "<libavformat/avformat.h>".}
proc avformat_alloc_output_context2*(ctx: ptr ptr AVFormatContext;
                                      oformat: ptr AVOutputFormat;
                                      format_name: cstring;
                                      filename: cstring): cint
  {.importc: "avformat_alloc_output_context2",
    header: "<libavformat/avformat.h>".}
proc avformat_free_context*(s: ptr AVFormatContext)
  {.importc: "avformat_free_context", header: "<libavformat/avformat.h>".}
proc avformat_new_stream*(s: ptr AVFormatContext;
                           c: ptr AVCodec): ptr AVStream
  {.importc: "avformat_new_stream", header: "<libavformat/avformat.h>".}
proc avformat_write_header*(s: ptr AVFormatContext;
                             options: ptr ptr AVDictionary): cint
  {.importc: "avformat_write_header", header: "<libavformat/avformat.h>".}
proc av_write_trailer*(s: ptr AVFormatContext): cint
  {.importc: "av_write_trailer", header: "<libavformat/avformat.h>".}
proc av_read_frame*(s: ptr AVFormatContext; pkt: ptr AVPacket): cint
  {.importc: "av_read_frame", header: "<libavformat/avformat.h>".}
proc av_interleaved_write_frame*(s: ptr AVFormatContext;
                                  pkt: ptr AVPacket): cint
  {.importc: "av_interleaved_write_frame",
    header: "<libavformat/avformat.h>".}
proc av_write_frame*(s: ptr AVFormatContext; pkt: ptr AVPacket): cint
  {.importc: "av_write_frame", header: "<libavformat/avformat.h>".}
proc av_find_best_stream*(ic: ptr AVFormatContext; `type`: AVMediaType;
                           wanted_stream_nb, related_stream: cint;
                           decoder_ret: pointer;
                           flags: cint): cint
  {.importc: "av_find_best_stream", header: "<libavformat/avformat.h>".}
proc avformat_seek_file*(s: ptr AVFormatContext; stream_index: cint;
                          min_ts, ts, max_ts: int64; flags: cint): cint
  {.importc: "avformat_seek_file", header: "<libavformat/avformat.h>".}
proc av_seek_frame*(s: ptr AVFormatContext; stream_index: cint;
                    timestamp: int64; flags: cint): cint
  {.importc: "av_seek_frame", header: "<libavformat/avformat.h>".}
proc avio_open*(s: ptr ptr AVIOContext; url: cstring; flags: cint): cint
  {.importc: "avio_open", header: "<libavformat/avio.h>".}
proc avio_closep*(s: ptr ptr AVIOContext): cint
  {.importc: "avio_closep", header: "<libavformat/avio.h>".}
proc av_dump_format*(ic: ptr AVFormatContext; index: cint;
                      url: cstring; is_output: cint)
  {.importc: "av_dump_format", header: "<libavformat/avformat.h>".}
proc av_guess_format*(short_name, filename, mime_type: cstring): ptr AVOutputFormat
  {.importc: "av_guess_format", header: "<libavformat/avformat.h>".}

# --- Фильтрграф ---------------------------------------------------------------
type
  AVFilter* {.importc: "AVFilter",
              header: "<libavfilter/avfilter.h>".} = object
    name*: cstring

  AVFilterContext* {.importc: "AVFilterContext",
                     header: "<libavfilter/avfilter.h>".} = object
    filter*:     ptr AVFilter
    name*:       cstring
    nb_inputs*:  cuint
    nb_outputs*: cuint

  AVFilterGraph* {.importc: "AVFilterGraph",
                   header: "<libavfilter/avfilter.h>".} = object
    nb_filters*: cuint

  AVFilterInOut* {.importc: "AVFilterInOut",
                   header: "<libavfilter/avfilter.h>".} = object
    name*:       cstring
    filter_ctx*: ptr AVFilterContext
    pad_idx*:    cint
    next*:       ptr AVFilterInOut

proc avfilter_get_by_name*(name: cstring): ptr AVFilter
  {.importc: "avfilter_get_by_name", header: "<libavfilter/avfilter.h>".}
proc avfilter_graph_alloc*(): ptr AVFilterGraph
  {.importc: "avfilter_graph_alloc", header: "<libavfilter/avfilter.h>".}
proc avfilter_graph_free*(graph: ptr ptr AVFilterGraph)
  {.importc: "avfilter_graph_free", header: "<libavfilter/avfilter.h>".}
proc avfilter_graph_create_filter*(filt_ctx: ptr ptr AVFilterContext;
                                    filt: ptr AVFilter;
                                    name, args: cstring;
                                    opaque: pointer;
                                    graph_ctx: ptr AVFilterGraph): cint
  {.importc: "avfilter_graph_create_filter",
    header: "<libavfilter/avfilter.h>".}
proc avfilter_graph_parse_ptr*(graph: ptr AVFilterGraph;
                                filters: cstring;
                                inputs: ptr ptr AVFilterInOut;
                                outputs: ptr ptr AVFilterInOut;
                                log_ctx: pointer): cint
  {.importc: "avfilter_graph_parse_ptr",
    header: "<libavfilter/avfilter.h>".}
proc avfilter_graph_config*(graphctx: ptr AVFilterGraph;
                             log_ctx: pointer): cint
  {.importc: "avfilter_graph_config", header: "<libavfilter/avfilter.h>".}
proc avfilter_inout_alloc*(): ptr AVFilterInOut
  {.importc: "avfilter_inout_alloc", header: "<libavfilter/avfilter.h>".}
proc avfilter_inout_free*(inout: ptr ptr AVFilterInOut)
  {.importc: "avfilter_inout_free", header: "<libavfilter/avfilter.h>".}
proc av_buffersrc_add_frame_flags*(ctx: ptr AVFilterContext;
                                    frame: ptr AVFrame;
                                    flags: cint): cint
  {.importc: "av_buffersrc_add_frame_flags",
    header: "<libavfilter/buffersrc.h>".}
proc av_buffersink_get_frame*(ctx: ptr AVFilterContext;
                               frame: ptr AVFrame): cint
  {.importc: "av_buffersink_get_frame",
    header: "<libavfilter/buffersink.h>".}
proc av_buffersink_get_time_base*(ctx: ptr AVFilterContext): AVRational
  {.importc: "av_buffersink_get_time_base",
    header: "<libavfilter/buffersink.h>".}
proc av_buffersink_get_frame_rate*(ctx: ptr AVFilterContext): AVRational
  {.importc: "av_buffersink_get_frame_rate",
    header: "<libavfilter/buffersink.h>".}
proc av_buffersink_set_frame_size*(ctx: ptr AVFilterContext; frame_size: cuint)
  {.importc: "av_buffersink_set_frame_size",
    header: "<libavfilter/buffersink.h>".}

# --- Ошибки -------------------------------------------------------------------
proc av_strerror*(errnum: cint; errbuf: cstring;
                   errbuf_size: csize_t): cint
  {.importc: "av_strerror", header: "<libavutil/error.h>".}

proc ffErrStr*(code: cint): string =
  var buf = newString(256)
  discard av_strerror(code, buf.cstring, 256)
  let z = buf.find('\0')
  if z >= 0: buf.setLen(z)
  result = buf

proc ffCheck*(code: cint; msg: string) =
  if code < 0:
    raise newException(IOError,
      msg & ": " & ffErrStr(code) & " (code=" & $code & ")")

proc ffCheckWarn*(code: cint; msg: string): bool {.discardable.} =
  if code < 0:
    echo "[WARN] " & msg & ": " & ffErrStr(code) & " (code=" & $code & ")"
    return false
  return true

# --- Misc avutil --------------------------------------------------------------
proc av_mallocz*(size: csize_t): pointer
  {.importc: "av_mallocz", header: "<libavutil/mem.h>".}
proc av_free*(p: pointer)
  {.importc: "av_free", header: "<libavutil/mem.h>".}
proc av_freep*(p: pointer)
  {.importc: "av_freep", header: "<libavutil/mem.h>".}
proc av_strdup*(s: cstring): cstring
  {.importc: "av_strdup", header: "<libavutil/mem.h>".}

# --- Вспомогательные Nim-утилиты ----------------------------------------------
proc getStreamFps*(stream: ptr AVStream): float =
  let avg = av_q2d(stream.avg_frame_rate)
  if avg > 0.1: return avg
  let r = av_q2d(stream.r_frame_rate)
  if r > 0.1: return r
  return 25.0

proc getStreamFpsRat*(stream: ptr AVStream): AVRational =
  if stream.avg_frame_rate.num > 0 and stream.avg_frame_rate.den > 0:
    return stream.avg_frame_rate
  if stream.r_frame_rate.num > 0 and stream.r_frame_rate.den > 0:
    return stream.r_frame_rate
  return AVRational(num: 25, den: 1)

proc isVideoStream*(stream: ptr AVStream): bool {.inline.} =
  stream.codecpar.codec_type == AVMEDIA_TYPE_VIDEO
proc isAudioStream*(stream: ptr AVStream): bool {.inline.} =
  stream.codecpar.codec_type == AVMEDIA_TYPE_AUDIO
proc isSubtitleStream*(stream: ptr AVStream): bool {.inline.} =
  stream.codecpar.codec_type == AVMEDIA_TYPE_SUBTITLE

