// lib/core/session_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'languages.dart';
import 'models.dart';

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

  String fallbackPathFor(String videoPath) =>
      p.join(fallbackDir, '${p.basename(videoPath)}.subtitler.json');

  String backupPathFor(String videoPath, String lang) =>
      '$videoPath.subtitler.$lang.json';

  String fallbackBackupPathFor(String videoPath, String lang) =>
      p.join(fallbackDir, '${p.basename(videoPath)}.subtitler.$lang.json');

  /// Возвращает сессию, только если отпечаток совпал с [actual].
  /// Сессии прежних схем читаются (см. [Session.fromJson]).
  Future<Session?> load(String videoPath, SourceFingerprint actual) =>
      _loadFirst(
          [sessionPathFor(videoPath), fallbackPathFor(videoPath)], actual);

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
    final session = await _loadFirst([
      backupPathFor(videoPath, lang),
      fallbackBackupPathFor(videoPath, lang),
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

  Future<Session?> _loadFirst(
      List<String> paths, SourceFingerprint actual) async {
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final session = Session.fromJson(json);
        if (!session.fingerprint.matches(actual)) continue;
        return session;
      } on FormatException {
        continue; // битый файл или схема новее нашей — как будто сессии нет
      } on TypeError {
        continue;
      }
    }
    return null;
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
