# PMI — Parallel Motion Interpolate  (v1.3)

Мощная утилита для увеличения частоты кадров видео, на вход которой подаётся стандартный исходник (например, 24, 25 или 30 кадров в секунду), а на выходе формируется плавное кинематографичное видео с частотой 60, 90 или даже 120 FPS (кадров в секунду).

Обработка распараллелена по всем ядрам процессора. Используется высококачественный фильтр `minterpolate`. Кодирование осуществляется кодеком **x264**; аудио и субтитры копируются без изменений.

Приложение разработано на языке программирования **Nim**. Все необходимые для интерполяции кадров модули FFmpeg линкуются статически. Никаких зависимостей, всё внутри бинарного файла.

## Интерфейс терминала
![Интерфейс терминала](./archive/Screenshot.png)

---

## Быстрая сборка (v1.2+)

Начиная с v1.2 в проекте есть `config.nims` — NimScript-файл, который Nim
компилятор выполняет автоматически перед сборкой. Он сам клонирует и
собирает статический FFmpeg, если его ещё нет. Поэтому достаточно:

```bash
sudo dnf install -y nasm yasm gcc gcc-c++ make pkg-config \
                    x264-devel zlib-devel bzip2-devel xz-devel nim git

cd PMI/
nim c -d:release --threads:on PMI.nim
```

Проверить версию собранного бинаря:

```bash
./PMI --version
# PMI (Parallel Motion Interpolate) v1.3
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
| `-V`, `--version` | — | Показать версию и выйти |

---

## История изменений

Полная история изменений (v1.0 → v1.3), включая описание всех багфиксов
пайплайна и находок статического аудита, вынесена в
[CHANGELOG.md](./CHANGELOG.md).

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
