# PMI — Руководство по сборке

Подробное руководство по компиляции всех зависимостей (libx264, FFmpeg) и самого приложения PMI на Fedora Linux.

---

## Содержание

1. [Требования к системе](#1-требования-к-системе)
2. [Структура директорий](#2-структура-директорий)
3. [Установка системных зависимостей](#3-установка-системных-зависимостей)
4. [Сборка libx264](#4-сборка-libx264-опционально)
5. [Сборка FFmpeg со статической линковкой](#5-сборка-ffmpeg)
6. [Сборка PMI](#6-сборка-pmi)
7. [Проверка сборки](#7-проверка-сборки)
8. [Устранение типичных ошибок](#8-устранение-типичных-ошибок)
9. [Детали линковки](#9-детали-линковки)

---

## 1. Требования к системе

| Компонент | Минимум | Рекомендуется |
|---|---|---|
| ОС | Fedora 38+ | Fedora 40+ |
| GCC | 12+ | 14+ |
| RAM при сборке FFmpeg | 2 ГБ | 4 ГБ |
| Дисковое пространство | ~1 ГБ | ~2 ГБ |
| Nim | 1.6+ | 2.0+ |

Проверить версию Nim:
```bash
nim --version
```

Если Nim не установлен:
```bash
sudo dnf install nim
# или через choosenim:
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

---

## 2. Структура директорий

PMI ожидает следующую структуру по умолчанию. Все пути можно переопределить аргументами Makefile.

```
~/projects/                     ← произвольная родительская папка
├── FFmpeg/                     ← исходники FFmpeg (клонируется сюда)
├── x264/                       ← исходники libx264 (опционально, если собирать вручную)
└── PMI/                        ← исходники PMI
    ├── PMI.nim
    ├── worker.nim
    ├── concat.nim
    ├── ffmpeg_api.nim
    ├── Makefile
    ├── scripts/
    │   └── build_ffmpeg.sh
    └── ffmpeg_build/           ← создаётся автоматически при make build-ffmpeg
        ├── include/
        │   ├── libavcodec/
        │   ├── libavfilter/
        │   ├── libavformat/
        │   ├── libavutil/
        │   ├── libswresample/
        │   └── libswscale/
        └── lib/
            ├── libavcodec.a
            ├── libavfilter.a
            ├── libavformat.a
            ├── libavutil.a
            ├── libswresample.a
            └── libswscale.a
```

Если FFmpeg лежит в другом месте, путь передаётся явно:
```bash
make build-ffmpeg FFMPEG_SRC=/opt/sources/FFmpeg
make build
```

---

## 3. Установка системных зависимостей

```bash
sudo dnf install -y \
  gcc gcc-c++ make pkg-config \
  nasm yasm \
  nim \
  x264-devel \
  zlib-devel \
  bzip2-devel \
  xz-devel \
  git
```

**Назначение каждого пакета:**

- `nasm`, `yasm` — ассемблеры, используются FFmpeg для оптимизированных SIMD-функций (без них сборка пройдёт, но будет медленнее на ~20–40%)
- `x264-devel` — системная libx264; FFmpeg будет слинкован с ней статически через `--enable-libx264`
- `zlib-devel`, `bzip2-devel`, `xz-devel` — сжатие, необходимо для некоторых контейнеров и демуксеров
- `gcc-c++` — нужен для сборки некоторых частей FFmpeg

Проверить наличие всего:
```bash
make check-deps
```

---

## 4. Сборка libx264 (опционально)

> **Если `x264-devel` уже установлен через dnf — этот шаг можно пропустить.**  
> Собирать libx264 вручную имеет смысл если нужна свежая версия или специфические флаги.

### Клонирование исходников

```bash
cd ~/projects
git clone https://code.videolan.org/videolan/x264.git
cd x264
```

### Конфигурация и сборка

```bash
./configure \
  --prefix=/usr/local \
  --enable-static \
  --enable-pic \
  --disable-cli \
  --bit-depth=all

make -j$(nproc)
sudo make install
sudo ldconfig
```

**Флаги:**
- `--enable-static` — статическая библиотека `libx264.a`
- `--enable-pic` — Position Independent Code, обязателен для статической линковки в разделяемые объекты
- `--disable-cli` — не собирать утилиту командной строки `x264`
- `--bit-depth=all` — поддержка 8-bit и 10-bit

### Проверка

```bash
pkg-config --modversion x264
# вывод: 0.164.xxxx (или выше)

ls -lh /usr/local/lib/libx264.a
```

---

## 5. Сборка FFmpeg

FFmpeg собирается как набор статических `.a`-библиотек, устанавливаемых в `PMI/ffmpeg_build/`. В продакшн-системе не устанавливается, используется только PMI.

### Клонирование исходников FFmpeg

```bash
cd ~/projects
git clone https://git.ffmpeg.org/ffmpeg.git FFmpeg
# или зеркало на GitHub (быстрее):
git clone https://github.com/FFmpeg/FFmpeg.git FFmpeg
```

> Используется стабильная ветка `master`. Для воспроизводимости можно зафиксировать конкретный тег:
> ```bash
> cd FFmpeg
> git checkout n7.1
> ```

### Сборка через Makefile (рекомендуется)

```bash
cd ~/projects/PMI
make build-ffmpeg
```

Makefile автоматически:
1. Проверит наличие `FFmpeg/configure`
2. Установит недостающие зависимости через `dnf`
3. Запустит `./configure` с нужными флагами
4. Выполнит `make -j$(nproc)` и `make install` в `ffmpeg_build/`

Сборка займёт **10–20 минут** в зависимости от железа.

### Сборка вручную (для отладки)

Если нужно контролировать каждый шаг или Makefile не подходит:

```bash
cd ~/projects/FFmpeg

./configure \
  --prefix="$HOME/projects/PMI/ffmpeg_build" \
  \
  --enable-static \
  --disable-shared \
  --enable-pic \
  \
  --enable-gpl \
  --enable-version3 \
  \
  --enable-libx264 \
  \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --disable-autodetect \
  \
  --enable-protocol=file \
  \
  --enable-demuxer=matroska,mov,mpegts,avi,flv,concat \
  --enable-muxer=matroska,mp4,mov,avi,segment \
  \
  --enable-decoder=h264,hevc,mpeg4,mpeg2video,vp9,vp8,av1 \
  --enable-decoder=aac,ac3,mp3,eac3,dts,opus,vorbis,flac,truehd \
  --enable-decoder=ass,ssa,srt,subrip,dvd_subtitle,hdmv_pgs_subtitle \
  --enable-encoder=libx264 \
  \
  --enable-parser=h264,hevc,aac,ac3,mpegaudio,vp9,av1,mpeg4video \
  \
  --enable-filter=minterpolate,buffer,buffersink,scale,format,fps,setpts,fifo \
  \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata \
  \
  --extra-cflags="-O3 -march=native -fPIC" \
  --extra-ldflags="-static-libgcc" \
  --pkg-config-flags="--static"

make -j$(nproc)
make install
```

**Ключевые флаги конфигурации:**

| Флаг | Назначение |
|---|---|
| `--enable-static` / `--disable-shared` | Только статические `.a`, без `.so` |
| `--enable-pic` | Position Independent Code — обязателен при статической линковке |
| `--enable-gpl` | Лицензия GPL — открывает доступ к libx264 и другим GPL-компонентам |
| `--enable-libx264` | Включить энкодер H.264 через libx264 |
| `--disable-programs` | Не собирать `ffmpeg`, `ffprobe`, `ffplay` — экономит время |
| `--disable-autodetect` | Не искать системные библиотеки автоматически — воспроизводимая сборка |
| `--extra-cflags="-march=native"` | Оптимизация под текущий CPU (AVX2, AVX-512 если доступны) |
| `--pkg-config-flags="--static"` | pkg-config возвращает флаги для статической линковки |

### Проверка результата

```bash
ls -lh ~/projects/PMI/ffmpeg_build/lib/*.a
```

Ожидаемый вывод:
```
 43M  libavcodec.a
 11M  libavfilter.a
 17M  libavformat.a
2.5M  libswresample.a
3.5M  libswscale.a
 12M  libavutil.a
```

---

## 6. Сборка PMI

После того как `ffmpeg_build/lib/*.a` готовы:

```bash
cd ~/projects/PMI
make build
```

Это эквивалентно:
```bash
nim c \
  -d:release --opt:speed \
  --threads:on --mm:orc \
  --experimental:parallel \
  --passC:"-I./ffmpeg_build/include" \
  --passL:"-Wl,--start-group" \
  --passL:"./ffmpeg_build/lib/libavfilter.a" \
  --passL:"./ffmpeg_build/lib/libavcodec.a" \
  --passL:"./ffmpeg_build/lib/libavformat.a" \
  --passL:"./ffmpeg_build/lib/libswscale.a" \
  --passL:"./ffmpeg_build/lib/libswresample.a" \
  --passL:"./ffmpeg_build/lib/libavutil.a" \
  --passL:"-Wl,--end-group" \
  --passL:"-lx264 -lz -lbz2 -llzma -lpthread -lm -ldl" \
  -o:PMI PMI.nim
```

### Отладочная сборка

```bash
make debug
# создаёт PMI_debug с символами отладки
```

### Полная сборка с нуля (одна команда)

```bash
make build-ffmpeg && make build
```

---

## 7. Проверка сборки

```bash
# Проверить, что бинарь собран статически (нет зависимостей от libav*)
ldd ./PMI | grep -E "libav|libx264"
# Ожидаемый вывод: пусто (все зависимости встроены)

# Базовый тест
./PMI --help

# Узнать CPU-ядра (должно совпадать с nproc)
./PMI --help 2>&1 | head -1
```

### Зависимости бинаря

Статически слинкованный PMI зависит только от стандартных системных библиотек:

```bash
ldd ./PMI
# libpthread.so  — потоки
# libm.so        — математика
# libc.so        — стандартная библиотека C
# libdl.so       — динамическая загрузка (нужна внутри FFmpeg)
```

Бинарь можно скопировать на любую Fedora/RHEL-машину без установки каких-либо дополнительных пакетов.

---

## 8. Устранение типичных ошибок

### `configure: error: libx264 not found`

```bash
# Проверить установку
pkg-config --exists x264 && echo OK || echo NOT FOUND

# Установить
sudo dnf install x264-devel

# Если собирали вручную в /usr/local — обновить pkgconfig path
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
```

### `nasm/yasm not found`

```bash
sudo dnf install nasm yasm
```

FFmpeg всё равно соберётся без них, но выдаст предупреждение и не будет использовать SIMD-оптимизации.

### `error: undefined reference to 'av_...'` при сборке PMI

Порядок линковки имеет значение. GNU `ld` читает `.a`-файлы слева направо и разрешает символы только вперёд. Поэтому библиотеки обёрнуты в `--start-group` / `--end-group`:

```makefile
--passL:"-Wl,--start-group"
  ... все libav*.a ...
--passL:"-Wl,--end-group"
```

Это позволяет линкеру делать несколько проходов и разрешать циклические зависимости между `.a`-файлами.

### `error: 'AVCodec' has no member named '...'`

Версия FFmpeg в `ffmpeg_build/include/` не совпадает с той, под которую написан `ffmpeg_api.nim`. Убедитесь что заголовки и `.a`-библиотеки из одной сборки:

```bash
# Удалить старую сборку и пересобрать
make clean-all
make build-ffmpeg
make build
```

### Медленная сборка FFmpeg

На 4 ядрах ожидается ~15 мин, на 8 ядрах ~8 мин. Если сборка идёт на одном ядре — убедитесь что `nproc` работает корректно:

```bash
nproc
# если выдаёт 1 — проверьте настройки контейнера/виртуальной машины
make build-ffmpeg JOBS=8  # задать явно
```

---

## 9. Детали линковки

### Порядок библиотек FFmpeg

```
libavfilter → libavcodec → libavformat → libswscale → libswresample → libavutil
```

Каждая последующая зависит от предыдущих. При использовании `--start-group`/`--end-group` порядок формально не важен, но соблюдение его ускоряет линковку.

### Почему полный путь к `.a`, а не `-lavcodec`

```makefile
# ✓ Правильно — гарантированно берётся статическая библиотека из ffmpeg_build
--passL:"$(LIB)/libavcodec.a"

# ✗ Неправильно — линкер может найти системную libavcodec.so вместо нашей .a
--passL:"-lavcodec"
```

### Системные библиотеки (`-lx264 -lz -lbz2 -llzma`)

Эти библиотеки FFmpeg использует внутри своих `.a`-файлов. Они не встроены в `.a` и должны быть слинкованы отдельно:

- `-lx264` — кодек H.264
- `-lz` — zlib (сжатие)
- `-lbz2` — bzip2 (TS-контейнеры)
- `-llzma` — liblzma (некоторые контейнеры)
- `-lpthread` — POSIX-потоки
- `-lm` — математические функции
- `-ldl` — динамическая загрузка (внутри avformat)
