import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/logging.dart';
import '../core/path_hash.dart';

// Хеш пути нужен и ядру (имена сессий в запасной папке), а ядро не
// зависит от Flutter — поэтому он живёт там; здесь только для тех, кто
// привык брать его отсюда.
export '../core/path_hash.dart' show stablePathHash;

const String kFontAsset = 'assets/fonts/NotoSans-Regular.ttf';
const String kFontFamily = 'Noto Sans';

/// Готовит папки, которыми пользуется ядро.
///
/// Шрифт лежит внутри бандла приложения, а libass умеет читать только
/// обычные файлы — поэтому при запуске он выкладывается на диск.
class AppRuntime {
  /// Папка приложения (на Windows — перемещаемый профиль, Roaming): шрифт,
  /// настройки, запасные сессии. Всё мелкое.
  final String supportDir;
  final String fontsDir;

  /// Временные файлы обработки: звук, нарезанные сегменты. На Windows —
  /// LocalAppData: в перемещаемом профиле сотни мегабайт звука
  /// синхронизировались бы с сервером при каждом выходе из системы.
  final String workDir;

  /// Запасная папка для готовых файлов, когда рядом с видео писать нельзя.
  /// Тоже LocalAppData: видео с субтитрами весит как исходник.
  final String outputDir;

  final String? _journalDir;

  /// Где журнал и сохранённые копии журнала. На Windows — LocalAppData,
  /// рядом с рабочей папкой: из перемещаемого профиля журнал уезжал бы
  /// на сервер профилей. Не задана — папка приложения.
  String get logDir => _journalDir ?? supportDir;

  const AppRuntime({
    required this.supportDir,
    required this.fontsDir,
    required this.workDir,
    required this.outputDir,
    String? logDir,
  }) : _journalDir = logDir;

  static Future<AppRuntime> prepare({DebugLog? log}) async {
    final journal = log ?? DebugLog.instance;
    final support = await getApplicationSupportDirectory();
    final cache = await _cacheDirOr(support.path, journal);
    // На Android кеш система чистит сама — журнал сбоя там мог бы пропасть
    // раньше, чем его отправят, поэтому он остаётся среди постоянных
    // файлов, как и раньше.
    final logs = Platform.isAndroid ? support.path : cache;
    journal.attachFile(p.join(logs, 'subtitler.log'));

    final fonts = Directory(p.join(support.path, 'fonts'));
    fonts.createSync(recursive: true);
    final fontFile = File(p.join(fonts.path, p.basename(kFontAsset)));
    final bytes = await rootBundle.load(kFontAsset);
    // Перезаписываем всегда: так обновление приложения обновит и шрифт.
    await fontFile.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    journal.debug('Шрифт распакован: ${fontFile.path} '
        '(${bytes.lengthInBytes} байт)');

    // На Android кеш система чистит сама, когда не хватает места, — готовое
    // видео там пропало бы. Рабочие файлы пусть лежат в кеше, а запасная
    // папка для результата — среди постоянных файлов приложения.
    final work = Directory(p.join(cache, 'work'))..createSync(recursive: true);
    final output = Directory(
        p.join(Platform.isAndroid ? support.path : cache, 'output'));

    _removeOldWorkDir(p.join(support.path, 'work'), work.path, journal);
    _removeOldJournals(support.path, logs, journal);
    // Ждём, а не в фоне: видео, переданное при запуске, откроется сразу
    // после подготовки, и его рабочая папка не должна исчезнуть под ним.
    await removeStaleWorkDirs(work.path, log: journal);

    journal.info('Папка приложения: ${support.path}');
    journal.info('Рабочая папка: ${work.path}');
    return AppRuntime(
      supportDir: support.path,
      fontsDir: fonts.path,
      workDir: work.path,
      outputDir: output.path,
      logDir: logs,
    );
  }

  static Future<String> _cacheDirOr(String fallback, DebugLog log) async {
    try {
      return (await getApplicationCacheDirectory()).path;
    } catch (e) {
      log.warn('Папка для временных файлов недоступна ($e) — '
          'пишем их в папку приложения');
      return fallback;
    }
  }

  /// Прежние версии держали рабочую папку в Roaming. Там могли остаться
  /// сотни мегабайт звука; сессий и правок там нет — только нарезка,
  /// которую при нужде ядро сделает заново. Удаляется в фоне: запуск
  /// программы ждать этого не должен.
  static void _removeOldWorkDir(String old, String current, DebugLog log) {
    if (p.equals(old, current)) return;
    final dir = Directory(old);
    if (!dir.existsSync()) return;
    unawaited(dir.delete(recursive: true).then(
      (_) => log.info('Удалена прежняя рабочая папка: $old'),
      onError: (Object e) =>
          log.warn('Не удалось удалить прежнюю рабочую папку $old: $e'),
    ));
  }

