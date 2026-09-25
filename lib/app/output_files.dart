import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/logging.dart';
import '../core/models.dart';
import '../core/srt.dart';
import 'runtime.dart';

/// Выходной файл открыт другой программой (видеоплеером, чаще всего):
/// заменить его нельзя, пока её не закроют.
class FileBusyException implements Exception {
  final String path;
  const FileBusyException(this.path);

  @override
  String toString() => 'Файл $path открыт в другой программе';
}

/// Коды ошибок Windows, которые означают «файл держит другая программа».
/// 32 — ERROR_SHARING_VIOLATION (файл открыт без общего доступа),
/// 33 — ERROR_LOCK_VIOLATION (заблокирован участок файла).
/// Проверено на этой машине: открытие на дозапись файла, который держит
/// другой процесс, даёт 32, а файла «только для чтения» — 5.
const Set<int> kWindowsSharingViolationCodes = {32, 33};

/// Файл занят другой программой. На Unix обязательных блокировок нет,
/// и такой ошибки не бывает, а те же номера там значат другое (32 — EPIPE).
bool isSharingViolation(FileSystemException e, {bool? windows}) =>
    (windows ?? Platform.isWindows) &&
    kWindowsSharingViolationCodes.contains(e.osError?.errorCode);

/// Имена файлов, которые приложение пишет для одного видео, в одной папке.
///
/// `<имя>_ru.mp4` — видео с вшитыми субтитрами, `<имя>_orig.srt` и
/// `<имя>_ru.srt` — субтитры на языке оригинала и по-русски.
/// `<имя>_ru.partial.mp4` — недоделанное видео: ffmpeg пишет сюда, а под
/// финальное имя файл попадает только после проверки, что субтитры в кадре
/// видны. Иначе битый результат лежал бы рядом с исходником под именем
/// готового.
class OutputNames {
  final String dir;
  final String base;

  const OutputNames({required this.dir, required this.base});

  String get video => p.join(dir, '${base}_ru.mp4');
  String get partialVideo => p.join(dir, '${base}_ru.partial.mp4');
  String get origSrt => p.join(dir, '${base}_orig.srt');
  String get ruSrt => p.join(dir, '${base}_ru.srt');
}

/// Имя без расширения — как у исходного видео.
String outputBaseName(String videoPath) =>
    p.basenameWithoutExtension(videoPath);

/// Файлы рядом с видео.
OutputNames outputNamesBeside(String videoPath) => OutputNames(
      dir: p.dirname(videoPath),
      base: outputBaseName(videoPath),
    );

/// Файлы в запасной папке приложения — когда рядом с видео писать нельзя
/// (вещдок на защищённом носителе, сетевая папка без прав, контролируемый
/// доступ к папкам в Defender).
///
/// У каждого видео своя подпапка: копии вещдоков часто называются
/// одинаково («VID_0001.mp4» из разных дел), и в общей папке результат
/// одного молча заменил бы результат другого. Имя подпапки стабильно между
/// запусками, так что повторное сохранение того же видео попадает туда же.
OutputNames outputNamesInFallback(String videoPath, String fallbackRoot) {
  final base = outputBaseName(videoPath);
  final folder = '${_sanitize(base)}_${stablePathHash(videoPath)}';
  return OutputNames(dir: p.join(fallbackRoot, folder), base: base);
}

String _sanitize(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '_');
  // Очень длинное имя вещдока плюс путь к профилю легко переходят 260
  // символов; внутри своей папки нам хватит и начала имени.
  return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
}

/// Куда в итоге записаны субтитры.
class SrtFiles {
  final OutputNames names;

  /// Рядом с видео писать не удалось — файлы в запасной папке приложения.
  final bool inFallback;

  const SrtFiles({required this.names, required this.inFallback});
}

/// Пишет выходные файлы видео: рядом с ним, а если там нельзя — в
/// запасную папку приложения (§9 спецификации).
class OutputFiles {
  final String videoPath;
  final String fallbackRoot;
  final DebugLog log;
  final bool windows;

