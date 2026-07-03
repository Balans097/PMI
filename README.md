# PMI — Parallel Motion Interpolate  (v4)

Приложение на **Nim** со статической линковкой FFmpeg.  
Параллельно повышает FPS видео через `minterpolate`, кодирует в **x264**,
аудио и субтитры копируются без изменений.


## Интерфейс терминала
![Интерфейс терминала](./archive/Screenshot.png)

---

## Быстрая сборка (v4)

Начиная с v4 в проекте есть `config.nims` — NimScript-файл, который Nim
компилятор выполняет автоматически перед сборкой. Он сам клонирует и
собирает статический FFmpeg, если его ещё нет. Поэтому достаточно:

```bash
sudo dnf install -y nasm yasm gcc gcc-c++ make pkg-config \
                    x264-devel zlib-devel bzip2-devel xz-devel nim git

cd PMI/
nim c -d:release --threads:on PMI.nim
```

Первый запуск займёт ~10-15 минут (клонирование + сборка FFmpeg).
Повторные запуски пропускают этот шаг — `config.nims` проверяет наличие
`ffmpeg_build/lib/*.a` и, если они уже собраны, сразу переходит к линковке.

Если исходники FFmpeg уже лежат в нестандартном месте:

```bash
PMI_FFMPEG_SRC=/путь/к/FFmpeg nim c -d:release --threads:on PMI.nim
```

Ветка FFmpeg по умолчанию — `release/7.1`, зеркало GitHub
(`github.com/FFmpeg/FFmpeg`); правится в начале `config.nims`
(переменная `ffmpegBranch`).

### Альтернатива: Makefile (ручное управление шагами)

Если исходники FFmpeg уже клонированы вручную в `../FFmpeg/` и нужен
явный контроль над шагами (например, CI), можно по-прежнему пользоваться
Makefile — он не конфликтует с `config.nims`, но НЕ клонирует FFmpeg сам:

```bash
make check-deps
make build-ffmpeg    # ~10-15 мин
make build
```



## Структура

```
<родительская папка>/
├── FFmpeg/                 ← исходники FFmpeg (клонируются config.nims автоматически)
└── PMI/
    ├── PMI.nim              — оркестрация потоков (главный модуль)
    ├── config.nims          — автоклон + автосборка FFmpeg (см. «Быстрая сборка»)
    ├── Makefile              — ручная альтернатива config.nims (см. ниже)
    ├── src/
    │   ├── worker.nim       — seek → decode → minterpolate → x264
    │   ├── concat.nim       — склейка сегментов
    │   └── ffmpeg_api.nim   — Nim-обёртка над FFmpeg C API
    ├── ffmpeg_build/        ← создаётся при сборке (config.nims или make build-ffmpeg)
    │   ├── include/
    │   └── lib/  *.a
    └── PMI                  ← готовый бинарь (результат сборки)
```

`PMI.nim` подключает соседние модули как `import src/[ffmpeg_api, worker, concat]`;
сами `worker.nim`/`concat.nim` внутри `src/` импортируют `ffmpeg_api` обычным
`import ffmpeg_api` — они лежат в одной папке, путь указывать не нужно.

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

## Кросс-компиляция под Windows (mingw-w64)

Собранные под Linux `.a` в `ffmpeg_build/` (ELF) для Windows-бинаря не
годятся — FFmpeg и x264 нужно пересобрать отдельно под mingw-w64, а затем
кросс-скомпилировать `PMI.nim` под `--os:windows`. `config.nims` сейчас
собирает FFmpeg только под хост-платформу, поэтому для Windows-сборки
используется отдельная папка `ffmpeg_build_win/` и ручные шаги ниже.

### 1. Тулчейн на Fedora

```bash
sudo dnf install -y mingw64-gcc mingw64-gcc-c++ mingw64-binutils \
                     mingw64-winpthreads-static mingw64-zlib-static \
                     mingw64-bzip2-static mingw64-headers \
                     mingw64-pkg-config nasm yasm git make
```

### 2. Кросс-сборка x264

```bash
git clone https://code.videolan.org/videolan/x264.git ../x264-mingw
cd ../x264-mingw

./configure \
  --host=x86_64-w64-mingw32 \
  --cross-prefix=x86_64-w64-mingw32- \
  --enable-static --disable-cli --disable-opencl \
  --prefix="$(pwd)/../PMI/ffmpeg_build_win"

make -j$(nproc)
make install
cd ../PMI
```

### 3. Кросс-сборка FFmpeg

Та же ветка (`release/7.1`), тот же набор `--enable-*`, что в `Makefile`/
`config.nims`, но **без `-march=native`** (это опция под хост-CPU, при
кросс-сборке она бессмысленна/ломает сборку) и с явным кросс-тулчейном:

