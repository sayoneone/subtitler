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
  /// Папка приложения (на Windows — перемещаемый профиль, Roaming):
  /// журнал, шрифт, настройки, запасные сессии. Всё мелкое.
  final String supportDir;
  final String fontsDir;

  /// Временные файлы обработки: звук, нарезанные сегменты. На Windows —
  /// LocalAppData: в перемещаемом профиле сотни мегабайт звука
  /// синхронизировались бы с сервером при каждом выходе из системы.
  final String workDir;

  /// Запасная папка для готовых файлов, когда рядом с видео писать нельзя.
  /// Тоже LocalAppData: видео с субтитрами весит как исходник.
  final String outputDir;

  const AppRuntime({
    required this.supportDir,
    required this.fontsDir,
    required this.workDir,
    required this.outputDir,
  });

  static Future<AppRuntime> prepare({DebugLog? log}) async {
    final journal = log ?? DebugLog.instance;
    final support = await getApplicationSupportDirectory();
    journal.attachFile(p.join(support.path, 'subtitler.log'));

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
    final cache = await _cacheDirOr(support.path, journal);
    final work = Directory(p.join(cache, 'work'))..createSync(recursive: true);
    final output = Directory(
        p.join(Platform.isAndroid ? support.path : cache, 'output'));

    _removeOldWorkDir(p.join(support.path, 'work'), work.path, journal);

    journal.info('Папка приложения: ${support.path}');
    journal.info('Рабочая папка: ${work.path}');
    return AppRuntime(
      supportDir: support.path,
      fontsDir: fonts.path,
      workDir: work.path,
      outputDir: output.path,
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

  /// Рабочая папка под конкретное видео: имя стабильно, поэтому повторная
  /// обработка того же файла переиспользует уже нарезанные сегменты.
  String workDirFor(String videoPath) {
    final name = p.basenameWithoutExtension(videoPath);
    return p.join(workDir, '${_sanitize(name)}_${stablePathHash(videoPath)}');
  }

  static String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-zА-Яа-я0-9_-]+'), '_');
}