  /// Журналы, которые прежние версии писали в папку приложения (на
  /// Windows — перемещаемый профиль): subtitler.log и subtitler.prev.log,
  /// «Сохранить в файл» версий 0.1.x (subtitler-debug.log) и «Сохранить
  /// журнал» ранних сборок (subtitler-log-*.txt). В них распознанный текст
  /// и полные пути к видео, а профиль уезжает на сервер профилей. Все эти
  /// имена программа выбирала сама, человек свои файлы сюда не кладёт.
  /// Журнал теперь пишется в [logs]; если это та же папка (Android), в ней
  /// текущий журнал — трогать нечего. Удаляется в фоне, как и прежняя
  /// рабочая папка: запуск ждать этого не должен.
  static void _removeOldJournals(String support, String logs, DebugLog log) {
    if (p.equals(support, logs)) return;
    unawaited(() async {
      var removed = 0;
      try {
        await for (final entry in Directory(support).list(followLinks: false)) {
          if (entry is! File || !_oldJournal.hasMatch(p.basename(entry.path))) {
            continue;
          }
          try {
            await entry.delete();
            removed++;
          } on FileSystemException catch (e) {
            // Файл держит ещё открытая прежняя версия — уберём при
            // следующем запуске.
            log.warn('Не удалось удалить прежний журнал: $e');
          }
        }
      } on FileSystemException catch (e) {
        log.warn('Не удалось просмотреть папку приложения: $e');
      }
      if (removed > 0) {
        log.info('Удалены журналы прежних версий из папки приложения: '
            '$removed');
      }
    }());
  }

  static final _oldJournal = RegExp(
      r'^(subtitler\.log|subtitler\.prev\.log|subtitler-debug\.log|'
      r'subtitler-log-[0-9T-]+\.txt)$');

  /// Рабочая папка под конкретное видео: имя стабильно, поэтому повторная
  /// обработка недоделанной сессии переиспользует уже нарезанные сегменты.
  /// Когда распознано всё, нарезку ядро удаляет, а старые папки убирает
  /// [removeStaleWorkDirs].
  String workDirFor(String videoPath) {
    final name = p.basenameWithoutExtension(videoPath);
    return p.join(workDir, '${_sanitize(name)}_${stablePathHash(videoPath)}');
  }

  static String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-zА-Яа-я0-9_-]+'), '_');
}

/// Рабочие папки, которые не трогали дольше этого, удаляются при запуске.
///
/// Нарезка удаляется сама, как только все реплики распознаны, а SRT для
/// вшивания — сразу после сохранения. Остаются они только у недоделанных
/// сессий: обработку отменили, пропала сеть, программу закрыли посреди
/// работы. Нарезка нужна им, чтобы продолжить без повторной нарезки, но и
/// без неё ничего не теряется: распознанное лежит в файле сессии, а ролик
/// нарежется заново — это минуты работы ffmpeg, а не деньги. Неделя
/// покрывает обычный перерыв в работе с роликом (выходные, несколько дней
/// на другом деле); дольше хранить звук из материалов дела незачем.
const Duration kWorkDirMaxAge = Duration(days: 7);

/// Удаляет из [workRoot] рабочие папки видео, в которых ничего не менялось
/// дольше [maxAge]. Возраст считается по самому свежему файлу внутри;
/// папка без файлов — брошенная. Трогает только подпапки [workRoot]:
/// сессии (.subtitler.json), субтитры и видео лежат в других местах и
/// сюда не попадают.
Future<void> removeStaleWorkDirs(
  String workRoot, {
  Duration maxAge = kWorkDirMaxAge,
  DateTime? now,
  DebugLog? log,
}) async {
  final journal = log ?? DebugLog.instance;
  final root = Directory(workRoot);
  if (!root.existsSync()) return;
  final limit = (now ?? DateTime.now()).subtract(maxAge);
  var removed = 0;
  for (final entry in root.listSync(followLinks: false)) {
    if (entry is! Directory) continue;
    try {
      final newest = _newestFileTime(entry);
      if (newest != null && newest.isAfter(limit)) continue;
      await entry.delete(recursive: true);
      removed++;
    } on FileSystemException catch (e) {
      // Файл держит другая программа — уберём при следующем запуске.
      journal.warn('Не удалось удалить старую рабочую папку: $e');
    }
  }
  if (removed > 0) {
    journal.info('Удалено рабочих папок старше ${maxAge.inDays} дн.: $removed');
  }
}

DateTime? _newestFileTime(Directory dir) {
  DateTime? newest;
  for (final entry in dir.listSync(recursive: true, followLinks: false)) {
    if (entry is! File) continue;
    final modified = entry.statSync().modified;
    if (newest == null || modified.isAfter(newest)) newest = modified;
  }
  return newest;
}
