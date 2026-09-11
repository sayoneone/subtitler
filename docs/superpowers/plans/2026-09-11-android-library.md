# Библиотека обработок на Android — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** На телефоне видео приходит из галереи, файлов или WhatsApp, результат
лежит в закрытом хранилище приложения, им можно поделиться, а все обработки
видны в истории с поиском и понятными правилами очистки места.

**Architecture:** Чистый Dart для модели записи, индекса и политики очистки
(тестируется без телефона); файловый слой поверх них; приём видео и «Поделиться»
— тонкие обёртки над системными диалогами; экран истории поверх всего этого.

**Tech Stack:** Flutter, `image_picker` (галерея), `file_selector` (файлы),
`receive_sharing_intent` (WhatsApp), `share_plus` (отдача наружу).

**Spec:** `docs/superpowers/specs/2026-09-11-android-library-design.md`

## Global Constraints

- Видео из любого входа **немедленно копируется** в хранилище приложения:
  системный путь временный и может исчезнуть.
- Результат **никогда** не попадает в галерею и в облачный бэкап. Наружу —
  только через «Поделиться».
- Лимит места по умолчанию **2 ГБ**, настраивается.
- При нехватке места удаляется **только видео** (исходник и результат);
  текст, тайминги и перевод остаются всегда.
- **Закреплённые записи не трогаются автоматической очисткой никогда.**
- Пользователь предупреждается на трёх уровнях: заранее (>80 % лимита),
  в момент очистки, и пометкой на записи. Молчаливой пропажи файлов нет.
- Ручное удаление требует подтверждения.
- История — только на мобильных платформах; на Windows её нет.

---

### Task 1: Модель записи и индекс библиотеки

**Files:**
- Create: `lib/core/library/library_entry.dart`
- Test: `test/core/library/library_entry_test.dart`

**Interfaces:**
- Produces:
  - `class LibraryEntry { final String id; final String sourceName; final DateTime createdAt; final String lang; final int cueCount; final int flaggedCount; final bool pinned; final bool mediaRemoved; final int mediaBytes; ... copyWith/toJson/fromJson }`
  - `class LibraryIndex { final List<LibraryEntry> entries; int get totalBytes; Map<String,dynamic> toJson(); static LibraryIndex fromJson(...); }`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/library/library_entry_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/library/library_entry.dart';

LibraryEntry _entry(String id, {int bytes = 1000, bool pinned = false}) =>
    LibraryEntry(
      id: id,
      sourceName: '$id.mp4',
      createdAt: DateTime.utc(2026, 9, 11),
      lang: 'tr-TR',
      cueCount: 6,
      flaggedCount: 1,
      pinned: pinned,
      mediaRemoved: false,
      mediaBytes: bytes,
    );

