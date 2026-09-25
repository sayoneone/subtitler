// lib/core/session_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'languages.dart';
import 'models.dart';
import 'path_hash.dart';

/// Читает и пишет `<имя>.subtitler.json`. Если папка с исходником недоступна
/// для записи (вещдок на защищённом носителе), файл уходит в [fallbackDir].
///
/// Рядом с основной сессией могут лежать резервные копии для других языков —
/// `<имя>.subtitler.<язык>.json`. Туда уходит сессия, когда человек меняет
/// язык: вернуться к прежнему варианту можно бесплатно, вместе с правками.
class SessionStore {
  final String fallbackDir;
  SessionStore({required this.fallbackDir});

  String sessionPathFor(String videoPath) => '$videoPath.subtitler.json';

  /// В запасной папке лежат сессии видео со всех носителей, а копии
  /// вещдоков часто называются одинаково («VID_0001.mp4» из разных дел).
  /// Поэтому к имени видео добавлен хеш полного пути: иначе сессия
  /// одного дела молча затирала бы сессию другого — с ручными правками,
  /// а ролик пришлось бы оплачивать заново.
  String fallbackPathFor(String videoPath) =>
      p.join(fallbackDir, '${_fallbackStem(videoPath)}.subtitler.json');

  String backupPathFor(String videoPath, String lang) =>
      '$videoPath.subtitler.$lang.json';

  String fallbackBackupPathFor(String videoPath, String lang) => p.join(
      fallbackDir, '${_fallbackStem(videoPath)}.subtitler.$lang.json');

  /// «VID_0001.mp4.1a2b3c4d»: человек узнаёт видео по началу имени.
  /// Очень длинное имя обрезается: вместе с хешем и хвостом оно упёрлось
  /// бы в предел длины имени файла (255 символов), а уникальность и так
  /// даёт хеш.
  String _fallbackStem(String videoPath) {
    final name = p.basename(videoPath);
    final short = name.length > 100 ? name.substring(0, 100) : name;
    return '$short.${stablePathHash(videoPath)}';
  }

  /// Так запасные файлы называла прежняя версия — только по имени видео.
  /// Они читаются, чтобы не оплачивать уже обработанное заново, но не
  /// пишутся: такой файл общий для всех одноимённых видео.
  String _legacyFallbackPathFor(String videoPath) =>
      p.join(fallbackDir, '${p.basename(videoPath)}.subtitler.json');

  String _legacyFallbackBackupPathFor(String videoPath, String lang) =>
      p.join(fallbackDir, '${p.basename(videoPath)}.subtitler.$lang.json');

  /// Возвращает сессию, только если отпечаток совпал с [actual]; если
  /// подходят и файл рядом с видео, и запасной — более свежий.
  /// Сессии прежних схем читаются (см. [Session.fromJson]).
  Future<Session?> load(String videoPath, SourceFingerprint actual) =>
      _loadFreshest([
        sessionPathFor(videoPath),
        fallbackPathFor(videoPath),
        _legacyFallbackPathFor(videoPath),
      ], actual);

  /// Пишет сессию и возвращает фактический путь.
  Future<String> save(Session session) => _write(
        session,
        sessionPathFor(session.videoPath),
        fallbackPathFor(session.videoPath),
      );

  /// Кладёт [session] в резервную копию для её языка и возвращает путь.
  /// Прежняя копия того же языка заменяется: она старше.
  Future<String> saveBackup(Session session) => _write(
        session,
        backupPathFor(session.videoPath, session.lang),
        fallbackBackupPathFor(session.videoPath, session.lang),
      );

  /// Резервная копия для [lang], если она есть и относится к этому же файлу.
  Future<Session?> loadBackup(
    String videoPath,
    String lang,
    SourceFingerprint actual,
  ) async {
    final session = await _loadFreshest([
      backupPathFor(videoPath, lang),
      fallbackBackupPathFor(videoPath, lang),
      _legacyFallbackBackupPathFor(videoPath, lang),
    ], actual);
    // Копию могли переименовать руками — язык внутри важнее имени файла.
    return session?.lang == lang ? session : null;
  }

  /// Языки, для которых есть резервная копия: меню «Не тот язык?»
  /// помечает их как готовые — переключение бесплатное.
  Future<Set<String>> backupLanguages(
    String videoPath,
    SourceFingerprint actual,
  ) async {
    final found = <String>{};
    for (final lang in kLanguageCodes) {
      if (await loadBackup(videoPath, lang, actual) != null) found.add(lang);
    }
    return found;
  }

