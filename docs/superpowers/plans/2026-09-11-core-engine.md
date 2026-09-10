# Subtitler: ядро пайплайна — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Собрать headless-ядро приложения: из видеофайла и кода языка получить
`_orig.srt`, `_ru.srt` и видео с вшитыми русскими субтитрами — без единого экрана,
управляемое из CLI и полностью покрытое тестами.

**Architecture:** Чистый Dart для всего, что можно посчитать без I/O (парсер пауз,
сегментатор, SRT, валидация), тонкие изолированные адаптеры для внешнего мира
(`FfmpegRunner` над процессом ffmpeg, HTTP-клиенты Яндекса, файловое хранилище
сессии) и один оркестратор, который склеивает их и владеет статусами реплик.
UI (план 2) и упаковка (план 3) встают поверх этого ядра, ничего в нём не меняя.

**Tech Stack:** Flutter/Dart (тесты — `flutter test`), внешний бинарь ffmpeg,
Yandex SpeechKit STT v1 и Translate v2 поверх `dio`.

**Spec:** `docs/superpowers/specs/2026-09-10-subtitler-design.md` — план реализует
§6 (пайплайн), §8 (вшивание), §9 (сессия), §10 (ошибки) и части §7 (валидация
таймингов) и §13 (структура кода). Экраны §4, §5, §7 — план 2. Сборка §14 — план 3.

## Global Constraints

Значения скопированы из спеки дословно; они действуют во всех задачах.

- Flutter stable ≥ 3.44 (на машине разработчика 3.44.6). Версию фиксируем, обновление — только как проверяемая миграция.
- Целевая длина сегмента 2–8 с; жёсткий лимит SpeechKit v1 — 30 с и 1 МБ на запрос.
- Склейка соседних речевых интервалов: зазор ≤ 1.0 с И суммарная длина ≤ 8 с.
- Интервалы длиннее 8.5 с делятся по микропаузам (порог +3 dB, d = 0.15 с), в крайнем случае — принудительно по 7.2 с.
- Паддинг в тишину: `min(0.12 с, зазор_до_соседа / 2)` с каждой стороны. Сегменты не перекрываются никогда.
- Точность границ — 0.01 с.
- Цепочка порогов тишины: −30 dB/0.3 с → −25/0.3 → −20/0.25 → −18/0.25 → −15/0.25; критерий остановки — ≥ 1 паузы на 15 с длительности; если не помогло ни одно значение — принудительная нарезка по 7.2 с и флаг `forcedSplit`.
- Аудио сегмента: OggOpus, 64 kbit/s, моно (`-c:a libopus -b:a 64k`, `-ac 1`).
- STT: `POST https://stt.api.cloud.yandex.net/speech/v1/stt:recognize?topic=general&format=oggopus&lang=<код>`; заголовок `Authorization: Api-Key <ключ>`; `folderId` НЕ передаётся; `sampleRateHertz` не передаётся; коды языка полные — `tr-TR`, `uz-UZ`.
- Translate: `POST https://translate.api.cloud.yandex.net/translate/v2/translate`; `folderId` НЕ передаётся; коды короткие — `targetLanguageCode: "ru"`, `sourceLanguageCode: "tr"` / `"uz"` (`uz` — латиница; кириллический узбекский в переводчике имеет отдельный код `uzbcyr`); лимит 10 000 знаков считается по сумме всех строк батча; квота 20 запросов в секунду.
- Политика ошибок (одна для обоих клиентов): 429/5xx/сетевые — 3 попытки с паузами 1 с, 4 с, 10 с; после исчерпания реплика получает статус `failed`, обработка остальных продолжается. 401/403 — немедленная остановка всего прогона.
- Параллельных запросов к STT — не более 4 (квота API 20 rps).
- Вшивание: `-vf "subtitles=<srt>:fontsdir=<dir>:force_style='FontName=Noto Sans,Outline=2'" -c:v libx264 -crf 18 -preset veryfast -c:a copy`.
- Автопроверка видимости субтитров: в нижних 20 % высоты кадра число пикселей с яркостью > 200 должно вырасти минимум на 300 по сравнению с исходным кадром.
- Статусы реплики: `pending` (не распознавалась) → отправляется в API; `ok`, `empty` → не отправляются; `failed` → отправляется повторно.
- Сессия: `<имя>.subtitler.json` рядом с видео, при недоступной для записи папке — в папке приложения; отпечаток исходника = размер в байтах + длительность до 0.01 с; запись инкрементальная после каждого сегмента и каждого батча перевода.
- Ключ API никогда не попадает в сессию, логи и сообщения об ошибках.

---

### Task 1: Скелет проекта и все зависимости

Единственная цель задачи — поймать конфликты Android-тулчейна до того, как
написана хоть одна строка логики. Ставим сразу ВСЕ зависимости, включая те,
что понадобятся только в плане 2.

**Files:**
- Create: `pubspec.yaml`, `analysis_options.yaml`, `lib/main.dart`, `android/app/build.gradle.kts` (правки), `.gitignore`
- Test: сборка (отдельного файла тестов нет)

**Interfaces:**
- Consumes: ничего.
- Produces: рабочий Flutter-проект с именем пакета `subtitler`; импорт `package:subtitler/...` доступен всем последующим задачам.

- [ ] **Step 1: Создать проект в существующем репозитории**

```bash
cd ~/Projects/subtitler
flutter create --project-name subtitler --org ru.subtitler \
  --platforms=windows,android,macos --overwrite .
```

`macos` нужен только как площадка для отладки UI на этой машине; в релиз он не идёт.

- [ ] **Step 2: Записать pubspec.yaml с закреплёнными версиями**

```yaml
name: subtitler
description: Русские субтитры для видео с турецкой и узбекской речью
publish_to: none
version: 0.1.0

environment:
  sdk: ">=3.5.0 <4.0.0"
  flutter: ">=3.44.0"

dependencies:
  flutter:
    sdk: flutter
  flutter_localizations:
    sdk: flutter

  # сеть и файлы
  dio: ^5.11.1
  path: ^1.9.0
  path_provider: ^2.1.6

  # ключ пользователя
  flutter_secure_storage: ^11.1.0

  # ffmpeg на Android (на десктопе используем внешний ffmpeg.exe)
  ffmpeg_kit_flutter_new: ^4.6.2

  # плеер предпросмотра (план 2). Пин на main: фикс краша hot-restart
  # на Flutter 3.38+ есть в main, но не выпущен на pub.dev.
  media_kit:
    git:
      url: https://github.com/media-kit/media-kit.git
      path: media_kit
  media_kit_video:
    git:
      url: https://github.com/media-kit/media-kit.git
      path: media_kit_video
  media_kit_libs_video: ^1.0.7

  # приём и выдача файлов (план 2)
  receive_sharing_intent: ^1.9.0
  share_plus: ^13.3.0
  gal: ^2.3.3
  desktop_drop: ^0.8.4
  file_selector: ^1.1.0
  window_manager: ^0.5.2
  package_info_plus: ^10.2.1
  wakelock_plus: ^1.8.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
  assets:
    - assets/fonts/
```

- [ ] **Step 3: Привести Android-конфигурацию к требованиям пакетов**

В `android/app/build.gradle.kts` выставить (значения — из требований
receive_sharing_intent 1.9.0 и ffmpeg_kit_flutter_new 4.6.2):

```kotlin
android {
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "ru.subtitler.subtitler"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}
```

- [ ] **Step 4: Положить заглушку main.dart**

```dart
import 'package:flutter/material.dart';

void main() => runApp(const SubtitlerApp());

class SubtitlerApp extends StatelessWidget {
  const SubtitlerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: Center(child: Text('Subtitler'))),
    );
  }
}
```

- [ ] **Step 5: Создать папку под шрифт (заполнится в задаче 14)**

```bash
mkdir -p assets/fonts
touch assets/fonts/.gitkeep
```

- [ ] **Step 6: Проверить, что зависимости ставятся и код анализируется**

Run: `flutter pub get && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 7: Проверить сборку под Android — здесь ловятся конфликты тулчейна**

Run: `flutter build apk --debug`
Expected: `Built build/app/outputs/flutter-apk/app-debug.apk`

Если сборка падает на несовместимости AGP/Kotlin/compileSdk — чинить здесь и
сейчас, не переходя к следующей задаче: это и есть главный риск проекта.

- [ ] **Step 8: Проверить сборку под десктоп**

Run: `flutter build macos --debug`
Expected: сборка завершается без ошибок.

- [ ] **Step 9: Коммит**

```bash
git add -A
git commit -m "Скелет проекта со всеми зависимостями"
```

---

### Task 2: Модели данных и их сериализация

**Files:**
- Create: `lib/core/models.dart`
- Test: `test/core/models_test.dart`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `class TimeRange { final double start; final double end; const TimeRange(this.start, this.end); double get duration; }`
  - `enum CueStatus { pending, ok, empty, failed }`
  - `enum CueFlag { repeatLoop, translateFailed, forcedSplit }`
  - `class Cue { final int index; final TimeRange range; final String orig; final String ru; final CueStatus status; final Set<CueFlag> flags; Cue copyWith({...}); Map<String, dynamic> toJson(); static Cue fromJson(Map<String, dynamic>); }`
  - `class SourceFingerprint { final int sizeBytes; final double durationSec; bool matches(SourceFingerprint other); Map<String, dynamic> toJson(); static SourceFingerprint fromJson(...); }`
  - `class Session { final int schemaVersion; final String videoPath; final SourceFingerprint fingerprint; final String lang; final String silenceThreshold; final bool forcedSplit; final List<Cue> cues; ... toJson/fromJson }`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/models_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';

void main() {
  test('TimeRange считает длительность', () {
    expect(const TimeRange(1.5, 4.25).duration, closeTo(2.75, 1e-9));
  });

  test('Cue переживает сериализацию без потерь', () {
    const cue = Cue(
      index: 3,
      range: TimeRange(7.52, 13.23),
      orig: '*** biraz *** var',
      ru: '***',
      status: CueStatus.ok,
      flags: {CueFlag.repeatLoop},
    );
    final restored = Cue.fromJson(cue.toJson());
    expect(restored.index, 3);
    expect(restored.range.start, closeTo(7.52, 1e-9));
    expect(restored.range.end, closeTo(13.23, 1e-9));
    expect(restored.orig, cue.orig);
    expect(restored.ru, cue.ru);
    expect(restored.status, CueStatus.ok);
    expect(restored.flags, {CueFlag.repeatLoop});
  });

  test('Отпечаток совпадает при равных размере и длительности', () {
    const a = SourceFingerprint(sizeBytes: 6571302, durationSec: 34.80);
    const b = SourceFingerprint(sizeBytes: 6571302, durationSec: 34.801);
    const c = SourceFingerprint(sizeBytes: 6571303, durationSec: 34.80);
    expect(a.matches(b), isTrue, reason: 'разница длительности < 0.01 с');
    expect(a.matches(c), isFalse, reason: 'другой размер файла');
  });

  test('Session переживает сериализацию', () {
    const session = Session(
      videoPath: '/tmp/video.mp4',
      fingerprint: SourceFingerprint(sizeBytes: 10, durationSec: 1.0),
      lang: 'tr-TR',
      silenceThreshold: '-30dB',
      forcedSplit: true,
      cues: [
        Cue(index: 1, range: TimeRange(0, 1.7), orig: 'abi', ru: 'брат',
            status: CueStatus.ok, flags: {}),
      ],
    );
    final restored = Session.fromJson(session.toJson());
    expect(restored.schemaVersion, 1);
    expect(restored.lang, 'tr-TR');
    expect(restored.forcedSplit, isTrue);
    expect(restored.cues.single.orig, 'abi');
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/models_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:subtitler/core/models.dart'`

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/models.dart

/// Отрезок времени в секундах от начала видео.
class TimeRange {
  final double start;
  final double end;
  const TimeRange(this.start, this.end);

  double get duration => end - start;

  Map<String, dynamic> toJson() => {'start': start, 'end': end};

  static TimeRange fromJson(Map<String, dynamic> json) =>
      TimeRange((json['start'] as num).toDouble(), (json['end'] as num).toDouble());
}

/// Что уже известно о реплике. От статуса зависит, пойдёт ли она в платный API
/// при возобновлении сессии.
enum CueStatus { pending, ok, empty, failed }

/// Пометки, из-за которых реплику стоит показать человеку.
enum CueFlag { repeatLoop, translateFailed, forcedSplit }

class Cue {
  final int index;
  final TimeRange range;
  final String orig;
  final String ru;
  final CueStatus status;
  final Set<CueFlag> flags;

  const Cue({
    required this.index,
    required this.range,
    required this.orig,
    required this.ru,
    required this.status,
    required this.flags,
  });

  Cue copyWith({
    int? index,
    TimeRange? range,
    String? orig,
    String? ru,
    CueStatus? status,
    Set<CueFlag>? flags,
  }) {
    return Cue(
      index: index ?? this.index,
      range: range ?? this.range,
      orig: orig ?? this.orig,
      ru: ru ?? this.ru,
      status: status ?? this.status,
      flags: flags ?? this.flags,
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'range': range.toJson(),
        'orig': orig,
        'ru': ru,
        'status': status.name,
        'flags': flags.map((f) => f.name).toList(),
      };

  static Cue fromJson(Map<String, dynamic> json) => Cue(
        index: json['index'] as int,
        range: TimeRange.fromJson(json['range'] as Map<String, dynamic>),
        orig: json['orig'] as String,
        ru: json['ru'] as String,
        status: CueStatus.values.byName(json['status'] as String),
        flags: (json['flags'] as List)
            .map((n) => CueFlag.values.byName(n as String))
            .toSet(),
      );
}

/// Лёгкий отпечаток исходного файла: защищает от подстановки чужой сессии
/// другому видео с тем же именем.
class SourceFingerprint {
  final int sizeBytes;
  final double durationSec;

  const SourceFingerprint({required this.sizeBytes, required this.durationSec});

  bool matches(SourceFingerprint other) =>
      sizeBytes == other.sizeBytes &&
      (durationSec - other.durationSec).abs() < 0.01;

  Map<String, dynamic> toJson() =>
      {'sizeBytes': sizeBytes, 'durationSec': durationSec};

  static SourceFingerprint fromJson(Map<String, dynamic> json) =>
      SourceFingerprint(
        sizeBytes: json['sizeBytes'] as int,
        durationSec: (json['durationSec'] as num).toDouble(),
      );
}

class Session {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String videoPath;
  final SourceFingerprint fingerprint;
  final String lang;
  final String silenceThreshold;
  final bool forcedSplit;
  final List<Cue> cues;