  OutputFiles({
    required this.videoPath,
    required this.fallbackRoot,
    DebugLog? log,
    bool? windows,
  })  : log = log ?? DebugLog.instance,
        windows = windows ?? Platform.isWindows;

  OutputNames get beside => outputNamesBeside(videoPath);
  OutputNames get fallback => outputNamesInFallback(videoPath, fallbackRoot);

  /// Пишет оба .srt. Сначала рядом с видео; при отказе в записи — в
  /// запасную папку. Занятый файл ([FileBusyException]) в запасную папку
  /// не уводит: человек закроет программу и повторит, а искать файлы
  /// по двум местам ему не придётся.
  Future<SrtFiles> writeSrts(List<Cue> cues) async {
    final orig = buildSrt(cues, field: SrtField.orig);
    final ru = buildSrt(cues, field: SrtField.ru);
    try {
      await _writePair(beside, orig, ru);
      return SrtFiles(names: beside, inFallback: false);
    } on FileSystemException catch (e) {
      if (isSharingViolation(e, windows: windows)) {
        throw FileBusyException(e.path ?? beside.ruSrt);
      }
      log.warn('Рядом с видео записать субтитры нельзя ($e) — '
          'пишем в папку приложения ${fallback.dir}');
    }
    Directory(fallback.dir).createSync(recursive: true);
    await _writePair(fallback, orig, ru);
    return SrtFiles(names: fallback, inFallback: true);
  }

  Future<void> _writePair(OutputNames names, String orig, String ru) async {
    try {
      await File(names.origSrt).writeAsString(orig, flush: true);
      await File(names.ruSrt).writeAsString(ru, flush: true);
    } on FileSystemException catch (e) {
      // В тексте исключения Dart не всегда указан путь — добавим свой.
      if (e.path == null) {
        throw FileSystemException(e.message, names.ruSrt, e.osError);
      }
      rethrow;
    }
    log.info('Записаны ${names.origSrt} и ${names.ruSrt}');
  }

  /// Можно ли положить готовое видео по пути [path].
  ///
  /// Проверяется ДО вшивания, чтобы не кодировать ролик минутами и только
  /// потом узнать, что файл занят. Занят — [FileBusyException]; нет прав
  /// (файл или папка только на чтение) — `false`, тогда видео уходит в
  /// запасную папку.
  bool canReplace(String path) {
    final file = File(path);
    try {
      if (file.existsSync()) {
        // Дозапись ничего не меняет, но требует тех же прав, что и замена,
        // и не проходит, если файл держит другая программа.
        file.openSync(mode: FileMode.append).closeSync();
        return true;
      }
      // Файла нет — пробуем создать пустышку под временным именем.
      final probe = File('$path.write-test');
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } on FileSystemException catch (e) {
      if (isSharingViolation(e, windows: windows)) throw FileBusyException(path);
      log.warn('Записать $path нельзя: $e');
      return false;
    }
  }

  /// Ставит проверенный файл [from] на место [to].
  ///
  /// Прежний файл удаляется отдельно, до переименования: переименование
  /// поверх занятого файла Windows отклоняет с тем же кодом 5, что и файл
  /// без прав, а удаление — с кодом 32, по которому видно, что файл занят.
  void replace(String from, String to) {
    final target = File(to);
    try {
      if (target.existsSync()) target.deleteSync();
    } on FileSystemException catch (e) {
      if (isSharingViolation(e, windows: windows)) throw FileBusyException(to);
      rethrow;
    }
    File(from).renameSync(to);
  }
}

/// Удаляет файл, если он есть, и молчит об ошибке: это уборка за собой,
/// и падать из-за неё хуже, чем оставить мусор.
void deleteQuietly(String path, {DebugLog? log}) {
  try {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException catch (e) {
    (log ?? DebugLog.instance).warn('Не удалось удалить $path: $e');
  }
}
