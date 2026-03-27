# PMI — Parallel Motion Interpolate  (v2)

Приложение на **Nim** со статической линковкой FFmpeg.  
Параллельно повышает FPS видео через `minterpolate`, кодирует в **x264**,
аудио и субтитры копируются без изменений.

---

## Структура

```
<родительская папка>/
├── FFmpeg/               ← исходники FFmpeg
└── PMI/
    ├── src/
    │   ├── PMI.nim        — оркестрация потоков
    │   ├── worker.nim     — seek → decode → minterpolate → x264
    │   ├── concat.nim     — склейка сегментов
    │   └── ffmpeg_api.nim — Nim-обёртка над FFmpeg C API
    ├── scripts/
    │   └── build_ffmpeg.sh
    ├── ffmpeg_build/      — создаётся при make build-ffmpeg
    │   ├── include/
    │   └── lib/  *.a
    ├── Makefile
    └── PMI                ← готовый бинарь
```

---

## Сборка

```bash
# Зависимости (Fedora/RHEL)
sudo dnf install -y nasm yasm gcc gcc-c++ make pkg-config \
                    x264-devel zlib-devel bzip2-devel xz-devel nim

# Проверка
make check-deps

# Шаг 1: статические .a библиотеки FFmpeg (~10-15 мин)
make build-ffmpeg

# Шаг 2: бинарь PMI
make build
```

Если FFmpeg лежит не в `../FFmpeg/`:
```bash
make build-ffmpeg FFMPEG_SRC=/другой/путь/к/FFmpeg
```

---

## Использование

```bash
./PMI -i film.mkv -o film_60fps.mkv --fps=60
./PMI -i video.mp4 -o out.mkv --fps=120 --preset=ultrafast --crf=22
./PMI film.ts --fps=90 --mi-mode=blend -o film_90.mkv
./PMI -i input.mkv -o output.mkv --fps=60 -j 4 -v
./PMI --help
```

---

## Параметры

| Параметр | Умолчание | Описание |
|---|---|---|
| `-i`, `--input` | `input.mkv` | Входной файл |
| `-o`, `--output` | `output.mkv` | Выходной файл |
| `--fps` | `60` | Целевой FPS |
| `-j`, `--jobs` | авто (CPU) | Число параллельных потоков |
| `--mi-mode` | `mci` | mci \| blend \| dup |
| `--mc-mode` | `aobmc` | aobmc \| obmc |
| `--me-mode` | `bidir` | bidir \| bilat |
| `--vsbmc` | `1` | Variable-size block MC |
| `--preset` | `slow` | x264 preset |
| `--crf` | `18` | x264 CRF (0–51) |
| `--temp-dir` | авто | Папка для временных сегментов |
| `--keep-temp` | — | Не удалять сегменты |
| `-v` | — | AV_LOG_INFO |

---

## Ключевые исправления v2

### worker.nim

**Flush pipeline** — исходный код имел ошибку двойного flush энкодера.
Теперь три строго разделённые фазы:
1. `avcodec_send_packet(nil)` → drain декодера → `buffersrc_add_frame`
2. `buffersrc_add_frame(nil)` → `drainFilter()` (EOF-сигнал фильтру)
3. `avcodec_send_frame(nil)` → `flushEncoder()` (drain пакетов энкодера)

**Конвертация пикселей** — добавлен `format=pix_fmts=yuv420p` в граф если
источник не YUV420P (10-bit HEVC, VP9, AV1). Без этого x264 падал с
`AVERROR_EINVAL` при открытии кодека.

**PTS из buffersink** — вместо ручного счётчика `ptsCounter` используется
`filtFrame.pts` из буфера фильтра, конвертируемый в `time_base` энкодера.
Это устраняет рассинхронизацию аудио/видео при mci-интерполяции.

**pixel_aspect** — SAR берётся из `decCtx.sample_aspect_ratio` (важно для
анаморфного DVD/Blu-ray). В исходнике было захардкожено `1/1`.

**av_strdup для имён FilterInOut** — FFmpeg ожидает heap-строки которые
освобождает сам. В исходнике передавались стековые строковые литералы.

### concat.nim

**Параметры видеопотока** — берутся из первого сегмента через
`avcodec_parameters_copy`. Исходный `encCtxRef` создавался без
`avcodec_open2` и не имел корректного `extradata` (SPS/PPS).
Результат: повреждённый заголовок MKV/MP4.

**PtsClock** — тип с методом `advance()` гарантирует строгое возрастание
DTS (`newDts <= lastDts` → `newDts = lastDts + 1`). В исходнике условие
было `<= prevDts` вместо строгого `< prevDts`.

**Фильтрация потоков** — копируются только `AUDIO` и `SUBTITLE`. DATA,
ATTACHMENT и прочие типы пропускаются (в исходнике могли вызвать ошибку
контейнера при записи).

### ffmpeg_api.nim

Добавлены:
- `av_opt_set` — для `pix_fmts` на buffersink
- `av_packet_rescale_ts` — упрощает rescale при flush
- `avcodec_find_encoder` — по codec ID
- `AVOutputFormat.flags` — для проверки `AVFMT_GLOBALHEADER`
- `AV_CODEC_FLAG_GLOBAL_HEADER` как именованная константа
- `AVSEEK_FLAG_*` константы
- `getStreamFps`, `getStreamFpsRat`, `isVideoStream`, `isAudioStream`, `isSubtitleStream`

### PMI.nim

- Убрано обращение к несуществующему `vi.targetFps`
- `concatSegments` вызывается без `encCtxRef`
- `MIN_SEG_DURATION = 2.0` с (minterpolate нужен контекст кадров)
- Склейка продолжается при частичных ошибках сегментов

---

## Детали линковки

```
libavfilter → libavcodec → libavformat → libswscale → libswresample → libavutil
```

GNU `ld` читает `.a` слева направо — зависящая библиотека должна стоять левее.

```makefile
# ✓ Полный путь → гарантированно статика
--passL:"$(LIB)/libavcodec.a"

# ✗ Может найти системную .so
--passL:"-lavcodec"
```