  /// Смена языка без оплаты: если для [lang] есть резервная копия, она
  /// становится основной сессией, а [current] уходит в свою копию.
  ///
  /// Возвращает восстановленную сессию или `null`, если копии нет —
  /// тогда ничего не записывается, и распознавать придётся заново
  /// (`Pipeline.process` с `resumeFrom: current`).
  ///
  /// Язык теперь выбран человеком: уверенность сбрасывается в `null`,
  /// вторым языком становится тот, с которого переключились. Пробы обеих
  /// сессий объединяются — за все уже заплачено.
  Future<Session?> swapWithBackup(Session current, String lang) async {
    if (lang == current.lang) return null;
    final backup =
        await loadBackup(current.videoPath, lang, current.fingerprint);
    if (backup == null) return null;

    await saveBackup(current);
    final restored = backup.copyWith(
      langConfidence: null,
      langRunnerUp: current.lang,
      probeTexts: mergeProbeTexts(backup.probeTexts, current.probeTexts),
    );
    await save(restored);
    return restored;
  }

  /// Самая свежая из подходящих сессий по [paths].
  ///
  /// Файл может быть и рядом с видео, и в запасной папке: сессию создали,
  /// пока в папку видео можно было писать, а потом папку записали на диск
  /// или защитили от записи — правки ушли в запасную папку, а файл рядом
  /// с видео остался прежним. Первый попавшийся вернул бы старый текст, и
  /// правки молча пропали бы. Поля времени в схеме нет, поэтому сравнивается
  /// время изменения файла. На Windows Dart отдаёт его с точностью до
  /// секунды (проверено прогоном); при равенстве берётся файл, стоящий в
  /// [paths] раньше, — обычное место рядом с видео.
  Future<Session?> _loadFreshest(
      List<String> paths, SourceFingerprint actual) async {
    Session? freshest;
    DateTime? freshestTime;
    for (final path in paths) {
      final file = File(path);
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) continue;
      final Session session;
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        session = Session.fromJson(json);
      } on FormatException {
        continue; // битый файл или схема новее нашей — как будто сессии нет
      } on TypeError {
        continue;
      }
      if (!session.fingerprint.matches(actual)) continue;
      if (freshestTime == null || stat.modified.isAfter(freshestTime)) {
        freshest = session;
        freshestTime = stat.modified;
      }
    }
    return freshest;
  }

  Future<String> _write(Session session, String primary, String fallback) async {
    final content = const JsonEncoder.withIndent(' ').convert(session.toJson());
    try {
      await _replace(primary, content);
      return primary;
    } on FileSystemException {
      Directory(fallbackDir).createSync(recursive: true);
      await _replace(fallback, content);
      return fallback;
    }
  }

  /// Пишет файл целиком или никак.
  ///
  /// `writeAsString` открывает файл в режиме [FileMode.write], и тот
  /// обнуляется ещё до записи данных. Закрыли окно или программа упала
  /// в этот момент — остаётся пустой файл: сессии «нет», ролик
  /// распознаётся заново за деньги, ручные правки пропали. Поэтому
  /// данные пишутся во временный файл рядом, а на место встают
  /// переименованием: на Windows это `MoveFileExW` с
  /// `MOVEFILE_REPLACE_EXISTING` (runtime/bin/file_win.cc в Dart SDK), в
  /// Unix — `rename`; прежний файл заменяется целиком.
  ///
  /// Переименование отклоняется (код 5), если прежний файл «только для
  /// чтения» или его держит другая программа без права удаления, —
  /// проверено на Windows. Тогда, как и при отказе прямой записи,
  /// сессия уходит в запасную папку, а временный файл удаляется.
  static Future<void> _replace(String path, String content) async {
    final temp = File('$path.tmp');
    try {
      await temp.writeAsString(content, flush: true);
      await temp.rename(path);
    } on FileSystemException {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } on FileSystemException {
        // Не удалось убрать за собой — не повод терять саму запись.
      }
      rethrow;
    }
  }
}

/// Объединяет пробные распознавания двух сессий одного файла.
/// При совпадении реплики берётся текст из [b].
Map<String, Map<int, String>> mergeProbeTexts(
  Map<String, Map<int, String>> a,
  Map<String, Map<int, String>> b,
) {
  final merged = <String, Map<int, String>>{};
  for (final source in [a, b]) {
    for (final entry in source.entries) {
      (merged[entry.key] ??= {}).addAll(entry.value);
    }
  }
  return merged;
}