  const Session({
    this.schemaVersion = currentSchemaVersion,
    required this.videoPath,
    required this.fingerprint,
    required this.lang,
    required this.silenceThreshold,
    required this.forcedSplit,
    required this.cues,
  });

  Session copyWith({List<Cue>? cues, String? lang}) => Session(
        schemaVersion: schemaVersion,
        videoPath: videoPath,
        fingerprint: fingerprint,
        lang: lang ?? this.lang,
        silenceThreshold: silenceThreshold,
        forcedSplit: forcedSplit,
        cues: cues ?? this.cues,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'videoPath': videoPath,
        'fingerprint': fingerprint.toJson(),
        'lang': lang,
        'silenceThreshold': silenceThreshold,
        'forcedSplit': forcedSplit,
        'cues': cues.map((c) => c.toJson()).toList(),
      };

  static Session fromJson(Map<String, dynamic> json) => Session(
        schemaVersion: json['schemaVersion'] as int,
        videoPath: json['videoPath'] as String,
        fingerprint:
            SourceFingerprint.fromJson(json['fingerprint'] as Map<String, dynamic>),
        lang: json['lang'] as String,
        silenceThreshold: json['silenceThreshold'] as String,
        forcedSplit: json['forcedSplit'] as bool,
        cues: (json['cues'] as List)
            .map((c) => Cue.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/models_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/models.dart test/core/models_test.dart
git commit -m "Модели: TimeRange, Cue, Session и сериализация"
```

---

### Task 3: Парсер вывода silencedetect

`silencedetect` пишет события в stderr парами: `silence_start` и `silence_end`.
Между ними — тишина, вне их — речь. Хвост после последнего `silence_end` — тоже речь.

**Files:**
- Create: `lib/core/pipeline/silence_parser.dart`
- Test: `test/core/pipeline/silence_parser_test.dart`

**Interfaces:**
- Consumes: `TimeRange` из `lib/core/models.dart`.
- Produces:
  - `enum SilenceEventKind { start, end }`
  - `class SilenceEvent { final SilenceEventKind kind; final double time; const SilenceEvent(this.kind, this.time); }`
  - `List<SilenceEvent> parseSilenceLog(String log)`
  - `List<TimeRange> speechIntervals(List<SilenceEvent> events, double duration)`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/pipeline/silence_parser_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/silence_parser.dart';

const _log = '''
[Parsed_silencedetect_0 @ 0x14b0058d0] silence_start: 1.70208
[Parsed_silencedetect_0 @ 0x14b0058d0] silence_end: 3.18225 | silence_duration: 1.48017
[Parsed_silencedetect_0 @ 0x14b0058d0] silence_start: 6.55142
[Parsed_silencedetect_0 @ 0x14b0058d0] silence_end: 7.52108 | silence_duration: 0.96966
''';

void main() {
  test('Парсер вытаскивает события в порядке появления', () {
    final events = parseSilenceLog(_log);
    expect(events.length, 4);
    expect(events[0].kind, SilenceEventKind.start);
    expect(events[0].time, closeTo(1.70208, 1e-6));
    expect(events[1].kind, SilenceEventKind.end);
    expect(events[1].time, closeTo(3.18225, 1e-6));
    expect(events[3].time, closeTo(7.52108, 1e-6));
  });

  test('Парсер игнорирует посторонние строки лога', () {
    final events = parseSilenceLog('Stream #0:0 Audio: aac\nframe= 42 fps=0.0\n');
    expect(events, isEmpty);
  });

  test('Речь — это промежутки между паузами, включая хвост', () {
    final speech = speechIntervals(parseSilenceLog(_log), 10.0);
    expect(speech.length, 3);
    expect(speech[0].start, closeTo(0.0, 1e-9));
    expect(speech[0].end, closeTo(1.70208, 1e-6));
    expect(speech[1].start, closeTo(3.18225, 1e-6));
    expect(speech[1].end, closeTo(6.55142, 1e-6));
    expect(speech[2].start, closeTo(7.52108, 1e-6));
    expect(speech[2].end, closeTo(10.0, 1e-9), reason: 'хвост до конца файла');
  });

  test('Без событий весь файл считается речью', () {
    expect(speechIntervals(const [], 12.5).single.end, closeTo(12.5, 1e-9));
  });

  test('Пауза до конца файла не даёт хвостового интервала', () {
    final events = parseSilenceLog(
        '[silencedetect @ 0x1] silence_start: 9.5\n');
    final speech = speechIntervals(events, 10.0);
    expect(speech.length, 1);
    expect(speech.single.end, closeTo(9.5, 1e-9));
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/pipeline/silence_parser_test.dart`
Expected: FAIL — файл `silence_parser.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/pipeline/silence_parser.dart
import '../models.dart';

enum SilenceEventKind { start, end }

class SilenceEvent {
  final SilenceEventKind kind;
  final double time;
  const SilenceEvent(this.kind, this.time);
}

final _eventPattern =
    RegExp(r'silence_(start|end):\s*(-?\d+(?:\.\d+)?)');

/// Разбирает stderr ffmpeg с фильтром silencedetect.
List<SilenceEvent> parseSilenceLog(String log) {
  return _eventPattern.allMatches(log).map((m) {
    final kind = m.group(1) == 'start'
        ? SilenceEventKind.start
        : SilenceEventKind.end;
    return SilenceEvent(kind, double.parse(m.group(2)!));
  }).toList();
}

/// Инвертирует паузы в интервалы речи. Слишком короткие огрызки (< 0.05 с)
/// отбрасываются: это артефакты на границах, а не реплики.
List<TimeRange> speechIntervals(List<SilenceEvent> events, double duration) {
  if (events.isEmpty) return [TimeRange(0, duration)];

  final result = <TimeRange>[];
  double? speechStart = 0;

  for (final event in events) {
    if (event.kind == SilenceEventKind.start) {
      if (speechStart != null) {
        final start = speechStart.clamp(0.0, duration);
        final end = event.time.clamp(0.0, duration);
        if (end - start > 0.05) result.add(TimeRange(start, end));
      }
      speechStart = null;
    } else {
      speechStart = event.time.clamp(0.0, duration);
    }
  }

  if (speechStart != null && duration - speechStart > 0.05) {
    result.add(TimeRange(speechStart, duration));
  }
  return result;
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/pipeline/silence_parser_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/pipeline/silence_parser.dart test/core/pipeline/silence_parser_test.dart
git commit -m "Парсер вывода silencedetect"
```

---

### Task 4: Сегментатор

Превращает интервалы речи в сегменты 2–8 с: склеивает близкие, режет длинные,
добавляет паддинг так, чтобы соседи не перекрывались.

**Files:**
- Create: `lib/core/pipeline/segmenter.dart`
- Test: `test/core/pipeline/segmenter_test.dart`

**Interfaces:**
- Consumes: `TimeRange` из `lib/core/models.dart`.
- Produces:
  - константы `kMaxSegment = 8.0`, `kMaxGap = 1.0`, `kPad = 0.12`, `kForcedSplit = 7.2`, `kMinFragment = 1.2`
  - `List<TimeRange> buildSegments({required List<TimeRange> speech, required double duration, List<TimeRange> fineSpeech = const []})`
  - `List<TimeRange> forcedSegments(double duration)`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/pipeline/segmenter_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/segmenter.dart';

void main() {
  test('Близкие короткие интервалы склеиваются', () {
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 2.0), TimeRange(2.5, 4.0)],
      duration: 5.0,
    );
    expect(segments.length, 1, reason: 'зазор 0.5 с ≤ 1.0 с, сумма ≤ 8 с');
    expect(segments.single.start, closeTo(0.0, 1e-9));
    expect(segments.single.end, closeTo(4.12, 1e-9), reason: 'паддинг 0.12 в конце');
  });