```bash
cd ../FFmpeg

BUILD_WIN=$(pwd)/../PMI/ffmpeg_build_win
export PKG_CONFIG_LIBDIR="$BUILD_WIN/lib/pkgconfig"

./configure \
  --prefix="$BUILD_WIN" \
  --arch=x86_64 --target-os=mingw32 \
  --cross-prefix=x86_64-w64-mingw32- \
  --enable-cross-compile \
  --pkg-config=pkg-config --pkg-config-flags="--static" \
  --enable-static --disable-shared \
  --enable-gpl --enable-version3 --enable-libx264 \
  --disable-programs --disable-doc --disable-debug --disable-autodetect \
  --enable-protocol=file \
  --enable-demuxer=matroska,mov,mpegts,avi,flv,concat \
  --enable-muxer=matroska,mp4,mov,avi,segment \
  --enable-decoder=h264,hevc,mpeg4,mpeg2video,vp9,vp8,av1,aac,ac3,mp3,eac3,dts,opus,vorbis,flac,truehd,ass,ssa,srt,subrip,dvd_subtitle,hdmv_pgs_subtitle \
  --enable-encoder=libx264 \
  --enable-parser=h264,hevc,aac,ac3,mpegaudio,vp9,av1,mpeg4video \
  --enable-filter=minterpolate,buffer,buffersink,scale,format,fps,setpts,fifo \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata \
  --extra-cflags="-O3 -static" \
  --extra-ldflags="-static -static-libgcc"

make -j$(nproc)
make install
```

### 4. Кросс-компиляция PMI.nim

```bash
LIB=ffmpeg_build_win/lib
INC=ffmpeg_build_win/include

nim c -d:release --opt:speed --threads:on --mm:orc \
  --os:windows --cpu:amd64 \
  --gcc.exe:x86_64-w64-mingw32-gcc \
  --gcc.linkerexe:x86_64-w64-mingw32-gcc \
  --passC:"-I$INC" \
  --passL:"-Wl,--start-group" \
  --passL:"$LIB/libavfilter.a" \
  --passL:"$LIB/libavcodec.a" \
  --passL:"$LIB/libavformat.a" \
  --passL:"$LIB/libswscale.a" \
  --passL:"$LIB/libswresample.a" \
  --passL:"$LIB/libavutil.a" \
  --passL:"$LIB/libx264.a" \
  --passL:"-Wl,--end-group" \
  --passL:"-lz -lbz2 -lm" \
  --passL:"-lws2_32 -lsecur32 -lbcrypt -lole32 -lstrmiids -lksuser -lmfuuid -ldxva2 -levr" \
  --passL:"-static -static-libgcc -static-libstdc++" \
  -o:PMI.exe \
  PMI.nim
```

Пояснения:

- `--gcc.exe` / `--gcc.linkerexe` переключают Nim на `x86_64-w64-mingw32-gcc`
  вместо системного `gcc` — это и есть собственно кросс-компиляция.
- Группа `-Wl,--start-group … --end-group` нужна так же, как в Linux-сборке,
  из-за циклических зависимостей между `.a`.
- Дополнительные `-l...` (`ws2_32`, `secur32`, `bcrypt`, `ole32`,
  `strmiids`, `ksuser`, `mfuuid`, `dxva2`, `evr`) — системные Windows-библиотеки,
  которые требует FFmpeg на mingw (сеть, крипто, DirectShow/Media Foundation
  линкуются безусловно даже при `--disable-programs`). Если линковщик
  пожалуется на неразрешённые символы — добавляйте недостающую библиотеку
  по имени функции из ошибки (`undefined reference to ...@...`).

> **Важно:** пока `config.nims` не умеет собирать под mingw сам, поэтому при
> кросс-сборке его лучше временно отключать/игнорировать и использовать
> команду из шага 4 напрямую, указывая на `ffmpeg_build_win/`.

---

## Стиль кода (v4)

Во всех `.nim`-файлах проекта выдержаны единые соглашения:

- **Префиксный вызов функций**: `len(A)`, `find(str, ch)`, `extractFilename(path)` —
  вместо `A.len()`, `str.find(ch)`, `path.extractFilename`. Точка используется
  только для доступа к полям структур (`p.decCtx`, `job.outputFile`) и для
  простых числовых конверсий (`x.float`, `x.cint`) — это идиоматичный для Nim
  «каст», а не вызов метода.
  Исключение — `echo "текст"`, как и оговорено.
- **Блочные объявления**: два и более `const`/`let`/`var` подряд объединяются
  в один блок с отступом, а не пишутся отдельными строками с повторением
  ключевого слова.
- **Групповые `import`**: модули из одной библиотеки — через `[]` одной строкой
  (`import std/[strformat, os, math]`), локальные модули проекта — через
  запятую (`import ffmpeg_api, worker, concat`).
- Код обильно прокомментирован: пояснения к структурам данных, фазам
  flush-пайплайна, единицам измерения PTS/DTS и т. д.



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

**pict_type перед энкодером** — `filtFrame.pict_type`, унаследованный от
исходного декодированного кадра (в источнике есть B-кадры), пробрасывался
через фильтр-граф без изменений и попадал в `avcodec_send_frame`.
libx264-обёртка трактует ненулевой `pict_type` как явное указание типа
кадра, из-за чего на границах сегментов x264 ругался
`specified frame type ... not compatible with keyframe interval`
и сам принудительно менял тип. Перед кодированием `pict_type` теперь
сбрасывается в `AV_PICTURE_TYPE_NONE`, чтобы x264 сам решал I/P/B по
своей GOP-структуре.

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