void main() {
  test('Запись переживает сериализацию', () {
    final restored = LibraryEntry.fromJson(_entry('a').toJson());
    expect(restored.id, 'a');
    expect(restored.sourceName, 'a.mp4');
    expect(restored.lang, 'tr-TR');
    expect(restored.cueCount, 6);
    expect(restored.flaggedCount, 1);
    expect(restored.pinned, isFalse);
    expect(restored.mediaRemoved, isFalse);
    expect(restored.mediaBytes, 1000);
    expect(restored.createdAt, DateTime.utc(2026, 9, 11));
  });

  test('Индекс считает занятое место', () {
    final index = LibraryIndex(entries: [
      _entry('a', bytes: 1500),
      _entry('b', bytes: 2500),
    ]);
    expect(index.totalBytes, 4000);
  });

  test('Запись без медиа места не занимает', () {
    final entry = _entry('a', bytes: 5000).copyWith(
      mediaRemoved: true,
      mediaBytes: 0,
    );
    expect(LibraryIndex(entries: [entry]).totalBytes, 0);
    expect(entry.mediaRemoved, isTrue);
  });

  test('Индекс переживает сериализацию', () {
    final index = LibraryIndex(entries: [_entry('a'), _entry('b')]);
    final restored = LibraryIndex.fromJson(index.toJson());
    expect(restored.entries.map((e) => e.id), ['a', 'b']);
  });

  test('Битый индекс читается как пустой, а не роняет приложение', () {
    expect(LibraryIndex.fromJson(const {}).entries, isEmpty);
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/library/library_entry_test.dart`
Expected: FAIL — файла `library_entry.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/library/library_entry.dart

/// Одна обработка в истории.
class LibraryEntry {
  final String id;
  final String sourceName;
  final DateTime createdAt;
  final String lang;
  final int cueCount;
  final int flaggedCount;

  /// Закреплённые записи автоматическая очистка не трогает никогда.
  final bool pinned;

  /// Видео удалено ради места, текст остался.
  final bool mediaRemoved;

  /// Сколько занимают исходник и результат вместе.
  final int mediaBytes;

  const LibraryEntry({
    required this.id,
    required this.sourceName,
    required this.createdAt,
    required this.lang,
    required this.cueCount,
    required this.flaggedCount,
    required this.pinned,
    required this.mediaRemoved,
    required this.mediaBytes,
  });

  LibraryEntry copyWith({
    bool? pinned,
    bool? mediaRemoved,
    int? mediaBytes,
    int? cueCount,
    int? flaggedCount,
  }) =>
      LibraryEntry(
        id: id,
        sourceName: sourceName,
        createdAt: createdAt,
        lang: lang,
        cueCount: cueCount ?? this.cueCount,
        flaggedCount: flaggedCount ?? this.flaggedCount,
        pinned: pinned ?? this.pinned,
        mediaRemoved: mediaRemoved ?? this.mediaRemoved,
        mediaBytes: mediaBytes ?? this.mediaBytes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceName': sourceName,
        'createdAt': createdAt.toIso8601String(),
        'lang': lang,
        'cueCount': cueCount,
        'flaggedCount': flaggedCount,
        'pinned': pinned,
        'mediaRemoved': mediaRemoved,
        'mediaBytes': mediaBytes,
      };

  static LibraryEntry fromJson(Map<String, dynamic> json) => LibraryEntry(
        id: json['id'] as String,
        sourceName: json['sourceName'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        lang: json['lang'] as String? ?? '',
        cueCount: json['cueCount'] as int? ?? 0,
        flaggedCount: json['flaggedCount'] as int? ?? 0,
        pinned: json['pinned'] as bool? ?? false,
        mediaRemoved: json['mediaRemoved'] as bool? ?? false,
        mediaBytes: json['mediaBytes'] as int? ?? 0,
      );
}

class LibraryIndex {
  static const int currentVersion = 1;
  final List<LibraryEntry> entries;

  const LibraryIndex({required this.entries});

  int get totalBytes =>
      entries.fold(0, (sum, e) => sum + (e.mediaRemoved ? 0 : e.mediaBytes));

  Map<String, dynamic> toJson() => {
        'version': currentVersion,
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  static LibraryIndex fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    if (raw is! List) return const LibraryIndex(entries: []);
    return LibraryIndex(
      entries: raw
          .whereType<Map<String, dynamic>>()
          .map(LibraryEntry.fromJson)
          .toList(),
    );
  }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/library/library_entry_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/library test/core/library
git commit -m "Модель записи библиотеки и индекс"
```

---

### Task 2: Политика очистки места

Самая ответственная часть: она удаляет файлы. Поэтому она — чистая функция,
которая ничего не удаляет сама, а только говорит, что удалить.

**Files:**
- Create: `lib/core/library/cleanup_policy.dart`
- Test: `test/core/library/cleanup_policy_test.dart`

**Interfaces:**
- Consumes: `LibraryEntry`, `LibraryIndex`.
- Produces:
  - `const int kDefaultLimitBytes = 2 * 1024 * 1024 * 1024;`
  - `const double kWarnFraction = 0.8;`
  - `class CleanupPlan { final List<String> idsToStrip; final int freedBytes; final bool limitStillExceeded; bool get isEmpty; }`
  - `CleanupPlan planCleanup(LibraryIndex index, {required int limitBytes});`
  - `bool shouldWarnAboutSpace(LibraryIndex index, {required int limitBytes});`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/library/cleanup_policy_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/library/cleanup_policy.dart';
import 'package:subtitler/core/library/library_entry.dart';

LibraryEntry _entry(String id, int day, int bytes, {bool pinned = false}) =>
    LibraryEntry(
      id: id,
      sourceName: '$id.mp4',
      createdAt: DateTime.utc(2026, 9, day),
      lang: 'tr-TR',
      cueCount: 5,
      flaggedCount: 0,
      pinned: pinned,
      mediaRemoved: false,
      mediaBytes: bytes,
    );

void main() {
  test('Пока места хватает, ничего не удаляется', () {
    final plan = planCleanup(
      LibraryIndex(entries: [_entry('a', 1, 100), _entry('b', 2, 100)]),
      limitBytes: 1000,
    );
    expect(plan.isEmpty, isTrue);
    expect(plan.freedBytes, 0);
  });

  test('Удаляются самые старые и ровно столько, сколько нужно', () {
    final plan = planCleanup(
      LibraryIndex(entries: [
        _entry('старая', 1, 400),
        _entry('средняя', 2, 400),
        _entry('свежая', 3, 400),
      ]),
      limitBytes: 900,
    );
    // 1200 > 900: хватит убрать одну самую старую.
    expect(plan.idsToStrip, ['старая']);
    expect(plan.freedBytes, 400);
    expect(plan.limitStillExceeded, isFalse);
  });

  test('Закреплённые записи не трогаются никогда', () {
    final plan = planCleanup(
      LibraryIndex(entries: [
        _entry('старая-закреплённая', 1, 500, pinned: true),
        _entry('свежая', 3, 500),
      ]),
      limitBytes: 600,
    );
    expect(plan.idsToStrip, isNot(contains('старая-закреплённая')));
    expect(plan.idsToStrip, ['свежая']);
  });

  test('Если чистить нечего, честно сообщаем что лимит превышен', () {
    final plan = planCleanup(
      LibraryIndex(entries: [
        _entry('a', 1, 800, pinned: true),
        _entry('b', 2, 800, pinned: true),
      ]),
      limitBytes: 1000,
    );
    expect(plan.isEmpty, isTrue);
    expect(plan.limitStillExceeded, isTrue,
        reason: 'закреплённое не удаляем, но и молчать нельзя');
  });

  test('Записи без медиа в план не попадают: удалять там нечего', () {
    final stripped = _entry('a', 1, 0).copyWith(mediaRemoved: true);
    final plan = planCleanup(
      LibraryIndex(entries: [stripped, _entry('b', 2, 2000)]),
      limitBytes: 1000,
    );
    expect(plan.idsToStrip, ['b']);
  });

  test('Предупреждаем заранее, с 80 % лимита', () {
    LibraryIndex at(int bytes) =>
        LibraryIndex(entries: [_entry('a', 1, bytes)]);
    expect(shouldWarnAboutSpace(at(700), limitBytes: 1000), isFalse);
    expect(shouldWarnAboutSpace(at(800), limitBytes: 1000), isTrue);
    expect(shouldWarnAboutSpace(at(950), limitBytes: 1000), isTrue);
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/library/cleanup_policy_test.dart`
Expected: FAIL — файла `cleanup_policy.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/library/cleanup_policy.dart
import 'library_entry.dart';

/// Сколько места библиотеке разрешено занимать по умолчанию.
const int kDefaultLimitBytes = 2 * 1024 * 1024 * 1024;

/// С какой доли лимита предупреждаем заранее.
const double kWarnFraction = 0.8;

/// Что предстоит удалить. План только описывает — удаляет вызывающий,
/// и он же сообщает об этом человеку.
class CleanupPlan {
  /// У этих записей удаляются видео (исходник и результат). Текст остаётся.
  final List<String> idsToStrip;
  final int freedBytes;

  /// Места всё равно не хватает: всё оставшееся закреплено.
  final bool limitStillExceeded;

  const CleanupPlan({
    required this.idsToStrip,
    required this.freedBytes,
    required this.limitStillExceeded,
  });

  bool get isEmpty => idsToStrip.isEmpty;
}

/// Решает, у каких записей убрать видео, чтобы уложиться в [limitBytes].
///
/// Удаляются только видео и только у самых старых незакреплённых записей,
/// и ровно столько, сколько нужно. Текст, тайминги и перевод не трогаются
/// никогда: они весят килобайты, а именно за ними в историю и возвращаются.
CleanupPlan planCleanup(LibraryIndex index, {required int limitBytes}) {
  var total = index.totalBytes;
  if (total <= limitBytes) {
    return const CleanupPlan(
        idsToStrip: [], freedBytes: 0, limitStillExceeded: false);
  }

  final candidates = index.entries
      .where((e) => !e.pinned && !e.mediaRemoved && e.mediaBytes > 0)
      .toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  final ids = <String>[];
  var freed = 0;
  for (final entry in candidates) {
    if (total <= limitBytes) break;
    ids.add(entry.id);
    freed += entry.mediaBytes;
    total -= entry.mediaBytes;
  }

  return CleanupPlan(
    idsToStrip: ids,
    freedBytes: freed,
    limitStillExceeded: total > limitBytes,
  );
}

/// Пора ли предупредить, что место заканчивается.
bool shouldWarnAboutSpace(LibraryIndex index, {required int limitBytes}) =>
    index.totalBytes >= limitBytes * kWarnFraction;
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/library/cleanup_policy_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/library/cleanup_policy.dart test/core/library/cleanup_policy_test.dart
git commit -m "Политика очистки места: удаляем только видео и только незакреплённое"
```

---

### Task 3: Файловое хранилище библиотеки

**Files:**
- Create: `lib/core/library/library_store.dart`
- Test: `test/core/library/library_store_test.dart`

**Interfaces:**
- Consumes: `LibraryEntry`, `LibraryIndex`, `CleanupPlan`, `planCleanup`.
- Produces:
  - `class LibraryStore { LibraryStore({required String rootDir, DebugLog? log}); Future<LibraryIndex> load(); Future<void> save(LibraryIndex index); String dirFor(String id); String sourcePathFor(String id); String resultPathFor(String id); Future<LibraryEntry> intake({required String sourcePath, required String sourceName}); Future<int> measure(String id); Future<void> stripMedia(String id); Future<void> deleteEntry(String id); Future<CleanupPlan> enforceLimit({required int limitBytes}); }`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/library/library_store_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/library/library_store.dart';

void main() {
  late Directory root;
  late LibraryStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('library_test_');
    store = LibraryStore(rootDir: root.path);
  });
  tearDown(() => root.deleteSync(recursive: true));

  File _fakeVideo(String name, int bytes) {
    final f = File('${root.path}/$name')
      ..writeAsBytesSync(List.filled(bytes, 7));
    return f;
  }

  test('Приём копирует видео к себе: системный путь недолговечен', () async {
    final source = _fakeVideo('outside.mp4', 2048);
    final entry = await store.intake(
        sourcePath: source.path, sourceName: 'outside.mp4');

    final copied = File(store.sourcePathFor(entry.id));
    expect(copied.existsSync(), isTrue);
    expect(copied.lengthSync(), 2048);
    // Оригинал не трогаем: он чужой.
    expect(source.existsSync(), isTrue);
    expect(entry.sourceName, 'outside.mp4');
    expect(entry.mediaRemoved, isFalse);
  });

  test('Индекс читается и пишется', () async {
    final source = _fakeVideo('a.mp4', 100);
    final entry =
        await store.intake(sourcePath: source.path, sourceName: 'a.mp4');
    await store.save(LibraryIndexOf([entry]));

    final loaded = await store.load();
    expect(loaded.entries.single.id, entry.id);
  });

  test('Отсутствующий индекс — пустая библиотека, а не ошибка', () async {
    expect((await store.load()).entries, isEmpty);
  });

  test('Удаление видео оставляет текст', () async {
    final source = _fakeVideo('a.mp4', 512);
    final entry =
        await store.intake(sourcePath: source.path, sourceName: 'a.mp4');
    File('${store.dirFor(entry.id)}/ru.srt').writeAsStringSync('текст');

    await store.stripMedia(entry.id);

    expect(File(store.sourcePathFor(entry.id)).existsSync(), isFalse);
    expect(File('${store.dirFor(entry.id)}/ru.srt').existsSync(), isTrue,
        reason: 'текст должен пережить очистку места');
  });

  test('Полное удаление стирает папку записи целиком', () async {
    final source = _fakeVideo('a.mp4', 100);
    final entry =
        await store.intake(sourcePath: source.path, sourceName: 'a.mp4');
    await store.deleteEntry(entry.id);
    expect(Directory(store.dirFor(entry.id)).existsSync(), isFalse);
  });

  test('Очистка по лимиту убирает видео и помечает записи', () async {
    final entries = <String>[];
    for (final name in ['старая', 'свежая']) {
      final src = _fakeVideo('$name.mp4', 800);
      final e = await store.intake(sourcePath: src.path, sourceName: '$name.mp4');
      entries.add(e.id);
      // Делаем «старую» действительно старее.
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final plan = await store.enforceLimit(limitBytes: 1000);
    expect(plan.idsToStrip.length, 1);
    final index = await store.load();
    final stripped =
        index.entries.firstWhere((e) => e.id == plan.idsToStrip.single);
    expect(stripped.mediaRemoved, isTrue);
    expect(File(store.sourcePathFor(stripped.id)).existsSync(), isFalse);
  });
}

/// Мелкий помощник, чтобы тест читался: индекс из списка записей.
LibraryIndex LibraryIndexOf(List<LibraryEntry> entries) =>
    LibraryIndex(entries: entries);
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/library/library_store_test.dart`
Expected: FAIL — файла `library_store.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/library/library_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../logging.dart';
import 'cleanup_policy.dart';
import 'library_entry.dart';

export 'library_entry.dart';

/// Файлы библиотеки: по папке на обработку плюс общий индекс.
class LibraryStore {
  final String rootDir;
  final DebugLog log;

  LibraryStore({required this.rootDir, DebugLog? log})
      : log = log ?? DebugLog.instance;

  String get _indexPath => p.join(rootDir, 'index.json');

  String dirFor(String id) => p.join(rootDir, id);
  String sourcePathFor(String id) => p.join(dirFor(id), 'source.mp4');
  String resultPathFor(String id) => p.join(dirFor(id), 'result.mp4');

  Future<LibraryIndex> load() async {
    final file = File(_indexPath);
    if (!file.existsSync()) return const LibraryIndex(entries: []);
    try {
      return LibraryIndex.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      log.warn('Индекс библиотеки нечитаем ($e) — начинаем с пустого');
      return const LibraryIndex(entries: []);
    }
  }

  Future<void> save(LibraryIndex index) async {
    Directory(rootDir).createSync(recursive: true);
    await File(_indexPath).writeAsString(
      const JsonEncoder.withIndent(' ').convert(index.toJson()),
      flush: true,
    );
  }

  /// Идентификатор из времени: сортируется как дата и не требует случайности.
  static String _newId(DateTime now) =>
      now.toIso8601String().replaceAll(RegExp(r'[^0-9]'), '');

  /// Копирует видео к себе и заводит запись.
  ///
  /// Копия обязательна: система отдаёт путь во временную папку, который
  /// может исчезнуть, а исходник нужен потом для пересборки.
  Future<LibraryEntry> intake({
    required String sourcePath,
    required String sourceName,
  }) async {
    final now = DateTime.now();
    final id = _newId(now);
    Directory(dirFor(id)).createSync(recursive: true);

    await File(sourcePath).copy(sourcePathFor(id));
    final bytes = File(sourcePathFor(id)).lengthSync();
    log.info('В библиотеку принято: $sourceName ($bytes байт), запись $id');

    return LibraryEntry(
      id: id,
      sourceName: sourceName,
      createdAt: now,
      lang: '',
      cueCount: 0,
      flaggedCount: 0,
      pinned: false,
      mediaRemoved: false,
      mediaBytes: bytes,
    );
  }

  /// Сколько сейчас занимают видео этой записи.
  Future<int> measure(String id) async {
    var total = 0;
    for (final path in [sourcePathFor(id), resultPathFor(id)]) {
      final file = File(path);
      if (file.existsSync()) total += file.lengthSync();
    }
    return total;
  }

  /// Удаляет видео, оставляя текст.
  Future<void> stripMedia(String id) async {
    for (final path in [sourcePathFor(id), resultPathFor(id)]) {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    }
    log.info('Освобождено место: у записи $id удалены видео, текст сохранён');
  }

  Future<void> deleteEntry(String id) async {
    final dir = Directory(dirFor(id));
    if (dir.existsSync()) await dir.delete(recursive: true);
    log.info('Запись $id удалена полностью');
  }

  /// Приводит библиотеку к лимиту и возвращает, что было сделано —
  /// вызывающий обязан показать это человеку.
  Future<CleanupPlan> enforceLimit({required int limitBytes}) async {
    final index = await load();
    final plan = planCleanup(index, limitBytes: limitBytes);
    if (plan.isEmpty) {
      if (plan.limitStillExceeded) {
        log.warn('Место кончилось, но все записи закреплены — '
            'автоматически удалять нечего');
      }
      return plan;
    }

    for (final id in plan.idsToStrip) {
      await stripMedia(id);
    }
    await save(LibraryIndex(
      entries: index.entries
          .map((e) => plan.idsToStrip.contains(e.id)
              ? e.copyWith(mediaRemoved: true, mediaBytes: 0)
              : e)
          .toList(),
    ));
    return plan;
  }
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/library/library_store_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/library/library_store.dart test/core/library/library_store_test.dart
git commit -m "Файловое хранилище библиотеки: приём, замер, очистка"
```

---

### Task 4: Поиск по истории

**Files:**
- Create: `lib/core/library/library_search.dart`
- Test: `test/core/library/library_search_test.dart`

**Interfaces:**
- Produces: `List<LibraryEntry> searchLibrary(List<LibraryEntry> entries, String query, {required String Function(String id) textOf});`

- [ ] **Step 1: Написать падающий тест**

```dart
// test/core/library/library_search_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/library/library_entry.dart';
import 'package:subtitler/core/library/library_search.dart';

LibraryEntry _e(String id, String name) => LibraryEntry(
      id: id,
      sourceName: name,
      createdAt: DateTime.utc(2026, 9, 11),
      lang: 'tr-TR',
      cueCount: 3,
      flaggedCount: 0,
      pinned: false,
      mediaRemoved: false,
      mediaBytes: 10,
    );

void main() {
  final entries = [_e('1', 'встреча.mp4'), _e('2', 'склад.mp4')];
  final texts = {
    '1': 'Брат, доброе утро. Начинаем работу.',
    '2': 'Весы барахлят, завтра починим.',
  };
  String textOf(String id) => texts[id] ?? '';

  test('Пустой запрос возвращает всё', () {
    expect(searchLibrary(entries, '   ', textOf: textOf).length, 2);
  });

  test('Находит по тексту реплик, а не только по имени файла', () {
    final found = searchLibrary(entries, 'барахлят', textOf: textOf);
    expect(found.single.id, '2');
  });

  test('Находит по имени файла', () {
    expect(searchLibrary(entries, 'встреча', textOf: textOf).single.id, '1');
  });

  test('Регистр не важен', () {
    expect(searchLibrary(entries, 'БРАТ', textOf: textOf).single.id, '1');
  });

  test('Ничего не найдено — пустой список', () {
    expect(searchLibrary(entries, 'вертолёт', textOf: textOf), isEmpty);
  });
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `flutter test test/core/library/library_search_test.dart`
Expected: FAIL — файла `library_search.dart` не существует.

- [ ] **Step 3: Написать минимальную реализацию**

```dart
// lib/core/library/library_search.dart
import 'library_entry.dart';

/// Ищет по имени исходника и по тексту реплик.
///
/// Поиск по тексту здесь главный: через месяц имя файла не помнит никто,
/// а фразу из разговора — вполне.
List<LibraryEntry> searchLibrary(
  List<LibraryEntry> entries,
  String query, {
  required String Function(String id) textOf,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return entries;
  return entries.where((entry) {
    if (entry.sourceName.toLowerCase().contains(needle)) return true;
    return textOf(entry.id).toLowerCase().contains(needle);
  }).toList();
}
```

- [ ] **Step 4: Запустить тест и убедиться, что он проходит**

Run: `flutter test test/core/library/library_search_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Коммит**

```bash
git add lib/core/library/library_search.dart test/core/library/library_search_test.dart
git commit -m "Поиск по истории — в том числе по тексту реплик"
```

---

### Task 5: Приём видео из галереи, файлов и WhatsApp

**Files:**
- Modify: `pubspec.yaml` (добавить `image_picker`)
- Create: `lib/app/video_intake.dart`
- Modify: `lib/app/debug_controller.dart`, `lib/ui/debug_screen.dart`
- Modify: `android/app/src/main/AndroidManifest.xml` (intent-filter для приёма)

**Interfaces:**
- Produces:
  - `enum IntakeSource { gallery, files, shared }`
  - `class VideoIntake { Future<String?> pickFromGallery(); Future<String?> pickFromFiles(); Stream<String> sharedVideos(); }`

- [ ] **Step 1: Добавить зависимость**

```bash
flutter pub add image_picker
```

`image_picker` на Android 13+ использует системный выбор медиа: он не
требует доступа ко всему хранилищу — приложение получает только выбранный
ролик.

- [ ] **Step 2: Разрешить приём видео из других приложений**

В `android/app/src/main/AndroidManifest.xml`, внутри `<activity>`:

```xml
<!-- Приём видео из WhatsApp и любого другого приложения
     через «Поделиться». -->
<intent-filter>
    <action android:name="android.intent.action.SEND"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <data android:mimeType="video/*"/>
</intent-filter>
```

- [ ] **Step 3: Написать обёртку над источниками**

```dart
// lib/app/video_intake.dart
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/logging.dart';

const _videoTypes = XTypeGroup(
  label: 'Видео',
  extensions: ['mp4', 'mov', 'mkv', 'avi', 'm4v'],
);

/// Откуда приложение получает видео. Все три пути отдают обычный путь
/// к файлу, который тут же копируется в библиотеку: то, что возвращает
/// система, лежит во временной папке и долго не живёт.
class VideoIntake {
  final DebugLog log;
  final ImagePicker _picker = ImagePicker();

  VideoIntake({DebugLog? log}) : log = log ?? DebugLog.instance;

  Future<String?> pickFromGallery() async {
    final file = await _picker.pickVideo(source: ImageSource.gallery);
    if (file == null) {
      log.debug('Выбор из галереи отменён');
      return null;
    }
    log.info('Из галереи выбрано: ${file.name}');
    return file.path;
  }

  Future<String?> pickFromFiles() async {
    final file = await openFile(acceptedTypeGroups: [_videoTypes]);
    if (file == null) {
      log.debug('Выбор файла отменён');
      return null;
    }
    log.info('Из файлов выбрано: ${file.name}');
    return file.path;
  }

  /// Видео, которыми поделились в приложение, пока оно работало,
  /// плюс то, которым его открыли.
  Stream<String> sharedVideos() async* {
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    for (final file in initial) {
      log.info('Получено из другого приложения: ${file.path}');
      yield file.path;
    }
    await ReceiveSharingIntent.instance.reset();

    await for (final batch in ReceiveSharingIntent.instance.getMediaStream()) {
      for (final file in batch) {
        log.info('Получено из другого приложения: ${file.path}');
        yield file.path;
      }
    }
  }
}
```

- [ ] **Step 4: Проверить на эмуляторе**

Run: `flutter build apk --release && adb install -r build/app/outputs/flutter-apk/app-release.apk`

Открыть приложение, нажать «Из галереи», выбрать ролик (предварительно
положив его на устройство: `adb push clip.mp4 /sdcard/Movies/`).

Expected: в журнале появляется «Из галереи выбрано: …», затем
«В библиотеку принято: … байт». Путь, который отдала система, в журнале
виден — по нему сразу понятно, был это обычный файл или `content://`.

- [ ] **Step 5: Коммит**

```bash
git add pubspec.yaml pubspec.lock lib/app/video_intake.dart android/
git commit -m "Приём видео из галереи, файлов и других приложений"
```

---

### Task 6: Экран истории

**Files:**
- Create: `lib/ui/library_screen.dart`
- Modify: `lib/app/debug_controller.dart` (методы библиотеки), `lib/ui/debug_screen.dart` (вкладка)

**Interfaces:**
- Consumes: `LibraryStore`, `searchLibrary`, `CleanupPlan`, `share_plus`.
- Produces: экран со списком, поиском, действиями и предупреждением о месте.

- [ ] **Step 1: Добавить в контроллер работу с библиотекой**

```dart
  // в DebugController
  LibraryStore? library;
  LibraryIndex libraryIndex = const LibraryIndex(entries: []);
  int storageLimitBytes = kDefaultLimitBytes;
  CleanupPlan? lastCleanup;

  Future<void> reloadLibrary() async {
    libraryIndex = await library!.load();
    notifyListeners();
  }

  bool get spaceWarning =>
      shouldWarnAboutSpace(libraryIndex, limitBytes: storageLimitBytes);

  /// Чистит место и запоминает, что было удалено: человек должен узнать
  /// об этом, а не обнаружить пропажу.
  Future<void> enforceStorageLimit() async {
    final plan = await library!.enforceLimit(limitBytes: storageLimitBytes);
    if (!plan.isEmpty || plan.limitStillExceeded) lastCleanup = plan;
    await reloadLibrary();
  }

  Future<void> togglePinned(String id) async {
    libraryIndex = LibraryIndex(
      entries: libraryIndex.entries
          .map((e) => e.id == id ? e.copyWith(pinned: !e.pinned) : e)
          .toList(),
    );
    await library!.save(libraryIndex);
    notifyListeners();
  }

  Future<void> shareEntry(String id, {bool withSubtitles = true}) async {
    final files = <XFile>[];
    final result = File(library!.resultPathFor(id));
    if (result.existsSync()) files.add(XFile(result.path));
    if (withSubtitles) {
      for (final name in ['orig.srt', 'ru.srt']) {
        final f = File('${library!.dirFor(id)}/$name');
        if (f.existsSync()) files.add(XFile(f.path));
      }
    }
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files));
  }
```

- [ ] **Step 2: Написать экран**

Список записей (новые сверху), у каждой: имя исходника, дата, язык,
«реплик N, на проверку M», размер, значок закрепления. Действия: открыть,
поделиться, закрепить, удалить (с подтверждением).

Сверху — поле поиска. Если `spaceWarning`, над списком появляется полоса:

> Занято 1.7 из 2 ГБ. Когда место закончится, у самых старых записей будут
> удалены видео — текст останется. [Освободить место]

Если `lastCleanup` не пуст, показывается сообщение «Освобождено место:
у N записей удалены видео, текст сохранён» с кнопкой «Понятно», которая
очищает `lastCleanup`.

У записи с `mediaRemoved` вместо кнопок «Поделиться» и «Пересобрать» —
надпись «видео удалено, текст сохранён».

- [ ] **Step 3: Проверить на эмуляторе**

Прогнать ролик до конца, убедиться что запись появилась в истории,
поделиться ей, закрепить, выставить в настройках маленький лимит
(например 1 МБ) и убедиться, что предупреждение появляется, очистка
срабатывает, закреплённая запись остаётся, а сообщение о произошедшем
показывается.

- [ ] **Step 4: Коммит**

```bash
git add lib/ui/library_screen.dart lib/app/debug_controller.dart lib/ui/debug_screen.dart
git commit -m "Экран истории обработок с поиском и предупреждением о месте"
```

---

### Task 7: Связать обработку с библиотекой

**Files:**
- Modify: `lib/app/debug_controller.dart`

- [ ] **Step 1: Приём видео через библиотеку**

`setVideo` на мобильных платформах вызывает `library.intake(...)`, работает
с копией и заводит запись; рабочая папка обработки — папка записи.

- [ ] **Step 2: Обновление записи по итогам обработки**

После обработки в записи проставляются `lang`, `cueCount`, `flaggedCount`,
после вшивания — пересчитывается `mediaBytes`. Затем вызывается
`enforceStorageLimit()`.

- [ ] **Step 3: Проверить сквозной путь на эмуляторе**

Ролик из галереи → обработка → правка текста → вшивание → «Поделиться» →
запись видна в истории с верными числами.

- [ ] **Step 4: Коммит**

```bash
git add lib/app/debug_controller.dart
git commit -m "Обработка пишет результат в библиотеку"
```

---

### Task 8: Проверка на настоящем телефоне

Эмулятор не воспроизводит путь «WhatsApp → Поделиться → наше приложение»,
а это самый частый вход. Проверять надо на устройстве.

- [ ] **Step 1:** Поставить APK на телефон, отправить себе видео в WhatsApp.
- [ ] **Step 2:** «Поделиться» → Subtitler. Убедиться, что приложение
      открывается и ролик принят (видно в журнале).
- [ ] **Step 3:** Обработать, вшить, поделиться результатом обратно в WhatsApp.
- [ ] **Step 4:** Проверить, что готового видео **нет в галерее** и оно не
      появилось в облачном бэкапе.
- [ ] **Step 5:** Записать результат в `test/acceptance/README.md`.
