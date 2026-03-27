# PMI — Build Guide

A complete guide to compiling all dependencies (libx264, FFmpeg) and the PMI application itself on **Linux** and **Windows**.

---

## Table of Contents

1. [System Requirements](#1-system-requirements)
2. [Directory Structure](#2-directory-structure)
3. [Building on Linux](#3-building-on-linux)
   - 3.1 [Installing System Dependencies](#31-installing-system-dependencies)
   - 3.2 [Building libx264](#32-building-libx264-optional)
   - 3.3 [Building FFmpeg](#33-building-ffmpeg)
   - 3.4 [Building PMI](#34-building-pmi)
   - 3.5 [Verifying the Build](#35-verifying-the-build)
4. [Building on Windows (MSYS2 / MinGW-w64)](#4-building-on-windows-msys2--mingw-w64)
   - 4.1 [Installing MSYS2](#41-installing-msys2)
   - 4.2 [Installing Dependencies in MSYS2](#42-installing-dependencies-in-msys2)
   - 4.3 [Building libx264](#43-building-libx264-optional-1)
   - 4.4 [Building FFmpeg](#44-building-ffmpeg-1)
   - 4.5 [Installing Nim](#45-installing-nim)
   - 4.6 [Building PMI](#46-building-pmi-1)
   - 4.7 [Verifying the Build](#47-verifying-the-build-1)
5. [Troubleshooting](#5-troubleshooting)
6. [Linker Details](#6-linker-details)

---

## 1. System Requirements

| Component | Minimum | Recommended |
|---|---|---|
| OS | Linux x86-64 / Windows 10 x64 | Linux / Windows 11 |
| GCC | 12+ | 14+ |
| RAM (during FFmpeg build) | 2 GB | 4 GB |
| Disk space | ~1 GB | ~2 GB |
| Nim | 1.6+ | 2.0+ |

Check your Nim version:

```bash
nim --version
```

---

## 2. Directory Structure

PMI expects the following default layout. All paths can be overridden via Makefile arguments.

```
~/projects/
├── FFmpeg/                     ← FFmpeg source tree
├── x264/                       ← libx264 sources (only if building manually)
└── PMI/                        ← PMI sources
    ├── PMI.nim
    ├── worker.nim
    ├── concat.nim
    ├── ffmpeg_api.nim
    ├── Makefile
    ├── Makefile.windows
    └── ffmpeg_build/           ← created by make build-ffmpeg
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

If FFmpeg lives elsewhere, pass the path explicitly:

```bash
make build-ffmpeg FFMPEG_SRC=/opt/sources/FFmpeg
make build
```

---

## 3. Building on Linux

### 3.1 Installing System Dependencies

Pick the command for your distribution:

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

> On some Ubuntu releases the `nim` package may be outdated or missing. Use choosenim in that case (see below).

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

#### Installing Nim via choosenim (universal)

If the distribution package is too old or unavailable:

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
# Add to ~/.bashrc or ~/.zshrc:
export PATH="$HOME/.nimble/bin:$PATH"
```

---

**What each package is for:**

- `nasm`, `yasm` — assemblers for FFmpeg's SIMD optimizations; the build succeeds without them but performance drops by 20–40%
- `x264-devel` / `libx264-dev` / `x264` — libx264 for static linking via `--enable-libx264`
- `zlib`, `bzip2`, `xz` — compression support required by several container formats and demuxers
- `gcc-c++` / `g++` — needed to compile certain parts of FFmpeg

Verify everything is in place:

```bash
make check-deps
```

---

### 3.2 Building libx264 (optional)

> If `x264-devel` / `libx264-dev` / `x264` is already installed via your package manager, skip this step. Building manually is only necessary when you need a newer version or specific compiler flags.

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

**Flags:**

- `--enable-static` — build `libx264.a`
- `--enable-pic` — Position Independent Code, required for static linking
- `--disable-cli` — skip building the `x264` command-line tool
- `--bit-depth=all` — support both 8-bit and 10-bit in a single library

Verify:

```bash
pkg-config --modversion x264
ls -lh /usr/local/lib/libx264.a
```

---

### 3.3 Building FFmpeg

FFmpeg is built as a set of static `.a` libraries installed into `PMI/ffmpeg_build/`. It is not registered globally on the system.

#### Cloning the sources

```bash
cd ~/projects
git clone https://github.com/FFmpeg/FFmpeg.git FFmpeg
# Pin a specific tag for reproducible builds:
cd FFmpeg && git checkout n7.1
```

#### Building via Makefile (recommended)

```bash
cd ~/projects/PMI
make build-ffmpeg
```

The build takes **10–20 minutes** depending on hardware.

#### Building manually

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

**Key configure flags:**

| Flag | Purpose |
|---|---|
| `--enable-static` / `--disable-shared` | Static `.a` only, no `.so` |
| `--enable-pic` | Position Independent Code — required for static linking |
| `--enable-gpl` | GPL license — unlocks libx264 and other GPL components |
| `--enable-libx264` | Enable the H.264 encoder |
| `--disable-programs` | Skip building `ffmpeg`, `ffprobe`, `ffplay` — saves time |
| `--disable-autodetect` | Do not search for system libraries automatically — reproducible builds |
| `--extra-cflags="-march=native"` | Optimize for the current CPU (AVX2, AVX-512 if available) |
| `--pkg-config-flags="--static"` | pkg-config returns flags for static linking |

Verify the result:

```bash
ls -lh ~/projects/PMI/ffmpeg_build/lib/*.a
# Expected sizes:
#  43M  libavcodec.a
#  11M  libavfilter.a
#  17M  libavformat.a
# 2.5M  libswresample.a
# 3.5M  libswscale.a
#  12M  libavutil.a
```

---

### 3.4 Building PMI

```bash
cd ~/projects/PMI
make build
# Binary: ./PMI
```

Debug build:

```bash
make debug
# Binary: ./PMI_debug
```

Full build from scratch in one command:

```bash
make build-ffmpeg && make build
```

---

### 3.5 Verifying the Build

```bash
# Confirm no dependencies on system libav*
ldd ./PMI | grep -E "libav|libx264"
# Expected output: empty

./PMI --help
```

A statically linked PMI depends only on standard system libraries (`libpthread`, `libm`, `libc`, `libdl`) and can be copied to any other Linux machine without installing additional packages.

---

## 4. Building on Windows (MSYS2 / MinGW-w64)

On Windows the build is done inside an **MSYS2** environment with the **MinGW-w64 UCRT64** toolchain. This provides a full GCC, bash, make, and pkg-config — everything needed to build FFmpeg and PMI without any source-code changes.

> MSYS2 uses `pacman` (like Arch Linux) as its package manager.

---

### 4.1 Installing MSYS2

1. Download the installer from **https://www.msys2.org/**
2. Install to `C:\msys64` (the default path — keep it as-is)
3. After installation, launch **"MSYS2 UCRT64"** from the Start menu

> It is important to use **UCRT64** specifically, not MSYS, MINGW32, or CLANG64. UCRT64 uses the modern Universal C Runtime and a 64-bit GCC.

Initial package database update:

```bash
pacman -Syu
# The terminal will close — reopen MSYS2 UCRT64 and run:
pacman -Su
```

---

### 4.2 Installing Dependencies in MSYS2

All commands are run inside the **MSYS2 UCRT64** terminal:

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

Verify GCC:

```bash
gcc --version
# gcc (Rev..., Built by MSYS2 project) 14.x.x
```

---

### 4.3 Building libx264 (optional)

> The `mingw-w64-ucrt-x86_64-x264` package from the MSYS2 repository is sufficient for most cases. Build manually only if you need a non-standard configuration.

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

### 4.4 Building FFmpeg

```bash
cd ~/projects
git clone https://github.com/FFmpeg/FFmpeg.git FFmpeg
cd FFmpeg && git checkout n7.1
```

Configure for MinGW-w64:

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

**Differences from the Linux configuration:**

| Flag | Purpose |
|---|---|
| `--target-os=mingw32` | Build for Windows |
| `--arch=x86_64` | 64-bit target |
| `--cross-prefix=x86_64-w64-mingw32-` | MinGW-w64 toolchain prefix |
| `--extra-ldflags="-static"` | Full static linking (replaces `-static-libgcc`) |
| No `--enable-pic` | PIC is not needed for executables on Windows |

---

### 4.5 Installing Nim

**Option 1 — official installer (recommended):**

1. Download from **https://nim-lang.org/install_windows.html**
2. Install and add `nim` and `nimble` to the system PATH
3. Open a new MSYS2 UCRT64 terminal and verify:

```bash
nim --version
```

**Option 2 — choosenim inside MSYS2:**

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
export PATH="$HOME/.nimble/bin:$PATH"
```

**Important:** Nim must use the MinGW GCC from MSYS2, not MSVC. Verify:

```bash
nim c -e "echo gorge(\"gcc --version\")"
# Should print the MinGW GCC version, not cl.exe
```

---

### 4.6 Building PMI

```bash
cd ~/projects/PMI
make -f Makefile.windows build
# Binary: ./PMI.exe
```

Equivalent manual `nim` command:

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

**Windows system libraries replacing their Linux counterparts:**

| Linux | Windows (MinGW) | Purpose |
|---|---|---|
| `-lpthread` | built into libwinpthread | Threading |
| `-ldl` | not needed | Dynamic loading |
| — | `-lws2_32` | Windows Sockets (networking inside FFmpeg) |
| — | `-lsecur32` | Security API |
| — | `-lbcrypt` | Crypto API (hashing inside FFmpeg) |

---

### 4.7 Verifying the Build

```bash
# Check DLL dependencies
objdump -p PMI.exe | grep "DLL Name"
# Expected: only system DLLs (kernel32.dll, msvcrt.dll, winpthread-*.dll, etc.)
# Must NOT appear: avcodec-*.dll, avformat-*.dll, x264-*.dll

./PMI.exe --help
```

The finished `PMI.exe` can be copied to any Windows 10/11 x64 machine without installing additional software.

---

## 5. Troubleshooting

### `configure: error: libx264 not found`

```bash
# Check installation
pkg-config --exists x264 && echo OK || echo NOT FOUND

# Install via package manager:
sudo dnf install x264-devel           # Fedora
sudo apt install libx264-dev           # Ubuntu
sudo pacman -S x264                    # Arch
pacman -S mingw-w64-ucrt-x86_64-x264  # MSYS2

# If built manually into /usr/local:
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
```

### `nasm/yasm not found`

```bash
sudo dnf install nasm yasm           # Fedora
sudo apt install nasm yasm           # Ubuntu
sudo pacman -S nasm yasm             # Arch
pacman -S mingw-w64-ucrt-x86_64-nasm mingw-w64-ucrt-x86_64-yasm  # MSYS2
```

FFmpeg will still build without them, but without SIMD optimizations.

### `error: undefined reference to 'av_...'` when building PMI

All libav libraries must be wrapped in `--start-group` / `--end-group` to allow GNU `ld` to perform multiple passes and resolve circular dependencies between `.a` files:

```makefile
--passL:"-Wl,--start-group"
  ... all libav*.a files ...
--passL:"-Wl,--end-group"
```

### `error: 'AVCodec' has no member named '...'`

The headers in `ffmpeg_build/include/` do not match the `.a` libraries. Rebuild FFmpeg from scratch:

```bash
make clean-all
make build-ffmpeg
make build
```

### FFmpeg build is slow

Expected times: ~15 min on 4 cores, ~8 min on 8 cores. To set the job count explicitly:

```bash
nproc                        # check available core count
make build-ffmpeg JOBS=8
```

### Windows: `nim: command not found` in MSYS2

Nim is installed on Windows but its path is not visible inside MSYS2. Add it to `~/.bashrc` inside MSYS2:

```bash
export PATH="/c/Users/$USER/.nimble/bin:$PATH"
# Or if Nim was installed to Program Files:
export PATH="/c/Program Files/nim/bin:$PATH"
```

### Windows: linker errors involving `-lpthread`

In MinGW-w64, pthreads are provided by `libwinpthread`. If the linker complains:

```bash
pacman -S mingw-w64-ucrt-x86_64-winpthreads-git
```

---

## 6. Linker Details

### FFmpeg library order

```
libavfilter → libavcodec → libavformat → libswscale → libswresample → libavutil
```

With `--start-group`/`--end-group` the order is technically irrelevant, but following it speeds up linking.

### Why full paths to `.a` instead of `-lavcodec`

```makefile
# ✓ Correct — guaranteed to pick the .a from ffmpeg_build
--passL:"$(LIB)/libavcodec.a"

# ✗ Wrong — the linker may find a system .so/.dll instead of our .a
--passL:"-lavcodec"
```

### System libraries

**Linux:**

| Library | Purpose |
|---|---|
| `-lx264` | H.264 codec |
| `-lz` | zlib |
| `-lbz2` | bzip2 |
| `-llzma` | liblzma |
| `-lpthread` | POSIX threads |
| `-lm` | Math functions |
| `-ldl` | Dynamic loading |

**Windows (MinGW-w64):**

| Library | Purpose |
|---|---|
| `-lx264` | H.264 codec |
| `-lz`, `-lbz2`, `-llzma` | Compression |
| `-lm` | Math functions |
| `-lws2_32` | Windows Sockets |
| `-lsecur32` | Security API |
| `-lbcrypt` | Crypto API |
