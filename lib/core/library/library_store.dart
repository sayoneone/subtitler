import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../logging.dart';
import 'cleanup_policy.dart';
import 'library_entry.dart';

/// Файлы библиотеки: по папке на обработку плюс общий индекс.
///
/// Всё лежит в закрытом хранилище приложения: другие приложения этого не
/// видят, в галерею и облачный бэкап не попадает. Наружу файл уходит
/// только через «Поделиться» — осознанным действием человека.
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
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return const LibraryIndex(entries: []);
      }
      return LibraryIndex.fromJson(decoded);
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
  /// может исчезнуть в любой момент, а исходник нужен потом для пересборки
  /// видео с исправленным текстом.
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

  /// Удаляет видео, оставляя текст, тайминги и перевод.
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

  /// Приводит библиотеку к лимиту и возвращает, что было сделано.
  ///
  /// Вызывающий обязан показать это человеку: молчаливой пропажи видео
  /// быть не должно.
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
