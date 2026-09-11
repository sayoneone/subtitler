import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/library/library_entry.dart';
import 'package:subtitler/core/library/library_store.dart';

void main() {
  late Directory root;
  late LibraryStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('library_test_');
    store = LibraryStore(rootDir: root.path);
  });
  tearDown(() => root.deleteSync(recursive: true));

  File fakeVideo(String name, int bytes) =>
      File('${root.path}/$name')..writeAsBytesSync(List.filled(bytes, 7));

  test('Приём копирует видео к себе: системный путь недолговечен', () async {
    final source = fakeVideo('outside.mp4', 2048);
    final entry = await store.intake(
        sourcePath: source.path, sourceName: 'outside.mp4');

    final copied = File(store.sourcePathFor(entry.id));
    expect(copied.existsSync(), isTrue);
    expect(copied.lengthSync(), 2048);
    expect(source.existsSync(), isTrue, reason: 'чужой файл не трогаем');
    expect(entry.sourceName, 'outside.mp4');
    expect(entry.mediaRemoved, isFalse);
    expect(entry.mediaBytes, 2048);
  });

  test('Индекс читается и пишется', () async {
    final source = fakeVideo('a.mp4', 100);
    final entry =
        await store.intake(sourcePath: source.path, sourceName: 'a.mp4');
    await store.save(LibraryIndex(entries: [entry]));

    final loaded = await store.load();
    expect(loaded.entries.single.id, entry.id);
    expect(loaded.entries.single.sourceName, 'a.mp4');
  });

  test('Отсутствующий индекс — пустая библиотека, а не ошибка', () async {
    expect((await store.load()).entries, isEmpty);
  });

  test('Битый индекс не роняет приложение', () async {
    Directory(root.path).createSync(recursive: true);
    File('${root.path}/index.json').writeAsStringSync('{это не json');
    expect((await store.load()).entries, isEmpty);
  });

  test('Удаление видео оставляет текст', () async {
    final source = fakeVideo('a.mp4', 512);
    final entry =
        await store.intake(sourcePath: source.path, sourceName: 'a.mp4');
    File('${store.dirFor(entry.id)}/ru.srt').writeAsStringSync('текст');

    await store.stripMedia(entry.id);

    expect(File(store.sourcePathFor(entry.id)).existsSync(), isFalse);
    expect(File('${store.dirFor(entry.id)}/ru.srt').existsSync(), isTrue,
        reason: 'текст должен пережить очистку места');
  });

  test('Полное удаление стирает папку записи целиком', () async {
    final source = fakeVideo('a.mp4', 100);
    final entry =
        await store.intake(sourcePath: source.path, sourceName: 'a.mp4');
    await store.deleteEntry(entry.id);
    expect(Directory(store.dirFor(entry.id)).existsSync(), isFalse);
  });

  test('Замер считает и исходник, и результат', () async {
    final source = fakeVideo('a.mp4', 300);
    final entry =
        await store.intake(sourcePath: source.path, sourceName: 'a.mp4');
    File(store.resultPathFor(entry.id)).writeAsBytesSync(List.filled(200, 1));
    expect(await store.measure(entry.id), 500);
  });

  test('Очистка по лимиту убирает видео у самой старой и помечает её',
      () async {
    final ids = <String>[];
    for (final name in ['старая', 'свежая']) {
      final src = fakeVideo('$name.mp4', 800);
      final e =
          await store.intake(sourcePath: src.path, sourceName: '$name.mp4');
      ids.add(e.id);
      await store.save(LibraryIndex(
        entries: [
          for (final id in ids)
            (await store.load()).entries.firstWhere(
                  (x) => x.id == id,
                  orElse: () => e,
                ),
        ],
      ));
      // Идентификатор строится из времени — даём часам сдвинуться.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final plan = await store.enforceLimit(limitBytes: 1000);
    expect(plan.idsToStrip.length, 1);
    expect(plan.idsToStrip.single, ids.first, reason: 'убираем самую старую');

    final index = await store.load();
    final stripped = index.entries.firstWhere((e) => e.id == ids.first);
    expect(stripped.mediaRemoved, isTrue);
    expect(stripped.mediaBytes, 0);
    expect(File(store.sourcePathFor(ids.first)).existsSync(), isFalse);
    // У свежей записи видео на месте.
    expect(File(store.sourcePathFor(ids.last)).existsSync(), isTrue);
  });

  test('Пока места хватает, очистка ничего не делает', () async {
    final src = fakeVideo('a.mp4', 100);
    final entry =
        await store.intake(sourcePath: src.path, sourceName: 'a.mp4');
    await store.save(LibraryIndex(entries: [entry]));

    final plan = await store.enforceLimit(limitBytes: 1000);
    expect(plan.isEmpty, isTrue);
    expect(File(store.sourcePathFor(entry.id)).existsSync(), isTrue);
  });
}