  test('Далёкие интервалы остаются раздельными', () {
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 2.0), TimeRange(5.0, 7.0)],
      duration: 8.0,
    );
    expect(segments.length, 2);
  });

  test('Паддинг никогда не даёт перекрытия соседей', () {
    // зазор 0.1 с: половина зазора = 0.05, значит паддинг обрежется до 0.05.
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 5.0), TimeRange(5.1, 10.0)],
      duration: 10.0,
    );
    expect(segments.length, 2, reason: 'сумма 10 с > 8 с, склейки нет');
    expect(segments[0].end, lessThanOrEqualTo(segments[1].start),
        reason: 'перекрытие отправило бы один звук в платный API дважды');
    expect(segments[0].end, closeTo(5.05, 1e-9));
    expect(segments[1].start, closeTo(5.05, 1e-9));
  });

  test('Длинный интервал режется по микропаузам', () {
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 20.0)],
      duration: 20.0,
      fineSpeech: const [
        TimeRange(0.0, 6.0),
        TimeRange(6.3, 13.0),
        TimeRange(13.4, 20.0),
      ],
    );
    expect(segments.length, greaterThan(1));
    for (final s in segments) {
      expect(s.duration, lessThanOrEqualTo(kMaxSegment + 0.5));
    }
  });

  test('Без микропауз длинный интервал режется принудительно', () {
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 20.0)],
      duration: 20.0,
    );
    expect(segments.length, greaterThanOrEqualTo(3));
    for (final s in segments) {
      expect(s.duration, lessThanOrEqualTo(kMaxSegment + 0.5));
    }
  });

  test('Границы округляются до сотых', () {
    final segments = buildSegments(
      speech: const [TimeRange(1.234567, 3.987654)],
      duration: 5.0,
    );
    expect(segments.single.start, closeTo(1.11, 1e-9));
    expect(segments.single.end, closeTo(4.11, 1e-9));
  });

  test('Принудительная нарезка покрывает весь ролик кусками по 7.2 с', () {
    final segments = forcedSegments(20.0);
    expect(segments.first.start, 0.0);
    expect(segments.last.end, closeTo(20.0, 1e-9));
    for (final s in segments) {
      expect(s.duration, lessThanOrEqualTo(kForcedSplit + 1e-9));
    }
    for (var i = 0; i + 1 < segments.length; i++) {
      expect(segments[i].end, closeTo(segments[i + 1].start, 1e-9));
    }
  });

  test('Пустой вход даёт пустой результат', () {
    expect(buildSegments(speech: const [], duration: 10.0), isEmpty);
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/pipeline/segmenter_test.dart`
Expected: FAIL — файл `segmenter.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/pipeline/segmenter.dart
import '../models.dart';

/// Максимальная длина сегмента (лимит API — 30 с, но короткие реплики
/// распознаются заметно точнее).
const double kMaxSegment = 8.0;

/// Зазор, который ещё можно «проглотить» внутри одного сегмента.
const double kMaxGap = 1.0;

/// Сколько тишины прихватываем с каждой стороны, чтобы не срезать звуки.
const double kPad = 0.12;

/// Шаг принудительной нарезки, когда пауз нет.
const double kForcedSplit = 7.2;

/// Огрызок короче этого приклеивается к предыдущему сегменту.
const double kMinFragment = 1.2;

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// Строит сегменты для распознавания из интервалов речи.
///
/// [fineSpeech] — интервалы речи, найденные на более чувствительном пороге;
/// используются только чтобы разрезать слишком длинные куски по микропаузам.
List<TimeRange> buildSegments({
  required List<TimeRange> speech,
  required double duration,
  List<TimeRange> fineSpeech = const [],
}) {
  if (speech.isEmpty) return const [];
  final split = _splitLong(speech, fineSpeech);
  final merged = _merge(split);
  return _pad(merged, duration);
}

/// Нарезка вслепую: когда пауз не нашлось ни на одном пороге.
List<TimeRange> forcedSegments(double duration) {
  final result = <TimeRange>[];
  var cursor = 0.0;
  while (cursor < duration) {
    final end = (cursor + kForcedSplit) < duration ? cursor + kForcedSplit : duration;
    result.add(TimeRange(_round2(cursor), _round2(end)));
    cursor = end;
  }
  return result;
}

List<TimeRange> _splitLong(List<TimeRange> speech, List<TimeRange> fineSpeech) {
  final result = <TimeRange>[];
  for (final range in speech) {
    if (range.duration <= kMaxSegment + 0.5) {
      result.add(range);
      continue;
    }
    // Точки-кандидаты для разреза — середины микропауз внутри интервала.
    final cutPoints = <double>[];
    for (var i = 0; i + 1 < fineSpeech.length; i++) {
      final gapStart = fineSpeech[i].end;
      final gapEnd = fineSpeech[i + 1].start;
      if (gapStart > range.start + 1.0 &&
          gapEnd < range.end - 1.0 &&
          gapEnd - gapStart >= 0.10) {
        cutPoints.add((gapStart + gapEnd) / 2);
      }
    }
    var cursor = range.start;
    while (range.end - cursor > kMaxSegment + 0.5) {
      final candidates = cutPoints
          .where((p) => p >= cursor + 1.5 && p <= cursor + kMaxSegment)
          .toList();
      final next = candidates.isNotEmpty
          ? candidates.reduce((a, b) => a > b ? a : b)
          : cursor + kForcedSplit;
      result.add(TimeRange(cursor, next));
      cursor = next;
    }
    result.add(TimeRange(cursor, range.end));
  }
  return result;
}

List<TimeRange> _merge(List<TimeRange> ranges) {
  final merged = <TimeRange>[];
  for (final range in ranges) {
    final last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        range.start - last.end <= kMaxGap &&
        range.end - last.start <= kMaxSegment) {
      merged[merged.length - 1] = TimeRange(last.start, range.end);
    } else {
      merged.add(range);
    }
  }

  // Огрызки приклеиваем к предыдущему сегменту, если он это выдержит.
  final folded = <TimeRange>[];
  for (final range in merged) {
    final last = folded.isEmpty ? null : folded.last;
    if (last != null &&
        range.duration < kMinFragment &&
        range.start - last.end <= kMaxGap &&
        range.end - last.start <= kMaxSegment + 1.0) {
      folded[folded.length - 1] = TimeRange(last.start, range.end);
    } else {
      folded.add(range);
    }
  }
  return folded;
}

/// Добавляет паддинг, ограничивая его половиной зазора до соседа,
/// чтобы сегменты гарантированно не перекрывались.
List<TimeRange> _pad(List<TimeRange> ranges, double duration) {
  final result = <TimeRange>[];
  for (var i = 0; i < ranges.length; i++) {
    final range = ranges[i];
    final prevEnd = result.isEmpty ? 0.0 : result.last.end;
    final nextStart = i + 1 < ranges.length ? ranges[i + 1].start : duration;

    final padBefore = _min(kPad, _max(0.0, (range.start - prevEnd) / 2));
    final padAfter = _min(kPad, _max(0.0, (nextStart - range.end) / 2));

    final start = _round2(_max(prevEnd, _max(0.0, range.start - padBefore)));
    final end = _round2(_min(duration, range.end + padAfter));
    if (end > start) result.add(TimeRange(start, end));
  }
  return result;
}

double _min(double a, double b) => a < b ? a : b;
double _max(double a, double b) => a > b ? a : b;
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/pipeline/segmenter_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/pipeline/segmenter.dart test/core/pipeline/segmenter_test.dart
git commit -m "Сегментатор: склейка, деление длинных, паддинг без перекрытий"
```

---

### Task 5: Генерация и разбор SRT

**Files:**
- Create: `lib/core/srt.dart`
- Test: `test/core/srt_test.dart`

**Interfaces:**
- Consumes: `Cue`, `CueStatus`, `TimeRange` из `lib/core/models.dart`.
- Produces:
  - `enum SrtField { orig, ru }`
  - `String formatSrtTimestamp(double seconds)`
  - `double parseSrtTimestamp(String value)`
  - `String buildSrt(List<Cue> cues, {required SrtField field})`
  - `List<Cue> parseSrt(String content)`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/srt_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/srt.dart';

const _cues = [
  Cue(index: 1, range: TimeRange(0.0, 1.7), orig: 'abi gün ***',
      ru: 'Брат, наш ***.', status: CueStatus.ok, flags: {}),
  Cue(index: 2, range: TimeRange(3.18, 6.55), orig: '', ru: '',
      status: CueStatus.empty, flags: {}),
  Cue(index: 3, range: TimeRange(7.52, 13.23), orig: 'ne kadar çıkar ***',
      ru: 'Сколько материала выйдет.', status: CueStatus.ok, flags: {}),
];

void main() {
  test('Таймкод форматируется как ЧЧ:ММ:СС,ммм', () {
    expect(formatSrtTimestamp(0), '00:00:00,000');
    expect(formatSrtTimestamp(5.71), '00:00:05,710');
    expect(formatSrtTimestamp(63.456), '00:01:03,456');
    expect(formatSrtTimestamp(3723.9), '01:02:03,900');
  });

  test('Таймкод разбирается обратно', () {
    expect(parseSrtTimestamp('00:00:05,710'), closeTo(5.71, 1e-9));
    expect(parseSrtTimestamp('01:02:03,456'), closeTo(3723.456, 1e-9));
  });

  test('Пустые реплики не попадают в SRT, нумерация сплошная', () {
    final srt = buildSrt(_cues, field: SrtField.ru);
    expect(srt, contains('1\n00:00:00,000 --> 00:00:01,700\nБрат, наш ***.'));
    expect(srt, contains('2\n00:00:07,520 --> 00:00:13,230\nСколько материала выйдет.'));
    expect(srt, isNot(contains('00:00:03,180')), reason: 'пустая реплика пропущена');
  });

  test('Поле выбирается параметром', () {
    expect(buildSrt(_cues, field: SrtField.orig), contains('abi gün ***'));
    expect(buildSrt(_cues, field: SrtField.orig), isNot(contains('Брат')));
  });

  test('Разбор SRT возвращает те же тайминги и тексты', () {
    final parsed = parseSrt(buildSrt(_cues, field: SrtField.ru));
    expect(parsed.length, 2);
    expect(parsed.first.range.start, closeTo(0.0, 1e-9));
    expect(parsed.first.range.end, closeTo(1.7, 1e-9));
    expect(parsed.first.ru, 'Брат, наш ***.');
    expect(parsed.last.range.start, closeTo(7.52, 1e-9));
  });

  test('Многострочный текст реплики сохраняется', () {
    const multi = [
      Cue(index: 1, range: TimeRange(0, 2), orig: '', ru: 'Первая строка\nВторая строка',
          status: CueStatus.ok, flags: {}),
    ];
    final parsed = parseSrt(buildSrt(multi, field: SrtField.ru));
    expect(parsed.single.ru, 'Первая строка\nВторая строка');
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/srt_test.dart`
Expected: FAIL — файл `srt.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/srt.dart
import 'models.dart';

enum SrtField { orig, ru }

String _two(int v) => v.toString().padLeft(2, '0');
String _three(int v) => v.toString().padLeft(3, '0');

String formatSrtTimestamp(double seconds) {
  final totalMs = (seconds * 1000).round();
  final ms = totalMs % 1000;
  final totalSec = totalMs ~/ 1000;
  return '${_two(totalSec ~/ 3600)}:${_two((totalSec % 3600) ~/ 60)}:'
      '${_two(totalSec % 60)},${_three(ms)}';
}

double parseSrtTimestamp(String value) {
  final m = RegExp(r'(\d+):(\d+):(\d+),(\d+)').firstMatch(value.trim());
  if (m == null) throw FormatException('Не таймкод SRT: $value');
  return int.parse(m.group(1)!) * 3600 +
      int.parse(m.group(2)!) * 60 +
      int.parse(m.group(3)!) +
      int.parse(m.group(4)!) / 1000;
}

String _textOf(Cue cue, SrtField field) =>
    field == SrtField.orig ? cue.orig : cue.ru;

/// Собирает SRT из реплик. Реплики с пустым текстом пропускаются,
/// номера блоков идут подряд без дыр.
String buildSrt(List<Cue> cues, {required SrtField field}) {
  final buffer = StringBuffer();
  var number = 1;
  for (final cue in cues) {
    final text = _textOf(cue, field).trim();
    if (text.isEmpty) continue;
    buffer
      ..writeln(number)
      ..writeln('${formatSrtTimestamp(cue.range.start)} --> '
          '${formatSrtTimestamp(cue.range.end)}')
      ..writeln(text)
      ..writeln();
    number++;
  }
  return buffer.toString();
}

/// Разбирает SRT. Текст кладётся и в orig, и в ru: вызывающий знает,
/// какой это файл, а модель одна.
List<Cue> parseSrt(String content) {
  final blocks = content.trim().split(RegExp(r'\n\s*\n'));
  final cues = <Cue>[];
  for (final block in blocks) {
    final lines = block.trim().split('\n');
    if (lines.length < 3) continue;
    final times = lines[1].split('-->');
    if (times.length != 2) continue;
    final text = lines.sublist(2).join('\n').trim();
    cues.add(Cue(
      index: int.tryParse(lines[0].trim()) ?? cues.length + 1,
      range: TimeRange(parseSrtTimestamp(times[0]), parseSrtTimestamp(times[1])),
      orig: text,
      ru: text,
      status: CueStatus.ok,
      flags: const {},
    ));
  }
  return cues;
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/srt_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/srt.dart test/core/srt_test.dart
git commit -m "Генерация и разбор SRT"
```

---

### Task 6: Валидация таймингов и подсветка сомнительных реплик

**Files:**
- Create: `lib/core/pipeline/validation.dart`
- Test: `test/core/pipeline/validation_test.dart`

**Interfaces:**
- Consumes: `Cue`, `CueFlag`, `CueStatus`, `TimeRange` из `lib/core/models.dart`.
- Produces:
  - `enum TimingProblem { endBeforeStart, overlapsNext }`
  - `class TimingIssue { final int cueIndex; final TimingProblem problem; }`
  - `List<TimingIssue> validateTimings(List<Cue> cues)`
  - `bool hasRepeatLoop(String text)`
  - `List<Cue> applyAutoFlags(List<Cue> cues)`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/pipeline/validation_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/validation.dart';

Cue _cue(int i, double start, double end, {String orig = 'текст', String ru = 'текст',
    CueStatus status = CueStatus.ok}) {
  return Cue(index: i, range: TimeRange(start, end), orig: orig, ru: ru,
      status: status, flags: const {});
}

void main() {
  test('Корректные тайминги не дают замечаний', () {
    expect(validateTimings([_cue(1, 0, 2), _cue(2, 2.5, 4)]), isEmpty);
  });

  test('Конец раньше начала — ошибка', () {
    final issues = validateTimings([_cue(1, 5, 3)]);
    expect(issues.single.problem, TimingProblem.endBeforeStart);
    expect(issues.single.cueIndex, 1);
  });

  test('Нулевая длительность — ошибка', () {
    expect(validateTimings([_cue(1, 3, 3)]).single.problem,
        TimingProblem.endBeforeStart);
  });

  test('Перекрытие соседних реплик — ошибка', () {
    final issues = validateTimings([_cue(1, 0, 5), _cue(2, 4.5, 8)]);
    expect(issues.single.problem, TimingProblem.overlapsNext);
    expect(issues.single.cueIndex, 1);
  });

  test('Зацикленный повтор токена ловится с четвёртого раза', () {
    expect(hasRepeatLoop('*** *** *** ***'), isTrue);
    expect(hasRepeatLoop('*** *** ***'), isFalse);
    expect(hasRepeatLoop('bu niye çok sulu ***'), isFalse);
  });

  test('Повтор регистронезависим и не путается на пунктуации', () {
    expect(hasRepeatLoop('Da da, da. da da'), isTrue);
  });

  test('Автопометки ставятся по повтору, статусу и провалу перевода', () {
    final flagged = applyAutoFlags([
      _cue(1, 0, 2, orig: 'da da da da da'),
      _cue(2, 3, 5, status: CueStatus.failed, orig: '', ru: ''),
      _cue(3, 6, 8, orig: 'metin var', ru: ''),
      _cue(4, 9, 11),
    ]);
    expect(flagged[0].flags, contains(CueFlag.repeatLoop));
    expect(flagged[1].flags, contains(CueFlag.translateFailed));
    expect(flagged[2].flags, contains(CueFlag.translateFailed));
    expect(flagged[3].flags, isEmpty);
  });

  test('Пустая по смыслу реплика не помечается провалом перевода', () {
    final flagged = applyAutoFlags([_cue(1, 0, 2, orig: '', ru: '',
        status: CueStatus.empty)]);
    expect(flagged.single.flags, isEmpty);
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/pipeline/validation_test.dart`
Expected: FAIL — файл `validation.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/pipeline/validation.dart
import '../models.dart';

enum TimingProblem { endBeforeStart, overlapsNext }

class TimingIssue {
  final int cueIndex;
  final TimingProblem problem;
  const TimingIssue(this.cueIndex, this.problem);
}

/// Проверяет тайминги после ручной правки: некорректный SRT лучше не собирать.
List<TimingIssue> validateTimings(List<Cue> cues) {
  final issues = <TimingIssue>[];
  for (var i = 0; i < cues.length; i++) {
    final cue = cues[i];
    if (cue.range.end <= cue.range.start) {
      issues.add(TimingIssue(cue.index, TimingProblem.endBeforeStart));
      continue;
    }
    if (i + 1 < cues.length && cue.range.end > cues[i + 1].range.start) {
      issues.add(TimingIssue(cue.index, TimingProblem.overlapsNext));
    }
  }
  return issues;
}

/// Ловит характерный сбой распознавания: одно и то же слово подряд
/// четыре раза и больше (реальный случай — «***» восемь раз).
bool hasRepeatLoop(String text) {
  final tokens = text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((t) => t.isNotEmpty)
      .toList();
  var streak = 1;
  for (var i = 1; i < tokens.length; i++) {
    streak = tokens[i] == tokens[i - 1] ? streak + 1 : 1;
    if (streak >= 4) return true;
  }
  return false;
}

/// Проставляет пометки «стоит посмотреть человеку».
List<Cue> applyAutoFlags(List<Cue> cues) {
  return cues.map((cue) {
    final flags = <CueFlag>{...cue.flags};
    if (hasRepeatLoop(cue.orig)) flags.add(CueFlag.repeatLoop);
    if (cue.status == CueStatus.failed) flags.add(CueFlag.translateFailed);
    if (cue.orig.trim().isNotEmpty && cue.ru.trim().isEmpty) {
      flags.add(CueFlag.translateFailed);
    }
    return cue.copyWith(flags: flags);
  }).toList();
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/pipeline/validation_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/pipeline/validation.dart test/core/pipeline/validation_test.dart
git commit -m "Валидация таймингов и автопометки сомнительных реплик"
```

---

### Task 7: Запуск ffmpeg и сборка команд

Интерфейс `FfmpegRunner` — единственное место, которое на Android будет
подменено библиотекой. Сборка команд и экранирование — общие и чистые.

**Files:**
- Create: `lib/core/ffmpeg/ffmpeg_runner.dart`, `lib/core/ffmpeg/process_runner.dart`, `lib/core/ffmpeg/commands.dart`
- Test: `test/core/ffmpeg/commands_test.dart`, `test/core/ffmpeg/process_runner_test.dart`

**Interfaces:**
- Consumes: `TimeRange`.
- Produces:
  - `class FfmpegResult { final int exitCode; final String log; bool get ok => exitCode == 0; }`
  - `abstract class FfmpegRunner { Future<FfmpegResult> run(List<String> args, {void Function(double seconds)? onProgress}); Future<double> probeDuration(String path); }`
  - `class ProcessFfmpegRunner implements FfmpegRunner { ProcessFfmpegRunner({String ffmpegPath = 'ffmpeg', String ffprobePath = 'ffprobe'}); }`
  - `String escapeFilterArg(String value)`
  - `class FfmpegCommands { static List<String> extractAudio(...); static List<String> detectSilence(...); static List<String> cutSegment(...); static List<String> burnSubtitles(...); static List<String> grayBand(...); }`

- [ ] **Step 1: Написать падающий тест на сборку команд**

```dart
// test/core/ffmpeg/commands_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/commands.dart';

void main() {
  test('Спецсимволы в путях фильтра экранируются', () {
    expect(escapeFilterArg(r'C:\Users\dev\subs.srt'),
        r'C\:\\Users\\dev\\subs.srt');
    expect(escapeFilterArg("it's.srt"), r"it\'s.srt");
  });

  test('Команда извлечения звука даёт моно 48 кГц', () {
    final args = FfmpegCommands.extractAudio(input: 'in.mp4', output: 'out.wav');
    expect(args, containsAllInOrder(['-i', 'in.mp4']));
    expect(args, containsAllInOrder(['-ac', '1']));
    expect(args, containsAllInOrder(['-ar', '48000']));
    expect(args, contains('-vn'));
    expect(args.last, 'out.wav');
  });

  test('Команда поиска пауз содержит порог и длительность', () {
    final args = FfmpegCommands.detectSilence(
        input: 'a.wav', noise: '-30dB', minDuration: 0.3);
    expect(args, contains('silencedetect=noise=-30dB:d=0.3'));
    expect(args, containsAllInOrder(['-f', 'null']));
  });

  test('Команда нарезки задаёт границы и OggOpus 64k моно', () {
    final args = FfmpegCommands.cutSegment(
        input: 'a.wav', output: 's.ogg', start: 7.52, end: 13.23);
    expect(args, containsAllInOrder(['-ss', '7.52']));
    expect(args, containsAllInOrder(['-to', '13.23']));
    expect(args, containsAllInOrder(['-c:a', 'libopus']));
    expect(args, containsAllInOrder(['-b:a', '64k']));
    expect(args, containsAllInOrder(['-ac', '1']));
  });

  test('Команда вшивания фиксирует кодек, качество и копирование звука', () {
    final args = FfmpegCommands.burnSubtitles(
      input: 'in.mp4',
      srtPath: 'subs.srt',
      fontsDir: 'fonts',
      output: 'out.mp4',
    );
    final filter = args[args.indexOf('-vf') + 1];
    expect(filter, contains('subtitles=subs.srt'));
    expect(filter, contains('fontsdir=fonts'));
    expect(filter, contains("force_style='FontName=Noto Sans,Outline=2'"));
    expect(args, containsAllInOrder(['-c:v', 'libx264']));
    expect(args, containsAllInOrder(['-crf', '18']));
    expect(args, containsAllInOrder(['-c:a', 'copy']));
  });

  test('Команда серой полосы вырезает нижние 20 % кадра в файл', () {
    final args = FfmpegCommands.grayBand(
        input: 'v.mp4', atSeconds: 4.2, output: 'band.gray');
    expect(args, containsAllInOrder(['-ss', '4.20']));
    expect(args.join(' '), contains('crop=iw:ih*0.2:0:ih*0.8'));
    expect(args.join(' '), contains('format=gray'));
    expect(args, containsAllInOrder(['-f', 'rawvideo']));
    expect(args.last, 'band.gray',
        reason: 'пишем в файл, а не в stdout: так работает и Android-раннер');
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/ffmpeg/commands_test.dart`
Expected: FAIL — файл `commands.dart` не существует.

- [ ] **Step 3: Написать сборку команд**

```dart
// lib/core/ffmpeg/commands.dart

/// Экранирует значение внутри аргумента фильтра ffmpeg.
/// Порядок важен: сначала обратный слэш, иначе экранируем собственные вставки.
String escapeFilterArg(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll(':', r'\:')
    .replaceAll("'", r"\'");

class FfmpegCommands {
  static List<String> extractAudio({
    required String input,
    required String output,
  }) =>
      [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-i', input,
        '-vn', '-ac', '1', '-ar', '48000', '-c:a', 'pcm_s16le',
        output,
      ];

  static List<String> detectSilence({
    required String input,
    required String noise,
    required double minDuration,
  }) =>
      [
        '-hide_banner', '-nostats',
        '-i', input,
        '-af', 'silencedetect=noise=$noise:d=$minDuration',
        '-f', 'null', '-',
      ];

  static List<String> cutSegment({
    required String input,
    required String output,
    required double start,
    required double end,
  }) =>
      [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-i', input,
        '-ss', start.toStringAsFixed(2),
        '-to', end.toStringAsFixed(2),
        '-vn', '-ac', '1', '-c:a', 'libopus', '-b:a', '64k',
        output,
      ];

  static List<String> burnSubtitles({
    required String input,
    required String srtPath,
    required String fontsDir,
    required String output,
  }) {
    final filter = 'subtitles=${escapeFilterArg(srtPath)}'
        ':fontsdir=${escapeFilterArg(fontsDir)}'
        ":force_style='FontName=Noto Sans,Outline=2'";
    return [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-i', input,
      '-vf', filter,
      '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast',
      '-c:a', 'copy',
      '-movflags', '+faststart',
      '-progress', 'pipe:1',
      output,
    ];
  }

  /// Один кадр нижних 20 % экрана в виде сырых байт яркости —
  /// вход для проверки, что субтитры действительно нарисовались.
  /// Пишем в файл, а не в stdout: библиотечный раннер на Android
  /// не отдаёт поток вывода наружу.
  static List<String> grayBand({
    required String input,
    required double atSeconds,
    required String output,
  }) =>
      [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-ss', atSeconds.toStringAsFixed(2),
        '-i', input,
        '-vf', 'crop=iw:ih*0.2:0:ih*0.8,format=gray',
        '-frames:v', '1',
        '-f', 'rawvideo', output,
      ];
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/ffmpeg/commands_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Написать падающий тест на исполнителя**

```dart
// test/core/ffmpeg/process_runner_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';

void main() {
  late Directory tmp;
  final runner = ProcessFfmpegRunner();

  setUpAll(() => tmp = Directory.systemTemp.createTempSync('runner_test_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('Синтезирует тон и читает его длительность', () async {
    final wav = '${tmp.path}/tone.wav';
    final made = await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3',
      wav,
    ]);
    expect(made.ok, isTrue, reason: made.log);
    expect(await runner.probeDuration(wav), closeTo(3.0, 0.05));
  });

  test('Неверные аргументы дают ненулевой код и текст ошибки', () async {
    final result = await runner.run(['-i', '${tmp.path}/нет-такого.mp4', '-f', 'null', '-']);
    expect(result.ok, isFalse);
    expect(result.log, isNotEmpty);
  });

  test('FfmpegResult.ok привязан к нулевому коду', () {
    expect(const FfmpegResult(exitCode: 0, log: '').ok, isTrue);
    expect(const FfmpegResult(exitCode: 1, log: '').ok, isFalse);
  });
}
```

- [ ] **Step 6: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/ffmpeg/process_runner_test.dart`
Expected: FAIL — файлы `ffmpeg_runner.dart` и `process_runner.dart` не существуют.

- [ ] **Step 7: Написать интерфейс и реализацию через процесс**

```dart
// lib/core/ffmpeg/ffmpeg_runner.dart
class FfmpegResult {
  final int exitCode;
  final String log;
  const FfmpegResult({required this.exitCode, required this.log});
  bool get ok => exitCode == 0;
}

/// Единственная точка, где ядро зависит от того, как именно доступен ffmpeg:
/// внешним процессом на десктопе или библиотекой на Android.
abstract class FfmpegRunner {
  /// [onProgress] получает позицию обработки в секундах, если команда
  /// запущена с `-progress pipe:1`.
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(double seconds)? onProgress,
  });

  Future<double> probeDuration(String path);
}
```

```dart
// lib/core/ffmpeg/process_runner.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ffmpeg_runner.dart';

/// Десктопная реализация: ffmpeg как отдельный процесс.
/// На Windows путь укажет на `tools/ffmpeg/ffmpeg.exe` рядом с приложением,
/// в тестах и разработке берётся из PATH.
class ProcessFfmpegRunner implements FfmpegRunner {
  final String ffmpegPath;
  final String ffprobePath;

  ProcessFfmpegRunner({
    this.ffmpegPath = 'ffmpeg',
    this.ffprobePath = 'ffprobe',
  });

  static final _outTimeUs = RegExp(r'out_time_us=(\d+)');

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(double seconds)? onProgress,
  }) async {
    final process = await Process.start(ffmpegPath, args);
    final log = StringBuffer();

    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach(log.write);

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      final match = _outTimeUs.firstMatch(line);
      if (match != null && onProgress != null) {
        onProgress(int.parse(match.group(1)!) / 1000000);
      }
    });

    final exitCode = await process.exitCode;
    await Future.wait([stderrDone, stdoutDone]);
    return FfmpegResult(exitCode: exitCode, log: log.toString());
  }

  @override
  Future<double> probeDuration(String path) async {
    final result = await Process.run(ffprobePath, [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=nw=1:nk=1',
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('ffprobe не смог прочитать $path: ${result.stderr}');
    }
    return double.parse((result.stdout as String).trim());
  }
}
```

- [ ] **Step 8: Запустить оба теста и убедиться, что они проходят**

Run: `flutter test test/core/ffmpeg/`
Expected: `All tests passed!`

- [ ] **Step 9: Коммит**

```bash
git add lib/core/ffmpeg test/core/ffmpeg
git commit -m "FfmpegRunner: интерфейс, запуск процессом, сборка команд"
```

---

### Task 8: Адаптивный подбор порога тишины

**Files:**
- Create: `lib/core/pipeline/silence_scanner.dart`
- Test: `test/core/pipeline/silence_scanner_test.dart`

**Interfaces:**
- Consumes: `FfmpegRunner`, `FfmpegResult`, `FfmpegCommands`, `parseSilenceLog`, `speechIntervals`, `buildSegments`, `forcedSegments`, `TimeRange`.
- Produces:
  - `class SilenceProfile { final String threshold; final double minDuration; const SilenceProfile(this.threshold, this.minDuration); }`
  - `const List<SilenceProfile> kSilenceProfiles`
  - `class SilenceScan { final List<TimeRange> segments; final String threshold; final bool forcedSplit; }`
  - `class SilenceScanner { SilenceScanner(this.runner); Future<SilenceScan> scan({required String audioPath, required double duration}); }`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/pipeline/silence_scanner_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitler/core/pipeline/silence_scanner.dart';

/// Отдаёт заранее заготовленный лог для каждого порога.
class FakeRunner implements FfmpegRunner {
  final Map<String, String> logsByThreshold;
  final List<String> triedThresholds = [];
  FakeRunner(this.logsByThreshold);

  @override
  Future<FfmpegResult> run(List<String> args,
      {void Function(double seconds)? onProgress}) async {
    final filter = args[args.indexOf('-af') + 1];
    final threshold =
        RegExp(r'noise=(-?\d+dB)').firstMatch(filter)!.group(1)!;
    triedThresholds.add(threshold);
    return FfmpegResult(
        exitCode: 0, log: logsByThreshold[threshold] ?? '');
  }

  @override
  Future<double> probeDuration(String path) async => 30.0;
}

void main() {
  test('Останавливается на первом пороге, где нашлись паузы', () async {
    final runner = FakeRunner({
      '-30dB': '''
silence_start: 5.0
silence_end: 6.0 | silence_duration: 1.0
silence_start: 12.0
silence_end: 13.0 | silence_duration: 1.0
''',
    });
    final scan = await SilenceScanner(runner)
        .scan(audioPath: 'a.wav', duration: 30.0);
    expect(scan.threshold, '-30dB');
    expect(runner.triedThresholds, ['-30dB'], reason: 'дальше идти не нужно');
    expect(scan.forcedSplit, isFalse);
    expect(scan.segments, isNotEmpty);
  });

  test('Перебирает пороги, пока пауз недостаточно', () async {
    final runner = FakeRunner({
      '-15dB': '''
silence_start: 5.0
silence_end: 6.0 | silence_duration: 1.0
silence_start: 12.0
silence_end: 13.0 | silence_duration: 1.0
''',
    });
    final scan = await SilenceScanner(runner)
        .scan(audioPath: 'a.wav', duration: 30.0);
    expect(scan.threshold, '-15dB');
    expect(runner.triedThresholds,
        ['-30dB', '-25dB', '-20dB', '-18dB', '-15dB']);
    expect(scan.forcedSplit, isFalse);
  });

  test('Если пауз нет нигде — принудительная нарезка и флаг', () async {
    final runner = FakeRunner(const {});
    final scan = await SilenceScanner(runner)
        .scan(audioPath: 'a.wav', duration: 30.0);
    expect(scan.forcedSplit, isTrue);
    expect(scan.segments.length, greaterThan(3));
    expect(scan.segments.last.end, closeTo(30.0, 1e-9));
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/pipeline/silence_scanner_test.dart`
Expected: FAIL — файл `silence_scanner.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/pipeline/silence_scanner.dart
import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../models.dart';
import 'segmenter.dart';
import 'silence_parser.dart';

class SilenceProfile {
  final String threshold;
  final double minDuration;
  const SilenceProfile(this.threshold, this.minDuration);
}

/// Пороги от щадящего к агрессивному: на записях со стройплощадки тихих
/// пауз не бывает, приходится спускаться до −15 dB.
const List<SilenceProfile> kSilenceProfiles = [
  SilenceProfile('-30dB', 0.3),
  SilenceProfile('-25dB', 0.3),
  SilenceProfile('-20dB', 0.25),
  SilenceProfile('-18dB', 0.25),
  SilenceProfile('-15dB', 0.25),
];

class SilenceScan {
  final List<TimeRange> segments;
  final String threshold;
  final bool forcedSplit;
  const SilenceScan({
    required this.segments,
    required this.threshold,
    required this.forcedSplit,
  });
}

class SilenceScanner {
  final FfmpegRunner runner;
  SilenceScanner(this.runner);

  /// Считается, что порог подошёл, если найдена хотя бы одна пауза
  /// на каждые 15 секунд записи.
  static int _requiredPauses(double duration) =>
      (duration / 15).floor().clamp(1, 1 << 30);

  Future<List<SilenceEvent>> _detect(
      String audioPath, SilenceProfile profile) async {
    final result = await runner.run(FfmpegCommands.detectSilence(
      input: audioPath,
      noise: profile.threshold,
      minDuration: profile.minDuration,
    ));
    return parseSilenceLog(result.log);
  }

  Future<SilenceScan> scan({
    required String audioPath,
    required double duration,
  }) async {
    final needed = _requiredPauses(duration);

    for (final profile in kSilenceProfiles) {
      final events = await _detect(audioPath, profile);
      final pauses =
          events.where((e) => e.kind == SilenceEventKind.start).length;
      if (pauses < needed) continue;

      final speech = speechIntervals(events, duration);
      // Более чувствительный порог нужен только чтобы резать длинные куски.
      final needsFine =
          speech.any((r) => r.duration > kMaxSegment + 0.5);
      var fine = const <TimeRange>[];
      if (needsFine) {
        final bumped = int.parse(profile.threshold.replaceAll('dB', '')) + 3;
        fine = speechIntervals(
          await _detect(audioPath, SilenceProfile('${bumped}dB', 0.15)),
          duration,
        );
      }

      return SilenceScan(
        segments: buildSegments(
            speech: speech, duration: duration, fineSpeech: fine),
        threshold: profile.threshold,
        forcedSplit: false,
      );
    }

    return SilenceScan(
      segments: forcedSegments(duration),
      threshold: kSilenceProfiles.last.threshold,
      forcedSplit: true,
    );
  }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/pipeline/silence_scanner_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/pipeline/silence_scanner.dart test/core/pipeline/silence_scanner_test.dart
git commit -m "Адаптивный подбор порога тишины с принудительным фолбэком"
```

---

### Task 9: Нарезка сегментов в OggOpus

**Files:**
- Create: `lib/core/pipeline/segment_cutter.dart`
- Test: `test/core/pipeline/segment_cutter_test.dart`

**Interfaces:**
- Consumes: `FfmpegRunner`, `FfmpegCommands`, `TimeRange`.
- Produces:
  - `class SegmentFile { final int index; final TimeRange range; final String path; }`
  - `class SegmentCutter { SegmentCutter(this.runner); Future<List<SegmentFile>> cut({required String audioPath, required List<TimeRange> segments, required String outputDir}); }`
  - `const int kMaxSegmentBytes = 1000000;`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/pipeline/segment_cutter_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/segment_cutter.dart';

void main() {
  late Directory tmp;
  late String tone;
  final runner = ProcessFfmpegRunner();

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('cutter_test_');
    tone = '${tmp.path}/tone.wav';
    await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=20',
      '-ac', '1', '-ar', '48000', tone,
    ]);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('Каждый сегмент превращается в непустой ogg-файл', () async {
    final files = await SegmentCutter(runner).cut(
      audioPath: tone,
      segments: const [TimeRange(0.0, 5.0), TimeRange(6.0, 12.0)],
      outputDir: tmp.path,
    );
    expect(files.length, 2);
    expect(files[0].index, 1);
    expect(files[1].index, 2);
    for (final f in files) {
      final file = File(f.path);
      expect(file.existsSync(), isTrue, reason: f.path);
      expect(file.lengthSync(), greaterThan(0));
      expect(file.lengthSync(), lessThan(kMaxSegmentBytes),
          reason: 'лимит SpeechKit v1 — 1 МБ на запрос');
    }
  });

  test('Имена файлов упорядочены и не конфликтуют', () async {
    final files = await SegmentCutter(runner).cut(
      audioPath: tone,
      segments: const [TimeRange(0.0, 2.0), TimeRange(3.0, 5.0)],
      outputDir: tmp.path,
    );
    expect(files.map((f) => f.path.split('/').last).toList(),
        ['seg_001.ogg', 'seg_002.ogg']);
  });

  test('Ошибка ffmpeg превращается в исключение с текстом лога', () async {
    expect(
      () => SegmentCutter(runner).cut(
        audioPath: '${tmp.path}/нет-файла.wav',
        segments: const [TimeRange(0.0, 1.0)],
        outputDir: tmp.path,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/pipeline/segment_cutter_test.dart`
Expected: FAIL — файл `segment_cutter.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/pipeline/segment_cutter.dart
import 'dart:io';

import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../models.dart';

/// Жёсткий лимит SpeechKit v1 на один синхронный запрос.
const int kMaxSegmentBytes = 1000000;

class SegmentFile {
  final int index;
  final TimeRange range;
  final String path;
  const SegmentFile({
    required this.index,
    required this.range,
    required this.path,
  });
}

class SegmentCutter {
  final FfmpegRunner runner;
  SegmentCutter(this.runner);

  Future<List<SegmentFile>> cut({
    required String audioPath,
    required List<TimeRange> segments,
    required String outputDir,
  }) async {
    Directory(outputDir).createSync(recursive: true);
    final files = <SegmentFile>[];

    for (var i = 0; i < segments.length; i++) {
      final index = i + 1;
      final name = 'seg_${index.toString().padLeft(3, '0')}.ogg';
      final path = '$outputDir${Platform.pathSeparator}$name';

      final result = await runner.run(FfmpegCommands.cutSegment(
        input: audioPath,
        output: path,
        start: segments[i].start,
        end: segments[i].end,
      ));
      if (!result.ok) {
        throw StateError('Не удалось вырезать сегмент $index: ${result.log}');
      }
      files.add(SegmentFile(index: index, range: segments[i], path: path));
    }
    return files;
  }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/pipeline/segment_cutter_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/pipeline/segment_cutter.dart test/core/pipeline/segment_cutter_test.dart
git commit -m "Нарезка сегментов в OggOpus 64k моно"
```

---

### Task 10: Ошибки API и политика повторов

**Files:**
- Create: `lib/core/cloud/api_errors.dart`, `lib/core/cloud/retry.dart`
- Test: `test/core/cloud/retry_test.dart`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `class ApiException implements Exception { final int? statusCode; final String message; }`
  - `class AuthException extends ApiException` — 401/403, останавливает весь прогон
  - `class TransientException extends ApiException` — 429/5xx/сеть, подлежит повтору
  - `const List<Duration> kRetryDelays = [1s, 4s, 10s]`
  - `Future<T> withRetry<T>(Future<T> Function() body, {List<Duration> delays, Future<void> Function(Duration)? sleep})`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/cloud/retry_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/retry.dart';

void main() {
  test('Успех с первой попытки не порождает пауз', () async {
    final slept = <Duration>[];
    final value = await withRetry(() async => 'ok', sleep: (d) async => slept.add(d));
    expect(value, 'ok');
    expect(slept, isEmpty);
  });

  test('Временная ошибка повторяется с паузами 1, 4, 10 секунд', () async {
    final slept = <Duration>[];
    var attempts = 0;
    final value = await withRetry(
      () async {
        attempts++;
        if (attempts < 3) throw TransientException(statusCode: 429, message: 'busy');
        return 'ok';
      },
      sleep: (d) async => slept.add(d),
    );
    expect(value, 'ok');
    expect(attempts, 3);
    expect(slept, [const Duration(seconds: 1), const Duration(seconds: 4)]);
  });

  test('После трёх неудач исключение пробрасывается наружу', () async {
    var attempts = 0;
    await expectLater(
      withRetry(
        () async {
          attempts++;
          throw TransientException(statusCode: 500, message: 'boom');
        },
        sleep: (_) async {},
      ),
      throwsA(isA<TransientException>()),
    );
    expect(attempts, 3, reason: 'ровно три попытки');
  });

  test('Ошибка авторизации не повторяется — прогон надо останавливать', () async {
    var attempts = 0;
    await expectLater(
      withRetry(
        () async {
          attempts++;
          throw AuthException(statusCode: 403, message: 'нет роли');
        },
        sleep: (_) async {},
      ),
      throwsA(isA<AuthException>()),
    );
    expect(attempts, 1);
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/cloud/retry_test.dart`
Expected: FAIL — файлы `api_errors.dart` и `retry.dart` не существуют.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/cloud/api_errors.dart
class ApiException implements Exception {
  final int? statusCode;
  final String message;
  const ApiException({this.statusCode, required this.message});

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// 401/403 — ключ неверен или у сервисного аккаунта нет нужной роли.
/// Повторять бессмысленно: останавливаем весь прогон.
class AuthException extends ApiException {
  const AuthException({super.statusCode, required super.message});
}

/// 429/5xx/обрыв сети — имеет смысл повторить.
class TransientException extends ApiException {
  const TransientException({super.statusCode, required super.message});
}
```

```dart
// lib/core/cloud/retry.dart
import 'api_errors.dart';

/// Паузы между попытками. Длина списка задаёт число повторов.
const List<Duration> kRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 4),
  Duration(seconds: 10),
];

/// Повторяет [body] при временных ошибках. [sleep] подменяется в тестах,
/// чтобы не ждать по-настоящему.
Future<T> withRetry<T>(
  Future<T> Function() body, {
  List<Duration> delays = kRetryDelays,
  Future<void> Function(Duration)? sleep,
}) async {
  final wait = sleep ?? Future<void>.delayed;
  final maxAttempts = delays.length;

  for (var attempt = 1; ; attempt++) {
    try {
      return await body();
    } on TransientException {
      if (attempt >= maxAttempts) rethrow;
      await wait(delays[attempt - 1]);
    }
  }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/cloud/retry_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/cloud test/core/cloud
git commit -m "Классы ошибок API и политика повторов"
```

---

### Task 11: Клиент SpeechKit

**Files:**
- Create: `lib/core/cloud/speechkit_client.dart`
- Test: `test/core/cloud/speechkit_client_test.dart`

**Interfaces:**
- Consumes: `ApiException`, `AuthException`, `TransientException` из `api_errors.dart`.
- Produces:
  - `const List<String> kSupportedSttLangs = ['tr-TR', 'uz-UZ']`
  - `class SpeechKitClient { SpeechKitClient({required Dio dio, required String apiKey, String baseUrl}); Future<String> recognize({required List<int> oggBytes, required String lang}); }`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/cloud/speechkit_client_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';

void main() {
  late HttpServer server;
  late String baseUrl;
  late List<HttpRequest> received;
  int Function() nextStatus = () => 200;
  String Function() nextBody = () => '{"result":"tam 12 saat var"}';

  setUp(() async {
    received = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      received.add(request);
      await request.drain<void>();
      request.response.statusCode = nextStatus();
      request.response.write(nextBody());
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  SpeechKitClient client() => SpeechKitClient(
        dio: Dio(),
        apiKey: 'TEST-KEY',
        baseUrl: baseUrl,
      );

  test('Запрос содержит нужные параметры и заголовок с ключом', () async {
    await client().recognize(oggBytes: utf8.encode('ogg'), lang: 'tr-TR');
    final request = received.single;
    expect(request.method, 'POST');
    expect(request.uri.queryParameters['lang'], 'tr-TR');
    expect(request.uri.queryParameters['format'], 'oggopus');
    expect(request.uri.queryParameters['topic'], 'general');
    expect(request.uri.queryParameters.containsKey('folderId'), isFalse,
        reason: 'с ключом сервисного аккаунта folderId запрещён');
    expect(request.uri.queryParameters.containsKey('sampleRateHertz'), isFalse);
    expect(request.headers.value('Authorization'), 'Api-Key TEST-KEY');
  });

  test('Успешный ответ отдаёт распознанный текст', () async {
    final text = await client().recognize(
        oggBytes: utf8.encode('ogg'), lang: 'tr-TR');
    expect(text, 'tam 12 saat var');
  });

  test('Отсутствие речи — пустая строка, а не ошибка', () async {
    nextBody = () => '{"result":""}';
    expect(await client().recognize(oggBytes: utf8.encode('o'), lang: 'uz-UZ'), '');
  });

  test('401 и 403 дают AuthException', () async {
    nextStatus = () => 401;
    nextBody = () => '{"error":"unauthorized"}';
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR'),
      throwsA(isA<AuthException>()),
    );
    nextStatus = () => 403;
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR'),
      throwsA(isA<AuthException>()),
    );
  });

  test('429 и 500 дают TransientException', () async {
    nextStatus = () => 429;
    nextBody = () => 'too many requests';
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR'),
      throwsA(isA<TransientException>()),
    );
    nextStatus = () => 500;
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR'),
      throwsA(isA<TransientException>()),
    );
  });

  test('Неизвестный язык отклоняется до похода в сеть', () async {
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'ru-RU'),
      throwsA(isA<ArgumentError>()),
    );
    expect(received, isEmpty);
  });

  test('Сообщение об ошибке не содержит ключ', () async {
    nextStatus = () => 403;
    nextBody = () => 'forbidden';
    try {
      await client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR');
      fail('должно было бросить');
    } on ApiException catch (e) {
      expect(e.toString(), isNot(contains('TEST-KEY')));
    }
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/cloud/speechkit_client_test.dart`
Expected: FAIL — файл `speechkit_client.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/cloud/speechkit_client.dart
import 'package:dio/dio.dart';

import 'api_errors.dart';

/// Языки, которые приложение отправляет в распознавание. Язык всегда задаётся
/// явно: автоопределение для узбекского даёт молчаливые ошибки.
const List<String> kSupportedSttLangs = ['tr-TR', 'uz-UZ'];

class SpeechKitClient {
  final Dio dio;
  final String apiKey;
  final String baseUrl;

  SpeechKitClient({
    required this.dio,
    required this.apiKey,
    this.baseUrl = 'https://stt.api.cloud.yandex.net',
  });

  /// Распознаёт один сегмент. Пустая строка означает «речи не найдено».
  Future<String> recognize({
    required List<int> oggBytes,
    required String lang,
  }) async {
    if (!kSupportedSttLangs.contains(lang)) {
      throw ArgumentError.value(lang, 'lang', 'Поддерживаются $kSupportedSttLangs');
    }

    try {
      final response = await dio.post<Map<String, dynamic>>(
        '$baseUrl/speech/v1/stt:recognize',
        queryParameters: {
          'topic': 'general',
          'format': 'oggopus',
          'lang': lang,
        },
        data: Stream.fromIterable([oggBytes]),
        options: Options(
          headers: {
            'Authorization': 'Api-Key $apiKey',
            Headers.contentLengthHeader: oggBytes.length,
          },
          responseType: ResponseType.json,
        ),
      );
      return (response.data?['result'] as String?) ?? '';
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  ApiException _mapError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      return AuthException(
        statusCode: status,
        message: status == 401
            ? 'Ключ неверный или отозван'
            : 'У ключа нет роли ai.speechkit-stt.user',
      );
    }
    if (status == 429 || (status != null && status >= 500)) {
      return TransientException(
          statusCode: status, message: 'Сервис распознавания недоступен');
    }
    if (status == null) {
      return const TransientException(message: 'Нет связи с сервисом распознавания');
    }
    return ApiException(
        statusCode: status, message: 'Ошибка распознавания (код $status)');
  }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/cloud/speechkit_client_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/cloud/speechkit_client.dart test/core/cloud/speechkit_client_test.dart
git commit -m "Клиент SpeechKit v1 с явным языком и разбором ошибок"
```

---

### Task 12: Клиент Translate

**Files:**
- Create: `lib/core/cloud/translate_client.dart`
- Test: `test/core/cloud/translate_client_test.dart`

**Interfaces:**
- Consumes: `ApiException`, `AuthException`, `TransientException`.
- Produces:
  - `String toTranslateCode(String sttLang)` — `tr-TR` → `tr`, `uz-UZ` → `uz`
  - `const int kTranslateBatchCharLimit = 10000`
  - `List<List<String>> splitIntoBatches(List<String> texts)`
  - `class TranslateClient { TranslateClient({required Dio dio, required String apiKey, String baseUrl}); Future<List<String>> translate({required List<String> texts, required String sourceLang}); }`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/cloud/translate_client_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/translate_client.dart';

void main() {
  test('Полный код локали превращается в короткий код переводчика', () {
    expect(toTranslateCode('tr-TR'), 'tr');
    expect(toTranslateCode('uz-UZ'), 'uz',
        reason: 'uz — латиница, именно её отдаёт распознавание; '
            'кириллический узбекский в переводчике зовётся uzbcyr');
    expect(() => toTranslateCode('xx-XX'), throwsA(isA<ArgumentError>()));
  });

  test('Батчи режутся по сумме длин, а не по числу строк', () {
    final texts = [
      'a' * 6000,
      'b' * 5000,
      'c' * 100,
    ];
    final batches = splitIntoBatches(texts);
    expect(batches.length, 2);
    expect(batches[0].length, 1, reason: '6000 + 5000 > 10000');
    expect(batches[1].length, 2);
    for (final batch in batches) {
      expect(batch.fold<int>(0, (sum, t) => sum + t.length),
          lessThanOrEqualTo(kTranslateBatchCharLimit));
    }
  });

  group('сетевые', () {
    late HttpServer server;
    late String baseUrl;
    late List<Map<String, dynamic>> bodies;
    late List<HttpRequest> received;
    int status = 200;

    setUp(() async {
      bodies = [];
      received = [];
      status = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        received.add(request);
        final raw = await utf8.decoder.bind(request).join();
        if (raw.isNotEmpty) bodies.add(jsonDecode(raw) as Map<String, dynamic>);
        request.response.statusCode = status;
        if (status == 200) {
          final texts = (bodies.last['texts'] as List).cast<String>();
          request.response.write(jsonEncode({
            'translations': [for (final t in texts) {'text': 'RU:$t'}],
          }));
        } else {
          request.response.write('error');
        }
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    TranslateClient client() =>
        TranslateClient(dio: Dio(), apiKey: 'TEST-KEY', baseUrl: baseUrl);

    test('Тело запроса содержит короткие коды и не содержит folderId', () async {
      await client().translate(texts: ['merhaba'], sourceLang: 'tr-TR');
      expect(bodies.single['targetLanguageCode'], 'ru');
      expect(bodies.single['sourceLanguageCode'], 'tr');
      expect(bodies.single.containsKey('folderId'), isFalse);
      expect(received.single.headers.value('Authorization'), 'Api-Key TEST-KEY');
    });

    test('Переводы возвращаются в исходном порядке', () async {
      final result = await client()
          .translate(texts: ['bir', 'iki', 'üç'], sourceLang: 'tr-TR');
      expect(result, ['RU:bir', 'RU:iki', 'RU:üç']);
    });

    test('Длинный список уходит несколькими запросами и склеивается', () async {
      final texts = ['x' * 7000, 'y' * 7000];
      final result = await client().translate(texts: texts, sourceLang: 'uz-UZ');
      expect(received.length, 2);
      expect(result.length, 2);
      expect(result[0], startsWith('RU:x'));
      expect(result[1], startsWith('RU:y'));
    });

    test('Пустой список не ходит в сеть', () async {
      expect(await client().translate(texts: const [], sourceLang: 'tr-TR'),
          isEmpty);
      expect(received, isEmpty);
    });

    test('403 даёт AuthException с упоминанием роли перевода', () async {
      status = 403;
      try {
        await client().translate(texts: ['a'], sourceLang: 'tr-TR');
        fail('должно было бросить');
      } on AuthException catch (e) {
        expect(e.message, contains('ai.translate.user'));
        expect(e.toString(), isNot(contains('TEST-KEY')));
      }
    });

    test('503 даёт TransientException', () async {
      status = 503;
      await expectLater(
        client().translate(texts: ['a'], sourceLang: 'tr-TR'),
        throwsA(isA<TransientException>()),
      );
    });
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/cloud/translate_client_test.dart`
Expected: FAIL — файл `translate_client.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/cloud/translate_client.dart
import 'package:dio/dio.dart';

import 'api_errors.dart';

/// Лимит одного запроса: считается по сумме длин всех строк батча.
const int kTranslateBatchCharLimit = 10000;

/// Узбекский в переводчике представлен двумя языками: `uz` — латиница,
/// `uzbcyr` — кириллица. Распознавание отдаёт узбекский латиницей,
/// поэтому здесь `uz`. Если текст реплики отредактируют кириллицей,
/// для неё понадобится `uzbcyr` — это задача редактора, не этого клиента.
const Map<String, String> _sttToTranslate = {'tr-TR': 'tr', 'uz-UZ': 'uz'};

/// Translate v2 принимает короткие коды языков, а не полные локали.
String toTranslateCode(String sttLang) {
  final code = _sttToTranslate[sttLang];
  if (code == null) {
    throw ArgumentError.value(sttLang, 'sttLang', 'Неизвестный язык распознавания');
  }
  return code;
}

List<List<String>> splitIntoBatches(List<String> texts) {
  final batches = <List<String>>[];
  var current = <String>[];
  var currentLength = 0;

  for (final text in texts) {
    if (current.isNotEmpty &&
        currentLength + text.length > kTranslateBatchCharLimit) {
      batches.add(current);
      current = <String>[];
      currentLength = 0;
    }
    current.add(text);
    currentLength += text.length;
  }
  if (current.isNotEmpty) batches.add(current);
  return batches;
}

class TranslateClient {
  final Dio dio;
  final String apiKey;
  final String baseUrl;

  TranslateClient({
    required this.dio,
    required this.apiKey,
    this.baseUrl = 'https://translate.api.cloud.yandex.net',
  });

  /// Переводит тексты на русский, сохраняя порядок.
  Future<List<String>> translate({
    required List<String> texts,
    required String sourceLang,
  }) async {
    if (texts.isEmpty) return const [];
    final source = toTranslateCode(sourceLang);
    final result = <String>[];

    for (final batch in splitIntoBatches(texts)) {
      try {
        final response = await dio.post<Map<String, dynamic>>(
          '$baseUrl/translate/v2/translate',
          data: {
            'targetLanguageCode': 'ru',
            'sourceLanguageCode': source,
            'texts': batch,
          },
          options: Options(headers: {'Authorization': 'Api-Key $apiKey'}),
        );
        final translations = (response.data?['translations'] as List?) ?? const [];
        result.addAll(translations.map((t) => (t as Map)['text'] as String));
      } on DioException catch (e) {
        throw _mapError(e);
      }
    }
    return result;
  }

  ApiException _mapError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      return AuthException(
        statusCode: status,
        message: status == 401
            ? 'Ключ неверный или отозван'
            : 'У ключа нет роли ai.translate.user',
      );
    }
    if (status == 429 || (status != null && status >= 500)) {
      return TransientException(
          statusCode: status, message: 'Сервис перевода недоступен');
    }
    if (status == null) {
      return const TransientException(message: 'Нет связи с сервисом перевода');
    }
    return ApiException(
        statusCode: status, message: 'Ошибка перевода (код $status)');
  }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/cloud/translate_client_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/cloud/translate_client.dart test/core/cloud/translate_client_test.dart
git commit -m "Клиент Translate v2: короткие коды языков и батчи по сумме длин"
```

---

### Task 13: Хранилище сессии

**Files:**
- Create: `lib/core/session_store.dart`
- Test: `test/core/session_store_test.dart`

**Interfaces:**
- Consumes: `Session`, `Cue`, `SourceFingerprint` из `models.dart`.
- Produces:
  - `class SessionStore { SessionStore({required String fallbackDir}); String sessionPathFor(String videoPath); Future<Session?> load(String videoPath, SourceFingerprint actual); Future<String> save(Session session); }`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/session_store_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/session_store.dart';

void main() {
  late Directory tmp;
  late Directory fallback;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('session_test_');
    fallback = Directory.systemTemp.createTempSync('session_fallback_');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
    fallback.deleteSync(recursive: true);
  });

  Session sessionFor(String videoPath, {int size = 100}) => Session(
        videoPath: videoPath,
        fingerprint: SourceFingerprint(sizeBytes: size, durationSec: 34.8),
        lang: 'tr-TR',
        silenceThreshold: '-30dB',
        forcedSplit: false,
        cues: const [
          Cue(index: 1, range: TimeRange(0, 1.7), orig: 'abi', ru: 'брат',
              status: CueStatus.ok, flags: {}),
        ],
      );

  test('Файл сессии кладётся рядом с видео', () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    final store = SessionStore(fallbackDir: fallback.path);

    final saved = await store.save(sessionFor(video));
    expect(saved, '${tmp.path}/clip.mp4.subtitler.json');
    expect(File(saved).existsSync(), isTrue);
  });

  test('Сессия читается обратно при совпадении отпечатка', () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    final store = SessionStore(fallbackDir: fallback.path);
    await store.save(sessionFor(video));

    final loaded = await store.load(video,
        const SourceFingerprint(sizeBytes: 100, durationSec: 34.8));
    expect(loaded, isNotNull);
    expect(loaded!.cues.single.orig, 'abi');
  });

  test('Чужая сессия отбрасывается: другой файл с тем же именем', () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    final store = SessionStore(fallbackDir: fallback.path);
    await store.save(sessionFor(video));

    final loaded = await store.load(video,
        const SourceFingerprint(sizeBytes: 999, durationSec: 12.0));
    expect(loaded, isNull, reason: 'подстановка чужих реплик недопустима');
  });

  test('Отсутствие файла сессии — это null, а не исключение', () async {
    final store = SessionStore(fallbackDir: fallback.path);
    expect(
        await store.load('${tmp.path}/нет.mp4',
            const SourceFingerprint(sizeBytes: 1, durationSec: 1)),
        isNull);
  });

  test('Битый JSON не роняет приложение', () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    File('${tmp.path}/clip.mp4.subtitler.json').writeAsStringSync('{не json');
    final store = SessionStore(fallbackDir: fallback.path);
    expect(
        await store.load(video,
            const SourceFingerprint(sizeBytes: 100, durationSec: 34.8)),
        isNull);
  });

  test('Папка только на чтение — сессия уходит в запасной каталог', () async {
    final readOnly = Directory('${tmp.path}/ro')..createSync();
    final video = '${readOnly.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    Process.runSync('chmod', ['555', readOnly.path]);
    addTearDown(() => Process.runSync('chmod', ['755', readOnly.path]));

    final store = SessionStore(fallbackDir: fallback.path);
    final saved = await store.save(sessionFor(video));

    expect(saved, startsWith(fallback.path));
    expect(File(saved).existsSync(), isTrue);

    final loaded = await store.load(video,
        const SourceFingerprint(sizeBytes: 100, durationSec: 34.8));
    expect(loaded, isNotNull, reason: 'запасная сессия тоже должна читаться');
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/session_store_test.dart`
Expected: FAIL — файл `session_store.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/session_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

/// Читает и пишет `<имя>.subtitler.json`. Если папка с исходником недоступна
/// для записи (вещдок на защищённом носителе), файл уходит в [fallbackDir].
class SessionStore {
  final String fallbackDir;
  SessionStore({required this.fallbackDir});

  String sessionPathFor(String videoPath) => '$videoPath.subtitler.json';

  String fallbackPathFor(String videoPath) =>
      p.join(fallbackDir, '${p.basename(videoPath)}.subtitler.json');

  /// Возвращает сессию, только если отпечаток совпал с [actual].
  Future<Session?> load(String videoPath, SourceFingerprint actual) async {
    for (final path in [sessionPathFor(videoPath), fallbackPathFor(videoPath)]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final session = Session.fromJson(json);
        if (session.schemaVersion != Session.currentSchemaVersion) continue;
        if (!session.fingerprint.matches(actual)) continue;
        return session;
      } on FormatException {
        continue; // битый файл — как будто сессии нет
      } on TypeError {
        continue;
      }
    }
    return null;
  }

  /// Пишет сессию и возвращает фактический путь.
  Future<String> save(Session session) async {
    final content = const JsonEncoder.withIndent(' ').convert(session.toJson());
    final primary = sessionPathFor(session.videoPath);
    try {
      await File(primary).writeAsString(content, flush: true);
      return primary;
    } on FileSystemException {
      final fallback = fallbackPathFor(session.videoPath);
      Directory(fallbackDir).createSync(recursive: true);
      await File(fallback).writeAsString(content, flush: true);
      return fallback;
    }
  }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/session_store_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/session_store.dart test/core/session_store_test.dart
git commit -m "Хранилище сессии: отпечаток исходника и запасной каталог"
```

---

### Task 14: Вшивание субтитров и проверка видимости

Проверка нужна из-за реального поведения libass на Android: без
зарегистрированного шрифта ffmpeg завершается с кодом 0, а субтитров в кадре нет.

**Files:**
- Create: `lib/core/pipeline/burner.dart`
- Download: `assets/fonts/NotoSans-Regular.ttf`
- Test: `test/core/pipeline/burner_test.dart`

**Interfaces:**
- Consumes: `FfmpegRunner`, `FfmpegCommands`.
- Produces:
  - `const int kSubtitleLumaThreshold = 200;`
  - `const int kSubtitleMinNewPixels = 300;`
  - `int countBrightPixels(List<int> grayBytes)`
  - `class SubtitleBurner { SubtitleBurner(this.runner); Future<void> burn({required String input, required String srtPath, required String fontsDir, required String output, void Function(double)? onProgress}); Future<void> burnAndVerify({required String input, required String srtPath, required String fontsDir, required String output, required double checkAtSeconds, void Function(double)? onProgress}); Future<bool> subtitlesVisible({required String original, required String burned, required double atSeconds}); }`
  - `class SubtitlesInvisibleException implements Exception { const SubtitlesInvisibleException(String message); }`

- [ ] **Step 1: Положить шрифт в ассеты**

```bash
curl -L -o assets/fonts/NotoSans-Regular.ttf \
  https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf
```

Проверить, что скачался настоящий шрифт, а не HTML-страница ошибки:

Run: `file assets/fonts/NotoSans-Regular.ttf`
Expected: `TrueType Font data` (если получили HTML — взять шрифт с fonts.google.com вручную).

- [ ] **Step 2: Написать падающий тест**

```dart
// test/core/pipeline/burner_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/pipeline/burner.dart';

void main() {
  late Directory tmp;
  final runner = ProcessFfmpegRunner();
  late String video;
  late String srt;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('burner_test_');
    video = '${tmp.path}/src.mp4';
    srt = '${tmp.path}/subs.srt';

    // Тёмный ролик: любой светлый пиксель внизу — это уже субтитр.
    await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=black:s=640x360:d=6',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
      '-shortest', video,
    ]);

    File(srt).writeAsStringSync('''
1
00:00:01,000 --> 00:00:05,000
Проверка субтитров
''');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('Счётчик светлых пикселей считает только яркие байты', () {
    expect(countBrightPixels([0, 10, 199, 200, 201, 255]), 2,
        reason: 'строго больше порога 200');
    expect(countBrightPixels(const []), 0);
  });

  test('Вшивание создаёт видео, где субтитры действительно видны', () async {
    final out = '${tmp.path}/out.mp4';
    final burner = SubtitleBurner(runner);

    await burner.burn(
      input: video,
      srtPath: srt,
      fontsDir: 'assets/fonts',
      output: out,
    );

    expect(File(out).existsSync(), isTrue);
    expect(File(out).lengthSync(), greaterThan(0));
    expect(
      await burner.subtitlesVisible(
          original: video, burned: out, atSeconds: 3.0),
      isTrue,
    );
  });

  test('burnAndVerify пропускает удачное вшивание', () async {
    await SubtitleBurner(runner).burnAndVerify(
      input: video,
      srtPath: srt,
      fontsDir: 'assets/fonts',
      output: '${tmp.path}/verified.mp4',
      checkAtSeconds: 3.0,
    );
    expect(File('${tmp.path}/verified.mp4').existsSync(), isTrue);
  });

  test('burnAndVerify бросает исключение, если субтитров в кадре нет', () async {
    // SRT, у которого нет ни одной реплики в момент проверки.
    final lateSrt = '${tmp.path}/late.srt';
    File(lateSrt).writeAsStringSync('''
1
00:00:05,500 --> 00:00:05,900
Поздняя реплика
''');
    await expectLater(
      SubtitleBurner(runner).burnAndVerify(
        input: video,
        srtPath: lateSrt,
        fontsDir: 'assets/fonts',
        output: '${tmp.path}/invisible.mp4',
        checkAtSeconds: 3.0,
      ),
      throwsA(isA<SubtitlesInvisibleException>()),
    );
  });

  test('Копия без субтитров проверку не проходит', () async {
    final copy = '${tmp.path}/copy.mp4';
    await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-i', video, '-c', 'copy', copy,
    ]);
    expect(
      await SubtitleBurner(runner)
          .subtitlesVisible(original: video, burned: copy, atSeconds: 3.0),
      isFalse,
      reason: 'иначе проверка бесполезна и пропустит невидимые субтитры',
    );
  });

  test('Прогресс сообщается по ходу кодирования', () async {
    final seen = <double>[];
    await SubtitleBurner(runner).burn(
      input: video,
      srtPath: srt,
      fontsDir: 'assets/fonts',
      output: '${tmp.path}/progress.mp4',
      onProgress: seen.add,
    );
    expect(seen, isNotEmpty);
    expect(seen.last, greaterThan(0));
  });
}
```

- [ ] **Step 3: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/pipeline/burner_test.dart`
Expected: FAIL — файл `burner.dart` не существует.

- [ ] **Step 4: Написать минимальную реализацию**

```dart
// lib/core/pipeline/burner.dart
import 'dart:io';

import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';

/// Яркость, выше которой пиксель считаем частью белого текста субтитров.
const int kSubtitleLumaThreshold = 200;

/// На столько должно вырасти число светлых пикселей в нижней полосе кадра,
/// чтобы считать субтитры отрисованными. Шум компрессии столько не даёт.
const int kSubtitleMinNewPixels = 300;

int countBrightPixels(List<int> grayBytes) =>
    grayBytes.where((b) => b > kSubtitleLumaThreshold).length;

class SubtitlesInvisibleException implements Exception {
  final String message;
  const SubtitlesInvisibleException(this.message);
  @override
  String toString() => message;
}

class SubtitleBurner {
  final FfmpegRunner runner;
  SubtitleBurner(this.runner);

  Future<void> burn({
    required String input,
    required String srtPath,
    required String fontsDir,
    required String output,
    void Function(double seconds)? onProgress,
  }) async {
    final result = await runner.run(
      FfmpegCommands.burnSubtitles(
        input: input,
        srtPath: srtPath,
        fontsDir: fontsDir,
        output: output,
      ),
      onProgress: onProgress,
    );
    if (!result.ok) {
      throw StateError('Не удалось вшить субтитры: ${result.log}');
    }
  }

  /// Вшивает и сразу проверяет результат. Это основной вход для приложения:
  /// «ffmpeg вернул 0» само по себе ничего не гарантирует.
  Future<void> burnAndVerify({
    required String input,
    required String srtPath,
    required String fontsDir,
    required String output,
    required double checkAtSeconds,
    void Function(double seconds)? onProgress,
  }) async {
    await burn(
      input: input,
      srtPath: srtPath,
      fontsDir: fontsDir,
      output: output,
      onProgress: onProgress,
    );
    final visible = await subtitlesVisible(
      original: input,
      burned: output,
      atSeconds: checkAtSeconds,
    );
    if (!visible) {
      throw const SubtitlesInvisibleException(
          'Субтитры не отрисовались: проверьте, что шрифт зарегистрирован');
    }
  }

  /// Сравнивает нижнюю полосу кадра до и после вшивания.
  /// Ненулевой код возврата ffmpeg здесь не показатель: libass без шрифта
  /// «успешно» рисует пустоту.
  Future<bool> subtitlesVisible({
    required String original,
    required String burned,
    required double atSeconds,
  }) async {
    final before = await _brightPixels(original, atSeconds);
    final after = await _brightPixels(burned, atSeconds);
    return after - before >= kSubtitleMinNewPixels;
  }

  Future<int> _brightPixels(String video, double atSeconds) async {
    final dir = Directory.systemTemp.createTempSync('band_');
    try {
      final bandPath = '${dir.path}${Platform.pathSeparator}band.gray';
      final result = await runner.run(FfmpegCommands.grayBand(
        input: video,
        atSeconds: atSeconds,
        output: bandPath,
      ));
      if (!result.ok) {
        throw StateError('Не удалось получить кадр из $video: ${result.log}');
      }
      return countBrightPixels(File(bandPath).readAsBytesSync());
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
}
```

- [ ] **Step 5: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/pipeline/burner_test.dart`
Expected: `All tests passed!`

- [ ] **Step 6: Коммит**

```bash
git add lib/core/pipeline/burner.dart assets/fonts/NotoSans-Regular.ttf test/core/pipeline/burner_test.dart
git commit -m "Вшивание субтитров и проверка, что они действительно видны"
```

---

### Task 15: Оркестратор пайплайна

Склеивает всё: статусы реплик, возобновление без повторной оплаты, отмена,
остановка на ошибке авторизации, ограничение параллельных запросов.

**Files:**
- Create: `lib/core/pipeline/pipeline.dart`
- Test: `test/core/pipeline/pipeline_test.dart`

**Interfaces:**
- Consumes: всё, что создано в задачах 2–13.
- Produces:
  - `enum PipelineStage { extractingAudio, detectingSilence, recognizing, translating, done }`
  - `class PipelineProgress { final PipelineStage stage; final int done; final int total; }`
  - `class NoSpeechFoundException implements Exception`
  - `class Pipeline { Pipeline({required FfmpegRunner runner, required SpeechKitClient stt, required TranslateClient translate, required SessionStore store, required String workDir}); Future<Session> process({required String videoPath, required String lang, Session? resumeFrom, void Function(PipelineProgress)? onProgress, Future<void> Function(Duration)? sleep, bool Function()? isCancelled}); }`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/pipeline/pipeline_test.dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';
import 'package:subtitler/core/cloud/translate_client.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/pipeline.dart';
import 'package:subtitler/core/session_store.dart';

/// Подставной STT: отдаёт текст по номеру вызова и считает обращения.
class FakeStt implements SpeechKitClient {
  final List<String> Function() texts;
  int calls = 0;
  Object? throwOnFirst;
  FakeStt(this.texts);

  @override
  Future<String> recognize({required List<int> oggBytes, required String lang}) async {
    if (calls == 0 && throwOnFirst != null) {
      calls++;
      throw throwOnFirst!;
    }
    final list = texts();
    final value = calls < list.length ? list[calls] : '';
    calls++;
    return value;
  }

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

class FakeTranslate implements TranslateClient {
  int calls = 0;
  @override
  Future<List<String>> translate(
      {required List<String> texts, required String sourceLang}) async {
    calls++;
    return texts.map((t) => 'RU:$t').toList();
  }

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

void main() {
  late Directory tmp;
  late String video;
  final runner = ProcessFfmpegRunner();

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('pipeline_test_');
    video = '${tmp.path}/clip.mp4';
    // Речь-тишина-речь-тишина-речь: три сегмента при пороге -30dB.
    await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=15',
      '-f', 'lavfi',
      '-i', 'aevalsrc=0.5*sin(440*2*PI*t)*between(mod(t\\,5)\\,0\\,3):d=15',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
      video,
    ]);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Pipeline build(FakeStt stt, FakeTranslate tr) => Pipeline(
        runner: runner,
        stt: stt,
        translate: tr,
        store: SessionStore(fallbackDir: tmp.path),
        workDir: '${tmp.path}/work',
      );

  test('Успешный прогон заполняет реплики и переводы', () async {
    final stt = FakeStt(() => ['bir', 'iki', 'üç']);
    final tr = FakeTranslate();
    final session = await build(stt, tr)
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});

    expect(session.cues, isNotEmpty);
    expect(session.lang, 'tr-TR');
    final recognized = session.cues.where((c) => c.status == CueStatus.ok);
    expect(recognized, isNotEmpty);
    expect(recognized.first.ru, startsWith('RU:'));
  });

  test('Пустой ответ распознавания даёт статус empty, а не ошибку', () async {
    final stt = FakeStt(() => ['', '', '']);
    final session = await build(stt, FakeTranslate())
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});
    expect(session.cues.every((c) => c.status == CueStatus.empty), isTrue);
  });

  test('Возобновление не отправляет в API уже распознанные сегменты', () async {
    final first = FakeStt(() => ['bir', 'iki', 'üç']);
    final session = await build(first, FakeTranslate())
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});
    final callsFirstRun = first.calls;
    expect(callsFirstRun, greaterThan(0));

    final second = FakeStt(() => ['НЕ ДОЛЖНО ВЫЗЫВАТЬСЯ']);
    await build(second, FakeTranslate()).process(
      videoPath: video,
      lang: 'tr-TR',
      resumeFrom: session,
      sleep: (_) async {},
    );
    expect(second.calls, 0, reason: 'повторная оплата уже распознанного');
  });

  test('Ошибка авторизации останавливает весь прогон', () async {
    final stt = FakeStt(() => ['bir'])
      ..throwOnFirst = const AuthException(statusCode: 403, message: 'нет роли');
    await expectLater(
      build(stt, FakeTranslate())
          .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {}),
      throwsA(isA<AuthException>()),
    );
    expect(stt.calls, 1, reason: 'после 403 других запросов быть не должно');
  });

  test('Временная ошибка после ретраев помечает реплику failed, прогон продолжается',
      () async {
    final stt = FakeStt(() => ['bir', 'iki', 'üç'])
      ..throwOnFirst =
          const TransientException(statusCode: 500, message: 'boom');
    final session = await build(stt, FakeTranslate())
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});
    expect(session.cues.any((c) => c.status == CueStatus.failed), isTrue);
    expect(session.cues.any((c) => c.status == CueStatus.ok), isTrue,
        reason: 'соседние сегменты обработаны');
  });

  test('Отмена прерывает прогон и сохраняет уже готовое', () async {
    var checks = 0;
    final stt = FakeStt(() => ['bir', 'iki', 'üç']);
    final session = await build(stt, FakeTranslate()).process(
      videoPath: video,
      lang: 'tr-TR',
      sleep: (_) async {},
      // Первая проверка пропускает один сегмент, дальше — отмена.
      isCancelled: () => checks++ > 0,
    );
    expect(session.cues.any((c) => c.status == CueStatus.ok), isTrue,
        reason: 'успевшее до отмены должно сохраниться');
    expect(session.cues.any((c) => c.status == CueStatus.pending), isTrue,
        reason: 'остальное осталось необработанным и будет доделано позже');
  });

  test('Возобновление без файлов сегментов не теряет распознанный текст',
      () async {
    final stt = FakeStt(() => ['bir', 'iki', 'üç']);
    final session = await build(stt, FakeTranslate())
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});
    final recognized = session.cues.where((c) => c.status == CueStatus.ok).length;
    expect(recognized, greaterThan(0));

    // Имитируем перезапуск приложения: временная папка исчезла.
    Directory('${tmp.path}/work').deleteSync(recursive: true);

    final second = FakeStt(() => ['НЕ ДОЛЖНО ВЫЗЫВАТЬСЯ']);
    final resumed = await build(second, FakeTranslate()).process(
      videoPath: video,
      lang: 'tr-TR',
      resumeFrom: session,
      sleep: (_) async {},
    );
    expect(second.calls, 0, reason: 'заново платить за распознавание нельзя');
    expect(resumed.cues.where((c) => c.status == CueStatus.ok).length,
        recognized);
  });

  test('Прогресс сообщает этапы по порядку', () async {
    final stages = <PipelineStage>[];
    await build(FakeStt(() => ['bir']), FakeTranslate()).process(
      videoPath: video,
      lang: 'tr-TR',
      sleep: (_) async {},
      onProgress: (p) => stages.add(p.stage),
    );
    expect(stages.first, PipelineStage.extractingAudio);
    expect(stages, contains(PipelineStage.detectingSilence));
    expect(stages, contains(PipelineStage.recognizing));
    expect(stages.last, PipelineStage.done);
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/pipeline/pipeline_test.dart`
Expected: FAIL — файл `pipeline.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/pipeline/pipeline.dart
import 'dart:io';

import '../cloud/api_errors.dart';
import '../cloud/retry.dart';
import '../cloud/speechkit_client.dart';
import '../cloud/translate_client.dart';
import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../models.dart';
import '../session_store.dart';
import 'segment_cutter.dart';
import 'silence_scanner.dart';
import 'validation.dart';

enum PipelineStage {
  extractingAudio,
  detectingSilence,
  recognizing,
  translating,
  done,
}

class PipelineProgress {
  final PipelineStage stage;
  final int done;
  final int total;
  const PipelineProgress(this.stage, {this.done = 0, this.total = 0});
}

/// Звук есть, но речи не нашлось нигде.
class NoSpeechFoundException implements Exception {
  const NoSpeechFoundException();
  @override
  String toString() => 'Речь в ролике не обнаружена';
}

class Pipeline {
  final FfmpegRunner runner;
  final SpeechKitClient stt;
  final TranslateClient translate;
  final SessionStore store;
  final String workDir;

  Pipeline({
    required this.runner,
    required this.stt,
    required this.translate,
    required this.store,
    required this.workDir,
  });

  Future<Session> process({
    required String videoPath,
    required String lang,
    Session? resumeFrom,
    void Function(PipelineProgress)? onProgress,
    Future<void> Function(Duration)? sleep,
    bool Function()? isCancelled,
  }) async {
    final cancelled = isCancelled ?? () => false;
    final report = onProgress ?? (_) {};

    Directory(workDir).createSync(recursive: true);
    final duration = await runner.probeDuration(videoPath);
    final fingerprint = SourceFingerprint(
      sizeBytes: File(videoPath).lengthSync(),
      durationSec: duration,
    );

    var session = resumeFrom;
    if (session == null || session.lang != lang) {
      session = await _prepare(
        videoPath: videoPath,
        lang: lang,
        duration: duration,
        fingerprint: fingerprint,
        report: report,
      );
    } else if (!_segmentsPresent(session)) {
      // Приложение перезапускали: рабочая папка с сегментами исчезла.
      // Нарезаем заново, но уже распознанный текст переносим — он оплачен.
      final fresh = await _prepare(
        videoPath: videoPath,
        lang: lang,
        duration: duration,
        fingerprint: fingerprint,
        report: report,
      );
      session = _mergeRecognized(fresh: fresh, previous: session);
    }

    session = await _recognizeAll(
      session: session,
      report: report,
      sleep: sleep,
      cancelled: cancelled,
    );
    session = await _translateAll(
      session: session,
      report: report,
      sleep: sleep,
      cancelled: cancelled,
    );

    session = session.copyWith(cues: applyAutoFlags(session.cues));
    await store.save(session);
    report(const PipelineProgress(PipelineStage.done));
    return session;
  }

  /// Извлекает звук, ищет паузы, нарезает сегменты и создаёт пустые реплики.
  Future<Session> _prepare({
    required String videoPath,
    required String lang,
    required double duration,
    required SourceFingerprint fingerprint,
    required void Function(PipelineProgress) report,
  }) async {
    report(const PipelineProgress(PipelineStage.extractingAudio));
    final audioPath = '$workDir${Platform.pathSeparator}audio.wav';
    final extracted = await runner
        .run(FfmpegCommands.extractAudio(input: videoPath, output: audioPath));
    if (!extracted.ok) {
      throw StateError('Не удалось извлечь звук: ${extracted.log}');
    }

    report(const PipelineProgress(PipelineStage.detectingSilence));
    final scan = await SilenceScanner(runner)
        .scan(audioPath: audioPath, duration: duration);
    if (scan.segments.isEmpty) throw const NoSpeechFoundException();

    final files = await SegmentCutter(runner).cut(
      audioPath: audioPath,
      segments: scan.segments,
      outputDir: '$workDir${Platform.pathSeparator}segments',
    );

    return Session(
      videoPath: videoPath,
      fingerprint: fingerprint,
      lang: lang,
      silenceThreshold: scan.threshold,
      forcedSplit: scan.forcedSplit,
      cues: [
        for (final file in files)
          Cue(
            index: file.index,
            range: file.range,
            orig: '',
            ru: '',
            status: CueStatus.pending,
            flags: scan.forcedSplit ? const {CueFlag.forcedSplit} : const {},
          ),
      ],
    );
  }

  String _segmentPath(int index) =>
      '$workDir${Platform.pathSeparator}segments${Platform.pathSeparator}'
      'seg_${index.toString().padLeft(3, '0')}.ogg';

  /// Есть ли на диске файлы сегментов, которые ещё предстоит распознать.
  bool _segmentsPresent(Session session) {
    final todo = session.cues.where(
        (c) => c.status == CueStatus.pending || c.status == CueStatus.failed);
    if (todo.isEmpty) return true; // распознавать нечего — файлы не нужны
    return todo.every((c) => File(_segmentPath(c.index)).existsSync());
  }

  /// Переносит уже полученные тексты на свежую нарезку по совпадающим границам.
  Session _mergeRecognized({required Session fresh, required Session previous}) {
    final byIndex = {for (final cue in previous.cues) cue.index: cue};
    return fresh.copyWith(
      cues: fresh.cues.map((cue) {
        final old = byIndex[cue.index];
        final sameRange = old != null &&
            (old.range.start - cue.range.start).abs() < 0.01 &&
            (old.range.end - cue.range.end).abs() < 0.01;
        if (!sameRange || old.status == CueStatus.pending) return cue;
        return cue.copyWith(
          orig: old.orig,
          ru: old.ru,
          status: old.status,
          flags: old.flags,
        );
      }).toList(),
    );
  }

  Future<Session> _recognizeAll({
    required Session session,
    required void Function(PipelineProgress) report,
    required Future<void> Function(Duration)? sleep,
    required bool Function() cancelled,
  }) async {
    final cues = [...session.cues];
    final todo = cues
        .where((c) => c.status == CueStatus.pending || c.status == CueStatus.failed)
        .toList();
    var done = 0;

    for (final cue in todo) {
      if (cancelled()) break;
      report(PipelineProgress(PipelineStage.recognizing,
          done: done, total: todo.length));

      final bytes = File(_segmentPath(cue.index)).readAsBytesSync();
      final position = cues.indexWhere((c) => c.index == cue.index);
      try {
        final text = await withRetry(
          () => stt.recognize(oggBytes: bytes, lang: session.lang),
          sleep: sleep,
        );
        cues[position] = cue.copyWith(
          orig: text,
          status: text.trim().isEmpty ? CueStatus.empty : CueStatus.ok,
        );
      } on AuthException {
        await store.save(session.copyWith(cues: cues));
        rethrow; // ключ или роль — продолжать бессмысленно
      } on ApiException {
        cues[position] = cue.copyWith(status: CueStatus.failed);
      }

      done++;
      // Инкрементальная запись: обрыв не обнуляет оплаченное.
      session = session.copyWith(cues: cues);
      await store.save(session);
    }
    return session.copyWith(cues: cues);
  }

  Future<Session> _translateAll({
    required Session session,
    required void Function(PipelineProgress) report,
    required Future<void> Function(Duration)? sleep,
    required bool Function() cancelled,
  }) async {
    if (cancelled()) return session;

    final cues = [...session.cues];
    final pending = cues
        .where((c) => c.status == CueStatus.ok && c.ru.trim().isEmpty)
        .toList();
    if (pending.isEmpty) return session;

    report(PipelineProgress(PipelineStage.translating,
        done: 0, total: pending.length));

    try {
      final translations = await withRetry(
        () => translate.translate(
          texts: pending.map((c) => c.orig).toList(),
          sourceLang: session.lang,
        ),
        sleep: sleep,
      );
      for (var i = 0; i < pending.length && i < translations.length; i++) {
        final position = cues.indexWhere((c) => c.index == pending[i].index);
        cues[position] = cues[position].copyWith(ru: translations[i]);
      }
    } on AuthException {
      await store.save(session.copyWith(cues: cues));
      rethrow;
    } on ApiException {
      // Перевод не получен — реплики останутся без ru и получат пометку
      // в applyAutoFlags; распознанный текст при этом не потерян.
    }

    session = session.copyWith(cues: cues);
    await store.save(session);
    return session;
  }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/pipeline/pipeline_test.dart`
Expected: `All tests passed!`

Если тест «Отмена прерывает прогон» падает из-за того, что сегментов
получилось меньше двух — увеличьте длительность синтетического ролика в
`setUpAll` до 25 секунд: логика отмены проверяется на втором сегменте.

- [ ] **Step 5: Коммит**

```bash
git add lib/core/pipeline/pipeline.dart test/core/pipeline/pipeline_test.dart
git commit -m "Оркестратор: статусы реплик, возобновление, отмена, остановка на 403"
```

---

### Task 16: CLI-харнесс и приёмка на реальных роликах

Ядро должно быть запускаемо без UI — это и инструмент отладки, и способ
проверить пайплайн на настоящих видео до того, как появятся экраны.

**Files:**
- Create: `tool/pipeline_cli.dart`, `test/acceptance/README.md`
- Test: ручной прогон на трёх роликах

**Interfaces:**
- Consumes: `Pipeline`, `SessionStore`, `SpeechKitClient`, `TranslateClient`, `ProcessFfmpegRunner`, `SubtitleBurner`, `buildSrt`.
- Produces: исполняемый скрипт `dart run tool/pipeline_cli.dart <видео> --lang tr-TR`.

- [ ] **Step 1: Написать CLI**

```dart
// tool/pipeline_cli.dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';
import 'package:subtitler/core/cloud/translate_client.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/burner.dart';
import 'package:subtitler/core/pipeline/pipeline.dart';
import 'package:subtitler/core/session_store.dart';
import 'package:subtitler/core/srt.dart';

/// Отладочный запуск ядра без интерфейса:
///   YC_API_KEY=... dart run tool/pipeline_cli.dart video.mp4 --lang tr-TR
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Использование: pipeline_cli <видео> --lang tr-TR|uz-UZ');
    exit(2);
  }

  final videoPath = args.first;
  final langIndex = args.indexOf('--lang');
  final lang = langIndex >= 0 && langIndex + 1 < args.length
      ? args[langIndex + 1]
      : 'tr-TR';

  final apiKey = Platform.environment['YC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('Не задан YC_API_KEY');
    exit(2);
  }

  final dio = Dio();
  final runner = ProcessFfmpegRunner();
  final workDir = Directory.systemTemp.createTempSync('subtitler_cli_').path;

  final pipeline = Pipeline(
    runner: runner,
    stt: SpeechKitClient(dio: dio, apiKey: apiKey),
    translate: TranslateClient(dio: dio, apiKey: apiKey),
    store: SessionStore(fallbackDir: workDir),
    workDir: workDir,
  );

  final session = await pipeline.process(
    videoPath: videoPath,
    lang: lang,
    onProgress: (p) => stdout.writeln(
        '${p.stage.name}${p.total > 0 ? ' ${p.done}/${p.total}' : ''}'),
  );

  final base = videoPath.replaceAll(RegExp(r'\.[^.]+$'), '');
  File('${base}_orig.srt')
      .writeAsStringSync(buildSrt(session.cues, field: SrtField.orig));
  File('${base}_ru.srt')
      .writeAsStringSync(buildSrt(session.cues, field: SrtField.ru));

  final output = '${base}_ru.mp4';
  final firstVisible = session.cues.firstWhere(
    (c) => c.ru.trim().isNotEmpty,
    orElse: () => session.cues.first,
  );

  final flagged = session.cues.where((c) => c.flags.isNotEmpty).length;
  try {
    await SubtitleBurner(runner).burnAndVerify(
      input: videoPath,
      srtPath: '${base}_ru.srt',
      fontsDir: 'assets/fonts',
      output: output,
      checkAtSeconds: (firstVisible.range.start + firstVisible.range.end) / 2,
    );
  } on SubtitlesInvisibleException catch (e) {
    stderr.writeln(e);
    exit(1);
  }

  stdout.writeln('Готово: $output');
  stdout.writeln('Реплик: ${session.cues.length}, на проверку: $flagged');
  stdout.writeln('Субтитры видны в кадре: да');
}
```

- [ ] **Step 2: Проверить, что CLI собирается и объясняет использование**

Run: `dart run tool/pipeline_cli.dart`
Expected: `Использование: pipeline_cli <видео> --lang tr-TR|uz-UZ`, код выхода 2.

- [ ] **Step 3: Запустить весь набор тестов**

Run: `flutter test`
Expected: все тесты проходят, ни одного пропущенного.

- [ ] **Step 4: Приёмка на реальных роликах**

Скопировать три ролика из ручного прогона в `test/acceptance/samples/`
(файлы `WhatsApp Video 2026-09-02 at 19.57.25*.mp4` из папки пользователя;
они не коммитятся — см. `.gitignore`) и прогнать каждый:

```bash
export YC_API_KEY='<ключ следователя>'
dart run tool/pipeline_cli.dart "test/acceptance/samples/v52.mp4" --lang tr-TR
dart run tool/pipeline_cli.dart "test/acceptance/samples/v26.mp4" --lang tr-TR
dart run tool/pipeline_cli.dart "test/acceptance/samples/v35.mp4" --lang tr-TR
```

Ожидаемое (эталон — ручной прогон 2026-09-02, все три ролика турецкие):

| Ролик | Длительность | Порог | Сегментов | Ожидаемые границы, с |
|---|---|---|---|---|
| v52 | 52.00 | −15dB | 9 | 0.00–5.71, 5.71–13.53, 13.53–20.73, 20.73–26.90, 26.90–28.94, 28.94–36.14, 36.14–42.50, 42.59–50.76, 51.62–52.00 |
| v26 | 25.71 | −18dB | 5 | 0.00–3.95, 4.18–8.25, 9.28–16.13, 16.49–22.21, 22.84–25.71 |
| v35 | 34.80 | −30dB | 6 | 0.00–1.70, 3.18–6.55, 7.52–13.23, 13.83–20.12, 21.58–29.64, 30.08–34.80 |

Проверить по каждому ролику:
1. Выбранный порог и число сегментов совпали с таблицей (расхождение границ до 0.05 с допустимо).
2. Распознанный турецкий текст осмысленный: в v35 должны появиться слова про весы (`***`) и субботу (`***`).
3. Сегменты без речи получили статус `empty` и не попали в SRT.
4. Последняя строка вывода — `Субтитры видны в кадре: да`.
5. Открыть `_ru.mp4` и глазами убедиться, что русский текст читается и не выходит за кадр.

Если пункт 1 не сошёлся — чинить сегментатор (задача 4) или подбор порога
(задача 8), а не подгонять таблицу.

- [ ] **Step 5: Записать инструкцию по приёмке**

```markdown
<!-- test/acceptance/README.md -->
# Приёмочные прогоны

Здесь лежат реальные ролики для сквозной проверки ядра. Сами видеофайлы
в репозиторий не коммитятся (следственные материалы) — их кладёт разработчик
локально в `samples/`.

Запуск: `YC_API_KEY=... dart run tool/pipeline_cli.dart samples/<файл>.mp4 --lang tr-TR`

Эталонные значения (порог тишины, число и границы сегментов) — в плане
`docs/superpowers/plans/2026-09-11-core-engine.md`, задача 16.
Расхождение означает регрессию в сегментаторе, а не повод менять эталон.
```

- [ ] **Step 6: Исключить приёмочные материалы из репозитория**

Добавить в `.gitignore`:

```
test/acceptance/samples/
*.subtitler.json
*_ru.mp4
*_orig.srt
*_ru.srt
```

- [ ] **Step 7: Коммит**

```bash
git add tool/pipeline_cli.dart test/acceptance/README.md .gitignore
git commit -m "CLI-харнесс ядра и инструкция по приёмочным прогонам"
```

---

## Что дальше

Этот план закрывает ядро. Дальше — отдельные планы:

- **План 2 (интерфейс):** экраны онбординга, главного, выбора языка, обработки,
  редактора и экспорта (§4, §5, §7 спеки); `LibRunner` для Android поверх
  `ffmpeg_kit_flutter_new`; хранение ключа в `flutter_secure_storage`.
- **План 3 (упаковка):** portable ZIP для Windows с тремя DLL и `ffmpeg.exe`,
  подписанный APK, GitHub Actions (§14 спеки).
