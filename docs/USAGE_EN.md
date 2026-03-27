# PMI — User Guide

**PMI (Parallel Motion Interpolate)** is a tool for increasing video frame rate using optical flow interpolation (`minterpolate` filter). The input video is split into segments, each processed in parallel, and the segments are then joined together. Audio tracks and subtitles are copied without re-encoding.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Full Parameter Reference](#2-full-parameter-reference)
3. [Usage Examples](#3-usage-examples)
4. [Interpolation Quality Settings](#4-interpolation-quality-settings)
5. [x264 Encoding Settings](#5-x264-encoding-settings)
6. [Parallelism and Performance](#6-parallelism-and-performance)
7. [Supported Formats](#7-supported-formats)
8. [Understanding the Output](#8-understanding-the-output)
9. [Recommendations and Limitations](#9-recommendations-and-limitations)

---

## 1. Quick Start

```bash
# Upscale a film to 60 fps with default settings
./PMI -i film.mkv -o film_60fps.mkv --fps=60

# Minimal command (input file as a positional argument)
./PMI film.mkv --fps=60
# → produces output.mkv
```

---

## 2. Full Parameter Reference

### Core parameters

| Parameter | Default | Description |
|---|---|---|
| `-i`, `--input=FILE` | `input.mkv` | Input video file |
| `-o`, `--output=FILE` | `output.mkv` | Output video file |
| `--fps=N` | `60` | Target frame rate (1–240) |
| `-j`, `--jobs=N` | auto (= CPU count) | Number of parallel worker threads |

### Interpolation parameters (`minterpolate`)

| Parameter | Default | Options | Description |
|---|---|---|---|
| `--mi-mode=MODE` | `mci` | `mci`, `blend`, `dup` | Interpolation algorithm |
| `--mc-mode=MODE` | `aobmc` | `aobmc`, `obmc` | Motion compensation algorithm |
| `--me-mode=MODE` | `bidir` | `bidir`, `bilat` | Motion estimation algorithm |
| `--vsbmc=N` | `1` | `0`, `1` | Variable-size block motion compensation |

### Encoding parameters (x264)

| Parameter | Default | Description |
|---|---|---|
| `--preset=NAME` | `slow` | Speed/quality trade-off: `ultrafast` → `veryslow` |
| `--crf=N` | `18` | Quality: 0 (best) — 51 (worst); 18–23 is optimal |

### Miscellaneous

| Parameter | Default | Description |
|---|---|---|
| `--temp-dir=DIR` | `.pmi_tmp_*` | Directory for temporary segment files |
| `--keep-temp` | off | Do not delete temporary segments after completion |
| `-v`, `--verbose` | off | Enable verbose FFmpeg output (`AV_LOG_INFO`) |
| `-h`, `--help` | — | Show help |

---

## 3. Usage Examples

### Basic scenarios

```bash
# 24 → 60 fps, default settings
./PMI -i film.mkv -o film_60fps.mkv --fps=60

# 24 → 120 fps
./PMI -i film.mkv -o film_120fps.mkv --fps=120

# 25 → 90 fps (sports, animation)
./PMI -i cartoon.mp4 -o cartoon_90fps.mkv --fps=90

# Input file as positional argument
./PMI film.mkv --fps=60 -o film_60fps.mkv
```

### Maximum interpolation quality

The slowest and most accurate mode. Recommended for cinematic material where motion accuracy matters most:

```bash
./PMI \
  -i film.mkv \
  -o film_60fps_best.mkv \
  --fps=60 \
  --mi-mode=mci \
  --mc-mode=aobmc \
  --me-mode=bilat \
  --vsbmc=1 \
  --preset=veryslow \
  --crf=16 \
  -j 1
```

**Why `-j 1`:** at maximum quality, parallel processing can introduce subtle artifacts at segment boundaries (minterpolate loses inter-segment context). A single thread processes the entire video in one pass.

**Why `--me-mode=bilat`:** the bilateral motion estimation algorithm is more accurate than `bidir` for scenes with non-uniform motion, but is significantly slower.

### High quality, reasonable speed

A good balance for most movies:

```bash
./PMI \
  -i film.mkv \
  -o film_60fps_hq.mkv \
  --fps=60 \
  --mi-mode=mci \
  --mc-mode=aobmc \
  --me-mode=bidir \
  --vsbmc=1 \
  --preset=slow \
  --crf=18
```

### Fast processing (preview)

For checking the result before a full-quality run:

```bash
./PMI \
  -i film.mkv \
  -o film_60fps_preview.mkv \
  --fps=60 \
  --mi-mode=blend \
  --preset=ultrafast \
  --crf=26
```

`blend` is ~5× faster than `mci` but simply mixes adjacent frames without optical flow — the result is less sharp.

### Animation and cartoons

For animation without complex camera movement. `dup` simply duplicates frames without interpolation — useful when only a formally correct FPS is needed without added smoothness:

```bash
# Smooth interpolation for anime (caution: may produce artifacts on flash cuts)
./PMI \
  -i anime.mkv \
  -o anime_60fps.mkv \
  --fps=60 \
  --mi-mode=mci \
  --mc-mode=obmc \
  --me-mode=bidir \
  --vsbmc=0 \
  --preset=slow \
  --crf=18

# Frame duplication — no artifacts, no added smoothness
./PMI -i anime.mkv -o anime_60fps_dup.mkv --fps=60 --mi-mode=dup
```

### Controlling thread count

```bash
# Use all cores (default)
./PMI -i film.mkv -o out.mkv --fps=60

# Limit to 4 threads (leave headroom for other tasks)
./PMI -i film.mkv -o out.mkv --fps=60 -j 4

# Single thread — maximum quality or diagnostics
./PMI -i film.mkv -o out.mkv --fps=60 -j 1
```

### Keeping temporary files (debugging)

```bash
./PMI \
  -i film.mkv \
  -o out.mkv \
  --fps=60 \
  --temp-dir=/tmp/pmi_segments \
  --keep-temp \
  -v

# Segments are available at /tmp/pmi_segments/ after processing
ls /tmp/pmi_segments/
```

### Different input formats

```bash
./PMI -i film.mkv  -o out.mkv --fps=60   # MKV
./PMI -i film.mp4  -o out.mkv --fps=60   # MP4 (H.264, HEVC)
./PMI -i film.avi  -o out.mkv --fps=60   # AVI
./PMI -i film.ts   -o out.mkv --fps=60   # MPEG-TS (broadcasts, recordings)
./PMI -i video.flv -o out.mkv --fps=60   # FLV
```

The output container is determined by the extension of `-o`:

```bash
./PMI -i film.mkv -o out.mp4 --fps=60    # output in MP4
```

---

## 4. Interpolation Quality Settings

### `--mi-mode` — interpolation algorithm

The main parameter affecting quality and speed.

| Mode | Speed | Quality | Description |
|---|---|---|---|
| `mci` | slow | ★★★★★ | Motion Compensated Interpolation — computes motion vectors and synthesizes intermediate frames. Best result for video with smooth motion |
| `blend` | fast | ★★★☆☆ | Weighted blend of adjacent frames. Fast, but produces ghosting on fast motion |
| `dup` | instant | ★★☆☆☆ | Nearest-frame duplication. No artifacts, but no added smoothness |

**Content recommendations:**

| Content type | Recommended mode |
|---|---|
| Live-action film, TV series | `mci` |
| Documentary | `mci` |
| Sports with fast motion | `mci` + `bilat` |
| Anime, cartoons | `mci` or `blend` |
| Slideshows, static scenes | `dup` |
| Preview / draft | `blend` |

### `--mc-mode` — motion compensation

Applies only when `--mi-mode=mci`.

| Mode | Speed | Quality | Description |
|---|---|---|---|
| `aobmc` | slower | ★★★★★ | Adaptive Overlapped Block MC — eliminates block artifacts at region boundaries |
| `obmc` | faster | ★★★★☆ | Overlapped Block MC — basic overlapping algorithm |

### `--me-mode` — motion estimation

Applies only when `--mi-mode=mci`.

| Mode | Speed | Quality | Description |
|---|---|---|---|
| `bidir` | faster | ★★★★☆ | Bidirectional motion estimation. Works well for most scenes |
| `bilat` | slower | ★★★★★ | Bilateral motion estimation. More accurate for non-uniform motion (zoom, pan + moving objects) |

### `--vsbmc` — variable-size block compensation

| Value | Description |
|---|---|
| `1` (on) | Use variable-size blocks. Better on fine details, slower |
| `0` (off) | Fixed-size blocks. Faster, less accurate on complex scenes |

### Quality matrix

Overall rating of popular combinations (★ = better):

| Combination | Quality | Speed | Use case |
|---|---|---|---|
| `mci` + `aobmc` + `bilat` + `vsbmc=1` | ★★★★★ | ★☆☆☆☆ | Film, archiving |
| `mci` + `aobmc` + `bidir` + `vsbmc=1` | ★★★★☆ | ★★★☆☆ | Everyday use |
| `mci` + `obmc` + `bidir` + `vsbmc=0` | ★★★☆☆ | ★★★★☆ | Fast processing |
| `blend` + any | ★★☆☆☆ | ★★★★★ | Preview |
| `dup` + any | ★☆☆☆☆ | ★★★★★ | FPS change without effect |

---

## 5. x264 Encoding Settings

### `--crf` — video quality

CRF (Constant Rate Factor) controls output quality. Lower = better quality and larger file.

| CRF | Quality | File size | Recommendation |
|---|---|---|---|
| 0 | Lossless | Very large | Mastering only |
| 16–17 | Visually transparent | Large | Archiving |
| 18 | Very high | Large | Default |
| 20–22 | High | Medium | Storage and streaming |
| 23–25 | Good | Medium | Streaming |
| 28+ | Noticeable loss | Small | Not recommended |

> Since minterpolate-synthesized frames already contain some inherent error, CRF 18–20 is sufficient — the difference from CRF 16 on interpolated material is practically invisible.

### `--preset` — x264 encoding speed

The preset affects only encoding speed and file size, not visual quality at a given CRF.

| Preset | Speed | Compression | Use case |
|---|---|---|---|
| `ultrafast` | ★★★★★ | ★☆☆☆☆ | Preview |
| `superfast` | ★★★★☆ | ★★☆☆☆ | Draft |
| `veryfast` | ★★★★☆ | ★★★☆☆ | Quick save |
| `faster` | ★★★☆☆ | ★★★☆☆ | |
| `fast` | ★★★☆☆ | ★★★★☆ | |
| `medium` | ★★★☆☆ | ★★★★☆ | Balanced |
| `slow` | ★★☆☆☆ | ★★★★★ | Default, recommended |
| `slower` | ★★☆☆☆ | ★★★★★ | |
| `veryslow` | ★☆☆☆☆ | ★★★★★ | Maximum compression |

---

## 6. Parallelism and Performance

### How parallelism works

PMI divides the input video into N equal segments (one per thread) and processes them simultaneously. Each thread:

- seeks to its segment's start position in the source file
- reads an additional 2 seconds before the start (context for minterpolate)
- applies the minterpolate filter graph
- encodes with x264
- writes a temporary `.mkv` file

After all threads finish, `concat` joins the segments and muxes the audio/subtitles from the original source.

### Performance reference

Example on 1920×800, 24 fps → 60 fps, 8 cores:

| Preset | mi-mode | me-mode | Time (18 s clip) |
|---|---|---|---|
| `slow` + `mci` + `bidir` | mci | bidir | ~6 min |
| `slow` + `mci` + `bilat` | mci | bilat | ~10–12 min |
| `ultrafast` + `blend` | blend | — | ~30 s |

Real-world time scales linearly with video length.

### Thread count recommendations

```bash
# Maximum speed — all cores (default)
./PMI -i film.mkv -o out.mkv --fps=60

# Keep the system responsive — half the cores
./PMI -i film.mkv -o out.mkv --fps=60 -j $(( $(nproc) / 2 ))

# Single thread — maximum quality without seam artifacts
./PMI -i film.mkv -o out.mkv --fps=60 -j 1
```

### Minimum video length

PMI requires at least **4 seconds** per segment (`MIN_SEG_DURATION` constant). On an 8-core machine with an 18-second clip only 4 segments will be created instead of 8. For full core utilization use clips longer than ~32 seconds.

---

## 7. Supported Formats

### Input containers

| Format | Extensions |
|---|---|
| Matroska | `.mkv` |
| MPEG-4 | `.mp4`, `.m4v` |
| QuickTime | `.mov` |
| AVI | `.avi` |
| MPEG-TS | `.ts`, `.m2ts` |
| Flash Video | `.flv` |

### Input video codecs

| Codec | Notes |
|---|---|
| H.264 / AVC | Primary format |
| H.265 / HEVC | Including 10-bit |
| MPEG-4 Part 2 | DivX, Xvid |
| MPEG-2 Video | DVD, broadcast TV |
| VP8, VP9 | WebM content |
| AV1 | Modern format |

### Output formats

The output container is determined by the file extension passed to `-o`:

| Extension | Container |
|---|---|
| `.mkv` | Matroska (recommended) |
| `.mp4` | MPEG-4 |
| `.mov` | QuickTime |

The output video codec is always **H.264 (libx264)**.

### Audio and subtitles

All audio tracks and subtitle streams from the source are copied without re-encoding:

| Type | Supported codecs |
|---|---|
| Audio | AAC, AC3, EAC3, MP3, DTS, Opus, Vorbis, FLAC, TrueHD |
| Subtitles | ASS/SSA, SRT, SubRip, DVD sub, PGS (Blu-ray) |

---

## 8. Understanding the Output

### Thread launch lines

```
[LAUNCH] Thread  0 | start=00:00:00 clean=00:00:04 → output_seg0000.mkv
```

- `start` — segment start position in the source video
- `clean` — duration of the "clean" portion that will appear in the output

### Segment completion lines

```
[SEG 00] dec=163 enc=267 dur=4.450s → output_seg0000.mkv
```

- `dec=163` — 163 source frames decoded
- `enc=267` — 267 frames encoded after interpolation
- `dur=4.450s` — actual segment duration

The ratio `267/163 ≈ 1.64×`. The theoretical expectation for 24→60 fps is `2.5×`. The gap is because minterpolate spends some frames "warming up" the algorithm on short segments. On a full-length film the multiplier will be close to the theoretical value.

### Final statistics

```
Input frames:    745
Output frames:   1077
Multiplier:      ×1.45
Speed:           ×0.05 of real time
```

- **Speed** — ratio of video duration to processing time. A value below 1 means processing is slower than real time — this is expected for `mci` + `slow`.

### Progress bar

```
[DONE  1/4] Seg.00 | dec=163 enc=267 dur=4.45s | 7 MB | ETA 00:13:45  [██████████░░...]
```

ETA is calculated from the average completion time of finished segments — it may be inaccurate if segments vary in complexity.

---

## 9. Recommendations and Limitations

### When minterpolate gives good results

- Live-action film and TV series with smooth camera movement
- Documentary video
- Video game footage with a fixed camera
- Nature footage, landscapes

### When minterpolate may produce artifacts

- **Hard cuts** — the filter "smears" the transition between scenes. Scene change detection (`scd=fdiff`) helps partially, but not in all cases.
- **On-screen text** — characters may "drift" during camera movement.
- **Very fast motion** (action, fight scenes) — motion vectors may misfire.
- **Anime** — deliberately low frame rates (8–12 fps) are a stylistic choice; interpolation changes the feel of the animation.

### Disk space

Temporary segments occupy additional space. For a 2-hour film:

- Input file: ~8–15 GB (depends on bitrate)
- Temporary segments: approximately 2× the output file size
- Output file: approximately 1.5–2× the input (more frames at the same CRF)

Make sure the volume containing `--temp-dir` has enough free space.

### Choosing the target FPS

| Source FPS | Recommended target FPS |
|---|---|
| 24 | 48, 60, 120 |
| 25 | 50, 75, 100 |
| 30 | 60, 90, 120 |
| 50 | 100 |
| 60 | 120 |

Integer multiples produce the cleanest results because every original frame maps to an exact integer number of interpolated frames. Non-integer ratios (e.g. 24→90) work but force minterpolate to synthesize frames at fractional positions.
