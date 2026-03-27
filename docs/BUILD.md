# PMI — Руководство по сборке

Подробное руководство по компиляции всех зависимостей (libx264, FFmpeg) и самого приложения PMI на **Linux** и **Windows**.

---

## Содержание

1. [Требования к системе](#1-требования-к-системе)
2. [Структура директорий](#2-структура-директорий)
3. [Сборка на Linux](#3-сборка-на-linux)
   - 3.1 [Установка системных зависимостей](#31-установка-системных-зависимостей)
   - 3.2 [Сборка libx264](#32-сборка-libx264-опционально)
   - 3.3 [Сборка FFmpeg](#33-сборка-ffmpeg)
   - 3.4 [Сборка PMI](#34-сборка-pmi)
   - 3.5 [Проверка сборки](#35-проверка-сборки)
4. [Сборка на Windows (MSYS2 / MinGW-w64)](#4-сборка-на-windows-msys2--mingw-w64)
   - 4.1 [Установка MSYS2](#41-установка-msys2)
   - 4.2 [Установка зависимостей в MSYS2](#42-установка-зависимостей-в-msys2)
   - 4.3 [Сборка libx264](#43-сборка-libx264-опционально-1)
   - 4.4 [Сборка FFmpeg](#44-сборка-ffmpeg-1)
   - 4.5 [Установка Nim](#45-установка-nim)
   - 4.6 [Сборка PMI](#46-сборка-pmi-1)
   - 4.7 [Проверка сборки](#47-проверка-сборки-1)
5. [Устранение типичных ошибок](#5-устранение-типичных-ошибок)
6. [Детали линковки](#6-детали-линковки)

---

## 1. Требования к системе

| Компонент | Минимум | Рекомендуется |
|---|---|---|
| ОС | Linux x86-64 / Windows 10 x64 | Linux / Windows 11 |
| GCC | 12+ | 14+ |
| RAM при сборке FFmpeg | 2 ГБ | 4 ГБ |
| Дисковое пространство | ~1 ГБ | ~2 ГБ |
| Nim | 1.6+ | 2.0+ |

Проверить версию Nim:

```bash
nim --version
```

---

## 2. Структура директорий

PMI ожидает следующую структуру по умолчанию. Все пути можно переопределить аргументами Makefile.

```
~/projects/
├── FFmpeg/                     ← исходники FFmpeg
├── x264/                       ← исходники libx264 (если собирать вручную)
└── PMI/                        ← исходники PMI
    ├── PMI.nim
    ├── worker.nim
    ├── concat.nim
    ├── ffmpeg_api.nim
    ├── Makefile
    ├── Makefile.windows
    └── ffmpeg_build/           ← создаётся при make build-ffmpeg
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

Если FFmpeg лежит в другом месте — путь передаётся явно:

```bash
make build-ffmpeg FFMPEG_SRC=/opt/sources/FFmpeg
make build
```

---

## 3. Сборка на Linux

### 3.1 Установка системных зависимостей

Выберите команду для своего дистрибутива:

**Fedora / RHEL / CentOS Stream:**

```bash
sudo dnf install -y \
  gcc gcc-c++ make pkg-config \
  nasm yasm \
  nim \
  x264-devel \
  zlib-devel bzip2-devel xz-devel \
  git
```

**Ubuntu / Debian:**

```bash
sudo apt update && sudo apt install -y \
  gcc g++ make pkg-config \
  nasm yasm \
  nim \
  libx264-dev \
  zlib1g-dev libbz2-dev liblzma-dev \
  git
```

> На некоторых версиях Ubuntu пакет `nim` может быть устаревшим. В таком случае используйте choosenim (см. ниже).

**Arch Linux / Manjaro:**

```bash
sudo pacman -S --needed \
  gcc make pkg-config \
  nasm yasm \
  nim \
  x264 \
  zlib bzip2 xz \
  git
```

#### Установка Nim через choosenim (универсальный способ)

Если версия Nim в репозитории дистрибутива устарела или отсутствует:

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
# Добавить в ~/.bashrc или ~/.zshrc:
export PATH="$HOME/.nimble/bin:$PATH"
```

---

**Назначение пакетов:**

- `nasm`, `yasm` — ассемблеры для SIMD-оптимизаций FFmpeg; без них сборка пройдёт, но производительность будет ниже на 20–40%
- `x264-devel` / `libx264-dev` / `x264` — libx264 для статической линковки через `--enable-libx264`
- `zlib`, `bzip2`, `xz` — сжатие, требуется для ряда контейнеров и демуксеров
- `gcc-c++` / `g++` — нужен для сборки некоторых частей FFmpeg

Проверить наличие всего:

```bash
make check-deps
```

---

### 3.2 Сборка libx264 (опционально)

> Если пакет `x264-devel` / `libx264-dev` / `x264` уже установлен через менеджер пакетов — этот шаг можно пропустить. Собирать вручную имеет смысл только для получения свежей версии или специфических флагов компилятора.

```bash
cd ~/projects
git clone https://code.videolan.org/videolan/x264.git
cd x264

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

- `--enable-static` — собрать `libx264.a`
- `--enable-pic` — Position Independent Code, обязателен при статической линковке
- `--disable-cli` — не собирать утилиту `x264`
- `--bit-depth=all` — поддержка 8-bit и 10-bit в одной библиотеке

Проверка:

```bash
pkg-config --modversion x264
ls -lh /usr/local/lib/libx264.a
```

---

### 3.3 Сборка FFmpeg

FFmpeg собирается как набор статических `.a`-библиотек и устанавливается в `PMI/ffmpeg_build/`. В системе глобально не регистрируется.

#### Клонирование исходников

```bash
cd ~/projects
git clone https://github.com/FFmpeg/FFmpeg.git FFmpeg
# Зафиксировать конкретный тег для воспроизводимой сборки:
cd FFmpeg && git checkout n7.1
```

#### Сборка через Makefile (рекомендуется)

```bash
cd ~/projects/PMI
make build-ffmpeg
```

Сборка займёт **10–20 минут** в зависимости от железа.

#### Сборка вручную

```bash
cd ~/projects/FFmpeg

./configure \
  --prefix="$HOME/projects/PMI/ffmpeg_build" \
  --enable-static \
  --disable-shared \
  --enable-pic \
  --enable-gpl \
  --enable-version3 \
  --enable-libx264 \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --disable-autodetect \
  --enable-protocol=file \
  --enable-demuxer=matroska,mov,mpegts,avi,flv,concat \
  --enable-muxer=matroska,mp4,mov,avi,segment \
  --enable-decoder=h264,hevc,mpeg4,mpeg2video,vp9,vp8,av1 \
  --enable-decoder=aac,ac3,mp3,eac3,dts,opus,vorbis,flac,truehd \
  --enable-decoder=ass,ssa,srt,subrip,dvd_subtitle,hdmv_pgs_subtitle \
  --enable-encoder=libx264 \
  --enable-parser=h264,hevc,aac,ac3,mpegaudio,vp9,av1,mpeg4video \
  --enable-filter=minterpolate,buffer,buffersink,scale,format,fps,setpts,fifo \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata \
  --extra-cflags="-O3 -march=native -fPIC" \
  --extra-ldflags="-static-libgcc" \
  --pkg-config-flags="--static"

make -j$(nproc)
make install
```

**Ключевые флаги:**

| Флаг | Назначение |
|---|---|
| `--enable-static` / `--disable-shared` | Только `.a`, без `.so` |
| `--enable-pic` | Position Independent Code — обязателен при статической линковке |
| `--enable-gpl` | GPL-лицензия — открывает доступ к libx264 |
| `--enable-libx264` | Включить H.264-энкодер |
| `--disable-programs` | Не собирать `ffmpeg`, `ffprobe`, `ffplay` — экономит время |
| `--disable-autodetect` | Не искать системные библиотеки автоматически — воспроизводимая сборка |
| `--extra-cflags="-march=native"` | Оптимизация под текущий CPU (AVX2, AVX-512) |
| `--pkg-config-flags="--static"` | pkg-config возвращает флаги для статической линковки |

Проверка результата:

```bash
ls -lh ~/projects/PMI/ffmpeg_build/lib/*.a
# Ожидаемые размеры:
#  43M  libavcodec.a
#  11M  libavfilter.a
#  17M  libavformat.a
# 2.5M  libswresample.a
# 3.5M  libswscale.a
#  12M  libavutil.a
```

---

### 3.4 Сборка PMI

```bash
cd ~/projects/PMI
make build
# Бинарь: ./PMI
```

Отладочная сборка:

```bash
make debug
# Бинарь: ./PMI_debug
```

Полная сборка с нуля одной командой:

```bash
make build-ffmpeg && make build
```

---

### 3.5 Проверка сборки

```bash
# Убедиться что нет зависимостей от системных libav*
ldd ./PMI | grep -E "libav|libx264"
# Ожидаемый вывод: пусто

./PMI --help
```

Статически слинкованный PMI зависит только от стандартных библиотек (`libpthread`, `libm`, `libc`, `libdl`) и может быть перенесён на любую другую Linux-машину без установки дополнительных пакетов.

---

## 4. Сборка на Windows (MSYS2 / MinGW-w64)

На Windows сборка ведётся в окружении **MSYS2** с тулчейном **MinGW-w64 UCRT64**. Это даёт полноценный GCC, bash, make и pkg-config — всё необходимое для сборки FFmpeg и PMI без изменений в исходном коде.

> MSYS2 использует `pacman` (как Arch Linux) для управления пакетами.

---

### 4.1 Установка MSYS2

1. Скачайте установщик с **https://www.msys2.org/**
2. Установите в `C:\msys64` (путь по умолчанию, рекомендуется оставить)
3. После установки запустите **«MSYS2 UCRT64»** из меню Пуск

> Важно использовать именно **UCRT64**, а не MSYS, MINGW32 или CLANG64. UCRT64 использует современный Universal C Runtime и 64-битный GCC.

Первичное обновление базы пакетов:

```bash
pacman -Syu
# Терминал закроется — откройте снова MSYS2 UCRT64 и выполните:
pacman -Su
```

---

### 4.2 Установка зависимостей в MSYS2

Все команды выполняются в терминале **MSYS2 UCRT64**:

```bash
pacman -S --needed \
  mingw-w64-ucrt-x86_64-gcc \
  mingw-w64-ucrt-x86_64-make \
  mingw-w64-ucrt-x86_64-pkg-config \
  mingw-w64-ucrt-x86_64-nasm \
  mingw-w64-ucrt-x86_64-yasm \
  mingw-w64-ucrt-x86_64-x264 \
  mingw-w64-ucrt-x86_64-zlib \
  mingw-w64-ucrt-x86_64-bzip2 \
  mingw-w64-ucrt-x86_64-xz \
  git \
  make
```

Проверить GCC:

```bash
gcc --version
# gcc (Rev..., Built by MSYS2 project) 14.x.x
```

---

### 4.3 Сборка libx264 (опционально)

> Пакет `mingw-w64-ucrt-x86_64-x264` из репозитория MSYS2 достаточен для большинства случаев. Собирать вручную нужно только для нестандартных конфигураций.

```bash
cd ~/projects
git clone https://code.videolan.org/videolan/x264.git
cd x264

./configure \
  --prefix=/ucrt64 \
  --host=x86_64-w64-mingw32 \
  --enable-static \
  --enable-pic \
  --disable-cli \
  --bit-depth=all

make -j$(nproc)
make install
```

---

### 4.4 Сборка FFmpeg

```bash
cd ~/projects
git clone https://github.com/FFmpeg/FFmpeg.git FFmpeg
cd FFmpeg && git checkout n7.1
```

Конфигурация для MinGW-w64:

```bash
./configure \
  --prefix="$HOME/projects/PMI/ffmpeg_build" \
  --arch=x86_64 \
  --target-os=mingw32 \
  --cross-prefix=x86_64-w64-mingw32- \
  --enable-static \
  --disable-shared \
  --enable-gpl \
  --enable-version3 \
  --enable-libx264 \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --disable-autodetect \
  --enable-protocol=file \
  --enable-demuxer=matroska,mov,mpegts,avi,flv,concat \
  --enable-muxer=matroska,mp4,mov,avi,segment \
  --enable-decoder=h264,hevc,mpeg4,mpeg2video,vp9,vp8,av1 \
  --enable-decoder=aac,ac3,mp3,eac3,dts,opus,vorbis,flac,truehd \
  --enable-decoder=ass,ssa,srt,subrip,dvd_subtitle,hdmv_pgs_subtitle \
  --enable-encoder=libx264 \
  --enable-parser=h264,hevc,aac,ac3,mpegaudio,vp9,av1,mpeg4video \
  --enable-filter=minterpolate,buffer,buffersink,scale,format,fps,setpts,fifo \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata \
  --extra-cflags="-O3 -march=native" \
  --extra-ldflags="-static" \
  --pkg-config-flags="--static"

make -j$(nproc)
make install
```

**Отличия от Linux-конфигурации:**

| Флаг | Назначение |
|---|---|
| `--target-os=mingw32` | Сборка для Windows |
| `--arch=x86_64` | 64-битная цель |
| `--cross-prefix=x86_64-w64-mingw32-` | Префикс тулчейна MinGW-w64 |
| `--extra-ldflags="-static"` | Полная статическая линковка (вместо `-static-libgcc`) |
| Нет `--enable-pic` | На Windows PIC не нужен для исполняемых файлов |

---

### 4.5 Установка Nim

**Вариант 1 — официальный установщик (рекомендуется):**

1. Скачайте с **https://nim-lang.org/install_windows.html**
2. Установите, добавив `nim` и `nimble` в системный PATH
3. Откройте новый терминал MSYS2 UCRT64 и проверьте:

```bash
nim --version
```

**Вариант 2 — choosenim в MSYS2:**

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
export PATH="$HOME/.nimble/bin:$PATH"
```

**Важно:** Nim должен использовать GCC из MSYS2, а не MSVC. Проверить:

```bash
nim c -e "echo gorge(\"gcc --version\")"
# Должен выводить версию MinGW GCC, а не cl.exe
```

---

### 4.6 Сборка PMI

```bash
cd ~/projects/PMI
make -f Makefile.windows build
# Бинарь: ./PMI.exe
```

Эквивалентная команда `nim` вручную:

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
  --passL:"-lx264 -lz -lbz2 -llzma -lm -lws2_32 -lsecur32 -lbcrypt" \
  -o:PMI.exe \
  PMI.nim
```

**Системные библиотеки Windows вместо Linux-аналогов:**

| Linux | Windows (MinGW) | Назначение |
|---|---|---|
| `-lpthread` | встроен в libwinpthread | Потоки |
| `-ldl` | не нужен | Динамическая загрузка |
| — | `-lws2_32` | Windows Sockets (сеть внутри FFmpeg) |
| — | `-lsecur32` | Security API |
| — | `-lbcrypt` | Crypto API (хеши внутри FFmpeg) |

---

### 4.7 Проверка сборки

```bash
# Проверить зависимости от DLL
objdump -p PMI.exe | grep "DLL Name"
# Должны быть только системные DLL: kernel32.dll, msvcrt.dll, winpthread-*.dll и т.п.
# Не должно быть: avcodec-*.dll, avformat-*.dll, x264-*.dll

./PMI.exe --help
```

Готовый `PMI.exe` можно перенести на любую Windows 10/11 x64 без установки дополнительного ПО.

---

## 5. Устранение типичных ошибок

### `configure: error: libx264 not found`

```bash
# Проверить установку
pkg-config --exists x264 && echo OK || echo NOT FOUND

# Установить через менеджер пакетов:
sudo dnf install x264-devel           # Fedora
sudo apt install libx264-dev           # Ubuntu
sudo pacman -S x264                    # Arch
pacman -S mingw-w64-ucrt-x86_64-x264  # MSYS2

# Если собирали вручную в /usr/local:
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
```

### `nasm/yasm not found`

```bash
sudo dnf install nasm yasm           # Fedora
sudo apt install nasm yasm           # Ubuntu
sudo pacman -S nasm yasm             # Arch
pacman -S mingw-w64-ucrt-x86_64-nasm mingw-w64-ucrt-x86_64-yasm  # MSYS2
```

FFmpeg соберётся без них, но без SIMD-оптимизаций.

### `error: undefined reference to 'av_...'` при сборке PMI

Все libav-библиотеки должны быть обёрнуты в `--start-group` / `--end-group` — это разрешает циклические зависимости между `.a`-файлами при многопроходной линковке GNU `ld`:

```makefile
--passL:"-Wl,--start-group"
  ... все libav*.a ...
--passL:"-Wl,--end-group"
```

### `error: 'AVCodec' has no member named '...'`

Версия заголовков в `ffmpeg_build/include/` не совпадает с `.a`-библиотеками. Пересобрать FFmpeg полностью:

```bash
make clean-all
make build-ffmpeg
make build
```

### Медленная сборка FFmpeg

На 4 ядрах — ~15 мин, на 8 ядрах — ~8 мин. Задать явно:

```bash
nproc                          # проверить число доступных ядер
make build-ffmpeg JOBS=8
```

### Windows: `nim: command not found` в MSYS2

Nim установлен в Windows, но путь не виден в MSYS2. Добавьте в `~/.bashrc` внутри MSYS2:

```bash
# Путь к установке Nim (Windows-формат через /c/...):
export PATH="/c/Users/$USER/.nimble/bin:$PATH"
# Или если Nim установлен в Program Files:
export PATH="/c/Program Files/nim/bin:$PATH"
```

### Windows: ошибки линковки с `-lpthread`

В MinGW-w64 pthreads реализованы через `libwinpthread`. Если линковщик жалуется:

```bash
pacman -S mingw-w64-ucrt-x86_64-winpthreads-git
```

---

## 6. Детали линковки

### Порядок библиотек FFmpeg

```
libavfilter → libavcodec → libavformat → libswscale → libswresample → libavutil
```

При использовании `--start-group`/`--end-group` порядок формально не важен, но соблюдение его ускоряет линковку.

### Почему полный путь к `.a`, а не `-lavcodec`

```makefile
# ✓ Правильно — гарантированно берётся .a из ffmpeg_build
--passL:"$(LIB)/libavcodec.a"

# ✗ Неправильно — линкер может найти системную .so/.dll вместо нашей .a
--passL:"-lavcodec"
```

### Системные библиотеки

**Linux:**

| Библиотека | Назначение |
|---|---|
| `-lx264` | Кодек H.264 |
| `-lz` | zlib |
| `-lbz2` | bzip2 |
| `-llzma` | liblzma |
| `-lpthread` | POSIX-потоки |
| `-lm` | Математические функции |
| `-ldl` | Динамическая загрузка |

**Windows (MinGW-w64):**

| Библиотека | Назначение |
|---|---|
| `-lx264` | Кодек H.264 |
| `-lz`, `-lbz2`, `-llzma` | Сжатие |
| `-lm` | Математические функции |
| `-lws2_32` | Windows Sockets |
| `-lsecur32` | Security API |
| `-lbcrypt` | Crypto API |
